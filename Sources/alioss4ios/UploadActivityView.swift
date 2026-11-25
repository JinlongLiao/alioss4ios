// Copyright 2026 jinlongliao
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// 当前与历史上传任务共用同一入口，运行、暂停、继续及撤销以队列状态为准。
struct UploadActivityView: View {
    @Environment(UploadQueue.self) private var uploadQueue
    @Environment(\.dismiss) private var dismiss
    @State private var pendingDiscard: UploadRecord?
    /// 保存待确认的任务，确认时显示完整远端路径。
    @State private var pendingOverwrite: UploadRecord?
    let profiles: [StorageProfile]

    var body: some View {
        NavigationStack {
            List {
                if let notice = uploadQueue.notice {
                    Text(appText(notice)).foregroundStyle(.red)
                }
                ForEach(uploadQueue.records.reversed()) { record in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(record.name).font(.headline)
                        Text(record.target.bucket.name + "/" + record.target.key)
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                        if record.status == .running || record.status == .paused || record.status == .failed {
                            ProgressView(
                                value: Double(uploadQueue.displayedUploadBytes(for: record)),
                                total: Double(max(1, record.size))
                            )
                        }
                        Text(appText(record.status.label)).font(.caption)
                        if !record.message.isEmpty {
                            Text(appText(record.message)).foregroundStyle(.red)
                        }
                        uploadActions(record)
                    }
                    .padding(.vertical, 5)
                }
            }
            .overlay {
                if uploadQueue.records.isEmpty && uploadQueue.notice == nil {
                    ContentUnavailableView(appText("暂无上传任务"), systemImage: "tray.and.arrow.up")
                }
            }
            .navigationTitle(appText("上传任务"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(appText("关闭")) { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(appText("清理历史")) { uploadQueue.clearFinishedUploads() }
                        .disabled(!uploadQueue.records.contains { $0.status == .completed || $0.status == .discarded })
                }
            }
            .confirmationDialog(
                appText("放弃上传并清理断点"),
                isPresented: Binding(
                    get: { pendingDiscard != nil },
                    set: { if !$0 { pendingDiscard = nil } }
                ),
                presenting: pendingDiscard
            ) { record in
                Button(appText("放弃上传"), role: .destructive) {
                    Task { await uploadQueue.discardUpload(record, profile: sourceProfile(record)) }
                }
            } message: { record in
                Text(record.name)
            }
            .alert(
                appText("覆盖远端文件？"),
                isPresented: Binding(
                    get: { pendingOverwrite != nil },
                    set: { if !$0 { pendingOverwrite = nil } }
                ),
                presenting: pendingOverwrite
            ) { record in
                Button(appText("覆盖上传"), role: .destructive) {
                    uploadQueue.resumeUpload(record, profile: sourceProfile(record), confirmOverwrite: true)
                }
                Button(appText("取消"), role: .cancel) {}
            } message: { record in
                Text(record.target.bucket.name + "/" + record.target.key)
            }
        }
        .frame(minWidth: 340, minHeight: 390)
    }

    /// 顺序区分暂停和撤销，只有明确撤销才调用服务端 Abort。
    @ViewBuilder
    private func uploadActions(_ record: UploadRecord) -> some View {
        if record.status == .queued || record.status == .running {
            Button(appText("暂停")) { uploadQueue.pauseUpload(record) }.buttonStyle(.borderless)
        } else if record.status == .paused || record.status == .failed {
            HStack {
                Button(appText(record.allowsOverwrite == true ? "继续覆盖上传" : "继续")) {
                    uploadQueue.resumeUpload(record, profile: sourceProfile(record))
                }
                if record.status == .failed && record.provider == .oss && record.allowsOverwrite != true {
                    Button(appText("覆盖上传")) { pendingOverwrite = record }
                }
                Button(appText("放弃"), role: .destructive) { pendingDiscard = record }
            }
            .buttonStyle(.borderless)
            .disabled(uploadQueue.discardingIDs.contains(record.id))
        }
    }

    /// 从当前账号列表找出任务原始账号，队列随后核对其端点配置。
    private func sourceProfile(_ record: UploadRecord) -> StorageProfile? {
        profiles.first { $0.id == record.profileID }
    }
}

private extension UploadRecord.Status {
    /// 展示队列持久化的真实进度状态。
    var label: String {
        switch self {
        case .queued: "排队中"
        case .running: "上传中"
        case .paused: "已暂停"
        case .failed: "上传失败"
        case .completed: "已完成"
        case .discarded: "已放弃"
        }
    }
}
