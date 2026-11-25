// Copyright 2026 jinlongliao
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import UniformTypeIdentifiers

/// 可在两端交换的 ALOS 密文文档。文件选择由系统完成。
private struct ProfileBackupDocument: FileDocument {
    /// 识别 Android 的后缀和 Apple 版早期导出的旧后缀。
    static let exportType = UTType(filenameExtension: "aloss", conformingTo: .data) ?? .data
    static let readableContentTypes = [
        exportType,
        UTType(filenameExtension: "alos", conformingTo: .data) ?? .data,
    ]
    let data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        guard let contents = configuration.file.regularFileContents,
              contents.count <= ProfileBackup.maximumLength else {
            throw BrowserError.message(appText("无法读取配置备份。"))
        }
        data = contents
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// 密码不持久化，导入只有完整解密并验证后才交给钥匙串保存。
struct ProfileBackupView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var notice = ""
    @State private var working = false
    @State private var importing = false
    @State private var exporting = false
    @State private var confirmingPasswordlessExport = false
    @State private var document: ProfileBackupDocument?

    let profiles: [StorageProfile]
    let importProfiles: ([StorageProfile]) throws -> Void

    var body: some View {
        NavigationStack {
            Form {
                SecureField(appText("备份密码"), text: $password)
                Button(appText("导出加密备份"), systemImage: "square.and.arrow.up") {
                    if password.isEmpty { confirmingPasswordlessExport = true } else { exportBackup() }
                }
                .disabled(working || profiles.isEmpty)
                Button(appText("导入并合并备份"), systemImage: "square.and.arrow.down") { importing = true }
                    .disabled(working)
                if working { ProgressView() }
                if !notice.isEmpty { Text(notice).foregroundStyle(.secondary) }
            }
            .padding()
            .navigationTitle(appText("账号备份"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(appText("关闭")) { dismiss() }.disabled(working) }
            }
        }
        .frame(minWidth: 340, minHeight: 240)
        .interactiveDismissDisabled(working)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data], onCompletion: readBackup)
        .confirmationDialog(
            appText("导出免密码备份"), isPresented: $confirmingPasswordlessExport, titleVisibility: .visible
        ) {
            Button(appText("导出免密码备份")) { exportBackup() }
            Button(appText("取消"), role: .cancel) {}
        } message: {
            Text(appText("免密码备份使用应用共用密钥，拿到文件的人可以读取账号配置。"))
        }
        .fileExporter(
            isPresented: $exporting, document: document, contentType: .data, defaultFilename: "alioss4ios.aloss"
        ) {
            if case .failure = $0 { notice = appText("未能保存加密备份。") }
            document = nil
        }
    }

    /// 密码派生在后台执行，界面关闭或任务完成后清空密码。
    private func exportBackup() {
        let snapshot = profiles
        let key = password
        password = ""
        working = true
        notice = ""
        Task {
            defer { working = false }
            do {
                let data = try await Task.detached(priority: .userInitiated) {
                    try ProfileBackup.exportProfiles(snapshot, password: key)
                }.value
                document = ProfileBackupDocument(data: data)
                exporting = true
            } catch {
                notice = appText("无法生成加密备份。")
            }
        }
    }

    /// 先验证文件大小，再解密和合并，防止部分配置失败时覆盖现有数据。
    private func readBackup(_ selection: Result<URL, Error>) {
        guard case let .success(url) = selection else { return }
        let key = password
        password = ""
        working = true
        notice = ""
        Task {
            defer { working = false }
            do {
                let profiles = try await Task.detached(priority: .userInitiated) {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                    guard values.isRegularFile == true, let size = values.fileSize,
                          size <= ProfileBackup.maximumLength else {
                        throw BrowserError.message(appText("备份文件超过大小上限，或不是普通文件。"))
                    }
                    let file = try FileHandle(forReadingFrom: url)
                    defer { try? file.close() }
                    let data = try file.read(upToCount: ProfileBackup.maximumLength + 1) ?? Data()
                    return try ProfileBackup.importProfiles(data, password: key)
                }.value
                try importProfiles(profiles)
                notice = String(format: appText("已导入 %lld 个账号。"), Int64(profiles.count))
            } catch {
                notice = (error as? BrowserError)?.localizedDescription ?? appText("无法读取或解密备份。")
            }
        }
    }
}
