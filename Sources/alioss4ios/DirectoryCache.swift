// Copyright 2026 jinlongliao
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation

/// 按账号、实际 Bucket 路由、前缀、游标和每页数量隔离缓存。
struct DirectoryCacheKey: Codable {
    /// 旧版 Bucket 缓存缺少展示字段，单独更新列桶键以立即读取新元数据。
    static let bucketListing = DirectoryCacheKey(bucket: nil, prefix: "bucket-list-v2", cursor: nil, pageSize: 0)

    let bucket: StorageBucket?
    let prefix: String
    let cursor: String?
    let pageSize: Int
}

/// 缓存只存储浏览结果，30 分钟内读取可用结果。失败允许调用方改走网络。
actor DirectoryCache {
    static let shared = DirectoryCache()

    private let root = URL.cachesDirectory
        .appending(path: "alioss4ios", directoryHint: .isDirectory)
        .appending(path: "lists-v1", directoryHint: .isDirectory)

    /// 缓存命中不触发网络，过期或被系统清理时返回空值。
    func load<Value: Decodable>(
        _ type: Value.Type, profile: UUID, key: DirectoryCacheKey
    ) -> Value? {
        guard let file = try? cacheFile(profile: profile, key: key),
              let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
              Date().timeIntervalSince(modified) < 30 * 60,
              let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// 单个结果原子落盘，目录中最多保留最近使用的 128 个页缓存。
    func store<Value: Encodable>(_ result: Value, profile: UUID, key: DirectoryCacheKey) {
        do {
            let file = try cacheFile(profile: profile, key: key)
            let directory = file.deletingLastPathComponent()
            let attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: attributes
            )
            try JSONEncoder().encode(result).write(to: file, options: .atomic)
            let pages = try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
            )
            if pages.count > 128 {
                let recent = pages.compactMap { page -> (URL, Date)? in
                    guard let date = try? page.resourceValues(forKeys: [.contentModificationDateKey])
                        .contentModificationDate else { return nil }
                    return (page, date)
                }.sorted { $0.1 > $1.1 }
                for page in recent.dropFirst(128) {
                    try? FileManager.default.removeItem(at: page.0)
                }
            }
        } catch {
            // 缓存写失败不改变已经取得的浏览结果。
        }
    }

    /// 远端写入或账号变更后丢弃所属账号的缓存。
    func invalidate(profile: UUID) {
        try? FileManager.default.removeItem(at: root.appending(path: profile.uuidString))
    }

    /// 清理限于当前应用的列表缓存。
    func clearAllDirectories() {
        try? FileManager.default.removeItem(at: root)
    }

    private func cacheFile(profile: UUID, key: DirectoryCacheKey) throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let hash = SHA256.hash(data: try encoder.encode(key)).map { String(format: "%02x", $0) }.joined()
        return root.appending(path: profile.uuidString).appending(path: hash + ".json")
    }
}

/// 用户提交路径后的导航目标。按 UTF-8 比较对象键，保留连续的路径分隔符。
struct BrowserPathTarget: Equatable {
    let prefix: String
    let highlightedObject: Data?

    /// 空输入或单个斜杠返回根目录，有尾斜杠的输入可以直接作为前缀。
    static func directory(for input: String) -> Self? {
        if input.isEmpty || input == "/" { return Self(prefix: "", highlightedObject: nil) }
        if input.hasSuffix("/") { return Self(prefix: input, highlightedObject: nil) }
        return nil
    }

    /// 精确匹配普通文件则进入父目录；只匹配前缀时按目录处理。
    static func resolve(_ input: String, in page: StoragePage) -> Self {
        guard let file = page.objects.first(where: { !$0.isDirectory && $0.key.utf8.elementsEqual(input.utf8) })
        else { return Self(prefix: input + "/", highlightedObject: nil) }
        let parent = input.lastIndex(of: "/").map { String(input[...$0]) } ?? ""
        return Self(prefix: parent, highlightedObject: file.id)
    }
}

/// 文件夹优先，时间相同时回落到名称和完整 key 的稳定排序。
enum DirectoryOrdering: String, CaseIterable, Identifiable {
    case nameAscending = "名称正序"
    case nameDescending = "名称倒序"
    case modifiedNewest = "最新修改优先"
    case modifiedOldest = "最早修改优先"

    var id: Self { self }

    /// 需要读取整个目录的排序只在完整结果可用时发布。
    var requiresCompleteDirectory: Bool { self != .nameAscending }

    /// 完整排序读取的条目上限，按服务端返回数量计算，包含重复条目。
    static let completeDirectoryLimit = 10_000

    /// 对完整扫描施加上限，不影响名称正序的按需分页。
    func exceedsDirectoryLimit(visitedCount: Int, hasNextPage: Bool) -> Bool {
        requiresCompleteDirectory && (visitedCount > Self.completeDirectoryLimit ||
            (visitedCount == Self.completeDirectoryLimit && hasNextPage))
    }

    /// 目录按名称排列；文件的未知修改时间在两个方向上都位于末尾。
    func precedes(_ left: StorageObject, _ right: StorageObject) -> Bool {
        if left.isDirectory != right.isDirectory { return left.isDirectory }
        let descending = self == .nameDescending || self == .modifiedNewest
        if !left.isDirectory && (self == .modifiedNewest || self == .modifiedOldest) {
            switch (left.modifiedAt, right.modifiedAt) {
            case let (lhs?, rhs?) where lhs != rhs: return descending ? lhs > rhs : lhs < rhs
            case (.none, .some): return false
            case (.some, .none): return true
            default: break
            }
        }
        let order = left.name.compare(right.name, options: [.caseInsensitive, .literal])
        if order != .orderedSame { return descending ? order == .orderedDescending : order == .orderedAscending }
        return descending ? right.key.utf16.lexicographicallyPrecedes(left.key.utf16) :
            left.key.utf16.lexicographicallyPrecedes(right.key.utf16)
    }
}
