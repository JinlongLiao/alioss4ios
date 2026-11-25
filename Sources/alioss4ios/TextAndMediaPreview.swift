// Copyright 2026 jinlongliao
// SPDX-License-Identifier: Apache-2.0

import AVKit
import CoreFoundation
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// 文本和媒体分类对应 Android 的文件名规则，播放能力由 Apple 系统解码器决定。
enum PreviewFormat {
    case html, text, markdown, document, image, media, unsupported

    init(name: String) {
        let lower = name.lowercased()
        let ext = (lower as NSString).pathExtension
        switch ext {
        case "html", "htm", "xhtml": self = .html
        case "md", "markdown", "mdown", "mkd", "mkdn": self = .markdown
        case "pdf", "docx", "xlsx", "pptx", "csv", "tsv": self = .document
        case "jpg", "jpeg", "png", "gif", "webp", "bmp", "heic", "heif", "svg": self = .image
        case "mp3", "m4a", "aac", "wav", "flac", "ogg", "oga", "opus", "wma", "amr", "mid", "midi",
             "mp4", "m4v", "mov", "mkv", "webm", "avi", "3gp", "wmv", "flv", "mpeg", "mpg":
            self = .media
        case "txt", "log", "rst", "tex", "adoc", "json", "xml", "yaml", "yml", "toml", "ini", "conf", "cfg",
             "properties", "env", "plist", "css", "scss", "sass", "less", "js", "ts", "jsx", "tsx", "mjs", "cjs",
             "vue", "svelte", "kt", "kts", "java", "gradle", "groovy", "scala", "clj", "cljs", "py", "ipynb",
             "rb", "php", "go", "rs", "swift", "lua", "dart", "erl", "ex", "exs", "c", "cc", "cpp", "cxx",
             "h", "hpp", "cs", "m", "mm", "r", "sh", "bash", "zsh", "fish", "bat", "cmd", "ps1", "psm1",
             "sql", "graphql", "gql", "proto", "thrift", "dockerfile", "tf", "hcl", "gitignore",
             "gitattributes", "gitconfig", "editorconfig":
            self = .text
        default:
            let conventional = ["readme", "license", "changelog", "dockerfile", "makefile", "notice",
                                "authors", "contributors", ".gitignore", ".gitattributes", ".editorconfig", ".env"]
            self = conventional.contains(lower) ? .text : .unsupported
        }
    }
}

/// 预览保留原始文本，Markdown 可切回源码。
/// 逐行比较确认前后的正文。先剥离公共首尾，超出 LCS 预算时展开整个变更区间。
func compareTextEditLines(original: String, draft: String) -> [String] {
    // 按 UTF-8 的 LF 字节分隔，避免 Swift 将 CRLF 视为一个字符而漏拆。
    let before = original.utf8.split(separator: 10, omittingEmptySubsequences: false)
    let after = draft.utf8.split(separator: 10, omittingEmptySubsequences: false)
    let commonSize = min(before.count, after.count)
    var start = 0
    while start < commonSize, before[start].elementsEqual(after[start]) { start += 1 }
    var end = 0
    while end < commonSize - start,
          before[before.count - 1 - end].elementsEqual(after[after.count - 1 - end]) { end += 1 }
    if start == before.count, start == after.count { return [] }

    func diffLine(_ prefix: String, _ line: String.UTF8View.SubSequence) -> String {
        prefix + String(decoding: line, as: UTF8.self).replacingOccurrences(of: "\r", with: "␍")
    }

    let removed = Array(before[start..<(before.count - end)])
    let added = Array(after[start..<(after.count - end)])
    var diff = before[max(0, start - 3)..<start].map { diffLine("  ", $0) }
    if !removed.isEmpty, !added.isEmpty, removed.count <= 250_000 / added.count {
        let stride = added.count + 1
        var lengths = Array(repeating: 0, count: (removed.count + 1) * stride)
        for old in removed.indices.reversed() {
            for new in added.indices.reversed() {
                let offset = old * stride + new
                lengths[offset] = removed[old].elementsEqual(added[new])
                    ? 1 + lengths[offset + stride + 1]
                    : max(lengths[offset + stride], lengths[offset + 1])
            }
        }
        var old = 0
        var new = 0
        while old < removed.count, new < added.count {
            if removed[old].elementsEqual(added[new]) {
                diff.append(diffLine("  ", removed[old]))
                old += 1
                new += 1
            } else if lengths[(old + 1) * stride + new] >= lengths[old * stride + new + 1] {
                diff.append(diffLine("- ", removed[old]))
                old += 1
            } else {
                diff.append(diffLine("+ ", added[new]))
                new += 1
            }
        }
        diff.append(contentsOf: removed.dropFirst(old).map { diffLine("- ", $0) })
        diff.append(contentsOf: added.dropFirst(new).map { diffLine("+ ", $0) })
    } else {
        diff.append(contentsOf: removed.map { diffLine("- ", $0) })
        diff.append(contentsOf: added.map { diffLine("+ ", $0) })
    }
    let trailingStart = before.count - end
    diff.append(contentsOf: before[trailingStart..<(trailingStart + min(3, end))].map { diffLine("  ", $0) })
    return diff
}

/// 文本编辑使用原编码及原 BOM。无法无损往返的对象仍可预览。
struct TextEditEncoding {
    let encoding: String.Encoding
    let bom: Data

    func encode(_ text: String) -> Data? {
        guard let body = text.data(using: encoding, allowLossyConversion: false) else { return nil }
        return bom + body
    }

    static func decode(_ data: Data, named name: String) -> (text: String, codec: Self)? {
        let xml = name.lowercased().hasSuffix(".xml")
        let marker: [(Data, String.Encoding)] = [
            (Data([0xEF, 0xBB, 0xBF]), .utf8), (Data([0xFF, 0xFE]), .utf16LittleEndian),
            (Data([0xFE, 0xFF]), .utf16BigEndian)
        ]
        let codec: Self
        if let (bom, encoding) = marker.first(where: { data.starts(with: $0.0) }) {
            codec = Self(encoding: encoding, bom: bom)
        } else if xml, data.starts(with: [60, 0, 63, 0]) {
            codec = Self(encoding: .utf16LittleEndian, bom: Data())
        } else if xml, data.starts(with: [0, 60, 0, 63]) {
            codec = Self(encoding: .utf16BigEndian, bom: Data())
        } else {
            var encoding = String.Encoding.utf8
            if xml {
                let declaration = String(decoding: data.prefix(512), as: UTF8.self)
                let pattern = #"^<\?xml\s+[^?]*?\bencoding\s*=\s*['"]([a-zA-Z0-9._-]+)['"]"#
                if let match = try? NSRegularExpression(pattern: pattern).firstMatch(
                    in: declaration, range: NSRange(declaration.startIndex..., in: declaration)
                ), let range = Range(match.range(at: 1), in: declaration) {
                    let identifier = CFStringConvertIANACharSetNameToEncoding(String(declaration[range]) as CFString)
                    guard identifier != kCFStringEncodingInvalidId else { return nil }
                    encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(identifier))
                }
            }
            codec = Self(encoding: encoding, bom: Data())
        }
        guard let text = String(data: data.dropFirst(codec.bom.count), encoding: codec.encoding),
              codec.encode(text) == data else { return nil }
        return (text, codec)
    }
}

struct TextPreview: Identifiable {
    let id: UUID
    let name: String
    /// 确认页显示完整 Bucket 和 key，便于核对同名对象。
    let target: String
    let text: String
    let markdown: Bool
    let etag: String?
    let replace: ((String, String) async throws -> String?)?
    let usesOSS: Bool
}

struct TextPreviewView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var showsSource = false
    @State private var currentText: String
    @State private var currentETag: String?
    @State private var draft: String?
    @State private var diff: [String] = []
    @State private var saving = false
    @State private var errorMessage = ""
    let preview: TextPreview

    init(preview: TextPreview) {
        self.preview = preview
        _currentText = State(initialValue: preview.text)
        _currentETag = State(initialValue: preview.etag)
    }

    var body: some View {
        NavigationStack {
            Group {
                if !diff.isEmpty {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 3) {
                            Text(appText("确认更新前，请检查以下差异。"))
                            Text(preview.target).font(.system(.footnote, design: .monospaced))
                                .padding(.bottom, 6)
                            if preview.usesOSS {
                                Text(appText("OSS 保存前校验版本，校验后仍可能发生并发更新。"))
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                            Text(appText("保存会替换同名对象，可能改变对象级访问权限。"))
                                .font(.footnote).foregroundStyle(.secondary)
                            ForEach(diff.indices, id: \.self) { index in
                                let line = diff[index]
                                Text(line)
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundStyle(line.hasPrefix("+") ? Color.green :
                                        line.hasPrefix("-") ? Color.red : Color.primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .textSelection(.enabled)
                        .padding()
                    }
                } else if draft != nil {
                    TextEditor(text: Binding(get: { draft ?? "" }, set: { draft = $0 }))
                        .font(.system(.body, design: .monospaced))
                        .padding()
                } else {
                    ScrollView {
                        if preview.markdown, !showsSource,
                           let rendered = try? AttributedString(
                            markdown: currentText, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
                           ) {
                            Text(rendered).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                .padding()
                        } else {
                            Text(currentText).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading).padding()
                        }
                    }
                }
            }
            .navigationTitle(preview.name)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(appText(!diff.isEmpty || draft != nil ? "返回" : "关闭")) {
                        if !diff.isEmpty { diff = [] }
                        else if draft != nil { draft = nil }
                        else { dismiss() }
                    }
                    .disabled(saving)
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    if saving {
                        ProgressView()
                    } else if !diff.isEmpty {
                        Button(appText("确认更新")) { saveConfirmedText() }
                    } else if let draft {
                        Button(appText("查看差异")) {
                            diff = compareTextEditLines(original: currentText, draft: draft)
                        }
                        .disabled(draft.utf8.elementsEqual(currentText.utf8))
                    } else {
                        if preview.markdown {
                            Button(appText(showsSource ? "预览" : "源码")) { showsSource.toggle() }
                        }
                        Button(appText("编辑")) {
                            if preview.replace == nil {
                                errorMessage = appText("文本无法使用原编码无损保存。")
                            } else if currentETag == nil {
                                errorMessage = appText("服务端未返回 ETag，无法安全更新文件。")
                            } else {
                                draft = currentText
                            }
                        }
                    }
                }
            }
            .alert(appText("更新失败"), isPresented: Binding(
                get: { !errorMessage.isEmpty }, set: { if !$0 { errorMessage = "" } }
            )) {
                Button(appText("关闭")) { errorMessage = "" }
            } message: {
                Text(errorMessage)
            }
        }
        .frame(minWidth: 300, minHeight: 390)
        .interactiveDismissDisabled(draft != nil || saving)
    }

    /// 只有确认页能调用写回，失败时保留草稿与差异。
    private func saveConfirmedText() {
        guard !saving, !diff.isEmpty, let draft, let currentETag, let replace = preview.replace else { return }
        saving = true
        Task {
            defer { saving = false }
            do {
                // 保存已完成。缺少新的 ETag 时保持预览，但不能用旧版本继续覆盖。
                self.currentETag = try await replace(draft, currentETag)
                currentText = draft
                self.draft = nil
                diff = []
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// AVPlayer 流式读取时使用短期签名链接，关闭后停止播放并释放网络请求。
struct MediaPreview: Identifiable {
    let id = UUID()
    let name: String
    let url: URL
    let autoPlay: Bool
}

struct MediaPreviewView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    let preview: MediaPreview

    @ViewBuilder private var playbackControls: some View {
        #if os(macOS)
        MacMediaPlayer(player: player)
        #else
        VideoPlayer(player: player)
        #endif
    }

    var body: some View {
        NavigationStack {
            playbackControls
                .navigationTitle(preview.name)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(appText("关闭")) { dismiss() } }
                }
        }
        .frame(minWidth: 340, minHeight: 310)
        .onAppear {
            let player = AVPlayer(url: preview.url)
            self.player = player
            if preview.autoPlay { player.play() }
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }
}


#if os(macOS)
/// 直接使用原生 AVKit 控件，避开 macOS 上 SwiftUI VideoPlayer 的桥接崩溃。
struct MacMediaPlayer: NSViewRepresentable {
    let player: AVPlayer?

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}
#endif
