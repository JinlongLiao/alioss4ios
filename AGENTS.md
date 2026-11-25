# 项目协作指南

## 项目范围

本仓库是 `alioss4ios`，支持 Apple 芯片 Mac、iPhone 和 iPad。以相邻的 `../alioss4droid` 为功能、配置和交互参考。对齐时核对 Android 当前源码，记录适配差异和实际验证范围。面向用户的说明和文档优先使用简体中文。

- `Sources/alioss4ios/` 存放 SwiftUI 界面、OSS/S3 适配器、账号备份、上传队列和本地化资源。
- `Tests/alioss4iosTests/` 存放 SwiftPM 回归测试，优先扩展同功能的现有测试。
- `Package.swift` 用于 Mac 构建与测试，`alioss4ios.xcodeproj` 用于 iPhone 和 iPad 构建。
- `scripts/build-macos.sh` 打包本地 Mac 应用，`docs/` 记录操作、构建和验收。

## 修改与验证

改动前检查工作区和相关调用路径。存在可用的 CodeGraph 索引时，优先用它定位代码。沿用现有 SwiftUI 页面、存储协议和账号状态。遵循 `.editorconfig` 与 `.gitattributes`，Swift 使用四空格缩进，文本使用 UTF-8 和 LF。保留用户已有改动。

- 业务改动运行 `swift test --arch arm64`。
- Mac 打包运行 `./scripts/build-macos.sh`。验证启动时用普通 `open dist/alioss4ios.app`，避免用 `open -n` 强制启动新实例。退出已有实例前先确认用户是否正在操作或上传。
- iOS 模拟器使用 `xcodebuild -project alioss4ios.xcodeproj -scheme alioss4ios -configuration Debug -destination 'generic/platform=iOS Simulator' build`。
- 界面改动覆盖窄屏 iPhone、宽屏 iPad 和 Mac。报告中分别记录构建、模拟器、真机及真实 Bucket 的验证结果。
- 完成前运行 `git diff --check`。文档以 [贡献指南](docs/贡献指南.md) 和 [构建与验收](docs/构建与验收.md) 为补充。

## 凭据与数据

凭据使用钥匙串。禁止将 AccessKey、Secret、SessionToken、真实备份、签名 URL 或签名材料写入仓库、测试夹具与验收记录。真实 Bucket 写入、删除和覆盖需取得明确授权。自定义端点保留 HTTPS 校验和配置中已有的部署路径。上传恢复只推进服务端已确认的分片。

## Git

本地默认分支为 `main`，远程 `origin` 为 `git@github.com:JinlongLiao/alioss4ios.git`。可执行只读 Git 检查。提交、推送及其它 Git 写操作需取得用户明确授权。提交沿用 Conventional Commits，保持单一主题。
