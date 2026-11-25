// Copyright 2026 jinlongliao
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation
import SmithyHTTPAPI
import XCTest
@testable import alioss4ios

/// 使用占位凭据验证输入边界和本地 SDK 签名，无需访问真实 Bucket。
final class StorageCompatibilityTests: XCTestCase {
    func testProfileRejectsAmbiguousOrInsecureEndpoint() throws {
        var profile = makeProfile(provider: .s3)
        for invalid in ["http://example.com", "https://a@example.com", "https://example.com?x=1"] {
            profile.endpoint = invalid
            XCTAssertThrowsError(try profile.validateProfile())
        }
        profile.endpoint = "https://example.com/storage/api"
        XCTAssertNoThrow(try profile.validateProfile())
    }

    /// 确认页显示删除、新增及换行差异。
    func testTextEditDiffShowsReplacementsAndLineEndings() {
        XCTAssertEqual(
            compareTextEditLines(original: "name:\n  key: before\nunchanged: true",
                                 draft: "name:\n  key: after\nunchanged: true"),
            ["  name:", "-   key: before", "+   key: after", "  unchanged: true"]
        )
        XCTAssertEqual(compareTextEditLines(original: "a\r\n", draft: "a\n"), ["- a␍", "+ a", "  "])
        XCTAssertEqual(compareTextEditLines(original: "a", draft: "a\n"), ["  a", "+ "])
        XCTAssertTrue(compareTextEditLines(original: "a", draft: "a").isEmpty)
        XCTAssertEqual(PreviewFormat(name: "config.XML"), .text)
        let bom = Data([0xFF, 0xFE])
        let encoded = bom + Data([60, 0, 120, 0, 62, 0])
        let decoded = TextEditEncoding.decode(encoded, named: "config.XML")
        XCTAssertEqual(decoded?.text, "<x>")
        XCTAssertEqual(decoded?.codec.encode("<y>"), bom + Data([60, 0, 121, 0, 62, 0]))
        XCTAssertNil(TextEditEncoding.decode(Data([0xC3]), named: "invalid.txt"))
        XCTAssertEqual(textEditETag("object-etag"), "\"object-etag\"")
        XCTAssertNil(textEditETag("*"))
        XCTAssertNil(textEditETag("W/\"weak\""))
        XCTAssertEqual(
            compareTextEditLines(original: "<config>\n  <port>80</port>\n</config>",
                                 draft: "<config>\n  <port>443</port>\n</config>"),
            ["  <config>", "-   <port>80</port>", "+   <port>443</port>", "  </config>"]
        )
    }

    /// HTML 通过账号的 SDK 读取，保留失败状态且拒绝超过预览上限的正文。
    func testHTMLPreviewReadsThroughAuthenticatedS3Client() async throws {
        let bucket = StorageBucket(name: "example-bucket")
        let content = Data("<p>HTML preview</p>".utf8)
        let storage = S3Storage(profile: makeProfile(provider: .s3),
                                httpClient: PreviewDownloadFixture(content: content, denied: false))
        let result = try await storage.readHTMLPreview(bucket: bucket, key: "index.html", maximumLength: content.count)
        XCTAssertEqual(result, content)
        do {
            _ = try await storage.readHTMLPreview(bucket: bucket, key: "index.html", maximumLength: content.count - 1)
            XCTFail("Expected the preview size limit")
        } catch BrowserError.message {
            // The oversized response must not become a preview.
        }
        let denied = S3Storage(profile: makeProfile(provider: .s3),
                               httpClient: PreviewDownloadFixture(content: content, denied: true))
        do {
            _ = try await denied.readHTMLPreview(bucket: bucket, key: "index.html", maximumLength: content.count)
            XCTFail("Expected the object read to be denied")
        } catch let BrowserError.previewHTTPStatus(status, _, requestID) {
            XCTAssertEqual(status, 403)
            XCTAssertEqual(requestID, "html-denied")
        }
    }

    /// 图片使用账号请求读取原始字节，供 Quick Look 读取本地副本。
    func testImagePreviewWritesAuthenticatedBytesToTemporaryFile() async throws {
        let png = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a9ZkAAAAASUVORK5CYII="
        ))
        let storage = S3Storage(profile: makeProfile(provider: .s3),
                                httpClient: PreviewDownloadFixture(content: png, denied: false))
        let file = try await storage.downloadImagePreview(
            bucket: StorageBucket(name: "example-bucket"), key: "sample.png", maximumLength: png.count
        )
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(try Data(contentsOf: file), png)
    }

    /// 服务端拒绝已变化的对象时，客户端仍携带原始 ETag 且抛出失败。
    func testS3TextReplacementWritesWithOriginalETag() async throws {
        let bucket = StorageBucket(name: "example-bucket")
        let content = Data("changed text".utf8)
        let etag = "\"snapshot-tag\""
        let accepted = S3Storage(profile: makeProfile(provider: .s3),
                                 httpClient: TextReplacementFixture(etag: etag, conflict: false))
        let updated = try await accepted.replaceTextObject(bucket: bucket, key: "config.txt", etag: etag, content: content)
        XCTAssertEqual(updated, "\"updated-tag\"")
        let rejected = S3Storage(profile: makeProfile(provider: .s3),
                                 httpClient: TextReplacementFixture(etag: etag, conflict: true))
        do {
            _ = try await rejected.replaceTextObject(bucket: bucket, key: "config.txt", etag: etag, content: content)
            XCTFail("Expected the server conflict to fail the replacement")
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
    }

    /// 目录应跟随方向按名称排列，未知时间始终置后，同名项使用完整 key。
    func testDirectoryOrderingMatchesAndroidDirectionAndUnknownDates() {
        let old = Date(timeIntervalSince1970: 10)
        let new = Date(timeIntervalSince1970: 20)
        let entries = [
            StorageObject(key: "new", isDirectory: false, modifiedAt: new),
            StorageObject(key: "a/", isDirectory: true),
            StorageObject(key: "aa-unknown", isDirectory: false),
            StorageObject(key: "Old", isDirectory: false, modifiedAt: old),
            StorageObject(key: "old", isDirectory: false, modifiedAt: old),
            StorageObject(key: "z/", isDirectory: true)
        ]
        XCTAssertEqual(entries.sorted(by: DirectoryOrdering.modifiedOldest.precedes).map(\.key),
                       ["a/", "z/", "Old", "old", "new", "aa-unknown"])
        XCTAssertEqual(entries.sorted(by: DirectoryOrdering.modifiedNewest.precedes).map(\.key),
                       ["z/", "a/", "new", "old", "Old", "aa-unknown"])
        XCTAssertEqual(entries.sorted(by: DirectoryOrdering.nameDescending.precedes).map(\.key),
                       ["z/", "a/", "old", "Old", "new", "aa-unknown"])
        let numbered = ["file2", "file10"].map { StorageObject(key: $0, isDirectory: false) }
        XCTAssertEqual(numbered.sorted(by: DirectoryOrdering.nameAscending.precedes).map(\.key),
                       ["file10", "file2"])
    }

    /// 全目录排序拒绝不完整结果，名称正序保留服务端的续页。
    func testCompleteDirectoryOrderingLimitLeavesAscendingPaginationAvailable() {
        for order in DirectoryOrdering.allCases where order.requiresCompleteDirectory {
            XCTAssertFalse(order.exceedsDirectoryLimit(visitedCount: 9_999, hasNextPage: true))
            XCTAssertFalse(order.exceedsDirectoryLimit(visitedCount: 10_000, hasNextPage: false))
            XCTAssertTrue(order.exceedsDirectoryLimit(visitedCount: 10_000, hasNextPage: true))
            XCTAssertTrue(order.exceedsDirectoryLimit(visitedCount: 10_001, hasNextPage: false))
        }
        XCTAssertFalse(DirectoryOrdering.nameAscending.exceedsDirectoryLimit(visitedCount: 10_001, hasNextPage: true))
    }

    /// 经 S3 SDK 连续解码 11 页，跨过 10000 项后仍能使用服务端续页令牌。
    func testS3AscendingPaginationReadsPastCompleteDirectoryLimit() async throws {
        let storage = S3Storage(profile: makeProfile(provider: .s3), httpClient: LargeDirectoryS3Fixture())
        let bucket = StorageBucket(name: "example-bucket")
        var cursor: String?
        var visitedCount = 0
        for index in 0...10 {
            let page = try await storage.listObjects(
                bucket: bucket, prefix: "large/", cursor: cursor, delimiter: "/", pageSize: 1_000
            )
            XCTAssertEqual(page.objects.count, index == 10 ? 1 : 1_000)
            XCTAssertEqual(page.objects.first?.key, "large/object-\(index * 1_000)")
            visitedCount += page.objects.count
            cursor = page.next
            XCTAssertEqual(cursor, index == 10 ? nil : "opaque-\(index + 1)")
            XCTAssertFalse(DirectoryOrdering.nameAscending.exceedsDirectoryLimit(
                visitedCount: visitedCount, hasNextPage: cursor != nil
            ))
        }
        XCTAssertEqual(visitedCount, 10_001)
    }

    /// 路径栏保留连续斜杠，精确命中实际对象才高亮。
    func testBrowserPathMatchesExactObjectKey() {
        let file = StorageObject(key: "目录//说明.txt", isDirectory: false)
        let page = StoragePage(objects: [file], next: nil)
        XCTAssertEqual(BrowserPathTarget.directory(for: "/")?.prefix, "")
        XCTAssertEqual(BrowserPathTarget.directory(for: "目录//")?.prefix, "目录//")
        XCTAssertNil(BrowserPathTarget.directory(for: "目录//说明.txt"))
        XCTAssertEqual(BrowserPathTarget.resolve(file.key, in: page), .init(
            prefix: "目录//", highlightedObject: file.id
        ))
        XCTAssertEqual(BrowserPathTarget.resolve("目录//说明", in: page), .init(
            prefix: "目录//说明/", highlightedObject: nil
        ))
        let decomposed = StorageObject(key: "cafe\u{0301}", isDirectory: false)
        XCTAssertNil(BrowserPathTarget.resolve("café", in: .init(objects: [decomposed], next: nil)).highlightedObject)
    }

    /// 旧缓存和上传历史不会因 Bucket 增加展示字段而失效。
    func testBucketMetadataKeepsExistingRoutingIdentity() throws {
        let legacy = Data(#"{"name":"sample","region":"us-west-2"}"#.utf8)
        let original = try JSONDecoder().decode(StorageBucket.self, from: legacy)
        XCTAssertNil(original.storageClass)
        XCTAssertNil(original.createdAt)

        var enriched = original
        enriched.storageClass = "Standard"
        enriched.createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(Set([original, enriched]).count, 1)
        let stored = try JSONDecoder().decode(StorageBucket.self, from: JSONEncoder().encode(enriched))
        XCTAssertEqual(stored.storageClass, enriched.storageClass)
        XCTAssertEqual(stored.createdAt, enriched.createdAt)
    }

    /// 在账号编辑时更新标准端点，保留 OSS 与 S3 网关配置。
    func testRegionPresetsKeepCustomEndpoints() throws {
        let beijing = try XCTUnwrap(StorageRegionPreset.oss.first { $0.code == "cn-beijing" })
        let west = try XCTUnwrap(StorageRegionPreset.s3.first { $0.code == "us-west-2" })
        var profile = makeProfile(provider: .oss)
        for endpoint in ["", "https://oss-cn-shanghai.aliyuncs.com/"] {
            profile.endpoint = endpoint
            beijing.apply(to: &profile)
            XCTAssertEqual(profile.region, "cn-beijing")
            XCTAssertEqual(profile.endpoint, "https://oss-cn-beijing.aliyuncs.com")
        }
        let gateway = "https://example.test/storage/gateway"
        profile.endpoint = gateway
        beijing.apply(to: &profile)
        XCTAssertEqual(profile.endpoint, gateway)
        profile.provider = .s3
        west.apply(to: &profile)
        XCTAssertEqual(profile.region, "us-west-2")
        XCTAssertEqual(profile.endpoint, gateway)
    }

    func testS3SignedUrlPreservesEndpointPathAndToken() async throws {
        var profile = makeProfile(provider: .s3)
        profile.endpoint = "https://example.com/storage/api"
        profile.sessionToken = "placeholder-token"
        profile.forcePathStyle = true
        let bucket = StorageBucket(name: "example-bucket")
        let url = try await S3Storage(profile: profile).signDownload(bucket: bucket, key: "目录/a b.txt", expiry: 3600)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.path, "/storage/api/example-bucket/目录/a b.txt")
        XCTAssertEqual(components.queryItems?.first { $0.name == "X-Amz-Security-Token" }?.value, profile.sessionToken)
        XCTAssertNotNil(components.queryItems?.first { $0.name == "X-Amz-Signature" }?.value)
    }

    func testOssSignedUrlUsesBucketAndEscapesObjectKey() async throws {
        let profile = makeProfile(provider: .oss)
        let bucket = StorageBucket(name: "example-bucket")
        let url = try await OssStorage(profile: profile).signDownload(bucket: bucket, key: "目录/a b.txt", expiry: 3600)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.host, "example-bucket.oss-cn-hangzhou.aliyuncs.com")
        XCTAssertEqual(components.path, "/目录/a b.txt")
        XCTAssertNotNil(components.queryItems?.first { $0.name == "x-oss-signature" }?.value)
    }

    func testOssSignedUrlPreservesConfiguredGatewayPath() async throws {
        var profile = makeProfile(provider: .oss)
        profile.endpoint = "https://example.com/storage/api/"
        let bucket = StorageBucket(name: "example-bucket", endpoint: "https://oss-cn-hangzhou.aliyuncs.com")
        let url = try await OssStorage(profile: profile).signDownload(
            bucket: bucket, key: "目录//a b.txt", expiry: 3600
        )
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.host, "example-bucket.example.com")
        XCTAssertEqual(components.path, "/storage/api/目录//a b.txt")
        XCTAssertNotNil(components.queryItems?.first { $0.name == "x-oss-signature" }?.value)
    }

    func testUploadSignsDestinationAndKeepsConditionalHeader() async throws {
        let bucket = StorageBucket(name: "example-bucket")
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try Data(repeating: 0x2A, count: 42).write(to: file, options: .withoutOverwriting)
        defer { try? FileManager.default.removeItem(at: file) }
        var profile = makeProfile(provider: .s3)
        profile.endpoint = "https://example.com/storage/api"
        let s3 = S3Storage(profile: profile, httpClient: UploadRequestVerifier(expectedPayloadSize: 42))
        try await s3.uploadObject(bucket: bucket, key: "a.txt", file: file)

        profile.sessionToken = "placeholder-token"
        let s3Request = try await S3Storage(profile: profile).signUpload(bucket: bucket, key: "a.txt")
        XCTAssertEqual(s3Request.httpMethod, "PUT")
        XCTAssertEqual(s3Request.value(forHTTPHeaderField: "If-None-Match"), "*")
        XCTAssertNil(s3Request.value(forHTTPHeaderField: "x-amz-security-token"))
        let s3URL = try XCTUnwrap(s3Request.url)
        let components = try XCTUnwrap(URLComponents(url: s3URL, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.path, "/storage/api/a.txt")
        XCTAssertEqual(components.queryItems?.first { $0.name == "X-Amz-Security-Token" }?.value, profile.sessionToken)

        let oss = OssStorage(profile: makeProfile(provider: .oss))
        let ossRequest = try await oss.signUpload(bucket: bucket, key: "a.txt")
        XCTAssertEqual(ossRequest.httpMethod, "PUT")
        XCTAssertEqual(ossRequest.value(forHTTPHeaderField: "x-oss-forbid-overwrite"), "true")
        let overwriteRequest = try await oss.signUpload(bucket: bucket, key: "a.txt", allowsOverwrite: true)
        XCTAssertEqual(overwriteRequest.value(forHTTPHeaderField: "x-oss-forbid-overwrite"), "false")
    }

    /// 系统上传需持有同一个分片会话标识，签名 URL 也要保留自定义路由和临时令牌。
    func testSignedUploadPartRetainsSessionAndGateway() async throws {
        let target = UploadTarget(bucket: StorageBucket(name: "example-bucket"), key: "目录/a b.txt")
        var s3 = makeProfile(provider: .s3)
        s3.endpoint = "https://example.com/storage/api"
        s3.sessionToken = "placeholder-token"
        s3.forcePathStyle = true
        let requests = try await [
            OssStorage(profile: makeProfile(provider: .oss))
                .signUploadPart(target: target, uploadID: "sample+/=", number: 3),
            S3Storage(profile: s3).signUploadPart(target: target, uploadID: "sample+/=", number: 3),
        ]
        for request in requests {
            let url = try XCTUnwrap(request.url)
            let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
            XCTAssertEqual(url.scheme, "https")
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertEqual(components.queryItems?.first { $0.name == "uploadId" }?.value, "sample+/=")
            XCTAssertEqual(components.queryItems?.first { $0.name == "partNumber" }?.value, "3")
        }
        let s3URL = try XCTUnwrap(requests.last?.url)
        let route = try XCTUnwrap(URLComponents(url: s3URL, resolvingAgainstBaseURL: false))
        XCTAssertEqual(route.path, "/storage/api/example-bucket/目录/a b.txt")
        XCTAssertEqual(route.queryItems?.first { $0.name == "X-Amz-Security-Token" }?.value, s3.sessionToken)
    }

    func testCnameParsingSeparatesCertificateAndDomainStatus() throws {
        let xml = """
        <ListCnameResult>
          <Cname><Domain>secure.example.com</Domain><Status>Enabled</Status>
            <Certificate><Status>Enabled</Status></Certificate>
          </Cname>
          <Cname><Domain>plain.example.com</Domain><Status>Enabled</Status></Cname>
          <Cname><Domain>disabled.example.com</Domain><Status>Disabled</Status>
            <Certificate><Status>Enabled</Status></Certificate>
          </Cname>
          <Cname><Domain>wild.example.com</Domain><Status>Enabled</Status><IsWildCard>true</IsWildCard></Cname>
        </ListCnameResult>
        """
        let domains = try CnameXMLParser.parseDomains(Data(xml.utf8))
        XCTAssertEqual(domains, [
            PublicLinkDomain(host: "secure.example.com", wantsHTTPS: true),
            PublicLinkDomain(host: "plain.example.com", wantsHTTPS: false),
        ])
        let signed = try XCTUnwrap(URL(string:
            "https://bucket.example.com/dir//%E4%B8%AD%20%E6%96%87/%25%3F%23.txt?signature=secret#fragment"
        ))
        let custom = try publicObjectLink(from: signed, domain: domains[1])
        XCTAssertEqual(custom.absoluteString, "http://plain.example.com/dir//%E4%B8%AD%20%E6%96%87/%25%3F%23.txt")
        let standard = try publicObjectLink(from: signed, domain: nil)
        XCTAssertEqual(standard.absoluteString, "https://bucket.example.com/dir//%E4%B8%AD%20%E6%96%87/%25%3F%23.txt")
    }

    /// 免密码导出使用 ALOS 应用密钥模式和随机盐，仍能检测密文篡改。
    func testPasswordlessBackupExportUsesAndroidMode() throws {
        let profiles = StorageProvider.allCases.map { makeProfile(provider: $0) }
        let backup = try ProfileBackup.exportProfiles(profiles, password: "")
        let second = try ProfileBackup.exportProfiles(profiles, password: "")
        XCTAssertEqual(Array(backup.prefix(7)), [65, 76, 79, 83, 1, 0, 16])
        XCTAssertNotEqual(backup[7..<23], second[7..<23])
        XCTAssertEqual(try ProfileBackup.importProfiles(backup, password: ""), profiles)
        var damaged = backup
        damaged[damaged.count - 1] ^= 1
        XCTAssertThrowsError(try ProfileBackup.importProfiles(damaged, password: ""))
    }

    func testEncryptedBackupRoundTripsAndRejectsWrongPassword() throws {
        var profile = makeProfile(provider: .s3)
        profile.sessionToken = "placeholder-token"
        profile.note = "示例配置"
        profile.forcePathStyle = true
        let backup = try ProfileBackup.exportProfiles([profile], password: "测试密码-1")
        XCTAssertEqual(backup.prefix(7), Data([65, 76, 79, 83, 1, 1, 16]))
        XCTAssertNil(backup.range(of: Data(profile.secret.utf8)))
        XCTAssertEqual(try ProfileBackup.importProfiles(backup, password: "测试密码-1"), [profile])
        XCTAssertThrowsError(try ProfileBackup.importProfiles(backup, password: "wrong"))
    }

    func testImportsJavaALOSBackupWithLegacyOssRegion() throws {
        // Java PBEKeySpec + AES/GCM independently produced this Android-compatible fixture.
        let encoded = """
            QUxPUwEBEAABAgMEBQYHCAkKCwwNDg8MGBcWFRQTEhEQDw4NUwwVROAKSJnj4V7bSQQhwOyfITUkMUHDbi2q
            UzFrQ3JpRr4Fhy8oUUXzzNKyC6RiWYI8YbksEP4hI4kRbkM7E0oml0Uv9Eo0OtbR36h8h2h9zDNFEItCVUVT
            yiXBfmjXaBkH2O5lV1pMi8zXs9jk1bjNqK1fntYIBACKsYf0PVhdW87GEkutabT8inmqJtERuSyCrc1P7fO7
            M12dqJUIWtLcXnFSelhOjLSqSfx6qCLlwSeHmeeJf5eqeMQzv0KqhirUfiKAJ9BkX7N16oAnJVnlgJJkATl1
            o6RmSvFPVlZ2Pa6n+Lt872DE+g==
            """
        let data = try XCTUnwrap(Data(base64Encoded: encoded, options: .ignoreUnknownCharacters))
        let profile = try XCTUnwrap(ProfileBackup.importProfiles(data, password: "fixture-密码").first)
        XCTAssertEqual(profile.provider, .oss)
        XCTAssertEqual(profile.endpoint, "https://oss-cn-hangzhou.aliyuncs.com")
        XCTAssertEqual(profile.region, "cn-hangzhou")
        XCTAssertEqual(profile.secret, "fixture-secret")
    }

    /// Android 应用密钥模式可以包含旧版非 UUID 账号 ID。
    func testImportsPasswordlessBackupWithStableLegacyIdentity() throws {
        let plaintext = Data("""
            {"version":1,"exportedAtMs":1,"profiles":[
              {"id":"legacy-oss-1","name":"Example","endpoint":"https://oss-cn-hangzhou.aliyuncs.com",
               "accessKeyId":"placeholder-key","accessKeySecret":"placeholder-secret"}
            ]}
            """.utf8)
        let salt = Data(repeating: 11, count: 16)
        let key = SymmetricKey(data: SHA256.hash(data: Data("AliOSS4Droid-keyv1.0-jinlongliao".utf8) + salt))
        let box = try AES.GCM.seal(plaintext, using: key)
        var backup = Data([65, 76, 79, 83, 1, 0, 16]) + salt + Data([12])
        backup.append(contentsOf: box.nonce)
        backup.append(box.ciphertext)
        backup.append(box.tag)
        let first = try XCTUnwrap(ProfileBackup.importProfiles(backup, password: "").first)
        let second = try XCTUnwrap(ProfileBackup.importProfiles(backup, password: "").first)
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(first.region, "cn-hangzhou")
    }

    func testInterfaceLanguageSelectsPackagedResources() {
        XCTAssertEqual(localizedAppText("账号", languageTag: "zh-Hans"), "账号")
        XCTAssertEqual(localizedAppText("账号", languageTag: "zh-TW"), "帳號")
        XCTAssertEqual(localizedAppText("添加账号", languageTag: "en"), "Add account")
        XCTAssertEqual(localizedAppText("账号", languageTag: "zh-Hans-TW"), "账号")
        XCTAssertEqual(localizedAppText("排序方式", languageTag: "en"), "Sort by")
        XCTAssertEqual(localizedAppText("排序方式", languageTag: "zh-Hant"), "排序方式")
        XCTAssertEqual(
            DirectoryOrdering.allCases.map { localizedAppText($0.rawValue, languageTag: "zh-Hant-HK") },
            ["名稱正序", "名稱倒序", "最新修改優先", "最早修改優先"]
        )
        XCTAssertEqual(
            DirectoryOrdering.allCases.map { localizedAppText($0.rawValue, languageTag: "en") },
            ["Name ascending", "Name descending", "Newest first", "Oldest first"]
        )
    }

    private func makeProfile(provider: StorageProvider) -> StorageProfile {
        StorageProfile(
            name: "Test",
            provider: provider,
            region: provider == .oss ? "cn-hangzhou" : "us-east-1",
            accessKeyID: "placeholder-key",
            secret: "placeholder-secret"
        )
    }
}

/// 验证实际 SDK 请求的条件头。模拟 HEAD 通过、PUT 前远端内容已变化。
private struct PreviewDownloadFixture: HTTPClient {
    let content: Data
    let denied: Bool

    func send(request: HTTPRequest) async throws -> HTTPResponse {
        XCTAssertEqual(request.method.rawValue.uppercased(), "GET")
        XCTAssertNotNil(request.headers.value(for: "Authorization"))
        if denied {
            return HTTPResponse(
                headers: Headers(["x-amz-request-id": "html-denied"]),
                body: .data(Data("<Error><Code>AccessDenied</Code></Error>".utf8)),
                statusCode: .forbidden
            )
        }
        return HTTPResponse(headers: Headers(["Content-Length": String(content.count)]),
                            body: .data(content), statusCode: .ok)
    }
}

private struct TextReplacementFixture: HTTPClient {
    let etag: String
    let conflict: Bool

    func send(request: HTTPRequest) async throws -> HTTPResponse {
        XCTAssertEqual(request.headers.value(for: "If-Match"), etag)
        if request.method.rawValue.uppercased() == "HEAD" {
            return HTTPResponse(headers: Headers([
                "ETag": etag, "Content-Type": "text/plain", "x-amz-meta-sample": "kept"
            ]), statusCode: .ok)
        }
        XCTAssertEqual(request.method.rawValue.uppercased(), "PUT")
        XCTAssertEqual(request.headers.value(for: "Content-Type"), "text/plain")
        XCTAssertEqual(request.headers.value(for: "x-amz-meta-sample"), "kept")
        if conflict {
            return HTTPResponse(
                body: .data(Data("<Error><Code>PreconditionFailed</Code></Error>".utf8)),
                statusCode: .preconditionFailed
            )
        }
        return HTTPResponse(headers: Headers(["ETag": "\"updated-tag\""]), statusCode: .ok)
    }
}

/// 提供分页 XML，使测试经过 S3 SDK 的请求序列化和响应解码。
private struct LargeDirectoryS3Fixture: HTTPClient {
    func send(request: HTTPRequest) async throws -> HTTPResponse {
        XCTAssertEqual(request.method.rawValue.uppercased(), "GET")
        let query = request.queryItems ?? []
        XCTAssertEqual(query.first { $0.name == "max-keys" }?.value, "1000")
        let cursor = query.first { $0.name == "continuation-token" }?.value
        let index = try XCTUnwrap(cursor.map { Int($0.dropFirst("opaque-".count)) } ?? 0)
        let start = index * 1_000
        let end = min(start + 1_000, 10_001)
        let objects = (start..<end).map { "<Contents><Key>large/object-\($0)</Key></Contents>" }.joined()
        let nextToken = index == 10 ? "" : "<NextContinuationToken>opaque-\(index + 1)</NextContinuationToken>"
        let xml = """
        <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
        <Name>example-bucket</Name><Prefix>large/</Prefix><MaxKeys>1000</MaxKeys>
        <IsTruncated>\(index < 10)</IsTruncated>\(objects)\(nextToken)
        </ListBucketResult>
        """
        return HTTPResponse(body: .data(Data(xml.utf8)), statusCode: .ok)
    }
}

/// 在 SDK 的传输边界核对实际签名、条件头和上传正文。
private struct UploadRequestVerifier: HTTPClient {
    let expectedPayloadSize: Int

    func send(request: HTTPRequest) async throws -> HTTPResponse {
        XCTAssertEqual(request.method.rawValue.uppercased(), "PUT")
        XCTAssertEqual(request.headers.value(for: "If-None-Match"), "*")
        let authorization = try XCTUnwrap(request.headers.value(for: "Authorization"))
        XCTAssertTrue(authorization.contains("Signature="))
        XCTAssertTrue(authorization.contains("if-none-match"))
        let length = request.headers.value(for: "X-Amz-Decoded-Content-Length")
            ?? request.headers.value(for: "Content-Length")
        XCTAssertEqual(length, String(expectedPayloadSize))
        guard case .stream(let stream) = request.body else {
            XCTFail("Expected a streamed upload request")
            return HTTPResponse(statusCode: .badRequest)
        }
        let expected = Data(repeating: 0x2A, count: expectedPayloadSize)
        var received = Data()
        for _ in 0..<8 {
            guard let part = try await stream.readAsync(upToCount: 1024), !part.isEmpty else { break }
            received.append(part)
            if received.range(of: expected) != nil { break }
        }
        XCTAssertNotNil(received.range(of: expected))
        return HTTPResponse(statusCode: .ok)
    }
}
