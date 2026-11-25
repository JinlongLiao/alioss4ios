// Copyright 2026 jinlongliao
// SPDX-License-Identifier: Apache-2.0

import AWSS3
import AWSSDKIdentity
import ClientRuntime
import Foundation
import SmithyHTTPAPI
import SmithyStreams

/// S3 浏览适配器，使用固定账号凭据和可选 SessionToken，支持自定义 HTTPS 端点。
struct S3Storage: ObjectStorage, MultipartStorage {
    let profile: StorageProfile

    /// 默认使用 SDK 的 HTTPS 客户端。测试可捕获最终出站请求和文件流。
    var httpClient: (any HTTPClient)? = nil

    /// 默认 Bucket 跳过账户级列举，供最小权限用户直接访问。
    func listBuckets() async throws -> [StorageBucket] {
        if !profile.bucket.isEmpty { return [StorageBucket(name: profile.bucket)] }
        let client = try makeClient()
        // AWS 在分页响应中返回 BucketRegion，后续浏览和签名都使用这个区域。
        // https://docs.aws.amazon.com/AmazonS3/latest/userguide/list-buckets.html
        let maxBuckets = profile.endpoint.isEmpty ? 1000 : nil
        var token: String?
        var buckets: [StorageBucket] = []
        repeat {
            let lastToken = token
            let response = try await client.listBuckets(input: ListBucketsInput(
                continuationToken: token, maxBuckets: maxBuckets
            ))
            buckets += (response.buckets ?? []).compactMap { bucket in
                guard let name = bucket.name else { return nil }
                let region = profile.endpoint.isEmpty ? bucket.bucketRegion : nil
                return StorageBucket(name: name, region: region, createdAt: bucket.creationDate)
            }
            token = response.continuationToken
            if token == lastToken { break }
        } while token?.isEmpty == false
        return buckets.sorted { $0.name < $1.name }
    }

    /// 使用服务端返回的不透明游标，目录和文件保留各自的完整 key。
    func listObjects(
        bucket: StorageBucket, prefix: String, cursor: String?, delimiter: String?, pageSize: Int
    ) async throws -> StoragePage {
        let result = try await makeClient(bucket).listObjectsV2(input: ListObjectsV2Input(
            bucket: bucket.name, continuationToken: cursor, delimiter: delimiter, maxKeys: pageSize, prefix: prefix
        ))
        let directories = (result.commonPrefixes ?? []).compactMap { entry -> StorageObject? in
            guard let key = entry.prefix else { return nil }
            return StorageObject(key: key, isDirectory: true)
        }
        let files = (result.contents ?? []).compactMap { item -> StorageObject? in
            guard let key = item.key, delimiter == nil || key != prefix else { return nil }
            return StorageObject(
                key: key, isDirectory: false, size: item.size.map(Int64.init),
                modifiedAt: item.lastModified, etag: item.eTag
            )
        }
        return StoragePage(objects: directories + files, next: result.nextContinuationToken)
    }

    /// 使用当前账号的 S3 SDK 客户端流式读取有限长度的预览数据。
    func readPreviewChunks(
        bucket: StorageBucket, key: String, maximumLength: Int, receive: (Data) throws -> Void
    ) async throws {
        let response: GetObjectOutput
        do {
            response = try await makeClient(bucket).getObject(input: .init(bucket: bucket.name, key: key))
        } catch let error as HTTPError {
            throw BrowserError.previewHTTPStatus(
                error.httpResponse.statusCode.rawValue,
                code: String(describing: type(of: error)),
                requestID: error.httpResponse.headers.value(for: "x-amz-request-id")
            )
        }
        switch response.body {
        case .data(let body):
            let data = body ?? Data()
            guard data.count <= maximumLength else { throw ObjectTransfer.previewSizeError() }
            try receive(data)
        case .stream(let stream):
            defer { stream.close() }
            guard (response.contentLength ?? 0) <= maximumLength else { throw ObjectTransfer.previewSizeError() }
            var received = 0
            while let data = try await stream.readAsync(upToCount: min(16 * 1024, maximumLength - received + 1)),
                  !data.isEmpty {
                try Task.checkCancellation()
                guard data.count <= maximumLength - received else { throw ObjectTransfer.previewSizeError() }
                received += data.count
                try receive(data)
            }
        case .none, .some(.noStream):
            return
        }
    }

    /// 检查同一对象的当前版本，仅在正文响应没有 ETag 时使用。
    func textObjectETag(bucket: StorageBucket, key: String) async throws -> String? {
        try await makeClient(bucket).headObject(input: .init(bucket: bucket.name, key: key)).eTag
    }

    /// PUT 再次执行 If-Match，确保 HEAD 后发生的并发内容更新仍能被服务端拒绝。
    func replaceTextObject(bucket: StorageBucket, key: String, etag: String, content: Data) async throws -> String? {
        let client = try makeClient(bucket)
        let head = try await client.headObject(input: .init(bucket: bucket.name, ifMatch: etag, key: key))
        guard head.contentEncoding?.lowercased() ?? "identity" == "identity",
              (head.tagCount ?? 0) == 0 else {
            throw BrowserError.message(appText("暂不支持更新带内容编码或对象标签的文本。"))
        }
        try Task.checkCancellation()
        var request = PutObjectInput(body: .data(content), bucket: bucket.name, ifMatch: etag, key: key)
        request.contentType = head.contentType
        request.cacheControl = head.cacheControl
        request.contentDisposition = head.contentDisposition
        request.contentLanguage = head.contentLanguage
        request.expires = head.expires
        request.metadata = head.metadata
        request.serverSideEncryption = head.serverSideEncryption
        request.ssekmsKeyId = head.ssekmsKeyId
        request.storageClass = head.storageClass
        let updated = try await client.putObject(input: request)
        return textEditETag(updated.eTag)
    }

    /// 让 SDK 从文件流计算签名和发送正文，避免拆出请求后与实际数据大小不一致。
    func uploadObject(bucket: StorageBucket, key: String, file: URL) async throws {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let stream = FileStream(fileHandle: handle)
        try Task.checkCancellation()
        _ = try await makeClient(bucket).putObject(input: PutObjectInput(
            body: .stream(stream), bucket: bucket.name, contentLength: stream.length, ifNoneMatch: "*", key: key
        ))
    }

    /// 使用服务端 ETag 条件，阻止删除列举后被覆盖的对象。
    func deleteObject(bucket: StorageBucket, key: String, etag: String?) async throws {
        _ = try await makeClient(bucket).deleteObject(input: DeleteObjectInput(
            bucket: bucket.name, ifMatch: etag, key: key
        ))
    }

    /// 厂商 SDK 校验 HTTP 200 中的错误 XML，目标同名时保留源对象。
    func copyObject(bucket: StorageBucket, source: StorageObject, destination: String) async throws {
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~/"
        )
        guard let copySource = (bucket.name + "/" + source.key).addingPercentEncoding(withAllowedCharacters: allowed) else {
            throw BrowserError.message(appText("无法编码源对象路径。"))
        }
        let result = try await makeClient(bucket).copyObject(input: CopyObjectInput(
            bucket: bucket.name, copySource: copySource, copySourceIfMatch: source.etag,
            ifNoneMatch: "*", key: destination
        ))
        guard result.copyObjectResult?.eTag?.isEmpty == false else {
            throw BrowserError.message(appText("S3 未确认目标对象已复制。"))
        }
    }

    /// AWS SDK 负责区域与 SigV4 签名，分享入口仅使用 HTTPS URL。
    func signDownload(bucket: StorageBucket, key: String, expiry: TimeInterval) async throws -> URL {
        let url = try await GetObjectInput(bucket: bucket.name, key: key)
            .presignURL(config: makeConfig(bucket), expiration: expiry)
        guard let url, url.scheme == "https" else {
            throw BrowserError.message(appText("服务未生成可用的 HTTPS 签名地址。"))
        }
        return url
    }

    /// URL 签名的默认序列化不包含条件头，因此在签名前补入防覆盖条件。
    func signUpload(bucket: StorageBucket, key: String) async throws -> URLRequest {
        var config = try makeConfig(bucket)
        config.httpInterceptorProviders.append(ConditionalUploadSigning())
        let signedURL = try await PutObjectInput(bucket: bucket.name, key: key)
            .presignURL(config: config, expiration: 3600)
        guard let url = signedURL, url.scheme == "https",
              let signedHeaders = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "X-Amz-SignedHeaders" })?.value,
              Set(signedHeaders.split(separator: ";")) == ["host", "if-none-match"] else {
            throw BrowserError.message(appText("服务未生成带防覆盖条件的 HTTPS 上传地址。"))
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("*", forHTTPHeaderField: "If-None-Match")
        return request
    }

    /// 使用 AWS SDK 签名固定分片，保留账号端点路径、Bucket 区域和临时凭据。
    func signUploadPart(target: UploadTarget, uploadID: String, number: Int) async throws -> URLRequest {
        let url = try await UploadPartInput(
            bucket: target.bucket.name, key: target.key, partNumber: number, uploadId: uploadID
        ).presignURL(config: makeConfig(target.bucket), expiration: 3600)
        guard let url, url.scheme == "https" else {
            throw BrowserError.message(appText("服务未生成可用的 HTTPS 上传地址。"))
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        return request
    }

    /// SDK 客户端通过与签名相同的配置解析端点及所在区域。
    func makeClient(_ bucket: StorageBucket? = nil) throws -> S3Client {
        S3Client(config: try makeConfig(bucket))
    }

    /// 跳过 AWS 环境端点覆写，同时保留显式配置的部署路径。
    private func makeConfig(_ bucket: StorageBucket?) throws -> S3Client.S3ClientConfig {
        let credentials = AWSCredentialIdentity(
            accessKey: profile.accessKeyID,
            secret: profile.secret,
            sessionToken: profile.sessionToken.isEmpty ? nil : profile.sessionToken
        )
        let resolver = StaticAWSCredentialIdentityResolver(credentials)
        let endpoint = URLComponents(string: profile.endpoint)
        let usesIP = endpoint?.host?.contains(":") == true
        return try S3Client.S3ClientConfig(
            awsCredentialIdentityResolver: resolver,
            maxAttempts: 3,
            requestChecksumCalculation: .whenRequired,
            ignoreConfiguredEndpointURLs: true,
            region: bucket?.region ?? profile.region,
            forcePathStyle: profile.forcePathStyle || usesIP || bucket?.name.contains(".") == true,
            endpoint: profile.endpoint.isEmpty ? nil : profile.endpoint,
            httpClientEngine: httpClient
        )
    }
}

/// 仅安装在小文件预签名配置中，SDK 的其他请求不使用此拦截器。
private struct ConditionalUploadSigning: HttpInterceptorProvider {
    func create<InputType, OutputType>() -> any Interceptor<InputType, OutputType, HTTPRequest, HTTPResponse> {
        ConditionalUploadHeader<InputType, OutputType>()
    }
}

/// 将条件头添加到实际参与 SigV4 签名的请求。
private struct ConditionalUploadHeader<Input, Output>: Interceptor {
    typealias InputType = Input
    typealias OutputType = Output
    typealias RequestType = HTTPRequest
    typealias ResponseType = HTTPResponse

    func modifyBeforeSigning(context: some MutableRequest<Input, HTTPRequest>) async throws {
        let builder = context.getRequest().toBuilder()
        builder.updateHeader(name: "If-None-Match", value: "*")
        context.updateRequest(updated: builder.build())
    }
}
