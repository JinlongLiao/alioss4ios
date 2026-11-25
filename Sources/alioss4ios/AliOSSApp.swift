// Copyright 2026 jinlongliao
// SPDX-License-Identifier: Apache-2.0

import QuickLook
import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// 同一套 SwiftUI 导航可用于 Apple 平台，Mac 为首个交付目标。
@main
struct AliOSSApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(MacApplicationDelegate.self) private var applicationDelegate
    #else
    @UIApplicationDelegateAdaptor(IOSApplicationDelegate.self) private var applicationDelegate
    #endif
    @State private var uploadQueue = UploadQueue.shared
    #if os(iOS)
    @Environment(\.scenePhase) private var scenePhase
    #endif
    @AppStorage("privacyAccepted") private var privacyAccepted = false
    @AppStorage("interfaceLanguage") private var interfaceLanguage = "system"

    #if os(macOS)
    init() {
        if !MacInstanceLock.acquired { exit(EXIT_SUCCESS) }
    }
    #endif

    var body: some Scene {
        #if os(macOS)
        Window("alioss4ios", id: "browser") {
            appContent.frame(minWidth: 360, minHeight: 420)
        }
        #else
        WindowGroup("alioss4ios") {
            appContent
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { uploadQueue.resumeUploadScheduling() }
        }
        #endif
    }

    /// 同意后才加载钥匙串和当前账号，语言变更保留会话状态。
    private var appContent: some View {
        Group {
            if privacyAccepted {
                BrowserView().environment(uploadQueue)
            } else {
                AboutStorageView { privacyAccepted = true }
            }
        }
        .environment(\.locale, interfaceLanguage == "system" ? .current : Locale(identifier: interfaceLanguage))
    }
}

#if os(macOS)
/// 文件窗口关闭后保留应用级任务。用户退出应用后从断点记录继续。
private final class MacApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
#endif

/// 两个一级入口共享同一个浏览状态。
private enum BrowserTab: Hashable {
    case files, settings
}

/// 浏览请求绑定当前账号、桶及路径，离开页面会取消相应任务。
private struct BrowserView: View {
    @Environment(UploadQueue.self) private var uploadQueue
    @Environment(\.colorScheme) private var systemColorScheme
    @Environment(\.locale) private var browserLocale
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    /// 与 Android 一致，文件和设置作为一级入口。
    @State private var selectedTab = BrowserTab.files
    @State private var showsUploads = false
    @State private var showsBackup = false
    @State private var showsPalettePicker = false
    @State private var showsAbout = false
    @AppStorage("directoryOrdering") private var ordering = DirectoryOrdering.nameAscending
    @AppStorage("directoryGrid") private var usesGrid = false
    @AppStorage("directoryPageSize") private var pageSize = 10
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("interfaceLanguage") private var interfaceLanguage = "system"
    @AppStorage("accentStyle") private var accentStyle = "default"
    @AppStorage("confirmDelete") private var confirmDestructiveOperations = true
    @AppStorage("autoPlayMedia") private var autoPlayMedia = true
    /// 以字节保留 Android 的 512 KiB 选项，旧整数 MiB 偏好仍可读取。
    @AppStorage("textPreviewLimitBytes") private var textPreviewLimitBytes = 0
    @AppStorage("textPreviewLimitMiB") private var legacyPreviewLimitMiB = 2
    @State private var highlightedObject: Data?
    @AppStorage("activeProfile") private var activeProfileID = ""
    @State private var profiles: [StorageProfile] = []
    @State private var editingProfile: StorageProfile?
    @State private var selectedBucket: StorageBucket?
    @State private var compactColumn = NavigationSplitViewColumn.sidebar
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var prefix = ""
    @State private var pathDraft = ""
    @FocusState private var pathInputFocused: Bool
    @State private var pathResolutionID = UUID()
    @State private var showsFileImporter = false
    /// 系统选择器打开后固定账号、Bucket 和前缀，回调不读取已变更的页面状态。
    @State private var pendingUploadDestination: (account: StorageProfile, bucket: StorageBucket, prefix: String)?
    @State private var showsDirectoryEditor = false
    @State private var directoryName = ""
    @State private var pendingDelete: StorageObject?
    @State private var pendingMove: StorageObject?
    @State private var mutationTask: Task<Void, Never>?
    @State private var downloadTask: Task<Void, Never>?
    #if os(iOS)
    @State private var exportedObject: LocalObjectFile?
    #endif
    @State private var buckets: [StorageBucket] = []
    @State private var objects: [StorageObject] = []
    @State private var cursor: String?
    @State private var refreshID = UUID()
    @State private var loading = false
    @State private var notice = ""
    @State private var signedURL: URL?
    @State private var vaultReady = false
    @State private var requestedPage: String?
    /// 单个目录代次内，每个游标只自动触发一次。失败后保留按钮供用户重试。
    @State private var automaticallyRequestedPages: Set<String> = []
    /// 面板按钮直接持有生成任务，关闭或切换目录会取消。
    @State private var shareLinkTask: Task<Void, Never>?
    @State private var linkObject: StorageObject?
    @State private var showsLinkOptions = false
    @State private var linkHours = 1
    @State private var usesPublicLink = false
    @State private var linkDomain: PublicLinkDomain?
    @State private var linkFailure = ""
    @State private var domainNotice = ""
    @State private var loadingLinkDomains = false
    @State private var domains: [PublicLinkDomain] = []
    @State private var previewURL: URL?
    @State private var HTMLPreviewDocument: HTMLPreview?
    @State private var textPreview: TextPreview?
    @State private var mediaPreview: MediaPreview?
    @State private var previewDirectory: URL?
    @State private var previewTask: Task<Void, Never>?

    private var profile: StorageProfile? {
        profiles.first { $0.id.uuidString == activeProfileID }
    }

    private var storage: (any ObjectStorage)? { profile?.makeStorage() }

    private var palette: BrowserPalette { BrowserPalette.resolve(accentStyle) }

    private var usesDarkTheme: Bool {
        appearance == "dark" || (appearance == "system" && systemColorScheme == .dark)
    }

    private var documentPreviewLimit: Int {
        textPreviewLimitBytes > 0 ? textPreviewLimitBytes : legacyPreviewLimitMiB * 1024 * 1024
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            fileBrowser
                .tabItem { Label(appText("文件"), systemImage: "folder") }
                .tag(BrowserTab.files)
            settingsPage
                .tabItem { Label(appText("设置"), systemImage: "gearshape") }
                .tag(BrowserTab.settings)
        }
        .fileImporter(isPresented: $showsFileImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) {
            importUploadFiles($0)
        }
        .alert(appText("新建目录"), isPresented: $showsDirectoryEditor) {
            TextField(appText("目录名"), text: $directoryName)
            Button(appText("取消"), role: .cancel) {}
            Button(appText("创建")) { createDirectory() }
        }
        .confirmationDialog(
            appText("删除远端对象"),
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { item in
            Button(appText("删除"), role: .destructive) { mutateObject(item, destination: nil) }
        } message: { item in
            Text(item.isDirectory ? "递归删除目录 \(item.key) 下的全部对象" : item.key)
        }
        .sheet(item: $pendingMove) { item in
            MoveObjectView(
                sourceKey: item.key,
                isDirectory: item.isDirectory,
                requiresConfirmation: confirmDestructiveOperations
            ) { destination in
                mutateObject(item, destination: destination)
            }
        }
        .quickLookPreview($previewURL)
        .sheet(item: $HTMLPreviewDocument) { HTMLPreviewView(HTML: $0) }
        .sheet(item: $textPreview) { TextPreviewView(preview: $0) }
        .sheet(item: $mediaPreview) { MediaPreviewView(preview: $0) }
        .onChange(of: previewURL) { _, newValue in
            if newValue == nil { removePreviewDirectory() }
        }
        .onDisappear { previewTask?.cancel() }
        .onAppear {
            loadVault()
            uploadQueue.loadUploadHistory()
        }
        .onChange(of: uploadQueue.lastCompleted?.id) { _, _ in
            if let job = uploadQueue.lastCompleted, job.profileID == profile?.id,
               job.target.bucket == selectedBucket, job.target.key.utf8.starts(with: prefix.utf8) {
                refreshDirectoryFromNetwork()
            } else if let job = uploadQueue.lastCompleted {
                Task { await DirectoryCache.shared.invalidate(profile: job.profileID) }
            }
        }
        .sheet(isPresented: $showsUploads) {
            UploadActivityView(profiles: profiles)
        }
        .sheet(isPresented: $showsPalettePicker) {
            ThemePalettePicker(selected: palette, dark: usesDarkTheme) { accentStyle = $0.rawValue }
        }
        .sheet(isPresented: $showsBackup) {
            ProfileBackupView(profiles: profiles, importProfiles: importProfiles)
        }
        .sheet(isPresented: $showsAbout) { AboutStorageView() }
        .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
        .tint(palette.tint(dark: usesDarkTheme))
        .fontDesign(palette.fontDesign)
        .onChange(of: ordering) { _, _ in reloadDirectory() }
        .onChange(of: pageSize) { _, _ in reloadDirectory() }
        .task(id: refreshID) { await fetchDirectoryPage(after: nil) }
        .task(id: requestedPage) {
            guard let requestedPage else { return }
            await fetchDirectoryPage(after: requestedPage)
            if !Task.isCancelled { self.requestedPage = nil }
        }
        .sheet(isPresented: $showsLinkOptions, onDismiss: clearShareLinkTask) {
            NavigationStack {
                Form {
                    if let signedURL {
                        Section {
                            Text(signedURL.absoluteString).font(.footnote).textSelection(.enabled)
                            ShareLink(appText("分享下载链接"), item: signedURL)
                            Button(appText("复制链接"), systemImage: "doc.on.doc") { copyShareAddress(signedURL) }
                        }
                    } else if shareLinkTask != nil {
                        ProgressView()
                    } else if !linkFailure.isEmpty {
                        Text(linkFailure).font(.footnote).foregroundStyle(.red)
                    }
                    Toggle(appText("公开链接"), isOn: $usesPublicLink)
                        .disabled(shareLinkTask != nil)
                    if !usesPublicLink {
                        Stepper(String(format: appText("有效期 %lld 小时"), Int64(linkHours)),
                                value: $linkHours, in: 1...168)
                            .disabled(shareLinkTask != nil)
                    } else if storage is OssStorage {
                        Picker(appText("域名"), selection: $linkDomain) {
                            Text(appText("默认存储端点")).tag(nil as PublicLinkDomain?)
                            ForEach(domains) { domain in Text(domain.host).tag(Optional(domain)) }
                        }
                        .disabled(shareLinkTask != nil)
                        if loadingLinkDomains {
                            ProgressView(appText("正在查询自定义域名"))
                        } else if !domainNotice.isEmpty {
                            Text(domainNotice).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                .navigationTitle(linkObject?.name ?? appText("分享下载链接"))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(appText("关闭")) { showsLinkOptions = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(appText("生成"), action: startShareLink)
                            .disabled(shareLinkTask != nil)
                    }
                }
                .onChange(of: usesPublicLink) { _, _ in clearShareLinkResult() }
                .onChange(of: linkHours) { _, _ in clearShareLinkResult() }
                .onChange(of: linkDomain) { _, _ in clearShareLinkResult() }
                .task(id: usesPublicLink) { await loadShareLinkDomains() }
            }
            .frame(minWidth: 300, minHeight: 370)
        }
        #if os(iOS)
        .sheet(item: $exportedObject, onDismiss: { downloadTask = nil }) { file in
            ObjectExportPicker(file: file) {
                exportedObject = nil
            }
        }
        #endif
        .sheet(item: $editingProfile) { draft in
            ProfileEditor(profile: draft, save: saveProfile)
        }
    }

    /// 宽屏保留 Bucket 侧栏，紧凑宽度由系统切换列表与内容。
    private var fileBrowser: some View {
        NavigationSplitView(columnVisibility: $columnVisibility, preferredCompactColumn: $compactColumn) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    accountSwitcher(maxWidth: 210)
                    Spacer(minLength: 8)
                    #if os(iOS)
                    if horizontalSizeClass == .compact { browserActions }
                    #endif
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                Divider()
                bucketList
            }
            .background { browserBackdrop.ignoresSafeArea() }
            #if os(iOS)
            .toolbar(horizontalSizeClass == .compact ? .hidden : .automatic, for: .navigationBar)
            .toolbarBackground(browserSurface, for: .navigationBar)
            .toolbarBackground(palette.browserSurface(dark: usesDarkTheme, atBottom: true), for: .tabBar)
            .toolbarBackground(.visible, for: .navigationBar, .tabBar)
            #endif
            .navigationSplitViewColumnWidth(min: 215, ideal: 250, max: 310)
        } detail: {
            VStack(alignment: .leading, spacing: 0) {
                if let bucket = selectedBucket {
                    directoryHeader(bucket)
                    if !notice.isEmpty {
                        Label(notice, systemImage: "exclamationmark.circle")
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                    }
                    if objects.isEmpty && !loading && notice.isEmpty {
                        Text(appText("此目录为空"))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        directoryContents
                    }

                } else {
                    VStack(spacing: 10) {
                        if profile == nil {
                            Button(appText("添加账号"), systemImage: "plus") { editingProfile = StorageProfile() }
                                .disabled(!vaultReady)
                        } else {
                            Text(appText("选择 Bucket")).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .toolbar {
                #if os(iOS)
                if horizontalSizeClass == .compact || columnVisibility == .detailOnly {
                    ToolbarItem(placement: .topBarLeading) { accountSwitcher(maxWidth: 130) }
                }
                #else
                if columnVisibility == .detailOnly {
                    ToolbarItem(placement: .navigation) { accountSwitcher(maxWidth: 180) }
                }
                #endif
                ToolbarItem(placement: .primaryAction) { browserActions }
            }
            #if os(iOS)
            .toolbarBackground(browserSurface, for: .navigationBar)
            .toolbarBackground(palette.browserSurface(dark: usesDarkTheme, atBottom: true), for: .tabBar)
            .toolbarBackground(.visible, for: .navigationBar, .tabBar)
            #endif
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { browserBackdrop.ignoresSafeArea() }
        }
        .navigationSplitViewStyle(.balanced)
    }

    private var browserBackdrop: some View { palette.browserBackdrop(dark: usesDarkTheme) }
    private var browserSurface: Color { palette.browserSurface(dark: usesDarkTheme) }

    /// 宽屏 Bucket 侧栏始终用列表，紧凑宽度支持与文件共用网格设置。
    private var usesBucketGrid: Bool {
        #if os(iOS)
        usesGrid && horizontalSizeClass == .compact
        #else
        false
        #endif
    }

    /// 账号下的 Bucket 以列表或卡片展示，列表和网格共用路由、元数据及选中状态。
    private var bucketList: some View {
        VStack(alignment: .leading, spacing: 0) {
            if profile != nil {
                HStack {
                    Text("Bucket").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    #if os(iOS)
                    if horizontalSizeClass == .compact { browserLayoutToggle }
                    #endif
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
            }
            if !notice.isEmpty && selectedBucket == nil {
                Label(notice, systemImage: "exclamationmark.circle")
                    .font(.footnote).foregroundStyle(.red)
                    .padding(.horizontal, 16).padding(.vertical, 8)
            }
            if usesBucketGrid && !buckets.isEmpty {
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 2), spacing: 10) {
                        ForEach(buckets) { bucket in
                            bucketRow(bucket, grid: true)
                        }
                    }
                    .padding(12)
                }
            } else {
                List {
                    if let profile {
                        ForEach(buckets) { bucket in
                            bucketRow(bucket)
                                .listRowBackground(selectedBucket == bucket ? Color.accentColor.opacity(0.10) : .clear)
                        }
                        if buckets.isEmpty && !loading && notice.isEmpty && profile.bucket.isEmpty {
                            Text(appText("没有可用的 Bucket")).foregroundStyle(.secondary).listRowBackground(Color.clear)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .overlay { if loading && buckets.isEmpty { ProgressView() } }
            }
        }
    }

    /// 只显示列表返回的元数据及账号配置的默认路由，避免额外申请读桶信息权限。
    private func bucketRow(_ bucket: StorageBucket, grid: Bool = false) -> some View {
        let isDefault = profile?.bucket == bucket.name
        let region = bucket.region ?? (isDefault ? profile?.region : nil)
        let endpoint = bucket.endpoint ?? profile?.endpoint
        let dateFormat = Date.FormatStyle().year().month(.abbreviated).day().locale(browserLocale)
        let attributes = [region, bucket.storageClass, bucket.createdAt?.formatted(dateFormat)]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        let description = VStack(alignment: .leading, spacing: 3) {
            Text(bucket.name)
                .fontWeight(grid ? .medium : .regular)
                .lineLimit(grid ? nil : 2)
                .truncationMode(.middle)
            if !attributes.isEmpty {
                Text(attributes).font(.caption).foregroundStyle(.secondary).lineLimit(grid ? nil : 2)
            }
            if let endpoint, !endpoint.isEmpty {
                Text(endpoint).font(grid ? .caption : .caption2).foregroundStyle(.secondary)
                    .lineLimit(grid ? nil : 1).truncationMode(.middle)
            }
        }
        let selected = selectedBucket == bucket
        return Button {
            openListedBucket(bucket)
        } label: {
            if grid {
                // 与 Android 双列卡片共用纵向结构，把整列宽度留给名称和元数据。
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        StorageItemIcon(item: .bucket, size: 48)
                        Spacer(minLength: 0)
                        if selected {
                            Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                                .accessibilityHidden(true)
                        }
                    }
                    description
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(
                    Color.accentColor.opacity(selected ? 0.12 : 0.06),
                    in: RoundedRectangle(cornerRadius: palette.cardRadius)
                )
                .contentShape(Rectangle())
            } else {
                HStack(spacing: 10) {
                    StorageItemIcon(item: .bucket)
                    description
                    Spacer(minLength: 4)
                    Image(systemName: selected ? "checkmark" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(selected ? Color.accentColor : .secondary)
                        .accessibilityHidden(true)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selectedBucket == bucket ? .isSelected : [])
        .contextMenu {
            if let endpoint, !endpoint.isEmpty, let url = URL(string: endpoint) {
                Button(appText("复制 Endpoint"), systemImage: "doc.on.doc") { copyShareAddress(url) }
            }
        }
    }

    /// 路径栏优先显示当前位置和上传，次要动作放到工具菜单。
    private func directoryHeader(_ bucket: StorageBucket) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(prefix.split(separator: "/").last.map(String.init) ?? bucket.name)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                browserLayoutToggle
                Button(appText("上传文件"), systemImage: "arrow.up") { openUploadFilePicker() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(mutationTask != nil)
            }
            HStack(spacing: 9) {
                if !prefix.isEmpty {
                    Button(appText("上一级"), systemImage: "arrow.up.left") { openParentDirectory() }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                }
                HStack(spacing: 8) {
                    TextField(appText("输入目录路径"), text: $pathDraft)
                        .textFieldStyle(.plain)
                        .font(.callout.monospaced())
                        .foregroundStyle(.primary)
                        .focused($pathInputFocused)
                        .submitLabel(.go)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .accessibilityLabel(appText("目录前缀"))
                        .onSubmit(submitBrowserPath)
                    Button(appText("跳转"), systemImage: "return") { submitBrowserPath() }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .padding(.horizontal, 10)
                .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
                if loading { ProgressView().controlSize(.small) }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { Divider() }
    }

    /// 原生菜单会缓存 Picker 标签。语种变化时重建选择器，排序值仍使用同一持久化绑定。
    private var directoryOrderingPicker: some View {
        let language = interfaceLanguage == "system" ? (Locale.preferredLanguages.first ?? "zh-Hans")
            : interfaceLanguage
        return Picker(localizedAppText("排序方式", languageTag: language), selection: $ordering) {
            ForEach(DirectoryOrdering.allCases) { sort in
                Text(localizedAppText(sort.rawValue, languageTag: language)).tag(sort)
            }
        }
        .id(language)
    }

    /// 在当前页直接切换列表与网格，沿用设置中的浏览布局选择。
    private var browserLayoutToggle: some View {
        Button {
            usesGrid.toggle()
        } label: {
            Image(systemName: usesGrid ? "list.bullet" : "square.grid.2x2")
                .frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(appText("浏览布局"))
        .accessibilityValue(appText(usesGrid ? "双列布局" : "列表"))
        .help(appText(usesGrid ? "列表" : "双列布局"))
    }

    /// 文件页的次要操作统一从更多菜单进入。
    private var browserActions: some View {
        Menu {
            if selectedBucket != nil {
                Button(appText("新建目录"), systemImage: "folder.badge.plus") {
                    directoryName = ""
                    showsDirectoryEditor = true
                }
                .disabled(mutationTask != nil)
                if mutationTask != nil {
                    Button(appText("取消当前操作"), systemImage: "stop.circle") { mutationTask?.cancel() }
                }
            }
            if selectedBucket != nil {
                directoryOrderingPicker
            }
            Button(appText("刷新"), systemImage: "arrow.clockwise") { refreshDirectoryFromNetwork() }
                .disabled(profile == nil)
            Button(appText("上传任务"), systemImage: "tray.and.arrow.up") { showsUploads = true }
        } label: {
            Label(appText("更多操作"), systemImage: "ellipsis").labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
    }

    /// 账号切换就地完成，新增、编辑和删除仍从设置进入。
    @ViewBuilder
    private func accountSwitcher(maxWidth: CGFloat) -> some View {
        if profiles.isEmpty {
            Button(appText("添加账号"), systemImage: "person.crop.circle.badge.plus") {
                editingProfile = StorageProfile()
            }
            .disabled(!vaultReady)
        } else {
            Menu {
                ForEach(profiles) { account in
                    Button {
                        if account.id != profile?.id { openProfile(account) }
                    } label: {
                        Label(
                            account.provider.rawValue + " · " + account.name,
                            systemImage: account.id == profile?.id ? "checkmark" : "key"
                        )
                    }
                }
                Divider()
                Button(appText("管理账号"), systemImage: "gearshape") { selectedTab = .settings }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "person.crop.circle")
                    Text(profile?.name ?? appText("选择账号")).lineLimit(1)
                    Image(systemName: "chevron.down").font(.caption2)
                }
                .frame(maxWidth: maxWidth, alignment: .leading)
            }
            .accessibilityLabel(appText("切换账号"))
            .accessibilityValue(profile?.name ?? appText("选择账号"))
        }
    }

    /// 在列表与网格之间共享对象动作，文件路径跳转时定位并高亮。
    private var directoryContents: some View {
        ScrollViewReader { reader in
            Group {
                if usesGrid {
                    ScrollView {
                        LazyVStack {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 138), spacing: 12)], spacing: 12) {
                                ForEach(objects) { item in
                                    objectCard(item)
                                        .padding(12)
                                        .background(item.id == highlightedObject ? Color.accentColor.opacity(0.18) : .clear)
                                        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: palette.cardRadius))
                                        .overlay {
                                            RoundedRectangle(cornerRadius: palette.cardRadius)
                                                .strokeBorder(.primary.opacity(0.10), lineWidth: 1)
                                                .allowsHitTesting(false)
                                        }
                                }
                            }
                            .padding()
                            nextPageButton
                        }
                    }
                } else {
                    List {
                        ForEach(objects) { item in
                            objectRow(item)
                                .listRowBackground(item.id == highlightedObject ? Color.accentColor.opacity(0.12) : .clear)
                        }
                        nextPageButton.listRowBackground(Color.clear)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .onChange(of: objects.count) { _, _ in
                if let highlightedObject, objects.contains(where: { $0.id == highlightedObject }) {
                    reader.scrollTo(highlightedObject, anchor: .center)
                }
            }
        }
    }

    @ViewBuilder
    private var nextPageButton: some View {
        if let cursor, !loading {
            Button(appText("加载更多")) { requestedPage = cursor }
                .id(cursor)
                .onAppear {
                    guard ordering == .nameAscending, self.cursor == cursor, requestedPage == nil,
                          automaticallyRequestedPages.insert(cursor).inserted else { return }
                    requestedPage = cursor
                }
        }
    }

    /// 紧凑卡片将次要操作集中到菜单，iPhone 仍可显示两列。
    private func objectCard(_ item: StorageObject) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                if item.isDirectory { openObjectDirectory(item) } else { previewObject(item) }
            } label: {
                HStack {
                    StorageItemIcon(item: item.isDirectory ? .folder : .file(item.name))
                    Text(item.name).lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            HStack {
                if let details = objectDetails(item) {
                    Text(details).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                objectActions(item)
            }
        }
        .buttonStyle(.borderless)
    }

    /// 同步列表和卡片的目录点击行为。
    private func openObjectDirectory(_ item: StorageObject) {
        highlightedObject = nil
        prefix = item.key
        reloadDirectory(syncPathDraft: true)
    }

    /// 为单独选中的对象重新读取分享域名。
    private func openLinkOptions(_ item: StorageObject) {
        linkObject = item
        linkDomain = nil
        domains = []
        domainNotice = ""
        linkFailure = ""
        signedURL = nil
        showsLinkOptions = true
    }

    /// 文件名称点击即预览；下载、链接和变更集中在行末菜单。
    private func objectRow(_ item: StorageObject) -> some View {
        HStack(spacing: 10) {
            Button {
                if item.isDirectory { openObjectDirectory(item) } else { previewObject(item) }
            } label: {
                HStack(spacing: 10) {
                    StorageItemIcon(item: item.isDirectory ? .folder : .file(item.name))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.name).lineLimit(1).truncationMode(.middle)
                        if let details = objectDetails(item) {
                            Text(details).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            objectActions(item)
        }
    }

    /// 列表和网格使用同一份元数据，时间随应用语言格式化。
    private func objectDetails(_ item: StorageObject) -> String? {
        if item.isDirectory { return appText("文件夹") }
        let size = item.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        let date = item.modifiedAt?.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(browserLocale))
        let parts = [size, date].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// 列表和网格共享同一组对象动作。
    private func objectActions(_ item: StorageObject) -> some View {
        Menu {
            if !item.isDirectory {
                Button(appText("下载"), systemImage: "arrow.down.to.line") { saveObject(item) }
                    .disabled(downloadTask != nil)
                Button(appText("生成下载链接"), systemImage: "link") { openLinkOptions(item) }
            }
            objectMutationMenu(item)
        } label: {
            Label(appText("更多操作"), systemImage: "ellipsis")
                .labelStyle(.iconOnly)
                .frame(minWidth: 44, minHeight: 44)
        }
        .menuStyle(.borderlessButton)
    }

    /// 设置与 Android 使用相同分组，账号管理和备份集中在设置页面。
    private var settingsPage: some View {
        NavigationStack {
            Form {
                Section(appText("账号")) {
                    ForEach(profiles) { account in
                        HStack {
                            Button {
                                openProfile(account)
                                selectedTab = .files
                            } label: {
                                Label(account.name, systemImage: account.id == profile?.id ? "checkmark.circle" : "key")
                            }
                            .buttonStyle(.plain)
                            Spacer()
                            Menu {
                                Button(appText("编辑")) { editingProfile = account }
                                Button(appText("删除"), role: .destructive) { removeProfile(account) }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                            }
                            .accessibilityLabel(appText("账号") + " · " + account.name)
                        }
                    }
                    Button(appText("添加账号"), systemImage: "plus") { editingProfile = StorageProfile() }
                        .disabled(!vaultReady)
                }
                .listRowBackground(Color.clear)
                Section(appText("外观")) {
                    Button {
                        showsPalettePicker = true
                    } label: {
                        HStack {
                            Text(appText("配色主题"))
                            Spacer()
                            Text(palette.title).foregroundStyle(.secondary)
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                        }
                    }
                    .buttonStyle(.plain)
                    Picker(appText("显示模式"), selection: $appearance) {
                        Text(appText("跟随系统")).tag("system")
                        Text(appText("浅色")).tag("light")
                        Text(appText("深色")).tag("dark")
                    }
                    Picker(appText("语言"), selection: $interfaceLanguage) {
                        Text(appText("跟随系统")).tag("system")
                        Text("简体中文").tag("zh-Hans")
                        Text("繁體中文").tag("zh-Hant")
                        Text("English").tag("en")
                    }
                }
                .listRowBackground(Color.clear)
                Section(appText("浏览设置")) {
                    directoryOrderingPicker
                    Picker(appText("浏览布局"), selection: $usesGrid) {
                        Text(appText("列表")).tag(false)
                        Text(appText("双列布局")).tag(true)
                    }
                    Picker(appText("每页数量"), selection: $pageSize) {
                        ForEach(Array(Set([10, 20, 50, 100, pageSize])).sorted(), id: \.self) { count in
                            Text(String(count)).tag(count)
                        }
                    }
                }
                .listRowBackground(Color.clear)
                Section(appText("预览")) {
                    Picker(appText("小型文档预览上限"), selection: Binding(
                        get: { documentPreviewLimit },
                        set: { textPreviewLimitBytes = $0 }
                    )) {
                        let presets = [512, 2048, 5120, 10240, 30720].map { $0 * 1024 }
                        ForEach(Array(Set(presets + [documentPreviewLimit])).sorted(), id: \.self) { size in
                            Text(size < 1024 * 1024 ? "\(size / 1024) KiB" : "\(size / (1024 * 1024)) MiB").tag(size)
                        }
                    }
                    Toggle(appText("自动播放音视频"), isOn: $autoPlayMedia)
                }
                .listRowBackground(Color.clear)
                Section(appText("安全")) {
                    Toggle(appText("破坏性操作二次确认"), isOn: $confirmDestructiveOperations)
                }
                .listRowBackground(Color.clear)
                Section(appText("本地存储")) {
                    Button(appText("清理浏览缓存")) {
                        Task {
                            await DirectoryCache.shared.clearAllDirectories()
                            reloadDirectory()
                        }
                    }
                }
                .listRowBackground(Color.clear)
                Section(appText("备份与恢复")) {
                    Button(appText("账号备份"), systemImage: "lock.doc") { showsBackup = true }
                        .disabled(!vaultReady)
                }
                .listRowBackground(Color.clear)
                Section(appText("关于")) {
                    Button(appText("关于与开源许可")) { showsAbout = true }
                }
                .listRowBackground(Color.clear)
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background { browserBackdrop.ignoresSafeArea() }
            .navigationTitle(appText("设置"))
            #if os(iOS)
            .toolbarBackground(browserSurface, for: .navigationBar)
            .toolbarBackground(palette.browserSurface(dark: usesDarkTheme, atBottom: true), for: .tabBar)
            .toolbarBackground(.visible, for: .navigationBar, .tabBar)
            #endif
        }
    }

    /// 初始化失败时关闭写入口，避免将已有账号覆盖为空列表。
    private func loadVault() {
        guard !vaultReady else { return }
        do {
            profiles = try ProfileVault.loadProfiles()
            vaultReady = true
            if let account = profile ?? profiles.first { openProfile(account) }
        } catch {
            notice = error.localizedDescription
        }
    }

    /// 先写钥匙串，再切换界面账号。
    private func saveProfile(_ account: StorageProfile) throws {
        guard vaultReady else { throw BrowserError.message(appText("钥匙串不可用。")) }
        try account.validateProfile()
        var updated = profiles
        if let index = updated.firstIndex(where: { $0.id == account.id }) {
            updated[index] = account
        } else {
            updated.append(account)
        }
        try ProfileVault.saveProfiles(updated)
        profiles = updated
        let generation = refreshID
        Task {
            await DirectoryCache.shared.invalidate(profile: account.id)
            if generation == refreshID, profiles.contains(where: { $0 == account }) {
                openProfile(account)
            }
        }
    }

    /// 先根据账号 ID 合并并保存完整集合，再刷新当前连接。
    private func importProfiles(_ incoming: [StorageProfile]) throws {
        guard vaultReady else { throw BrowserError.message(appText("钥匙串不可用。")) }
        var updated = profiles
        for account in incoming {
            if let index = updated.firstIndex(where: { $0.id == account.id }) {
                updated[index] = account
            } else {
                updated.append(account)
            }
        }
        try ProfileVault.saveProfiles(updated)
        profiles = updated
        let generation = refreshID
        Task {
            for account in incoming { await DirectoryCache.shared.invalidate(profile: account.id) }
            if generation == refreshID, let active = profile ?? profiles.first { openProfile(active) }
        }
    }

    /// 删除只影响本地配置，当前账号删除后重新计算浏览上下文。
    private func removeProfile(_ account: StorageProfile) {
        guard vaultReady else { return }
        do {
            let updated = profiles.filter { $0.id != account.id }
            try ProfileVault.saveProfiles(updated)
            profiles = updated
            Task { await DirectoryCache.shared.invalidate(profile: account.id) }
            if account.id.uuidString == activeProfileID {
                if let next = profiles.first {
                    openProfile(next)
                } else {
                    activeProfileID = ""
                    buckets = []
                    selectBucket(nil)
                }
            }
        } catch {
            notice = error.localizedDescription
        }
    }

    /// 切换账号时，直接进入显式配置的 Bucket，可使用只有桶级权限的账号。
    private func openProfile(_ account: StorageProfile) {
        activeProfileID = account.id.uuidString
        let defaultBucket = account.bucket.isEmpty ? nil : StorageBucket(name: account.bucket)
        buckets = defaultBucket.map { [$0] } ?? []
        selectBucket(defaultBucket)
    }

    /// 紧凑布局返回侧栏后，重新打开已选 Bucket 时保留原目录。
    private func openListedBucket(_ bucket: StorageBucket) {
        if selectedBucket == bucket {
            compactColumn = .detail
        } else {
            selectBucket(bucket)
        }
    }

    /// 切换桶从根路径开始。
    private func selectBucket(_ bucket: StorageBucket?) {
        highlightedObject = nil
        selectedBucket = bucket
        compactColumn = bucket == nil ? .sidebar : .detail
        prefix = ""
        reloadDirectory(syncPathDraft: true)
    }

    /// 通过删除末级路径返回父级，保留 key 中已有的连续分隔符。
    private func openParentDirectory() {
        highlightedObject = nil
        let path = prefix.dropLast()
        prefix = path.lastIndex(of: "/").map { String(path[...$0]) } ?? ""
        reloadDirectory(syncPathDraft: true)
    }

    /// 变更目录后停止上一代列表及链接请求。
    private func reloadDirectory(syncPathDraft: Bool = false, keepingTextPreview: UUID? = nil) {
        previewTask?.cancel()
        previewURL = nil
        HTMLPreviewDocument = nil
        if textPreview?.id != keepingTextPreview { textPreview = nil }
        mediaPreview = nil
        pendingDelete = nil
        pendingMove = nil
        requestedPage = nil
        automaticallyRequestedPages.removeAll()
        showsLinkOptions = false
        linkObject = nil
        clearShareLinkTask()
        objects = []
        cursor = nil
        notice = ""
        loading = false
        if syncPathDraft || !pathInputFocused { pathDraft = prefix }
        if syncPathDraft { pathInputFocused = false }
        refreshID = UUID()
    }

    /// 手工刷新以及写入成功后统一使该账号的浏览结果过期。
    private func refreshDirectoryFromNetwork(keepingTextPreview: UUID? = nil) {
        guard let profile else { return }
        let generation = refreshID
        Task {
            await DirectoryCache.shared.invalidate(profile: profile.id)
            if generation == refreshID { reloadDirectory(keepingTextPreview: keepingTextPreview) }
        }
    }

    /// 直接输入 Bucket 内的路径。空白或单个斜杠进入根目录。
    private func submitBrowserPath() {
        pathInputFocused = false
        resolveBrowserPath(pathDraft)
    }

    /// 输入目录前缀直接进入，精确命中的文件进入父目录并高亮。
    private func resolveBrowserPath(_ path: String) {
        guard let storage, let selectedBucket else { return }
        if let target = BrowserPathTarget.directory(for: path) {
            navigateToBrowserPath(target)
            return
        }
        let generation = refreshID
        let resolutionID = UUID()
        pathResolutionID = resolutionID
        Task {
            do {
                let page = try await storage.listObjects(
                    bucket: selectedBucket, prefix: path, cursor: nil, delimiter: nil, pageSize: 1
                )
                guard generation == refreshID, resolutionID == pathResolutionID else { return }
                navigateToBrowserPath(BrowserPathTarget.resolve(path, in: page))
            } catch {
                if generation == refreshID, resolutionID == pathResolutionID {
                    notice = appText("路径跳转失败，请检查目录和访问权限。")
                }
            }
        }
    }

    /// 统一提交已解析的目标，再刷新目录和路径栏。
    private func navigateToBrowserPath(_ target: BrowserPathTarget) {
        highlightedObject = target.highlightedObject
        prefix = target.prefix
        reloadDirectory(syncPathDraft: true)
    }

    /// 网络完成后检查代次及取消状态，避免迟到响应覆盖新目录。
    private func fetchDirectoryPage(after token: String?) async {
        guard let storage, let profile else { return }
        let generation = refreshID
        let requestedPrefix = prefix
        let sort = ordering
        let currentPageSize = sort.requiresCompleteDirectory ? 1_000 : pageSize
        loading = true
        defer { if generation == refreshID { loading = false } }
        do {
            if let selectedBucket {
                var next = token
                var seenTokens = Set<String>()
                var visitedCount = 0
                var entries = token == nil ? [] : objects
                var known = Set(entries.map(\.id))
                repeat {
                    let cacheKey = DirectoryCacheKey(
                        bucket: selectedBucket, prefix: requestedPrefix, cursor: next, pageSize: currentPageSize
                    )
                    let page: StoragePage
                    if let cached = await DirectoryCache.shared.load(
                        StoragePage.self, profile: profile.id, key: cacheKey
                    ) {
                        page = cached
                    } else {
                        page = try await storage.listObjects(
                            bucket: selectedBucket, prefix: requestedPrefix, cursor: next,
                            delimiter: "/", pageSize: currentPageSize
                        )
                        if !Task.isCancelled, generation == refreshID {
                            await DirectoryCache.shared.store(page, profile: profile.id, key: cacheKey)
                        }
                    }
                    guard !Task.isCancelled, generation == refreshID else { return }
                    visitedCount += page.objects.count
                    let nextPage = page.next.flatMap { $0.isEmpty ? nil : $0 }
                    if sort.exceedsDirectoryLimit(visitedCount: visitedCount, hasNextPage: nextPage != nil) {
                        notice = appText("目录超过 10000 项，无法完整排序。请切换为名称正序或进入子目录。")
                        return
                    }
                    if let nextPage, nextPage == next || !seenTokens.insert(nextPage).inserted ||
                        (page.objects.isEmpty && sort.requiresCompleteDirectory) {
                        notice = appText("存储服务返回的分页异常，请刷新重试。")
                        return
                    }
                    entries += page.objects.filter { known.insert($0.id).inserted }
                    next = nextPage
                    if !sort.requiresCompleteDirectory,
                       highlightedObject.map({ known.contains($0) }) != false { break }
                    // 文件跳转只扫描有限页；保留续页令牌，用户仍可按名称继续浏览。
                } while next != nil && (sort.requiresCompleteDirectory ||
                    visitedCount < DirectoryOrdering.completeDirectoryLimit)
                objects = entries.sorted(by: sort.precedes)
                cursor = next
            } else {
                let cacheKey = DirectoryCacheKey.bucketListing
                let result: [StorageBucket]
                if let cached = await DirectoryCache.shared.load(
                    [StorageBucket].self, profile: profile.id, key: cacheKey
                ) {
                    result = cached
                } else {
                    result = try await storage.listBuckets()
                    if !Task.isCancelled, generation == refreshID {
                        await DirectoryCache.shared.store(result, profile: profile.id, key: cacheKey)
                    }
                }
                guard !Task.isCancelled, generation == refreshID else { return }
                buckets = result
            }
        } catch {
            guard !Task.isCancelled, generation == refreshID else { return }
            notice = appText("读取存储列表失败。请检查区域、端点、网络和访问权限。")
        }
    }

    /// 核对当前目录并在打开系统选择器前捕获上传目标。
    private func openUploadFilePicker() {
        guard let profile, let selectedBucket else { return }
        pendingUploadDestination = (profile, selectedBucket, prefix)
        showsFileImporter = true
    }

    /// 文件选择结束后将固定目标交给应用级队列，切换页面不取消上传。
    private func importUploadFiles(_ selection: Result<[URL], Error>) {
        let destination = pendingUploadDestination
        pendingUploadDestination = nil
        guard let destination, case let .success(files) = selection, !files.isEmpty else { return }
        uploadQueue.enqueueUploadFiles(
            files, profile: destination.account, bucket: destination.bucket, prefix: destination.prefix
        )
        showsUploads = true
    }

    /// 创建空目录标记，目录名单段校验避免无意写入其他前缀。
    private func createDirectory() {
        guard let storage, let profile, let selectedBucket, mutationTask == nil else { return }
        let name = directoryName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
            notice = appText("请输入单级目录名。")
            return
        }
        let key = prefix + name + "/"
        let generation = refreshID
        mutationTask = Task {
            defer { mutationTask = nil }
            let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: file) }
            do {
                try Data().write(to: file, options: .withoutOverwriting)
                try await storage.uploadObject(bucket: selectedBucket, key: key, file: file)
                await DirectoryCache.shared.invalidate(profile: profile.id)
                if generation == refreshID { reloadDirectory() }
            } catch {
                if generation == refreshID {
                    notice = appText("创建目录失败。请检查是否已存在同名目录或缺少写入权限。")
                }
            }
        }
    }

    /// 目录和文件共用操作入口，确认时呈现完整 key 或递归范围。
    @ViewBuilder
    private func objectMutationMenu(_ item: StorageObject) -> some View {
        Button(appText("移动或重命名")) {
            pendingMove = item
        }
        .disabled(mutationTask != nil)
        Button(appText("删除"), role: .destructive) {
            if confirmDestructiveOperations { pendingDelete = item } else { mutateObject(item, destination: nil) }
        }
        .disabled(mutationTask != nil)
    }

    /// 捕获用户确认时的目标和路由，导航期间只在原目录仍可见时刷新。
    private func mutateObject(_ item: StorageObject, destination: String?) {
        guard let storage, let profile, let selectedBucket, mutationTask == nil else { return }
        let generation = refreshID
        mutationTask = Task {
            defer { mutationTask = nil }
            do {
                _ = try await ObjectMutations.mutateObjects(
                    storage: storage, bucket: selectedBucket, source: item, destination: destination
                )
                await DirectoryCache.shared.invalidate(profile: profile.id)
                if generation == refreshID { reloadDirectory() }
            } catch {
                await DirectoryCache.shared.invalidate(profile: profile.id)
                if generation == refreshID {
                    reloadDirectory()
                    notice = (error as? LocalizedError)?.errorDescription
                        ?? appText("操作失败，请刷新确认远端对象状态。")
                }
            }
        }
    }

    #if os(macOS)
    /// 用户确认保存位置后下载到磁盘，再原子替换目标，失败时保留原文件。
    private func saveObject(_ item: StorageObject) {
        guard let storage, let selectedBucket, downloadTask == nil else { return }
        let panel = NSSavePanel()
        let name = item.name
        panel.nameFieldStringValue = name.isEmpty || name == "." || name == ".." ? "文件" : name
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let previousFileExists = FileManager.default.fileExists(atPath: destination.path)
        downloadTask = Task {
            defer { downloadTask = nil }
            do {
                let address = try await storage.signDownload(bucket: selectedBucket, key: item.key, expiry: 300)
                let temporary = try await ObjectTransfer.downloadObject(from: address)
                defer { try? FileManager.default.removeItem(at: temporary) }
                if previousFileExists {
                    _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
                } else {
                    try FileManager.default.moveItem(at: temporary, to: destination)
                }
            } catch {
                notice = appText("下载失败。请检查访问权限、网络和目标目录。")
            }
        }
    }
    #else
    /// iOS 通过系统文档选择器将临时副本导出到用户指定位置。
    private func saveObject(_ item: StorageObject) {
        guard let storage, let selectedBucket, downloadTask == nil else { return }
        downloadTask = Task {
            do {
                let address = try await storage.signDownload(bucket: selectedBucket, key: item.key, expiry: 300)
                let temporary = try await ObjectTransfer.downloadObject(from: address)
                defer { try? FileManager.default.removeItem(at: temporary) }
                exportedObject = try LocalObjectFile.stageFile(temporary, name: item.name)
            } catch {
                downloadTask = nil
                notice = appText("下载失败。请检查访问权限、网络和本机存储空间。")
            }
        }
    }
    #endif

    /// 将对象流式下载至独立临时目录，通过系统 Quick Look 打开本地副本。
    private func previewObject(_ item: StorageObject) {
        guard let storage, let selectedBucket else { return }
        let type = PreviewFormat(name: item.name)
        guard type != .unsupported else {
            notice = appText("此文件类型暂时无法预览。")
            return
        }
        previewTask?.cancel()
        previewURL = nil
        HTMLPreviewDocument = nil
        textPreview = nil
        mediaPreview = nil
        previewTask = Task {
            do {
                let fileExtension = (item.name as NSString).pathExtension.lowercased()
                let isSmall = type == .html || type == .text || type == .markdown
                    || ["docx", "xlsx", "pptx", "csv", "tsv"].contains(fileExtension)
                let limit = isSmall ? documentPreviewLimit : 128 * 1024 * 1024
                guard type == .media || (item.size ?? 0) <= limit else {
                    throw ObjectTransfer.previewSizeError()
                }
                if type == .html || type == .image {
                    let provider = storage is OssStorage ? "OSS" : "S3"
                    let kind = type == .html ? "html" : "image"
                    do {
                        if type == .html {
                            let data = try await storage.readHTMLPreview(
                                bucket: selectedBucket, key: item.key, maximumLength: limit
                            )
                            try Task.checkCancellation()
                            HTMLPreviewDocument = HTMLPreview(
                                name: item.name, source: String(decoding: data, as: UTF8.self)
                            )
                        } else {
                            let temporary = try await storage.downloadImagePreview(
                                bucket: selectedBucket, key: item.key, maximumLength: limit
                            )
                            defer { try? FileManager.default.removeItem(at: temporary) }
                            try Task.checkCancellation()
                            try presentDownloadedPreview(temporary, named: item.name)
                        }
                        recordPreviewDiagnostic("provider=" + provider + " result=success", kind: kind)
                    } catch {
                        if !Task.isCancelled {
                            if let browserError = error as? BrowserError,
                               case let .previewHTTPStatus(status, code, requestID) = browserError {
                                recordPreviewDiagnostic([
                                    "provider=" + provider, "HTTP=" + String(status),
                                    "code=" + (code ?? "-"), "requestID=" + (requestID ?? "-")
                                ].joined(separator: " "), kind: kind)
                            } else {
                                let failure = error as NSError
                                recordPreviewDiagnostic(
                                    "provider=" + provider + " error=" + failure.domain + "/" + String(failure.code),
                                    kind: kind
                                )
                            }
                        }
                        throw error
                    }
                    return
                }
                let url = try await storage.signDownload(
                    bucket: selectedBucket, key: item.key, expiry: type == .media ? 3600 : 300
                )
                if type == .media {
                    try Task.checkCancellation()
                    mediaPreview = MediaPreview(name: item.name, url: url, autoPlay: autoPlayMedia)
                    return
                }
                if type == .text || type == .markdown {
                    var snapshot = try await ObjectTransfer.readObjectSnapshot(from: url, maximumLength: limit)
                    if textEditETag(snapshot.etag) == nil {
                        let headVersion = try? await storage.textObjectETag(bucket: selectedBucket, key: item.key)
                        try Task.checkCancellation()
                        // 列表版本只用于发起条件读取，服务端接受 If-Match 后才可编辑。
                        if let etag = textEditETag(headVersion) ?? textEditETag(item.etag),
                           let verified = try? await ObjectTransfer.readObjectSnapshot(
                            from: url, maximumLength: limit, matchingETag: etag
                           ), verified.etag == nil || textEditETag(verified.etag) == etag {
                            snapshot = (verified.data, etag)
                        }
                    }
                    try Task.checkCancellation()
                    let text = String(decoding: snapshot.data, as: UTF8.self)
                    let previewID = UUID()
                    let replace: ((String, String) async throws -> String?)?
                    let etag = textEditETag(snapshot.etag)
                    let decoded = TextEditEncoding.decode(snapshot.data, named: item.name)
                    if let codec = decoded?.codec {
                        replace = { draft, currentETag in
                            guard textPreview?.id == previewID else {
                                throw BrowserError.message(appText("对象已切换，请重新打开预览。"))
                            }
                            guard let content = codec.encode(draft) else {
                                throw BrowserError.message(appText("文本无法使用原编码无损保存。"))
                            }
                            guard content.count <= limit else {
                                throw BrowserError.message(appText("编辑后的文本超过大小上限。"))
                            }
                            let updatedETag = try await storage.replaceTextObject(
                                bucket: selectedBucket, key: item.key, etag: currentETag, content: content
                            )
                            if textPreview?.id == previewID {
                                refreshDirectoryFromNetwork(keepingTextPreview: previewID)
                            }
                            return updatedETag
                        }
                    } else {
                        replace = nil
                    }
                    textPreview = TextPreview(
                        id: previewID, name: item.name, target: "\(selectedBucket.name)/\(item.key)",
                        text: decoded?.text ?? text, markdown: type == .markdown,
                        etag: etag, replace: replace, usesOSS: storage is OssStorage
                    )
                    return
                }
                let temporary = try await ObjectTransfer.downloadObject(from: url, maximumLength: limit)
                defer { try? FileManager.default.removeItem(at: temporary) }
                try Task.checkCancellation()
                try presentDownloadedPreview(temporary, named: item.name)
            } catch {
                guard !Task.isCancelled else { return }
                notice = (error as? BrowserError)?.localizedDescription
                    ?? appText("预览下载失败。请检查访问权限、网络和磁盘空间。")
            }
        }
    }

    /// 用保留扩展名的本地副本交给 Quick Look，展示失败时清理新目录。
    private func presentDownloadedPreview(_ temporary: URL, named name: String) throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let safeName = name.isEmpty || name == "." || name == ".." ? "文件" : name
        let destination = directory.appending(component: safeName)
        do {
            try FileManager.default.moveItem(at: temporary, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        removePreviewDirectory()
        previewDirectory = directory
        previewURL = destination
    }

    /// 每类预览只保留最近一次读取结果，供真机诊断。
    private func recordPreviewDiagnostic(_ value: String, kind: String) {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " =-_/.:"))
        let record = String(value.unicodeScalars.filter { allowed.contains($0) }.prefix(512))
        let path = URL.temporaryDirectory.appending(path: "\(kind)-preview-status.txt")
        try? record.write(to: path, atomically: true, encoding: .utf8)
    }

    /// 关闭预览时释放临时副本。
    private func removePreviewDirectory() {
        if let previewDirectory {
            try? FileManager.default.removeItem(at: previewDirectory)
            self.previewDirectory = nil
        }
    }

    /// 只在用户点击复制时将链接放入剪贴板。
    private func copyShareAddress(_ url: URL) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        #else
        UIPasteboard.general.url = url
        #endif
    }

    /// 仅公开链接查询 OSS 自定义域名；分别呈现空列表和查询失败。
    private func loadShareLinkDomains() async {
        guard usesPublicLink, let storage = storage as? OssStorage, let selectedBucket else {
            loadingLinkDomains = false
            return
        }
        let generation = refreshID
        loadingLinkDomains = true
        domainNotice = ""
        defer { if !Task.isCancelled, generation == refreshID { loadingLinkDomains = false } }
        do {
            let result = try await storage.listPublicLinkDomains(bucket: selectedBucket)
            guard !Task.isCancelled, generation == refreshID else { return }
            domains = result
            if result.isEmpty { domainNotice = appText("没有可用的自定义域名，可使用默认端点。") }
        } catch {
            guard !Task.isCancelled, generation == refreshID else { return }
            domains = []
            linkDomain = nil
            domainNotice = appText("无法查询自定义域名。请检查 oss:ListCname 权限，或使用默认端点。")
        }
    }

    /// 重设过期时间或域名后，旧结果不再对应面板选项。
    private func clearShareLinkResult() {
        signedURL = nil
        linkFailure = ""
    }

    /// 关闭面板时结束请求，避免迟到结果覆盖下一次操作。
    private func clearShareLinkTask() {
        shareLinkTask?.cancel()
        shareLinkTask = nil
        clearShareLinkResult()
    }

    /// 点击确认动作后生成链接，关闭动作由独立工具栏按钮负责。
    private func startShareLink() {
        guard shareLinkTask == nil else { return }
        guard let storage, let selectedBucket, let linkObject else {
            linkFailure = appText("对象已切换，请重新打开预览。")
            return
        }
        let key = linkObject.key
        let expiry = TimeInterval(linkHours * 3600)
        let isPublic = usesPublicLink
        let domain = isPublic ? linkDomain : nil
        clearShareLinkResult()
        shareLinkTask = Task {
            defer { if !Task.isCancelled { shareLinkTask = nil } }
            do {
                let signed = try await storage.signDownload(bucket: selectedBucket, key: key, expiry: expiry)
                try Task.checkCancellation()
                signedURL = try isPublic ? publicObjectLink(from: signed, domain: domain) : signed
            } catch {
                guard !Task.isCancelled else { return }
                linkFailure = (error as? BrowserError)?.localizedDescription
                    ?? appText("生成下载链接失败。请检查连接配置和访问权限。")
            }
        }
    }
}

/// 在独立草稿中修改配置，失败时保留输入。
private struct ProfileEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var profile: StorageProfile
    let save: (StorageProfile) throws -> Void
    @State private var errorMessage = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField(appText("名称"), text: $profile.name)
                Picker(appText("类型"), selection: $profile.provider) {
                    ForEach(StorageProvider.allCases) { provider in
                        Text(provider.rawValue).tag(provider)
                    }
                }
                TextField(appText("区域"), text: $profile.region, prompt: Text(
                    profile.provider == .oss ? "cn-hangzhou" : "us-east-1"
                ))
                Menu(appText("选择区域")) {
                    ForEach(profile.provider == .oss ? StorageRegionPreset.oss : StorageRegionPreset.s3, id: \.code) {
                        preset in
                        Button(appText(preset.labelKey) + " · " + preset.code) {
                            preset.apply(to: &profile)
                        }
                    }
                }
                TextField(appText("HTTPS 端点（可选）"), text: $profile.endpoint)
                TextField(appText("默认 Bucket（可选）"), text: $profile.bucket)
                TextField(appText("备注（可选）"), text: Binding(get: { profile.note ?? "" }, set: { profile.note = $0 }))
                TextField("AccessKey ID", text: $profile.accessKeyID)
                SecureField("AccessKey Secret", text: $profile.secret)
                SecureField(appText("Session Token（可选）"), text: $profile.sessionToken)
                if profile.provider == .s3 {
                    Toggle(appText("使用 path-style"), isOn: $profile.forcePathStyle)
                }
                if !errorMessage.isEmpty {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
            .padding()
            .navigationTitle(appText("存储账号"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(appText("取消")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(appText("保存并激活")) {
                        do {
                            try save(profile)
                            dismiss()
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                }
            }
        }
        .frame(minWidth: 340, minHeight: 410)
    }
}
