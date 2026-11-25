// Copyright 2026 jinlongliao
// SPDX-License-Identifier: Apache-2.0

#if os(iOS)
import SwiftUI
import UIKit

/// 按文件名保留扩展名，临时目录独立存放。
struct LocalObjectFile: Identifiable {
    let url: URL

    var id: URL { url }

    static func stageFile(_ temporary: URL, name: String) throws -> LocalObjectFile {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let filename = name.isEmpty || name == "." || name == ".." ? "文件" : name
        let destination = directory.appending(component: filename)
        do {
            try FileManager.default.moveItem(at: temporary, to: destination)
            return LocalObjectFile(url: destination)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
}

/// 文档提供者复制完成或用户取消后才删除临时下载。
struct ObjectExportPicker: UIViewControllerRepresentable {
    let file: LocalObjectFile
    let close: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(directory: file.url.deletingLastPathComponent(), close: close) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let controller = UIDocumentPickerViewController(forExporting: [file.url], asCopy: true)
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    static func dismantleUIViewController(_ controller: UIDocumentPickerViewController, coordinator: Coordinator) {
        try? FileManager.default.removeItem(at: coordinator.directory)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let close: () -> Void
        let directory: URL

        init(directory: URL, close: @escaping () -> Void) {
            self.directory = directory
            self.close = close
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { close() }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { close() }
    }
}
#endif
