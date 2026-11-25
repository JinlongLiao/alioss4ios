// Copyright 2026 jinlongliao
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// 与 Android 按相同顺序展示主题及浅色缩略预览。选择配色不改变明暗设置。
struct ThemePalettePicker: View {
    @Environment(\.dismiss) private var dismiss
    let selected: BrowserPalette
    let dark: Bool
    let onSelect: (BrowserPalette) -> Void

    var body: some View {
        NavigationStack {
            ScrollViewReader { reader in
                List(BrowserPalette.allCases) { palette in
                    Button {
                        onSelect(palette)
                        dismiss()
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: palette == selected ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(palette == selected ? Color.accentColor : .secondary)
                                .accessibilityHidden(true)
                            Text(palette.title)
                            Spacer(minLength: 8)
                            preview(palette).accessibilityHidden(true)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(palette == selected ? .isSelected : [])
                    .listRowBackground(Color.clear)
                    .id(palette)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background { selected.browserBackdrop(dark: dark).ignoresSafeArea() }
                .onAppear { reader.scrollTo(selected, anchor: .center) }
            }
            .navigationTitle(appText("配色主题"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(appText("关闭")) { dismiss() } }
            }
        }
        .frame(minWidth: 320, minHeight: 350)
    }

    /// 预览用实际浅色工作区和主题主色，缩略卡片沿用该主题圆角。
    private func preview(_ palette: BrowserPalette) -> some View {
        VStack(spacing: 4) {
            ForEach(0..<2) { _ in
                HStack(spacing: 5) {
                    Circle().fill(palette.tint(dark: false)).frame(width: 6, height: 6)
                    Rectangle().fill(.black.opacity(0.27)).frame(width: 31, height: 2)
                    Spacer(minLength: 0)
                }
                .padding(3)
                .background(.white.opacity(0.52), in: RoundedRectangle(cornerRadius: max(2, palette.cardRadius / 4)))
            }
        }
        .padding(5)
        .frame(width: 80, height: 46)
        .background { palette.browserBackdrop(dark: false).clipShape(RoundedRectangle(cornerRadius: 7)) }
        .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(.primary.opacity(0.15), lineWidth: 1) }
    }
}
