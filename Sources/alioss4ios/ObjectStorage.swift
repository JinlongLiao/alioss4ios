// Copyright 2026 jinlongliao
// SPDX-License-Identifier: Apache-2.0

import AlibabaCloudOSS
import Foundation
import Network

/// 存储空间及服务返回的区域路由。默认 Bucket 延用账号设置。
struct StorageBucket: Identifiable, Hashable, Codable {
    let name: String
    var region: String? = nil
    var endpoint: String? = nil
    var storageClass: String? = nil
    var createdAt: Date? = nil

    var id: String { name }

    /// 展示字段不参与路由身份，旧上传记录和已选择的 Bucket 可继续匹配。
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.name == rhs.name && lhs.region == rhs.region && lhs.endpoint == rhs.endpoint
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(name)
        hasher.combine(region)
        hasher.combine(endpoint)
    }
}

/// 对象或虚拟目录。完整 key 始终用于远端操作。
struct StorageObject: Identifiable, Hashable, Codable {
    let key: String
    let isDirectory: Bool
    var size: Int64? = nil
    var modifiedAt: Date? = nil
    var etag: String? = nil

    var id: Data { Data(((isDirectory ? "directory:" : "object:") + key).utf8) }

    var name: String {
        let name = isDirectory && key.hasSuffix("/") ? key.dropLast() : key[...]
        return name.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? key
    }
}

/// 一页对象及服务端返回的下页游标。
struct StoragePage: Codable {
    let objects: [StorageObject]
    let next: String?
}

/// 浏览界面所用的最小存储契约，OSS 和 S3 分别由供应商 SDK 实现。
protocol ObjectStorage {
    func listBuckets() async throws -> [StorageBucket]
    func listObjects(
        bucket: StorageBucket, prefix: String, cursor: String?, delimiter: String?, pageSize: Int
    ) async throws -> StoragePage
    func readPreviewChunks(
        bucket: StorageBucket, key: String, maximumLength: Int, receive: (Data) throws -> Void
    ) async throws
    func textObjectETag(bucket: StorageBucket, key: String) async throws -> String?
    func replaceTextObject(bucket: StorageBucket, key: String, etag: String, content: Data) async throws -> String?
    func uploadObject(bucket: StorageBucket, key: String, file: URL) async throws
    func deleteObject(bucket: StorageBucket, key: String, etag: String?) async throws
    func validateNonOverwritingWrites(bucket: StorageBucket) async throws
    func copyObject(bucket: StorageBucket, source: StorageObject, destination: String) async throws
    func signDownload(bucket: StorageBucket, key: String, expiry: TimeInterval) async throws -> URL
}

/// 一般存储服务的条件复制可直接调用，OSS 单独确认 Bucket 版本设置。
extension ObjectStorage {
    func readPreviewChunks(
        bucket: StorageBucket, key: String, maximumLength: Int, receive: (Data) throws -> Void
    ) async throws {
        throw BrowserError.message(appText("无法读取预览数据。"))
    }

    /// 文档正文读取到内存，保留与图像流式读取相同的大小约束。
    func readHTMLPreview(bucket: StorageBucket, key: String, maximumLength: Int) async throws -> Data {
        var data = Data()
        try await readPreviewChunks(bucket: bucket, key: key, maximumLength: maximumLength) { data.append($0) }
        return data
    }

    /// 图片写入独立临时文件，取消或失败时删除不完整副本。
    func downloadImagePreview(bucket: StorageBucket, key: String, maximumLength: Int) async throws -> URL {
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        do {
            try Data().write(to: file, options: .withoutOverwriting)
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try await readPreviewChunks(bucket: bucket, key: key, maximumLength: maximumLength) {
                try handle.write(contentsOf: $0)
            }
            return file
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
    }

    func textObjectETag(bucket: StorageBucket, key: String) async throws -> String? { nil }

    func replaceTextObject(bucket: StorageBucket, key: String, etag: String, content: Data) async throws -> String? {
        throw BrowserError.message(appText("此存储服务不支持更新文本。"))
    }

    func validateNonOverwritingWrites(bucket: StorageBucket) async throws {}
}

/// 使用 OSS SDK 列举对象并生成下载地址，跨地域 Bucket 采用服务端提供的路由。
struct OssStorage: ObjectStorage, MultipartStorage {
    let profile: StorageProfile

    /// 默认 Bucket 账号可绕过服务级列举权限。
    func listBuckets() async throws -> [StorageBucket] {
        if !profile.bucket.isEmpty { return [StorageBucket(name: profile.bucket)] }
        var buckets: [StorageBucket] = []
        for try await page in makeClient().listBucketsPaginator(.init()) {
            buckets += (page.buckets ?? []).compactMap { bucket in
                guard let name = bucket.name else { return nil }
                let location = bucket.location.map {
                    $0.hasPrefix("oss-") ? String($0.dropFirst(4)) : $0
                }
                let endpoint = bucket.extranetEndpoint.map { $0.contains("://") ? $0 : "https://" + $0 }
                return StorageBucket(
                    name: name, region: bucket.region ?? location, endpoint: endpoint,
                    storageClass: bucket.storageClass, createdAt: bucket.creationDate
                )
            }
        }
        return buckets.sorted { $0.name < $1.name }
    }

    /// 用 delimiter 区分虚拟目录和对象，保留原始 key。
    func listObjects(
        bucket: StorageBucket, prefix: String, cursor: String?, delimiter: String?, pageSize: Int
    ) async throws -> StoragePage {
        let result = try await makeClient(bucket).listObjectsV2(.init(
            bucket: bucket.name, delimiter: delimiter, maxKeys: pageSize, prefix: prefix, continuationToken: cursor
        ))
        let directories = (result.commonPrefixes ?? []).compactMap { entry -> StorageObject? in
            guard let key = entry.prefix else { return nil }
            return StorageObject(key: key, isDirectory: true)
        }
        let files = (result.contents ?? []).compactMap { item -> StorageObject? in
            guard let key = item.key, delimiter == nil || key != prefix else { return nil }
            return StorageObject(
                key: key, isDirectory: false, size: item.size.map(Int64.init),
                modifiedAt: item.lastModified, etag: item.etag
            )
        }
        return StoragePage(objects: directories + files, next: result.nextContinuationToken)
    }

    /// 使用当前账号和 Bucket 路由读取预览，流式响应在首个超限字节停止。
    func readPreviewChunks(
        bucket: StorageBucket, key: String, maximumLength: Int, receive: (Data) throws -> Void
    ) async throws {
        let response: GetObjectResult
        do {
            response = try await makeClient(bucket).getObject(GetObjectRequest(
                bucket: bucket.name, key: key, acceptEncoding: "identity"
            ))
        } catch let error as ServerError {
            throw BrowserError.previewHTTPStatus(error.statusCode, code: error.code, requestID: error.requestId)
        }

        let input: InputStream
        switch response.body {
        case .data(let data):
            guard data.count <= maximumLength else { throw ObjectTransfer.previewSizeError() }
            try receive(data)
            return
        case .file(let url):
            guard let file = InputStream(url: url) else {
                throw BrowserError.message(appText("无法读取预览数据。"))
            }
            input = file
        case .stream(let stream):
            input = stream
        case Optional.none, .some(.none):
            return
        }

        input.open()
        defer { input.close() }
        guard (response.contentLength ?? 0) <= maximumLength else { throw ObjectTransfer.previewSizeError() }
        var received = 0
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            try Task.checkCancellation()
            let count = input.read(&buffer, maxLength: min(buffer.count, maximumLength - received + 1))
            if count < 0 { throw input.streamError ?? BrowserError.message(appText("无法读取预览数据。")) }
            if count == 0 { return }
            guard count <= maximumLength - received else { throw ObjectTransfer.previewSizeError() }
            received += count
            try receive(Data(buffer.prefix(count)))
        }
    }

    /// 版本补取使用同一 Bucket 路由和账号。
    func textObjectETag(bucket: StorageBucket, key: String) async throws -> String? {
        try await makeClient(bucket).headObject(HeadObjectRequest(
            bucket: bucket.name, key: key,
            commonProp: RequestModelProp(headers: ["Accept-Encoding": "identity"])
        )).etag
    }

    /// OSS PutObject 不支持 If-Match。先检查下载时的 ETag，再保留响应中的常用元数据写回。
    func replaceTextObject(bucket: StorageBucket, key: String, etag: String, content: Data) async throws -> String? {
        let client = makeClient(bucket)
        // 动态 gzip 不属于对象本身的内容编码。条件 HEAD 请求原始对象元数据。
        let head = try await client.headObject(HeadObjectRequest(
            bucket: bucket.name, key: key, ifMatch: etag,
            commonProp: RequestModelProp(headers: ["Accept-Encoding": "identity"])
        ))
        let encoding = head.contentEncoding?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        guard encoding.isEmpty || encoding == "identity",
              (head.taggingCount ?? 0) == 0 else {
            throw BrowserError.message(appText("暂不支持更新带内容编码或对象标签的文本。"))
        }
        try Task.checkCancellation()
        let updated = try await client.putObject(PutObjectRequest(
            bucket: bucket.name, key: key, serverSideEncryption: head.serverSideEncryption,
            serverSideDataEncryption: head.serverSideDataEncryption,
            serverSideEncryptionKeyId: head.serverSideEncryptionKeyId, storageClass: head.storageClass,
            cacheControl: head.cacheControl, contentDisposition: head.contentDisposition,
            expires: head.expires, contentType: head.contentType, metadata: head.metadata, body: .data(content)
        ))
        return textEditETag(updated.etag)
    }

    /// 先生成带覆盖保护的请求，再从文件上传正文。
    func uploadObject(bucket: StorageBucket, key: String, file: URL) async throws {
        try await validateNonOverwritingWrites(bucket: bucket)
        let request = try await signUpload(bucket: bucket, key: key)
        try Task.checkCancellation()
        try await ObjectTransfer.uploadObject(file, with: request)
    }

    #if os(macOS)
    /// Mac 前台使用账号签名的 OSS PUT，应用任务确认的覆盖策略并报告发送进度。
    func uploadFileWithAccount(
        bucket: StorageBucket, key: String, file: URL, allowsOverwrite: Bool = false,
        progress: @Sendable @escaping (Int64) -> Void
    ) async throws {
        do {
            try Task.checkCancellation()
            _ = try await makeClient(bucket).putObject(PutObjectRequest(
                bucket: bucket.name, key: key, forbidOverwrite: !allowsOverwrite, body: .file(file),
                progress: ProgressClosure { _, total, _ in progress(total) }
            ))
        } catch let error as ServerError {
            throw ossUploadError(error)
        }
    }
    #endif

    /// 将禁止覆盖的条件纳入签名，并返回上传必须携带的请求头。
    func signUpload(bucket: StorageBucket, key: String) async throws -> URLRequest {
        try await signUpload(bucket: bucket, key: key, allowsOverwrite: false)
    }

    /// 将用户本次确认的覆盖策略纳入 OSS PUT 签名。
    func signUpload(bucket: StorageBucket, key: String, allowsOverwrite: Bool) async throws -> URLRequest {
        let result = try await makeClient(bucket).presign(
            PutObjectRequest(bucket: bucket.name, key: key, forbidOverwrite: !allowsOverwrite),
            Date().addingTimeInterval(3600)
        )
        return try makeUploadURLRequest(result)
    }

    /// 保留 OSS SDK 签名所需的全部请求头，供文件上传复用。
    func makeUploadURLRequest(_ result: PresignResult) throws -> URLRequest {
        guard let url = URL(string: result.url), url.scheme == "https" else {
            throw BrowserError.message(appText("服务未生成可用的 HTTPS 上传地址。"))
        }
        var request = URLRequest(url: url)
        request.httpMethod = result.method
        for (name, value) in result.signedHeaders ?? [:] {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    /// OSS 删除接口没有 If-Match。先检查版本标记，拒绝删除已观测到被改写的对象。
    func deleteObject(bucket: StorageBucket, key: String, etag: String?) async throws {
        let client = makeClient(bucket)
        if let etag {
            _ = try await client.headObject(HeadObjectRequest(bucket: bucket.name, key: key, ifMatch: etag))
        }
        try Task.checkCancellation()
        _ = try await client.deleteObject(DeleteObjectRequest(bucket: bucket.name, key: key))
    }

    /// 一次移动开始前确认 OSS 版本设置。启用或暂停版本控制时，服务端忽略禁止覆盖条件。
    func validateNonOverwritingWrites(bucket: StorageBucket) async throws {
        let versioning = try await makeClient(bucket).getBucketVersioning(
            GetBucketVersioningRequest(bucket: bucket.name)
        )
        guard versioning.versioningConfiguration?.status?.isEmpty != false else {
            throw BrowserError.message(appText("此 OSS Bucket 的版本状态不支持禁止覆盖写入。"))
        }
    }

    /// 启用禁止覆盖条件，收到目标 ETag 后才报告复制完成。
    func copyObject(bucket: StorageBucket, source: StorageObject, destination: String) async throws {
        let result = try await makeClient(bucket).copyObject(CopyObjectRequest(
            bucket: bucket.name, key: destination, sourceBucket: bucket.name,
            sourceKey: source.key, forbidOverwrite: true, copySourceIfMatch: source.etag
        ))
        guard result.etag?.isEmpty == false else {
            throw BrowserError.message(appText("OSS 未确认目标对象已复制。"))
        }
    }

    /// OSS V4 预签名由 SDK 生成，只接受 HTTPS 地址。
    func signDownload(bucket: StorageBucket, key: String, expiry: TimeInterval) async throws -> URL {
        let result = try await makeClient(bucket).presign(
            AlibabaCloudOSS.GetObjectRequest(bucket: bucket.name, key: key), Date().addingTimeInterval(expiry)
        )
        guard let url = URL(string: result.url), url.scheme == "https" else {
            throw BrowserError.message(appText("服务未生成可用的 HTTPS 签名地址。"))
        }
        return url
    }

    /// 自定义代理端点保留部署路径，SDK 仍按原始 Bucket 和 key 签名。
    func makeClient(_ bucket: StorageBucket? = nil) -> Client {
        let credentials = StaticCredentialsProvider(
            accessKeyId: profile.accessKeyID,
            accessKeySecret: profile.secret,
            securityToken: profile.sessionToken.isEmpty ? nil : profile.sessionToken
        )
        let config = Configuration.default()
            .withRegion(bucket?.region ?? profile.region)
            .withCredentialsProvider(credentials)
        let explicit = URLComponents(string: profile.endpoint)
        let usesGateway = explicit?.percentEncodedPath.contains(where: { $0 != "/" }) == true
        let endpoint = (usesGateway ? profile.endpoint : bucket?.endpoint)
            ?? (profile.endpoint.isEmpty ? nil : profile.endpoint)
        if let endpoint { _ = config.withEndpoint(endpoint) }
        guard usesGateway, let explicit, let host = explicit.host else { return Client(config) }

        // SDK 0.4.0 默认只取 endpoint 的 host/port。通过公开端点构造器保留原有 path。
        return Client(config) { options in
            options.endpointProvider = { input in
                var endpoint = explicit
                var path = explicit.percentEncodedPath
                while path.hasSuffix("/") { path.removeLast() }
                let ip = IPv4Address(host) != nil || host.contains(":")
                if let bucket = input.bucket {
                    if ip {
                        path += "/" + bucket
                    } else {
                        endpoint.host = bucket + "." + host
                    }
                }
                if let key = input.key {
                    let safe = CharacterSet(
                        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~/"
                    )
                    guard let encoded = key.addingPercentEncoding(withAllowedCharacters: safe) else {
                        throw BrowserError.message(appText("无法编码 OSS 对象路径。"))
                    }
                    path += "/" + encoded
                }
                endpoint.percentEncodedPath = path.isEmpty ? "/" : path
                guard let url = endpoint.url else { throw BrowserError.message(appText("无法解析 OSS 端点。")) }
                return url.absoluteString
            }
        }
    }
}

/// 提取 OSS 上传失败的业务错误和请求 ID，供失败任务展示。
func ossUploadError(_ error: ServerError) -> BrowserError {
    let details = [appText("上传失败"), "HTTP \(error.statusCode)", error.code, error.message, error.requestId]
    return .message(details.filter { !$0.isEmpty }.joined(separator: " · "))
}
