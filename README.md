# alioss4ios · OSS and S3 Browser for Apple Platforms

[简体中文](README.zh-CN.md) · [文档索引](docs/文档索引.md)

Alioss4ios is a SwiftUI port of [alioss4droid](https://github.com/JinlongLiao/alioss4droid) for Apple silicon Macs, iPhone, and iPad. The Files and Settings navigation, storage profiles, and 18 color themes follow the Android edition, with native Apple layouts and controls.

## Features

- Alibaba Cloud OSS and AWS S3 profiles with Keychain storage, custom HTTPS endpoints, temporary credentials, and Android ALOS v1 backup import and export, with an optional password.
- Switch storage accounts from the top-left of the file browser. Wide windows keep the account and Bucket sidebar beside the contents.
- Bucket and object browsing, path navigation, sorting, caching, uploads, downloads, and same-bucket moves or renames.
- Upload history, multipart checkpoints, pause and resume, and explicit confirmation for destructive operations.
- Edit XML, JSON, YAML, TXT, Markdown, and other supported text formats. Review the line diff before confirming. The editor preserves supported encodings and verifies the original object version before replacing it. After saving, the updated text stays open in the same preview.
- Public and signed links, text and Markdown previews, HTML and image previews read directly from the current storage account. HTML provides a selectable source view, static rendering by default, and per-preview opt-in for JavaScript and external HTTPS resources. Audio and video use AVPlayer. Images and supported documents use Quick Look.

## Build and run

Use Xcode with Swift 6 or newer, plus network access to the SwiftPM dependencies. The minimum supported versions are macOS 14 on Apple silicon and iOS/iPadOS 17.

```bash
swift test --arch arm64
./scripts/build-macos.sh
open dist/alioss4ios.app
```

For iPhone or iPad, open `alioss4ios.xcodeproj` in Xcode and run the `alioss4ios` scheme. Select your development team for a physical device. See the [build and verification guide](docs/构建与验收.md) for simulator builds, signing, and validation.

## Documentation

- [使用手册](docs/使用手册.md)
- [项目设计与迁移说明](docs/项目设计与迁移说明.md)
- [构建与验收](docs/构建与验收.md)
- [贡献指南](docs/贡献指南.md)

The Apple silicon app, iPhone and iPad simulator apps, and an iPhone development build have launched. Live OSS and S3 read-only checks passed. On an iPhone, an OSS HTML object loaded through the account SDK and the previously failing image opened after the same read path was applied. Live write verification and iOS system suspension on a physical device remain pending.

## License

[Apache License 2.0](LICENSE)
