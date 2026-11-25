// Copyright 2026 jinlongliao
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Observation
#if os(iOS)
import UIKit
#endif

/// 本地上传历史不含账号凭据，已提交分片仅在服务端返回 ETag 后写入。
struct UploadRecord: Codable, Identifiable {
    enum Status: String, Codable {
        case queued, running, paused, failed, completed, discarded
    }

    let id: UUID
    let profileID: UUID
    let provider: StorageProvider
    let region: String
    let endpoint: String
    let pathStyle: Bool
    let target: UploadTarget
    let name: String
    let source: Data
    let size: Int
    let modifiedAt: Date
    var status: Status = .queued
    var uploadID: String?
    var parts: [UploadPartReceipt] = []
    var message = ""

    /// 分片至少 8 MiB，较大文件提高片长以保持不超过两个供应商的 10000 片上限。
    var partSize: Int {
        let minimum = 8 * 1024 * 1024
        return max(minimum, size / 10_000 + (size % 10_000 == 0 ? 0 : 1))
    }

    var uploadedBytes: Int {
        status == .completed ? size : min(size, parts.count * partSize)
    }

    func matchesProfile(_ profile: StorageProfile) -> Bool {
        profile.id == profileID && profile.provider == provider && profile.region == region
            && profile.endpoint == endpoint && profile.forcePathStyle == pathStyle
    }
}

/// 使用单个执行者串行处理队列；切换页面不影响任务，进程重启后从已落盘分片恢复。
@MainActor
@Observable
final class UploadQueue {
    static let shared = UploadQueue()

    private(set) var records: [UploadRecord] = []
    private(set) var lastCompleted: UploadRecord?
    private(set) var notice: String?
    private(set) var activeID: UUID?
    private(set) var discardingIDs: Set<UUID> = []

    /// 当前文件的发送量只用于 UI，服务端确认后才会写入上传历史。
    private var inFlightBytes = 0
    private var inFlightRequestID: UUID?

    /// 限制未确认字节的显示范围，避免回调超出文件大小或提前显示完成。
    func displayedUploadBytes(for record: UploadRecord) -> Int {
        if record.status == .completed { return max(1, record.size) }
        let confirmed = record.uploadedBytes
        guard record.id == activeID, record.status == .running else { return confirmed }
        return confirmed + min(inFlightBytes, max(0, record.size - confirmed - 1))
    }

    private var loaded = false
    private var activeTask: Task<Void, Never>?
    #if os(iOS)
    /// 仅为已开始的传输持有系统后台执行许可。
    private var backgroundUploadTask: UIBackgroundTaskIdentifier = .invalid
    /// 首次调度先接收上一进程的系统回执，再从最新历史选择待运行任务。
    private var recoveringSystemUploads = false
    private var recoveredSystemUploads = false
    #endif
    private var queuedProfiles: [UUID: StorageProfile] = [:]
    private let journal: URL
    private let makeStorage: (StorageProfile) -> any MultipartStorage

    init(
        journal: URL = URL.applicationSupportDirectory
            .appending(path: "alioss4ios", directoryHint: .isDirectory)
            .appending(path: "uploads.json"),
        makeStorage: @escaping (StorageProfile) -> any MultipartStorage = { $0.makeStorage() }
    ) {
        self.journal = journal
        self.makeStorage = makeStorage
    }

    /// 恢复历史后将曾运行或待运行的任务置为暂停，等待用户明确继续。
    func loadUploadHistory() {
        guard !loaded else { return }
        do {
            if FileManager.default.fileExists(atPath: journal.path) {
                let saved = try JSONDecoder().decode([UploadRecord].self, from: Data(contentsOf: journal))
                try saveUploadHistory(saved.map { record in
                    var updated = record
                    if record.status == .queued || record.status == .running { updated.status = .paused }
                    return updated
                })
            }
            loaded = true
        } catch {
            notice = appText("无法读取上传历史，暂停新建和修改任务。")
        }
    }

    /// 进程重启后保存系统交付的分片结果。已重试、撤销或完成的记录不接受旧回调。
    func recordRecoveredUploadPart(recordID: UUID, uploadID: String, receipt: UploadPartReceipt) {
        loadUploadHistory()
        guard let record = records.first(where: { $0.id == recordID }),
              (record.status == .paused || record.status == .queued), !discardingIDs.contains(recordID),
              activeID != recordID,
              record.uploadID == uploadID, record.uploadedBytes < record.size,
              receipt.number == record.parts.count + 1, !receipt.etag.isEmpty else { return }
        editUploadRecord(recordID) { $0.parts.append(receipt) }
    }

    /// 直接 PUT 的成功回执对应整个对象。只收尾仍在等待恢复的原任务。
    func recordRecoveredSingleUpload(recordID: UUID) {
        loadUploadHistory()
        guard let record = records.first(where: { $0.id == recordID }),
              (record.status == .paused || record.status == .queued), activeID != recordID,
              !discardingIDs.contains(recordID),
              record.uploadID == nil, record.size < record.partSize else { return }
        if editUploadRecord(recordID, { $0.status = .completed; $0.message = "" }) {
            queuedProfiles[recordID] = nil
            lastCompleted = record
        }
    }

    /// 解析本地文件时记录书签和源文件属性，写入历史后才允许调度。
    func enqueueUploadFiles(
        _ files: [URL], profile: StorageProfile, bucket: StorageBucket, prefix: String
    ) {
        guard loaded else { return }
        do {
            var updated = records
            var added: [UUID] = []
            for file in files {
                let scoped = file.startAccessingSecurityScopedResource()
                defer { if scoped { file.stopAccessingSecurityScopedResource() } }
                let metadata = try readUploadSourceMetadata(file)
                let name = file.lastPathComponent
                let target = UploadTarget(bucket: bucket, key: prefix + name)
                if updated.contains(where: {
                    $0.profileID == profile.id && $0.target == target
                        && $0.status != .completed && $0.status != .discarded
                }) {
                    throw BrowserError.message(String(format: appText("目标 %@ 已有上传任务。"), target.key))
                }
                #if os(macOS)
                let bookmark = try file.bookmarkData(options: .minimalBookmark)
                #else
                let bookmark = try file.bookmarkData()
                #endif
                let id = UUID()
                updated.append(UploadRecord(
                    id: id, profileID: profile.id, provider: profile.provider, region: profile.region,
                    endpoint: profile.endpoint, pathStyle: profile.forcePathStyle, target: target,
                    name: name, source: bookmark, size: metadata.size, modifiedAt: metadata.modifiedAt
                ))
                added.append(id)
            }
            try saveUploadHistory(updated)
            added.forEach { queuedProfiles[$0] = profile }
            notice = nil
            scheduleNextUpload()
        } catch {
            notice = (error as? BrowserError)?.localizedDescription ?? appText("无法准备上传任务。")
        }
    }

    /// 待执行任务可立即暂停。运行中任务要等当前请求收尾，迟到的已确认分片仍可保存。
    func pauseUpload(_ record: UploadRecord) {
        if activeID == record.id {
            activeTask?.cancel()
        } else if records.first(where: { $0.id == record.id })?.status == .queued,
                  editUploadRecord(record.id, { $0.status = .paused }) {
            queuedProfiles[record.id] = nil
        }
    }

    /// 以队列的当前记录为准，防止界面旧快照使已完成任务重新排队。
    func resumeUpload(_ record: UploadRecord, profile: StorageProfile?) {
        guard let current = records.first(where: { $0.id == record.id }),
              activeID != current.id, !discardingIDs.contains(current.id),
              current.status == .paused || current.status == .failed else { return }
        guard let profile, current.matchesProfile(profile) else {
            notice = appText("原账号或连接设置已变更，无法继续上传。")
            return
        }
        if editUploadRecord(current.id, {
            $0.status = .queued
            $0.message = ""
        }) {
            queuedProfiles[current.id] = profile
            notice = nil
            scheduleNextUpload()
        }
    }

    /// 清理暂停的上传会话。只有收到服务端确认后才移除本地断点。
    func discardUpload(_ record: UploadRecord, profile: StorageProfile?) async {
        guard let current = records.first(where: { $0.id == record.id }),
              current.status == .failed || current.status == .paused,
              activeID != current.id, discardingIDs.insert(current.id).inserted else { return }
        defer { discardingIDs.remove(current.id) }
        do {
            if let uploadID = current.uploadID {
                guard let profile, current.matchesProfile(profile) else {
                    throw BrowserError.message(appText("请恢复原账号后清理服务端分片。"))
                }
                try await makeStorage(profile).abortMultipartUpload(target: current.target, uploadID: uploadID)
            }
            if editUploadRecord(record.id, {
                $0.status = .discarded
                $0.uploadID = nil
                $0.parts = []
                $0.message = ""
            }) {
                notice = nil
            }
        } catch {
            notice = appText("服务端分片清理未确认，已保留任务记录。")
        }
    }

    /// 仅移除已完成或已确认撤销的任务记录。
    func clearFinishedUploads() {
        guard loaded else { return }
        do {
            try saveUploadHistory(records.filter { $0.status != .completed && $0.status != .discarded })
        } catch {
            notice = appText("无法清理本地上传历史。")
        }
    }

    #if os(iOS)
    /// 回到前台时继续原队列。已暂停的任务仍由用户选择是否恢复。
    func resumeUploadScheduling() {
        scheduleNextUpload()
    }

    /// 准备分片和合并对象需要应用执行时间。交由系统传输的分片在许可到期后继续。
    private func beginBackgroundUploadExecution(for id: UUID) {
        backgroundUploadTask = UIApplication.shared.beginBackgroundTask(withName: "Object upload") { [weak self] in
            guard let self, self.activeID == id else { return }
            if !BackgroundPartTransfer.shared.hasInFlightPart { self.activeTask?.cancel() }
            self.endBackgroundUploadExecution()
        }
    }

    /// 正常收尾和系统到期共享同一个幂等释放入口。
    private func endBackgroundUploadExecution() {
        guard backgroundUploadTask != .invalid else { return }
        let task = backgroundUploadTask
        backgroundUploadTask = .invalid
        UIApplication.shared.endBackgroundTask(task)
    }
    #endif

    /// 先保存运行状态再启动网络执行，避免重入产生两个执行者。
    private func scheduleNextUpload() {
        #if os(iOS)
        // 后台只收尾已开始的任务，避免在系统准备挂起时打开新的上传会话。
        guard UIApplication.shared.applicationState != .background else { return }
        if !recoveredSystemUploads {
            guard !recoveringSystemUploads, records.contains(where: { $0.status == .queued }) else { return }
            recoveringSystemUploads = true
            Task {
                await BackgroundPartTransfer.shared.recoverExistingUploads()
                recoveringSystemUploads = false
                recoveredSystemUploads = true
                scheduleNextUpload()
            }
            return
        }
        #endif
        guard activeTask == nil,
              let record = records.first(where: { $0.status == .queued }),
              let profile = queuedProfiles[record.id] else { return }
        guard editUploadRecord(record.id, { $0.status = .running }) else { return }
        queuedProfiles[record.id] = nil
        activeID = record.id
        activeTask = Task {
            #if os(iOS)
            beginBackgroundUploadExecution(for: record.id)
            #endif
            defer {
                #if os(iOS)
                endBackgroundUploadExecution()
                #endif
                activeTask = nil
                activeID = nil
                scheduleNextUpload()
            }
            await transferUpload(record, storage: makeStorage(profile))
        }
    }

    /// 恢复时重新验证本地文件。成功远端合并后才标记完成并通知浏览页面。
    private func transferUpload(_ record: UploadRecord, storage: any MultipartStorage) async {
        do {
            var stale = false
            let file = try URL(resolvingBookmarkData: record.source, bookmarkDataIsStale: &stale)
            let scoped = file.startAccessingSecurityScopedResource()
            defer { if scoped { file.stopAccessingSecurityScopedResource() } }
            try validateSource(file, record: record)
            try Task.checkCancellation()
            if record.size < record.partSize {
                try await transferSingleUpload(storage: storage, record: record, file: file)
            } else {
                try await transferUploadParts(record, file: file, storage: storage)
            }
            if editUploadRecord(record.id, { $0.status = .completed; $0.message = "" }) {
                lastCompleted = record
            }
        } catch {
            let interrupted = Task.isCancelled
            let description = (error as? BrowserError)?.localizedDescription
                ?? appText("上传未确认完成。可继续任务，或刷新远端目录核对目标对象。")
            editUploadRecord(record.id) {
                $0.status = interrupted ? .paused : .failed
                $0.message = interrupted ? "" : description
            }
        }
    }

    /// 小文件保留直接 PUT，签名包含防覆盖条件，再由系统从同一份暂存文件发送。
    private func transferSingleUpload(storage: any MultipartStorage, record: UploadRecord, file: URL) async throws {
        guard let signer = storage as? any BackgroundUploadSigning else {
            try await storage.uploadObject(bucket: record.target.bucket, key: record.target.key, file: file)
            return
        }
        try await storage.validateNonOverwritingWrites(bucket: record.target.bucket)
        let staged = try await stageUploadPart(file, offset: 0, length: record.size)
        defer { try? FileManager.default.removeItem(at: staged) }
        try validateSource(file, record: record)
        let request = try await signer.signUpload(bucket: record.target.bucket, key: record.target.key)
        _ = try await transferSignedFile(from: staged, request: request, record: record)
    }

    /// 同一个上传 ID 下复用确认的分片。若落盘失败，重试会重传同一分片序号。
    private func transferUploadParts(
        _ record: UploadRecord, file: URL, storage: any MultipartStorage
    ) async throws {
        let uploadID: String
        if let savedID = record.uploadID {
            uploadID = savedID
        } else {
            uploadID = try await storage.beginMultipartUpload(target: record.target)
            guard editUploadRecord(record.id, { $0.uploadID = uploadID }) else {
                try? await storage.abortMultipartUpload(target: record.target, uploadID: uploadID)
                throw BrowserError.message(appText("无法保存上传断点。"))
            }
        }

        var receipts = record.parts
        var offset = record.uploadedBytes
        while offset < record.size {
            try Task.checkCancellation()
            try validateSource(file, record: record)
            let length = min(record.partSize, record.size - offset)
            let partFile = try await stageUploadPart(file, offset: offset, length: length)
            defer { try? FileManager.default.removeItem(at: partFile) }
            try validateSource(file, record: record)
            try Task.checkCancellation()
            let number = receipts.count + 1
            let receipt = try await transferUploadPart(
                storage: storage, record: record, uploadID: uploadID, file: partFile, number: number
            )
            receipts.append(receipt)
            guard editUploadRecord(record.id, { $0.parts = receipts }) else {
                throw BrowserError.message(appText("无法保存已经上传的分片，请继续任务重试。"))
            }
            offset += length
        }

        try validateSource(file, record: record)
        try Task.checkCancellation()
        try await storage.completeMultipartUpload(target: record.target, uploadID: uploadID, parts: receipts)
    }

    /// 使用当前上传会话发送一片，只接受带 ETag 的成功响应。
    private func transferUploadPart(
        storage: any MultipartStorage, record: UploadRecord, uploadID: String, file: URL, number: Int
    ) async throws -> UploadPartReceipt {
        guard let signer = storage as? any BackgroundUploadSigning else {
            return try await storage.uploadPart(target: record.target, uploadID: uploadID, file: file, number: number)
        }
        let request = try await signer.signUploadPart(target: record.target, uploadID: uploadID, number: number)
        let etag = try await transferSignedFile(
            from: file, request: request, record: record, uploadID: uploadID, number: number
        )
        guard let etag, !etag.isEmpty else { throw BrowserError.message(appText("服务未确认分片完成。")) }
        return UploadPartReceipt(number: number, etag: etag)
    }

    /// iOS 优先交给系统后台会话。Mac 和后台会话启动失败时，从同一文件发送同一个签名请求。
    private func transferSignedFile(
        from file: URL, request: URLRequest, record: UploadRecord, uploadID: String? = nil, number: Int? = nil
    ) async throws -> String? {
        try Task.checkCancellation()
        let requestID = UUID()
        inFlightRequestID = requestID
        defer {
            inFlightRequestID = nil
            inFlightBytes = 0
        }
        let length = number == nil ? record.size : record.partSize
        #if os(iOS)
        do {
            let etag = try await BackgroundPartTransfer.shared.uploadPart(
                from: file, request: request, part: .init(recordID: record.id, uploadID: uploadID, number: number)
            ) { [weak self] bytesSent in
                self?.updateSentUploadBytes(bytesSent, limit: length, requestID: requestID)
            }
            if backgroundUploadTask == .invalid { beginBackgroundUploadExecution(for: record.id) }
            return etag
        } catch let error as URLError where error.code == .unknown {
            // 同一分片可重传，直接 PUT 继续使用原防覆盖签名。
            try Task.checkCancellation()
            inFlightBytes = 0
            if backgroundUploadTask == .invalid { beginBackgroundUploadExecution(for: record.id) }
        }
        #endif
        let response = try await ObjectTransfer.uploadSignedFile(file, with: request) { [weak self] bytesSent in
            Task { @MainActor in
                self?.updateSentUploadBytes(bytesSent, limit: length, requestID: requestID)
            }
        }
        return response.value(forHTTPHeaderField: "ETag")
    }

    /// 忽略已取消或已完成请求的迟到回调，避免覆盖下一文件的显示进度。
    private func updateSentUploadBytes(_ bytesSent: Int64, limit: Int, requestID: UUID) {
        guard inFlightRequestID == requestID else { return }
        inFlightBytes = min(limit, max(0, Int(clamping: bytesSent)))
    }

    /// 检查源文件类型、长度及修改时间，避免继续上传已经换内容的源文件。
    private func validateSource(_ file: URL, record: UploadRecord) throws {
        let metadata = try readUploadSourceMetadata(file)
        guard metadata.size == record.size, metadata.modifiedAt == record.modifiedAt else {
            throw BrowserError.message(appText("源文件已变化，请放弃旧任务后重新选择文件。"))
        }
    }

    /// 直接读取文件属性，避免 URL.resourceValues 复用上一次检查的缓存值。
    private func readUploadSourceMetadata(_ file: URL) throws -> (size: Int, modifiedAt: Date) {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber,
              let modifiedAt = attributes[.modificationDate] as? Date else {
            throw BrowserError.message(appText("请选择可读取的普通文件。"))
        }
        return (size.intValue, modifiedAt)
    }

    /// 原子写完整历史。UI 只发布成功持久化的新状态。
    @discardableResult
    private func editUploadRecord(_ id: UUID, _ update: (inout UploadRecord) -> Void) -> Bool {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return false }
        do {
            var updated = records
            update(&updated[index])
            try saveUploadHistory(updated)
            return true
        } catch {
            notice = appText("无法保存本地上传记录。")
            return false
        }
    }

    /// 同目录临时替换防止中断时破坏完整历史。
    private func saveUploadHistory(_ records: [UploadRecord]) throws {
        try FileManager.default.createDirectory(
            at: journal.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try JSONEncoder().encode(records).write(to: journal, options: .atomic)
        self.records = records
    }
}

/// 将指定范围写入临时文件，分片再大也只在内存中保留 1 MiB。
private func stageUploadPart(_ source: URL, offset: Int, length: Int) async throws -> URL {
    let staging = Task.detached(priority: .utility) {
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        do {
            try Data().write(to: file, options: .withoutOverwriting)
            let input = try FileHandle(forReadingFrom: source)
            defer { try? input.close() }
            let output = try FileHandle(forWritingTo: file)
            defer { try? output.close() }
            try input.seek(toOffset: UInt64(offset))
            var remaining = length
            while remaining > 0 {
                try Task.checkCancellation()
                guard let bytes = try input.read(upToCount: min(remaining, 1024 * 1024)), !bytes.isEmpty else {
                    throw BrowserError.message(appText("源文件读取不完整。"))
                }
                try output.write(contentsOf: bytes)
                remaining -= bytes.count
            }
            return file
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
    }
    return try await withTaskCancellationHandler {
        try await staging.value
    } onCancel: {
        staging.cancel()
    }
}
