// Copyright 2026 jinlongliao
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// 一次批量操作停止时提供完整进度，便于用户核对远端部分成功。
struct ObjectMutationFailure: LocalizedError {
    let completed: Int
    let total: Int
    let key: String
    let copied: Bool
    let underlying: Error

    var errorDescription: String? {
        let remaining = copied ? "此对象已确认复制，源对象仍需核对。" : "请检查权限、同名冲突和对象状态。"
        return "已完成 \(completed)/\(total)，在 \(key) 停止。\(remaining)"
    }
}

/// 使用目录快照规划递归写入，防止边分页边删除造成漏项。
enum ObjectMutations {
    /// 完整读取源前缀并验证目标后按顺序执行。复制未确认或任务取消时保留源对象。
    static func mutateObjects(
        storage: any ObjectStorage,
        bucket: StorageBucket,
        source: StorageObject,
        destination: String?
    ) async throws -> Int {
        let entries = try await snapshotObjects(storage: storage, bucket: bucket, source: source)
        let targets = try destination.map { try planMoveTargets(source: source, entries: entries, destination: $0) }
        if let unidentified = entries.first(where: { $0.etag?.isEmpty != false }) {
            throw BrowserError.message(String(format: appText("对象 %@ 缺少 ETag，请刷新后重试。"), unidentified.key))
        }
        if targets != nil { try await storage.validateNonOverwritingWrites(bucket: bucket) }
        var completed = 0
        for (index, item) in entries.enumerated() {
            var copied = false
            do {
                try Task.checkCancellation()
                if let targets {
                    try await storage.copyObject(bucket: bucket, source: item, destination: targets[index])
                    copied = true
                }
                try Task.checkCancellation()
                try await storage.deleteObject(bucket: bucket, key: item.key, etag: item.etag)
                completed += 1
            } catch {
                throw ObjectMutationFailure(
                    completed: completed, total: entries.count, key: item.key, copied: copied, underlying: error
                )
            }
        }
        return completed
    }

    /// 目录操作在任何写入之前验证标记、游标、对象范围和上限。
    private static func snapshotObjects(
        storage: any ObjectStorage, bucket: StorageBucket, source: StorageObject
    ) async throws -> [StorageObject] {
        if !source.isDirectory { return [source] }
        guard !source.key.isEmpty, source.key.hasSuffix("/") else {
            throw BrowserError.message(appText("无法确定目录的精确前缀。"))
        }
        var entries: [StorageObject] = []
        var cursor: String?
        var cursors = Set<String>()
        var objectIDs = Set<Data>()
        repeat {
            try Task.checkCancellation()
            let page = try await storage.listObjects(
                bucket: bucket, prefix: source.key, cursor: cursor, delimiter: nil, pageSize: 200
            )
            for item in page.objects {
                guard !item.isDirectory, item.key.utf8.starts(with: source.key.utf8) else {
                    throw BrowserError.message(appText("服务返回了超出目录范围的对象。"))
                }
                if objectIDs.insert(item.id).inserted { entries.append(item) }
            }
            guard entries.count <= 10_000 else {
                throw BrowserError.message(appText("目录包含超过 10000 个对象，请分批操作。"))
            }
            cursor = page.next.flatMap { $0.isEmpty ? nil : $0 }
            if let cursor, !cursors.insert(cursor).inserted {
                throw BrowserError.message(appText("服务返回了重复的分页游标，未开始写入。"))
            }
        } while cursor != nil
        guard !entries.isEmpty else {
            throw BrowserError.message(appText("目录已不存在或已为空，请刷新。"))
        }
        return entries
    }

    /// 使用 UTF-8 字节匹配前缀，云端 key 不做 Unicode 或路径规范化。
    private static func planMoveTargets(
        source: StorageObject, entries: [StorageObject], destination: String
    ) throws -> [String] {
        guard !destination.isEmpty else {
            throw BrowserError.message(appText("请输入目标对象路径。"))
        }
        if !source.isDirectory {
            guard !destination.utf8.elementsEqual(source.key.utf8) else {
                throw BrowserError.message(appText("源对象与目标对象相同。"))
            }
            return [destination]
        }
        let prefix = destination.hasSuffix("/") ? destination : destination + "/"
        guard !prefix.utf8.starts(with: source.key.utf8) else {
            throw BrowserError.message(appText("目标目录不能位于源目录内。"))
        }
        return try entries.map { item in
            let suffix = String(decoding: item.key.utf8.dropFirst(source.key.utf8.count), as: UTF8.self)
            let key = prefix + suffix
            guard !key.utf8.starts(with: source.key.utf8) else {
                throw BrowserError.message(appText("目标对象与待移动的源目录重叠。"))
            }
            return key
        }
    }
}
