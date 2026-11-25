// Copyright 2026 jinlongliao
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// 编辑同一 Bucket 的目标路径。开启二次确认时，提交前先展示固定的源和目标。
struct MoveObjectView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var destination: String
    @State private var confirmationDestination: String?

    private let sourceKey: String
    private let isDirectory: Bool
    private let requiresConfirmation: Bool
    private let commitMove: (String) -> Void

    init(sourceKey: String, isDirectory: Bool, requiresConfirmation: Bool, commitMove: @escaping (String) -> Void) {
        self.sourceKey = sourceKey
        self.isDirectory = isDirectory
        self.requiresConfirmation = requiresConfirmation
        self.commitMove = commitMove
        _destination = State(initialValue: sourceKey)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField(appText("同 Bucket 的目标路径"), text: $destination)
                    .disabled(confirmationDestination != nil)
                if let confirmationDestination {
                    LabeledContent(appText("源路径"), value: sourceKey)
                    LabeledContent(appText("目标路径"), value: confirmationDestination)
                    if isDirectory {
                        Text(appText("目录内的所有对象将逐个移动。"))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(appText("移动或重命名"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(appText("取消")) {
                        if confirmationDestination != nil {
                            confirmationDestination = nil
                        } else {
                            dismiss()
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(appText(requiresConfirmation && confirmationDestination == nil ? "继续" : "确认移动")) {
                        submitMove()
                    }
                    .disabled(destination.isEmpty || destination.utf8.elementsEqual(sourceKey.utf8))
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 220)
        #endif
    }

    /// 目标只在编辑阶段写入，确认阶段提交已展示的路径。
    private func submitMove() {
        if let confirmationDestination {
            commitMove(confirmationDestination)
        } else if requiresConfirmation {
            confirmationDestination = destination
            return
        } else {
            commitMove(destination)
        }
        dismiss()
    }
}
