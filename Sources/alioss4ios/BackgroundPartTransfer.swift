// Copyright 2026 jinlongliao
// SPDX-License-Identifier: Apache-2.0

#if os(iOS)
import Foundation
import UIKit

/// 每次仅向系统交接队列正在处理的一个分片。应用只在收到 ETag 后推进断点。
@MainActor
final class BackgroundPartTransfer: NSObject, URLSessionTaskDelegate {
    static let shared = BackgroundPartTransfer()
    static let identifier = "io.github.jinlongliao.alioss4ios.upload-parts"

    /// 系统会话跨进程保存标签，回调据此定位原分片，不存放签名 URL 或账号密钥。
    struct Part: Codable {
        let recordID: UUID
        let uploadID: String?
        let number: Int?
    }

    private var pending: (
        id: UUID, task: URLSessionUploadTask, result: CheckedContinuation<String, Error>, progress: (Int64) -> Void
    )?
    private var recoveringTaskIDs: Set<Int> = []
    /// 枚举系统任务时回调可先到达，暂存已结束的 ID，避免等待已交付的回调。
    private var finishedBeforeRecovery: Set<Int> = []
    private var finishRecovery: CheckedContinuation<Void, Never>?
    private var finishBackgroundEvents: (() -> Void)?
    private var checkedExistingTasks = false

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.sessionSendsLaunchEvents = true
        configuration.timeoutIntervalForResource = 3600
        return URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
    }()

    var hasInFlightPart: Bool { pending != nil }

    /// 队列在把任务标记为运行前调用，保证迟到回执先更新已确认分片。
    func recoverExistingUploads() async {
        guard !checkedExistingTasks else { return }
        let existing = await session.allTasks
        let unfinished = existing.filter {
            $0.state != .completed && !finishedBeforeRecovery.contains($0.taskIdentifier)
        }
        if !unfinished.isEmpty {
            await withCheckedContinuation { continuation in
                recoveringTaskIDs = Set(unfinished.map(\.taskIdentifier))
                finishRecovery = continuation
                // 旧进程的 Swift 任务无法继续，确认终态后再用持久化断点重新调度。
                unfinished.forEach { $0.cancel() }
            }
        }
        finishedBeforeRecovery.removeAll()
        checkedExistingTasks = true
    }

    /// 系统接收文件后可独立传输。用户主动暂停仍取消任务并等待终态回调。
    func uploadPart(
        from file: URL, request: URLRequest, part: Part, progress: @escaping (Int64) -> Void
    ) async throws -> String {
        let taskDescription = try JSONEncoder().encode(part).base64EncodedString()
        try Task.checkCancellation()
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { result in
                let task = session.uploadTask(with: request, fromFile: file)
                task.taskDescription = taskDescription
                pending = (id, task, result, progress)
                task.resume()
            }
        } onCancel: {
            Task { @MainActor in
                if self.pending?.id == id { self.pending?.task.cancel() }
            }
        }
    }

    /// 系统唤醒应用时重建同一会话，并在交付该批事件后通知系统。
    func reconnect(_ completion: @escaping () -> Void) {
        finishBackgroundEvents = completion
        _ = session
    }

    /// 进度属于系统当前执行的任务，不用于恢复断点。
    nonisolated func urlSession(
        _ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64, totalBytesExpectedToSend: Int64
    ) {
        MainActor.assumeIsolated {
            guard let pending, pending.task.taskIdentifier == task.taskIdentifier else { return }
            pending.progress(totalBytesSent)
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        MainActor.assumeIsolated {
            if !checkedExistingTasks { finishedBeforeRecovery.insert(task.taskIdentifier) }
            if recoveringTaskIDs.remove(task.taskIdentifier) != nil, recoveringTaskIDs.isEmpty {
                finishRecovery?.resume()
                finishRecovery = nil
            }
            let result: Result<String, Error>
            if let error {
                result = .failure(error)
            } else if let response = task.response as? HTTPURLResponse,
                      (200..<300).contains(response.statusCode),
                      response.url == task.originalRequest?.url,
                      let etag = response.value(forHTTPHeaderField: "ETag"), !etag.isEmpty {
                result = .success(etag)
            } else {
                result = .failure(BrowserError.message(appText("服务未确认后台分片完成。")))
            }
            if let pending, pending.task.taskIdentifier == task.taskIdentifier {
                self.pending = nil
                pending.result.resume(with: result)
            } else if case let .success(etag) = result,
                      let description = task.taskDescription, let data = Data(base64Encoded: description),
                      let part = try? JSONDecoder().decode(Part.self, from: data) {
                if let uploadID = part.uploadID, let number = part.number {
                    UploadQueue.shared.recordRecoveredUploadPart(
                        recordID: part.recordID, uploadID: uploadID,
                        receipt: UploadPartReceipt(number: number, etag: etag)
                    )
                } else if part.uploadID == nil, part.number == nil {
                    UploadQueue.shared.recordRecoveredSingleUpload(recordID: part.recordID)
                }
            }
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        MainActor.assumeIsolated {
            let completion = finishBackgroundEvents
            finishBackgroundEvents = nil
            // 延至下一次主队列执行，让当前回调唤醒的上传任务先写入断点。
            DispatchQueue.main.async { completion?() }
        }
    }
}

/// 将系统后台会话事件转发给应用唯一的分片会话。
final class IOSApplicationDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == BackgroundPartTransfer.identifier else {
            completionHandler()
            return
        }
        BackgroundPartTransfer.shared.reconnect(completionHandler)
    }
}
#endif
