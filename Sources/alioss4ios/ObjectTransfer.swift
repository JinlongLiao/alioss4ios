// Copyright 2026 jinlongliao
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// 文件传输不共享 Cookie 或凭据缓存。预签名请求只发往签名时确定的 HTTPS 地址。
enum ObjectTransfer {
    private static let session = URLSession(
        configuration: .ephemeral, delegate: SignedRequestDelegate(), delegateQueue: nil
    )

    /// 直接下载到磁盘。只有预览需要限制传输量，普通下载仍使用原生下载任务。
    static func downloadObject(from url: URL, maximumLength: Int? = nil) async throws -> URL {
        if let maximumLength {
            return try await downloadBoundedPreview(from: url, maximumLength: maximumLength)
        }
        let (file, response) = try await session.download(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            try? FileManager.default.removeItem(at: file)
            throw BrowserError.message(appText("对象下载失败。"))
        }
        return file
    }

    /// 按固定大小的块写入磁盘；即使服务端未声明长度，也在首个超限字节停止。
    private static func downloadBoundedPreview(from url: URL, maximumLength: Int) async throws -> URL {
        let (bytes, response) = try await session.bytes(from: url)
        defer { bytes.task.cancel() }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw BrowserError.message(appText("对象下载失败。"))
        }
        guard response.expectedContentLength <= maximumLength else { throw previewSizeError() }
        let file = URL.temporaryDirectory.appending(path: UUID().uuidString)
        do {
            try Data().write(to: file, options: .withoutOverwriting)
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            let chunkSize = 64 * 1024
            var chunk = Data()
            chunk.reserveCapacity(chunkSize)
            var count = 0
            for try await byte in bytes {
                guard count < maximumLength else { throw previewSizeError() }
                chunk.append(byte)
                count += 1
                if chunk.count == chunkSize {
                    try handle.write(contentsOf: chunk)
                    chunk.removeAll(keepingCapacity: true)
                }
            }
            if !chunk.isEmpty { try handle.write(contentsOf: chunk) }
            return file
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
    }

    /// 所有预览分支使用同一条超限提示。
    static func previewSizeError() -> BrowserError {
        .message(appText("对象超过预览上限，请下载后打开。"))
    }

    /// 读取小型预览，实际收到的字节数和声明长度都受同一上限约束。
    static func readObject(from url: URL, maximumLength: Int) async throws -> Data {
        try await readObjectSnapshot(from: url, maximumLength: maximumLength).data
    }

    /// ETag 来自下载正文的同一响应，避免将草稿绑定到较晚的对象版本。
    static func readObjectSnapshot(
        from url: URL, maximumLength: Int, matchingETag: String? = nil
    ) async throws -> (data: Data, etag: String?) {
        var request = URLRequest(url: url)
        if let matchingETag {
            // 避免对象存储按请求动态压缩并改变响应的正文表示及 ETag。
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            // 条件重读必须由服务端校验；URLCache 可能忽略 If-Match 并直接返回旧正文。
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            request.setValue(matchingETag, forHTTPHeaderField: "If-Match")
        }
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let response = response as? HTTPURLResponse else {
            throw BrowserError.message(appText("无法读取预览数据。"))
        }
        guard response.statusCode == 200 else {
            throw BrowserError.previewHTTPStatus(response.statusCode)
        }
        guard response.expectedContentLength <= maximumLength else {
            throw BrowserError.message(appText("对象超过预览上限。"))
        }
        var data = Data()
        for try await byte in bytes {
            guard data.count < maximumLength else { throw BrowserError.message(appText("对象超过预览上限。")) }
            data.append(byte)
        }
        return (data, response.value(forHTTPHeaderField: "ETag"))
    }

    /// 从本地文件上传，服务端必须确认成功。
    static func uploadObject(_ file: URL, with request: URLRequest) async throws {
        _ = try await uploadSignedFile(file, with: request)
    }

    /// 返回服务端响应头，分片上传用它获取 ETag。进度回调只报告网络发送量。
    static func uploadSignedFile(
        _ file: URL, with request: URLRequest, progress: (@Sendable (Int64) -> Void)? = nil
    ) async throws -> HTTPURLResponse {
        let delegate = progress.map { SignedRequestDelegate(progress: $0) }
        let (_, response) = try await session.upload(for: request, fromFile: file, delegate: delegate)
        guard let response = response as? HTTPURLResponse else {
            throw BrowserError.message(appText("上传未确认完成。可继续任务，或刷新远端目录核对目标对象。"))
        }
        guard (200..<300).contains(response.statusCode) else {
            let status = "HTTP \(response.statusCode) " + HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
            let requestID = response.value(forHTTPHeaderField: "x-oss-request-id")
                ?? response.value(forHTTPHeaderField: "x-amz-request-id")
            let detail = requestID.map { status + " · " + $0 } ?? status
            throw BrowserError.message(appText("上传失败") + " · " + detail)
        }
        return response
    }
}

/// 拒绝重定向，防止把查询中的临时凭据发往其他主机。
private final class SignedRequestDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let progress: (@Sendable (Int64) -> Void)?


    init(progress: (@Sendable (Int64) -> Void)? = nil) {
        self.progress = progress
    }

    /// SDK 可能重发请求，调用方使用当前请求的累计字节更新界面。
    func urlSession(
        _ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64, totalBytesExpectedToSend: Int64
    ) {
        progress?(totalBytesSent)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}


/// 只接受单一强 ETag，拒绝通配符、弱标记和能够注入其它头的值。
func textEditETag(_ raw: String?) -> String? {
    guard let raw else { return nil }
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    let unquoted = value.hasPrefix("\"") && value.hasSuffix("\"") ? String(value.dropFirst().dropLast()) : value
    guard !unquoted.isEmpty, unquoted != "*", unquoted.utf8.allSatisfy({ $0 >= 0x21 && $0 <= 0x7E && $0 != 0x22 }),
          !unquoted.hasPrefix("W/") else { return nil }
    return "\"\(unquoted)\""
}
