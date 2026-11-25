// Copyright 2026 jinlongliao
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Security

/// Apple 客户端对应 Android 的 OSS 与 S3 两种账号类型。
enum StorageProvider: String, CaseIterable, Codable, Identifiable {
    case oss = "OSS"
    case s3 = "S3"

    var id: Self { self }
}

/// 一套连接配置。含凭据的整组账号仅写入本机 Keychain。
struct StorageProfile: Identifiable, Codable, Equatable {
    var id = UUID()
    var name = ""
    var provider = StorageProvider.oss
    var endpoint = ""
    var region = ""
    var bucket = ""
    var accessKeyID = ""
    var secret = ""
    var sessionToken = ""
    var forcePathStyle = false
    var note: String?

    /// 保存前验证必填字段和 HTTPS 端点，保留用户配置的路径。
    func validateProfile() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !accessKeyID.isEmpty, !secret.isEmpty, !region.isEmpty else {
            throw BrowserError.message(appText("请填写名称、区域和访问密钥。"))
        }
        if !endpoint.isEmpty {
            guard let url = URLComponents(string: endpoint), url.scheme == "https",
                  let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
                  url.query == nil, url.fragment == nil else {
                throw BrowserError.message(appText("服务端点必须是无账号、查询参数或片段的 HTTPS 地址。"))
            }
        }
    }
}

/// 用于向界面传递不包含凭据、签名链接或完整请求的错误。
enum BrowserError: LocalizedError {
    case message(String)
    case previewHTTPStatus(Int, code: String? = nil, requestID: String? = nil)

    var errorDescription: String? {
        switch self {
        case .message(let description): description
        case .previewHTTPStatus(let status, _, _):
            String(format: appText("无法读取预览数据（HTTP %d）。"), status)
        }
    }
}

/// 使用一条 Keychain 记录原子替换账号集合，读取失败时禁止覆盖。
enum ProfileVault {
    private static var query: [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "io.github.jinlongliao.alioss4ios",
            kSecAttrAccount as String: "profiles",
            kSecAttrSynchronizable as String: false,
        ]
        #if os(iOS)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        return query
    }

    /// 首次运行返回空数组。Keychain 访问失败时抛出状态码供界面呈现。
    static func loadProfiles() throws -> [StorageProfile] {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let data = result as? Data else {
            throw BrowserError.message("读取钥匙串失败（\(status)）。")
        }
        return try JSONDecoder().decode([StorageProfile].self, from: data)
    }

    /// 先更新既有记录，首次保存时创建仅在本设备可用的记录。
    static func saveProfiles(_ profiles: [StorageProfile]) throws {
        let data = try JSONEncoder().encode(profiles)
        let values = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            var record = query
            record[kSecValueData as String] = data
            #if os(iOS)
            record[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            #endif
            status = SecItemAdd(record as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw BrowserError.message("保存钥匙串失败（\(status)）。")
        }
    }
}

extension StorageProfile {
    /// 账号快照用于创建同一供应商的浏览与上传服务。
    func makeStorage() -> any MultipartStorage {
        switch provider {
        case .oss: OssStorage(profile: self)
        case .s3: S3Storage(profile: self)
        }
    }
}
