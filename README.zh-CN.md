# alioss4ios · OSS / S3 Apple 客户端

[English](README.md) · [文档索引](docs/文档索引.md)

Alioss4ios 是基于 [alioss4droid](https://github.com/JinlongLiao/alioss4droid) 的 Apple 原生 OSS 与 S3 客户端。使用 SwiftUI、Keychain 以及 Alibaba Cloud OSS 和 AWS S3 官方 Swift SDK。macOS 与 iOS 共用账号、浏览、预览和传输实现。

## 本机运行

- Apple 芯片 Mac，macOS 14 或更新版本。构建后打开 `dist/alioss4ios.app`。
- iPhone 或 iPad，iOS/iPadOS 17 或更新版本。用 Xcode 打开 `alioss4ios.xcodeproj`，选择模拟器运行。真机需选择开发团队并生成配置描述文件。`dist/ios-simulator/alioss4ios.app` 可用于 Apple 芯片 Mac 上的 iOS 模拟器。

首次启动同意隐私说明，然后新增账号或导入 ALOS 备份。仅有 Bucket 级权限时填写默认 Bucket，可直接进入。AccessKey 和 SessionToken 保存在本机钥匙串。自定义服务端点使用 HTTPS，已有部署路径会保留。

## 操作入口与设备适配

- 文件和设置沿用 Android 的一级导航。文件页左上角可直接切换账号，并保留 Bucket 列表、路径、刷新与上传，设置页集中管理账号、外观、浏览、预览、安全、缓存和备份。
- iPhone 使用紧凑的分栏导航和双列卡片。iPad 与 Mac 在宽屏下保留 Bucket 侧栏，卡片列数随内容宽度调整。
- 配色提供 Android 同名的 18 套主题，并采用各主题的浅色与深色主色、页面背景和圆角。文件页和设置页共用所选主题的完整色阶，渐变主题保留颜色过渡，列表继续透出同一背景。控件、系统菜单和文件选择器遵循 Apple 平台交互。

## 迁移功能

| 功能 | Apple 版实现与边界 |
| --- | --- |
| 账号和备份 | OSS/S3 多账号、临时凭据、自定义端点和 path-style。支持 Android ALOS v1 备份双向导入导出，密码可选 |
| 浏览 | Bucket、名称升序下的滚动分页、目录和文件跳转、名称与时间排序、列表和网格、30 分钟磁盘列表缓存 |
| 文件操作 | 双端下载另存、创建目录、删除、同 Bucket 递归移动或重命名。递归操作有 10000 对象上限 |
| 文本编辑 | XML、JSON、YAML、TXT、Markdown 等支持编辑、逐行差异和确认更新。无损保留可识别的原编码，原版本无法验证时可继续预览。保存成功后停留在原预览并显示新正文。S3 由服务端校验 ETag，OSS 在写回前复查 |
| 链接 | 1～168 小时签名、公开链接、OSS 已启用的具体 CNAME，支持复制和系统分享 |
| 预览 | 文本与 Markdown、HTML 页面及可复制源码、AVPlayer 音视频，以及 Quick Look 图片、PDF、Office 和分隔文本。HTML 与图片通过当前账号直接读取。HTML 默认采用静态模式，确认后仅本次允许 JavaScript 和 HTTPS 外部资源。媒体编码和 Quick Look 格式支持取决于系统 |
| 上传 | 独立队列、进度、暂停、继续、撤销、历史清理。大文件记录服务端 Upload ID 和已完成分片。Mac 关窗可继续，退出后手动恢复。iOS 大文件分片和 OSS/S3 小文件交给系统后台会话，准备分片和合并仍需应用执行时间；退出后可恢复已落盘分片。挂起实测待验收 |
| 设置 | 明暗模式、18 套配色主题、简体中文、繁體中文与 English。第三方服务原始诊断采用服务返回语言 |

OSS 默认关闭版本控制时才能使用供应商的禁止覆盖条件。受保护的分片写入和移动需要读取 Bucket 版本状态。OSS 删除通过 HEAD 检查 ETag 后调用 DeleteObject，两步之间仍有并发写入窗口。S3 使用服务端条件请求。建议先在隔离 Bucket 验证，尤其是目录移动、同名目标、撤销和断点恢复。

## 构建与测试

需要 Xcode（Swift 6 或更新版本）和访问 SwiftPM 依赖的网络。

```bash
swift test --arch arm64
./scripts/build-macos.sh
open dist/alioss4ios.app
```

Mac 构建脚本在本地使用临时签名，不提供公证。模拟器包保留 Xcode 为应用生成的签名信息，钥匙串据此识别应用。真机包需使用开发团队或发布签名。单元测试使用占位凭据及服务端替身，涵盖签名、条件上传请求、目录分页和复制失败、分片重启恢复、CNAME 解析与备份加密兼容。

## 文档

- [使用手册](docs/使用手册.md)提供账号配置、文件操作和上传恢复说明。
- [项目设计与迁移说明](docs/项目设计与迁移说明.md)记录 Apple 端实现、平台差异和安全边界。
- [构建与验收](docs/构建与验收.md)记录签名方式、本地验证结果和未覆盖项。
- [贡献指南](docs/贡献指南.md)说明 Git 配置、源码格式和验证要求。

## 依赖

- [Alibaba Cloud OSS SDK for Swift V2 0.4.0](https://github.com/aliyun/alibabacloud-oss-swift-sdk-v2)
- [AWS SDK for Swift 1.8.35](https://github.com/awslabs/aws-sdk-swift)

## 许可证

[Apache License 2.0](LICENSE)
