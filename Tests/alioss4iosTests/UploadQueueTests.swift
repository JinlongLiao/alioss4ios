// Copyright 2026 jinlongliao
// SPDX-License-Identifier: Apache-2.0

import Foundation
import XCTest
@testable import alioss4ios

/// 通过持久化历史复现第二片失败后的进程重启，检查已确认分片不会重传。
final class UploadQueueTests: XCTestCase {
    @MainActor
    func testMultipartUploadResumesFromDurableReceipt() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appending(path: "object.bin")
        let journal = directory.appending(path: "history.json")
        try Data().write(to: source)
        let file = try FileHandle(forWritingTo: source)
        try file.truncate(atOffset: 8 * 1024 * 1024 + 37)
        try file.close()
        let storage = InterruptedMultipartStorage()
        let profile = StorageProfile(name: "Test", region: "cn-hangzhou")
        let first = UploadQueue(journal: journal, makeStorage: { _ in storage })
        first.loadUploadHistory()
        first.enqueueUploadFiles([source], profile: profile, bucket: StorageBucket(name: "bucket"), prefix: "dir/")
        let failed = try await awaitUploadStatus(.failed, from: first)
        XCTAssertEqual(failed.uploadID, "upload-1")
        XCTAssertEqual(failed.parts.map(\.number), [1])

        let restarted = UploadQueue(journal: journal, makeStorage: { _ in storage })
        restarted.loadUploadHistory()
        let restored = try XCTUnwrap(restarted.records.first)

        restarted.resumeUpload(restored, profile: profile)
        let completed = try await awaitUploadStatus(.completed, from: restarted)
        XCTAssertEqual(completed.parts.map(\.number), [1, 2])

        // 设置或文件页切换期间，界面可能仍持有恢复前的记录。
        restarted.resumeUpload(restored, profile: profile)
        XCTAssertEqual(restarted.records.first?.status, .completed)
        XCTAssertNil(restarted.activeID)

        let events = await storage.events
        XCTAssertEqual(events, ["begin", "part:1", "part:2", "part:2", "complete"])

        // 单独恢复先前的失败历史，验证变更过的源文件无法发送旧会话的分片。
        let staleJournal = directory.appending(path: "stale-history.json")
        try JSONEncoder().encode([failed]).write(to: staleJournal)
        let changedSource = try FileHandle(forWritingTo: source)
        try changedSource.truncate(atOffset: UInt64(restored.size + 1))
        try changedSource.close()
        let rejectedQueue = UploadQueue(journal: staleJournal, makeStorage: { _ in storage })
        rejectedQueue.loadUploadHistory()
        rejectedQueue.resumeUpload(failed, profile: profile)
        let rejected = try await awaitUploadStatus(.failed, from: rejectedQueue)
        XCTAssertEqual(rejected.parts, restored.parts)
        XCTAssertEqual(rejected.uploadID, restored.uploadID)
        let eventsAfterRejection = await storage.events
        XCTAssertEqual(eventsAfterRejection, events)
    }

    /// 重启时只接受当前会话的下一片，重复和旧会话回调不得增加进度。
    @MainActor
    func testRecoveredSystemReceiptPersistsOnce() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = directory.appending(path: "history.json")
        let record = UploadRecord(
            id: UUID(), profileID: UUID(), provider: .s3, region: "us-east-1", endpoint: "",
            pathStyle: false, target: UploadTarget(bucket: StorageBucket(name: "bucket"), key: "object"),
            name: "object", source: Data(), size: 9 * 1024 * 1024, modifiedAt: Date(),
            status: .running, uploadID: "current"
        )
        let single = UploadRecord(
            id: UUID(), profileID: UUID(), provider: .s3, region: "us-east-1", endpoint: "",
            pathStyle: false, target: record.target, name: "small", source: Data(), size: 42,
            modifiedAt: Date(), status: .running
        )
        try JSONEncoder().encode([record, single]).write(to: journal)
        let storage = InterruptedMultipartStorage()
        let queue = UploadQueue(journal: journal, makeStorage: { _ in storage })
        let first = UploadPartReceipt(number: 1, etag: "confirmed")
        queue.recordRecoveredUploadPart(recordID: record.id, uploadID: "stale", receipt: first)
        queue.recordRecoveredUploadPart(
            recordID: record.id, uploadID: "current", receipt: .init(number: 2, etag: "out-of-order")
        )
        XCTAssertTrue(try XCTUnwrap(queue.records.first).parts.isEmpty)
        queue.recordRecoveredUploadPart(recordID: record.id, uploadID: "current", receipt: first)
        queue.recordRecoveredUploadPart(recordID: record.id, uploadID: "current", receipt: first)
        let saved = try XCTUnwrap(JSONDecoder().decode([UploadRecord].self, from: Data(contentsOf: journal)).first)
        XCTAssertEqual(saved.status, .paused)
        XCTAssertEqual(saved.parts, [first])
        queue.recordRecoveredSingleUpload(recordID: record.id)
        XCTAssertEqual(queue.records.first?.status, .paused)
        queue.resumeUpload(record, profile: StorageProfile(id: record.profileID, provider: .s3, region: "us-east-1"))
        queue.resumeUpload(single, profile: StorageProfile(id: single.profileID, provider: .s3, region: "us-east-1"))
        XCTAssertEqual(queue.records.last?.status, .queued)
        // 继续后尚未启动的任务可接受旧进程的成功 PUT 回执。
        queue.recordRecoveredSingleUpload(recordID: single.id)
        let reloaded = UploadQueue(journal: journal)
        reloaded.loadUploadHistory()
        XCTAssertEqual(reloaded.records.last?.status, .completed)
        XCTAssertEqual(reloaded.records.last?.uploadedBytes, 42)
        _ = try await awaitUploadStatus(.failed, from: queue)
        let events = await storage.events
        XCTAssertTrue(events.isEmpty)
    }

    /// 远端清理未确认时保留断点，重试确认后清除断点和旧错误提示。
    @MainActor
    func testDiscardPreservesCheckpointUntilRemoteCleanupSucceeds() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = directory.appending(path: "history.json")
        let profile = StorageProfile(name: "Test", region: "cn-hangzhou")
        var record = UploadRecord(
            id: UUID(), profileID: profile.id, provider: .oss, region: profile.region, endpoint: "",
            pathStyle: false, target: UploadTarget(bucket: StorageBucket(name: "bucket"), key: "dir/object.bin"),
            name: "object.bin", source: Data(), size: 9 * 1024 * 1024, modifiedAt: Date(),
            status: .paused, uploadID: "upload-1"
        )
        record.parts = [UploadPartReceipt(number: 1, etag: "etag-1")]
        try JSONEncoder().encode([record]).write(to: journal)
        let storage = InterruptedMultipartStorage(failFirstAbort: true)
        let queue = UploadQueue(journal: journal, makeStorage: { _ in storage })
        queue.loadUploadHistory()
        await queue.discardUpload(record, profile: profile)
        let preserved = try XCTUnwrap(JSONDecoder().decode([UploadRecord].self, from: Data(contentsOf: journal)).first)
        XCTAssertEqual(preserved.status, .paused)
        XCTAssertEqual(preserved.uploadID, record.uploadID)
        XCTAssertEqual(preserved.parts, record.parts)
        XCTAssertNotNil(queue.notice)
        await queue.discardUpload(record, profile: profile)
        let cleaned = try XCTUnwrap(JSONDecoder().decode([UploadRecord].self, from: Data(contentsOf: journal)).first)
        XCTAssertEqual(cleaned.status, .discarded)
        XCTAssertNil(cleaned.uploadID)
        XCTAssertTrue(cleaned.parts.isEmpty)
        XCTAssertNil(queue.notice)
        let events = await storage.events
        XCTAssertEqual(events, ["abort:upload-1", "abort:upload-1"])
    }

    /// 使用有界等待，队列停滞就明确失败。
    @MainActor
    private func awaitUploadStatus(
        _ status: UploadRecord.Status, from queue: UploadQueue
    ) async throws -> UploadRecord {
        for _ in 0..<200 {
            if let record = queue.records.first, record.status == status { return record }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw BrowserError.message("上传队列未到达预期状态。")
    }
}

/// 服务端替身记录请求顺序，第二片仅首次请求失败。
private actor InterruptedMultipartStorage: MultipartStorage {
    var events: [String] = []
    var hasFailed = false
    private var failFirstAbort: Bool?

    init(failFirstAbort: Bool? = nil) {
        self.failFirstAbort = failFirstAbort
    }

    func beginMultipartUpload(target: UploadTarget) async throws -> String {
        XCTAssertEqual(target.key, "dir/object.bin")
        events.append("begin")
        return "upload-1"
    }

    func uploadPart(target: UploadTarget, uploadID: String, file: URL, number: Int) async throws -> UploadPartReceipt {
        XCTAssertEqual(uploadID, "upload-1")
        let length = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize
        XCTAssertEqual(length, number == 1 ? 8 * 1024 * 1024 : 37)
        events.append("part:\(number)")
        if number == 2 && !hasFailed {
            hasFailed = true
            throw BrowserError.message("模拟第二片中断")
        }
        return UploadPartReceipt(number: number, etag: "etag-\(number)")
    }

    func completeMultipartUpload(target: UploadTarget, uploadID: String, parts: [UploadPartReceipt]) async throws {
        XCTAssertEqual(parts.map(\.etag), ["etag-1", "etag-2"])
        events.append("complete")
    }

    func abortMultipartUpload(target: UploadTarget, uploadID: String) async throws {
        guard let failFirstAbort else { XCTFail("Unexpected abort"); return }
        events.append("abort:" + uploadID)
        if failFirstAbort {
            self.failFirstAbort = false
            throw BrowserError.message("模拟清理失败")
        }
    }
    func listBuckets() async throws -> [StorageBucket] { [] }

    func listObjects(
        bucket: StorageBucket, prefix: String, cursor: String?, delimiter: String?, pageSize: Int
    ) async throws -> StoragePage {
        StoragePage(objects: [], next: nil)
    }

    func uploadObject(bucket: StorageBucket, key: String, file: URL) async throws {
        XCTFail("Unexpected single upload")
    }
    func deleteObject(bucket: StorageBucket, key: String, etag: String?) async throws { XCTFail("Unexpected delete") }

    func copyObject(bucket: StorageBucket, source: StorageObject, destination: String) async throws {
        XCTFail("Unexpected copy")
    }

    func signDownload(bucket: StorageBucket, key: String, expiry: TimeInterval) async throws -> URL {
        throw BrowserError.message("Unexpected download")
    }
}
