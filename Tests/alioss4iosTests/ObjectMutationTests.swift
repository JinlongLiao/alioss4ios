// Copyright 2026 jinlongliao
// SPDX-License-Identifier: Apache-2.0

import Foundation
import XCTest
@testable import alioss4ios

/// 验证递归操作覆盖的对象范围、分页顺序及复制失败时的持久结果。
final class ObjectMutationTests: XCTestCase {
    private let bucket = StorageBucket(name: "example-bucket")
    private let directory = StorageObject(key: "src/", isDirectory: true)

    func testMoveCapturesPagesBeforeWritingAndStopsBeforeDeleteOnCopyFailure() async throws {
        let storage = RecordingStorage(failCopy: "src/z")
        do {
            _ = try await ObjectMutations.mutateObjects(
                storage: storage, bucket: bucket, source: directory, destination: "target"
            )
            XCTFail("Expected partial copy failure")
        } catch let failure as ObjectMutationFailure {
            XCTAssertEqual(failure.completed, 1)
            XCTAssertEqual(failure.total, 2)
            XCTAssertEqual(failure.key, "src/z")
            XCTAssertFalse(failure.copied)
        }
        let events = await storage.events
        XCTAssertEqual(events, [
            "list:first", "list:next", "copy:src//a→target//a", "delete:src//a", "copy:src/z→target/z",
        ])
    }

    func testMoveIntoOwnDirectoryNeverWrites() async throws {
        let storage = RecordingStorage(failCopy: nil)
        do {
            _ = try await ObjectMutations.mutateObjects(
                storage: storage, bucket: bucket, source: directory, destination: "src/child"
            )
            XCTFail("Expected recursive destination to be rejected")
        } catch is BrowserError {
            let events = await storage.events
            XCTAssertEqual(events, ["list:first", "list:next"])
        }
    }
}

/// 可追踪的服务端替身，每页给出独立游标和不做路径归一化的对象名。
private actor RecordingStorage: ObjectStorage {
    let failCopy: String?
    var events: [String] = []

    init(failCopy: String?) {
        self.failCopy = failCopy
    }

    func listBuckets() async throws -> [StorageBucket] {
        []
    }

    func listObjects(
        bucket: StorageBucket, prefix: String, cursor: String?, delimiter: String?, pageSize: Int
    ) async throws -> StoragePage {
        XCTAssertEqual(prefix, "src/")
        XCTAssertNil(delimiter)
        events.append("list:" + (cursor ?? "first"))
        let key = cursor == nil ? "src//a" : "src/z"
        return StoragePage(
            objects: [StorageObject(key: key, isDirectory: false, etag: "source-etag")],
            next: cursor == nil ? "next" : nil
        )
    }

    func uploadObject(bucket: StorageBucket, key: String, file: URL) async throws {
        XCTFail("Unexpected upload")
    }

    func deleteObject(bucket: StorageBucket, key: String, etag: String?) async throws {
        XCTAssertEqual(etag, "source-etag")
        events.append("delete:" + key)
    }

    func copyObject(bucket: StorageBucket, source: StorageObject, destination: String) async throws {
        events.append("copy:" + source.key + "→" + destination)
        if source.key == failCopy { throw BrowserError.message("目标冲突") }
    }

    func signDownload(bucket: StorageBucket, key: String, expiry: TimeInterval) async throws -> URL {
        throw BrowserError.message("Unexpected download")
    }
}
