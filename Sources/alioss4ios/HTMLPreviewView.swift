// Copyright 2026 jinlongliao
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import WebKit
#if os(iOS)
import UIKit
#endif

/// HTML 源码仅在本次预览中存在，未授权时不会请求外部资源。
struct HTMLPreview: Identifiable {
    let id = UUID()
    let name: String
    let source: String
}

struct HTMLPreviewView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var showsSource = false
    @State private var interactive = false
    @State private var asksInteractiveConsent = false
    @State private var renderingFailed = false
    let HTML: HTMLPreview

    @ViewBuilder private var sourceView: some View {
        #if os(iOS)
        VStack(alignment: .leading, spacing: 0) {
            if renderingFailed {
                Text(appText("无法启动安全预览。"))
                    .foregroundStyle(.secondary)
                    .padding([.horizontal, .top])
            }
            HTMLSourceTextView(source: HTML.source)
        }
        #else
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if renderingFailed {
                    Text(appText("无法启动安全预览。")).foregroundStyle(.secondary)
                }
                Text(HTML.source).font(.system(.body, design: .monospaced)).textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding()
        }
        #endif
    }

    var body: some View {
        NavigationStack {
            Group {
                if showsSource {
                    sourceView
                } else {
                    HTMLWebView(source: HTML.source, interactive: interactive) {
                        renderingFailed = true
                        showsSource = true
                    }
                    .id(interactive)
                }
            }
            .navigationTitle(HTML.name)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(appText("关闭")) { dismiss() } }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button(appText(showsSource ? "预览" : "源码")) {
                        renderingFailed = false
                        showsSource.toggle()
                    }
                    Button(appText(interactive ? "返回安全静态预览" : "开启完整网页预览")) {
                        if interactive { interactive = false } else { asksInteractiveConsent = true }
                    }
                }
            }
        }
        .frame(minWidth: 340, minHeight: 390)
        .confirmationDialog(appText("开启完整网页预览？"), isPresented: $asksInteractiveConsent) {
            Button(appText("仅本次预览开启")) {
                interactive = true
                renderingFailed = false
                showsSource = false
            }
        } message: {
            Text(appText("这将允许当前 HTML 文件运行 JavaScript 并加载 HTTPS 外部资源。不可信页面可能执行脚本或向外部服务器发送数据；文件访问、混合内容和页面跳转仍会被禁止。"))
        }
    }
}

/// 在 WebKit 规则安装完成后才载入文档，失败时由调用方回退到源码。
@MainActor
private final class HTMLWebCoordinator: NSObject, WKNavigationDelegate {
    private var loader: Task<Void, Never>?
    private var onFailure: (() -> Void)?

    func buildWebView(source: String, interactive: Bool, onFailure: @escaping () -> Void) -> WKWebView {
        self.onFailure = onFailure
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = interactive
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        let browser = WKWebView(frame: .zero, configuration: config)
        browser.navigationDelegate = self

        var blocked = ["http", "file", "ftp", "ws", "wss"]
        if !interactive { blocked.append("https") }
        let rules = blocked.map { scheme in
            ["trigger": ["url-filter": "^" + scheme + ":"], "action": ["type": "block"]]
        }
        loader = Task {
            do {
                let data = try JSONSerialization.data(withJSONObject: rules)
                let json = String(decoding: data, as: UTF8.self)
                guard let store = WKContentRuleListStore.default() else {
                    throw BrowserError.message(appText("WebKit 内容规则不可用。"))
                }
                guard let ruleList = try await store.compileContentRuleList(
                    forIdentifier: interactive ? "alioss4ios-interactive" : "alioss4ios-static",
                    encodedContentRuleList: json
                ) else {
                    throw BrowserError.message(appText("WebKit 无法生成内容规则。"))
                }
                try Task.checkCancellation()
                browser.configuration.userContentController.add(ruleList)
                browser.loadHTMLString(source, baseURL: nil)
            } catch {
                guard !Task.isCancelled else { return }
                onFailure()
            }
        }
        return browser
    }

    /// 保持文档内导航。外部 HTTPS 子资源只在用户授权后通过内容规则。
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        let url = action.request.url
        if action.targetFrame?.isMainFrame == true {
            return url?.absoluteString == "about:blank" ? .allow : .cancel
        }
        guard action.targetFrame != nil else { return .cancel }
        return url?.absoluteString == "about:blank" || url?.scheme == "data" ? .allow : .cancel
    }

    /// WebKit 加载失败时保留已下载源码，并允许手动重试预览。
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        onFailure?()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { onFailure?() }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        onFailure?()
    }

    /// 关闭预览时停止规则安装，并禁止旧 WebView 的回调修改界面。
    func cancelWebLoad() {
        onFailure = nil
        loader?.cancel()
    }
}

#if os(macOS)
private struct HTMLWebView: NSViewRepresentable {
    let source: String
    let interactive: Bool
    let onFailure: () -> Void

    func makeCoordinator() -> HTMLWebCoordinator { HTMLWebCoordinator() }

    func makeNSView(context: Context) -> WKWebView {
        context.coordinator.buildWebView(source: source, interactive: interactive, onFailure: onFailure)
    }

    func updateNSView(_ view: WKWebView, context: Context) {}

    static func dismantleNSView(_ view: WKWebView, coordinator: HTMLWebCoordinator) {
        coordinator.cancelWebLoad()
        view.stopLoading()
    }
}
#else
/// 由 TextKit 在滚动视口内排版，源码在本次预览内固定，无需随 SwiftUI 更新反复赋值。
private struct HTMLSourceTextView: UIViewRepresentable {
    let source: String

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView(usingTextLayoutManager: true)
        view.isEditable = false
        view.isSelectable = true
        view.backgroundColor = .clear
        view.textColor = .label
        view.font = UIFontMetrics(forTextStyle: .body).scaledFont(
            for: .monospacedSystemFont(ofSize: 17, weight: .regular)
        )
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        view.text = source
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {}
}

private struct HTMLWebView: UIViewRepresentable {
    let source: String
    let interactive: Bool
    let onFailure: () -> Void

    func makeCoordinator() -> HTMLWebCoordinator { HTMLWebCoordinator() }

    func makeUIView(context: Context) -> WKWebView {
        context.coordinator.buildWebView(source: source, interactive: interactive, onFailure: onFailure)
    }

    func updateUIView(_ view: WKWebView, context: Context) {}

    static func dismantleUIView(_ view: WKWebView, coordinator: HTMLWebCoordinator) {
        coordinator.cancelWebLoad()
        view.stopLoading()
    }
}
#endif
