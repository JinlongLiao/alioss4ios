// Copyright 2026 jinlongliao
// SPDX-License-Identifier: Apache-2.0

import CommonCrypto
import CryptoKit
import Foundation
import Security

/// Android ProfileBackupCodec 的 ALOS v1 交换格式。
/// 密码模式和 Android 应用密钥模式均可导入及导出。
enum ProfileBackup {
    static let maximumLength = 10 * 1024 * 1024

    private static let magic = Array("ALOS".utf8)
    private static let oldApplicationKey = Data("AliOSS4Droid-keyv1.0-jinlongliao".utf8)

    /// 留空使用 Android 应用密钥；有密码时用 PBKDF2 派生密钥。两种模式均使用随机盐和 AES-GCM。
    static func exportProfiles(_ profiles: [StorageProfile], password: String) throws -> Data {
        var salt = Data(count: 16)
        let status = salt.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, bytes.count, base)
        }
        guard status == errSecSuccess else { throw BrowserError.message(appText("无法生成备份随机盐。")) }
        let mode: UInt8 = password.isEmpty ? 0 : 1
        let key = try makeBackupKey(mode: mode, password: password, salt: salt)
        let payload = BackupPayload(
            version: 1, exportedAtMs: Int64(Date().timeIntervalSince1970 * 1000),
            profiles: profiles.map(BackupProfile.init)
        )
        let encrypted = try AES.GCM.seal(JSONEncoder().encode(payload), using: key)
        var file = Data(magic + [1, mode, 16])
        file.append(salt)
        file.append(12)
        file.append(contentsOf: encrypted.nonce)
        file.append(encrypted.ciphertext)
        file.append(encrypted.tag)
        guard file.count <= maximumLength else { throw BrowserError.message(appText("备份文件超过大小上限。")) }
        return file
    }

    /// 先校验头部和长度，再验 GCM 标签。导入失败时调用方保留现有账号。
    static func importProfiles(_ data: Data, password: String) throws -> [StorageProfile] {
        guard data.count >= 52, data.count <= maximumLength else {
            throw BrowserError.message(appText("备份长度不符合 ALOS v1 格式。"))
        }
        let bytes = [UInt8](data)
        guard Array(bytes[0..<4]) == magic, bytes[4] == 1, bytes[6] == 16, bytes[23] == 12 else {
            throw BrowserError.message(appText("无法识别 ALOS v1 备份格式。"))
        }
        let salt = Data(bytes[7..<23])
        let key = try makeBackupKey(mode: bytes[5], password: password, salt: salt)
        let tagIndex = bytes.count - 16
        let sealed = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: bytes[24..<36]),
            ciphertext: bytes[36..<tagIndex], tag: bytes[tagIndex...]
        )
        let plaintext: Data
        do {
            plaintext = try AES.GCM.open(sealed, using: key)
        } catch {
            throw BrowserError.message(appText("密码错误，或备份文件已经损坏。"))
        }
        let payload = try JSONDecoder().decode(BackupPayload.self, from: plaintext)
        guard payload.version == 1 else { throw BrowserError.message(appText("无法识别备份配置版本。")) }
        return try payload.profiles.map { item in
            let profile = try item.makeStorageProfile()
            try profile.validateProfile()
            return profile
        }
    }

    /// 导入和导出使用同一组模式编号及密钥派生规则。
    private static func makeBackupKey(mode: UInt8, password: String, salt: Data) throws -> SymmetricKey {
        switch mode {
        case 0:
            return SymmetricKey(data: SHA256.hash(data: oldApplicationKey + salt))
        case 1:
            guard !password.isEmpty else { throw BrowserError.message(appText("请输入备份密码。")) }
            return try derivePasswordKey(password, salt: salt)
        default:
            throw BrowserError.message(appText("无法识别备份加密模式。"))
        }
    }

    /// 与 Android PBEKeySpec 相同的 UTF-8 密码、盐和参数。
    private static func derivePasswordKey(_ password: String, salt: Data) throws -> SymmetricKey {
        var key = Data(count: 32)
        let status = key.withUnsafeMutableBytes { output in
            salt.withUnsafeBytes { saltBytes in
                password.withCString { passwordBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2), passwordBytes, password.utf8.count,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress, saltBytes.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 200_000,
                        output.bindMemory(to: UInt8.self).baseAddress, output.count
                    )
                }
            }
        }
        guard status == kCCSuccess else { throw BrowserError.message(appText("无法生成备份密码密钥。")) }
        return SymmetricKey(data: key)
    }
}

/// JSON 字段名与 Android 备份保持一致，缺失的旧字段由转换阶段补齐。
private struct BackupPayload: Codable {
    let version: Int
    let exportedAtMs: Int64
    let profiles: [BackupProfile]
}

private struct BackupProfile: Codable {
    let id: String
    let name: String
    let endpoint: String
    let accessKeyId: String
    let accessKeySecret: String
    let bucket: String?
    let note: String?
    let storageType: String?
    let region: String?
    let sessionToken: String?
    let forcePathStyle: Bool?

    init(_ profile: StorageProfile) {
        id = profile.id.uuidString
        name = profile.name
        endpoint = profile.endpoint
        accessKeyId = profile.accessKeyID
        accessKeySecret = profile.secret
        bucket = profile.bucket
        note = profile.note
        storageType = profile.provider == .s3 ? "AWS_S3" : "OSS"
        region = profile.region
        sessionToken = profile.sessionToken
        forcePathStyle = profile.forcePathStyle
    }

    /// Android 曾允许任意字符串 ID。稳定映射使再次导入能更新原账号。
    private var migratedProfileID: UUID {
        if let existing = UUID(uuidString: id) { return existing }
        var bytes = Array(SHA256.hash(data: Data(("alioss4ios.android-profile:" + id).utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x80
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    /// 老 Android OSS 配置把区域写在公开 Endpoint 中，标准格式可直接提取。
    func makeStorageProfile() throws -> StorageProfile {
        let provider: StorageProvider
        switch storageType {
        case nil, "OSS": provider = .oss
        case "AWS_S3": provider = .s3
        default: throw BrowserError.message(appText("备份包含未知的存储类型。"))
        }
        let guessedRegion: String
        if provider == .oss, let host = URL(string: endpoint)?.host,
           host.hasSuffix(".aliyuncs.com"), let part = host.split(separator: ".").first,
           part.hasPrefix("oss-") {
            let value = String(part.dropFirst(4))
            guessedRegion = value.hasSuffix("-internal") ? String(value.dropLast(9)) : value
        } else {
            guessedRegion = ""
        }
        let resolvedRegion = region.flatMap { $0.isEmpty ? nil : $0 } ?? guessedRegion
        return StorageProfile(
            id: migratedProfileID, name: name, provider: provider, endpoint: endpoint, region: resolvedRegion,
            bucket: bucket ?? "", accessKeyID: accessKeyId, secret: accessKeySecret,
            sessionToken: sessionToken ?? "", forcePathStyle: forcePathStyle ?? false, note: note
        )
    }
}
