// Copyright 2026 jinlongliao
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// 首次启动说明凭据、连接与本地数据用途，其后可在设置中重新查看。
struct AboutStorageView: View {
    @Environment(\.dismiss) private var dismiss

    var accept: (() -> Void)?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if accept == nil {
                        projectInformation
                    }
                    Text(appText("你的凭据保存在本机钥匙串。应用使用这些凭据连接你设置的 OSS 或 S3 服务。只有你选择备份、上传、下载或分享时，应用才会执行对应操作。"))
                    Text(appText("本地缓存包含列表和临时预览。你可以在浏览设置中清理列表缓存，预览副本在关闭后删除。"))
                    Link("Alibaba Cloud OSS Swift SDK · Apache 2.0", destination: URL(
                        string: "https://github.com/aliyun/alibabacloud-oss-swift-sdk-v2"
                    )!)
                    Link("AWS SDK for Swift · Apache 2.0", destination: URL(
                        string: "https://github.com/awslabs/aws-sdk-swift"
                    )!)
                    if let accept {
                        Button(appText("同意并开始"), action: accept)
                            .buttonStyle(.borderedProminent)
                    }
                }
                .frame(maxWidth: 560, alignment: .leading)
                .padding()
            }
            .navigationTitle(appText(accept == nil ? "关于" : "隐私与开源许可"))
            .toolbar {
                if accept == nil {
                    ToolbarItem(placement: .cancellationAction) { Button(appText("关闭")) { dismiss() } }
                }
            }
        }
        .frame(minWidth: 340, minHeight: 320)
    }

    /// 关于页展示当前包版本，并提供作者、项目源代码和随包附带的许可证。
    private var projectInformation: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("alioss4ios").font(.title.bold())
            if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
               let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String {
                Text(appText("版本") + " " + version + " (" + build + ")")
                    .foregroundStyle(.secondary)
            }
            Link(appText("作者") + " · jinlongliao", destination: URL(string: "https://github.com/JinlongLiao/")!)
            Link(appText("项目源码"), destination: URL(string: "https://github.com/JinlongLiao/alioss4ios")!)
            NavigationLink("Apache License 2.0") {
                ScrollView {
                    Text(verbatim: projectLicenseText)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: 720, alignment: .leading)
                        .padding()
                }
                .navigationTitle(appText("应用开源许可"))
            }
            Divider()
        }
    }

    /// SwiftPM 与 Xcode 的许可证分别来自资源包和主应用包。
    private var projectLicenseText: String {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        guard let url = bundle.url(forResource: "ProjectLicense", withExtension: "txt"),
              let license = try? String(contentsOf: url, encoding: .utf8) else {
            return appText("无法读取应用开源许可。")
        }
        return license
    }
}
