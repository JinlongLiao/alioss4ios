// Copyright 2026 jinlongliao
// SPDX-License-Identifier: Apache-2.0

import AlibabaCloudOSS
import AWSS3
import Foundation
import SmithyStreams

/// 分片写入操作共享同一个固定 Bucket 和原始对象 key。
struct UploadTarget: Codable, Hashable {
    let bucket: StorageBucket
    let key: String
    /// 仅在用户明确确认后构造允许覆盖的 OSS 请求目标。
    var allowsOverwrite: Bool? = nil
}

/// 只有服务器确认接受分片后才记录其序号与 ETag。
struct UploadPartReceipt: Codable, Equatable {
    let number: Int
    let etag: String
}

protocol MultipartStorage: ObjectStorage {
    func beginMultipartUpload(target: UploadTarget) async throws -> String
    func uploadPart(target: UploadTarget, uploadID: String, file: URL, number: Int) async throws -> UploadPartReceipt
    func completeMultipartUpload(target: UploadTarget, uploadID: String, parts: [UploadPartReceipt]) async throws
    func abortMultipartUpload(target: UploadTarget, uploadID: String) async throws
}

/// 预签名请求与正文分开，使系统可直接从磁盘发送指定分片。
protocol BackgroundUploadSigning {
    func signUpload(bucket: StorageBucket, key: String) async throws -> URLRequest
    func signUploadPart(target: UploadTarget, uploadID: String, number: Int) async throws -> URLRequest
}

extension OssStorage: BackgroundUploadSigning {
    /// 为系统文件上传生成固定分片的请求，传输正文由 URLSession 从磁盘读取。
    func signUploadPart(target: UploadTarget, uploadID: String, number: Int) async throws -> URLRequest {
        let result = try await makeClient(target.bucket).presign(
            AlibabaCloudOSS.UploadPartRequest(
                bucket: target.bucket.name, key: target.key, partNumber: number, uploadId: uploadID
            ),
            Date().addingTimeInterval(3600)
        )
        return try makeUploadURLRequest(result)
    }


    /// 普通上传先检查 Bucket 版本控制。明确确认覆盖后直接申请上传 ID。
    func beginMultipartUpload(target: UploadTarget) async throws -> String {
        if target.allowsOverwrite != true { try await validateNonOverwritingWrites(bucket: target.bucket) }
        let output = try await makeClient(target.bucket).initiateMultipartUpload(InitiateMultipartUploadRequest(
            bucket: target.bucket.name, key: target.key, forbidOverwrite: target.allowsOverwrite != true
        ))
        guard let id = output.uploadId, !id.isEmpty else {
            throw BrowserError.message(appText("OSS 未返回分片上传 ID。"))
        }
        return id
    }

    /// SDK 直接读取临时分片文件并校验服务端返回的 ETag。
    func uploadPart(target: UploadTarget, uploadID: String, file: URL, number: Int) async throws -> UploadPartReceipt {
        try await uploadPartWithAccount(target: target, uploadID: uploadID, file: file, number: number, progress: nil)
    }

    /// 使用账号签名发送文件分片，可选回调仅报告传输进度，断点以返回的 ETag 为准。
    func uploadPartWithAccount(
        target: UploadTarget, uploadID: String, file: URL, number: Int, progress: ProgressClosure?
    ) async throws -> UploadPartReceipt {
        let output = try await makeClient(target.bucket).uploadPart(AlibabaCloudOSS.UploadPartRequest(
            bucket: target.bucket.name, key: target.key, partNumber: number, uploadId: uploadID, body: .file(file),
            progress: progress
        ))
        guard let etag = output.etag, !etag.isEmpty else {
            throw BrowserError.message(appText("OSS 未确认分片完成。"))
        }
        return UploadPartReceipt(number: number, etag: etag)
    }

    /// 合并时按任务授权设置覆盖策略，服务端返回目标对象 ETag 才报告成功。
    func completeMultipartUpload(target: UploadTarget, uploadID: String, parts: [UploadPartReceipt]) async throws {
        if target.allowsOverwrite != true { try await validateNonOverwritingWrites(bucket: target.bucket) }
        let output = try await makeClient(target.bucket).completeMultipartUpload(CompleteMultipartUploadRequest(
            bucket: target.bucket.name, key: target.key, forbidOverwrite: target.allowsOverwrite != true, uploadId: uploadID,
            completeMultipartUpload: CompleteMultipartUpload(
                parts: parts.map { AlibabaCloudOSS.UploadPart(etag: $0.etag, partNumber: $0.number) }
            )
        ))
        guard output.etag?.isEmpty == false else { throw BrowserError.message(appText("OSS 未确认对象合并完成。")) }
    }

    /// 撤销单个上传会话，服务端释放已上传但未合并的分片。
    func abortMultipartUpload(target: UploadTarget, uploadID: String) async throws {
        _ = try await makeClient(target.bucket).abortMultipartUpload(AbortMultipartUploadRequest(
            bucket: target.bucket.name, key: target.key, uploadId: uploadID
        ))
    }
}

extension S3Storage: BackgroundUploadSigning {
    /// 发起服务端分片会话，覆盖条件在最终合并时检查。
    func beginMultipartUpload(target: UploadTarget) async throws -> String {
        let output = try await makeClient(target.bucket).createMultipartUpload(input: CreateMultipartUploadInput(
            bucket: target.bucket.name, key: target.key
        ))
        guard let id = output.uploadId, !id.isEmpty else {
            throw BrowserError.message(appText("S3 未返回分片上传 ID。"))
        }
        return id
    }

    /// SDK 从磁盘流式读取单片，避免随源文件或分片大小增长内存占用。
    func uploadPart(target: UploadTarget, uploadID: String, file: URL, number: Int) async throws -> UploadPartReceipt {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let stream = FileStream(fileHandle: handle)
        let output = try await makeClient(target.bucket).uploadPart(input: UploadPartInput(
            body: .stream(stream), bucket: target.bucket.name, contentLength: stream.length, key: target.key,
            partNumber: number, uploadId: uploadID
        ))
        guard let etag = output.eTag, !etag.isEmpty else {
            throw BrowserError.message(appText("S3 未确认分片完成。"))
        }
        return UploadPartReceipt(number: number, etag: etag)
    }

    /// 上送按分片序号排列的 ETag，拒绝合并到已经存在的对象名。
    func completeMultipartUpload(target: UploadTarget, uploadID: String, parts: [UploadPartReceipt]) async throws {
        let output = try await makeClient(target.bucket).completeMultipartUpload(input: CompleteMultipartUploadInput(
            bucket: target.bucket.name, ifNoneMatch: "*", key: target.key,
            multipartUpload: .init(parts: parts.map { .init(eTag: $0.etag, partNumber: $0.number) }),
            uploadId: uploadID
        ))
        guard output.eTag?.isEmpty == false else { throw BrowserError.message(appText("S3 未确认对象合并完成。")) }
    }

    /// 使用与原分片请求相同的端点和 Upload ID 释放会话。
    func abortMultipartUpload(target: UploadTarget, uploadID: String) async throws {
        _ = try await makeClient(target.bucket).abortMultipartUpload(input: AbortMultipartUploadInput(
            bucket: target.bucket.name, key: target.key, uploadId: uploadID
        ))
    }
}
