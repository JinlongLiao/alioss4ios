// Copyright 2026 jinlongliao
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// 文件页共用 Android 的存储桶、双层文件夹和折角文件图形，列表与网格使用同一套分类。
struct StorageItemIcon: View {
    enum Item {
        case bucket, folder, file(String)
    }

    let item: Item
    var size: CGFloat = 27

    var body: some View {
        Canvas { context, bounds in
            var drawing = context
            drawing.scaleBy(x: bounds.width / 32, y: bounds.height / 32)
            switch item {
            case .bucket: drawBucket(in: drawing)
            case .folder: drawFolder(in: drawing)
            case .file(let name): drawFile(name, in: drawing)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    /// 开口、桶壁与中部短线依照 Android 的 32 单位画布。
    private func drawBucket(in context: GraphicsContext) {
        let color = Color.accentColor
        let shell = Path {
            $0.move(to: CGPoint(x: 5, y: 9))
            $0.addLine(to: CGPoint(x: 7, y: 24))
            $0.addCurve(to: CGPoint(x: 25, y: 24), control1: CGPoint(x: 8, y: 29), control2: CGPoint(x: 24, y: 29))
            $0.addLine(to: CGPoint(x: 27, y: 9))
            $0.closeSubpath()
        }
        paint(shell, in: context, color: color, opacity: 0.28)
        let opening = Path(ellipseIn: CGRect(x: 5, y: 5.25, width: 22, height: 7.5))
        paint(opening, in: context, color: color, opacity: 0.14)
        let mark = Path {
            $0.move(to: CGPoint(x: 11, y: 19))
            $0.addCurve(to: CGPoint(x: 21, y: 19), control1: CGPoint(x: 14, y: 21), control2: CGPoint(x: 18, y: 21))
        }
        context.stroke(mark, with: .color(color), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
    }

    /// 分层轮廓在亮色和深色主题下均使用当前强调色。
    private func drawFolder(in context: GraphicsContext) {
        let color = Color.accentColor
        let back = Path {
            $0.move(to: CGPoint(x: 4, y: 10))
            $0.addQuadCurve(to: CGPoint(x: 7, y: 7), control: CGPoint(x: 4, y: 7))
            $0.addLines([CGPoint(x: 7, y: 7), CGPoint(x: 12, y: 7), CGPoint(x: 15, y: 10), CGPoint(x: 25, y: 10)])
            $0.addQuadCurve(to: CGPoint(x: 28, y: 13), control: CGPoint(x: 28, y: 10))
            $0.addLine(to: CGPoint(x: 26, y: 26))
            $0.addLine(to: CGPoint(x: 4, y: 26))
            $0.closeSubpath()
        }
        paint(back, in: context, color: color, opacity: 0.18)
        let front = Path {
            $0.move(to: CGPoint(x: 5, y: 14))
            $0.addLines([CGPoint(x: 5, y: 14), CGPoint(x: 12, y: 14), CGPoint(x: 15, y: 16), CGPoint(x: 27, y: 16)])
            $0.addQuadCurve(to: CGPoint(x: 28, y: 19), control: CGPoint(x: 29, y: 16))
            $0.addLine(to: CGPoint(x: 26, y: 24))
            $0.addQuadCurve(to: CGPoint(x: 22, y: 27), control: CGPoint(x: 25, y: 27))
            $0.addLine(to: CGPoint(x: 7, y: 27))
            $0.addQuadCurve(to: CGPoint(x: 4, y: 24), control: CGPoint(x: 4, y: 27))
            $0.addLine(to: CGPoint(x: 3, y: 17))
            $0.addQuadCurve(to: CGPoint(x: 5, y: 14), control: CGPoint(x: 3, y: 14))
            $0.closeSubpath()
        }
        paint(front, in: context, color: color, opacity: 0.58)
    }

    /// 折角保留统一文件轮廓，内部符号和颜色表示文件类别。
    private func drawFile(_ name: String, in context: GraphicsContext) {
        let (symbol, rgb) = Self.fileAppearance(name)
        let color = Color(
            red: Double((rgb >> 16) & 255) / 255,
            green: Double((rgb >> 8) & 255) / 255,
            blue: Double(rgb & 255) / 255
        )
        let paper = Path {
            $0.move(to: CGPoint(x: 9, y: 3))
            $0.addLine(to: CGPoint(x: 19, y: 3))
            $0.addLine(to: CGPoint(x: 26, y: 10))
            $0.addLine(to: CGPoint(x: 26, y: 26))
            $0.addQuadCurve(to: CGPoint(x: 23, y: 29), control: CGPoint(x: 26, y: 29))
            $0.addLine(to: CGPoint(x: 9, y: 29))
            $0.addQuadCurve(to: CGPoint(x: 6, y: 26), control: CGPoint(x: 6, y: 29))
            $0.addLine(to: CGPoint(x: 6, y: 6))
            $0.addQuadCurve(to: CGPoint(x: 9, y: 3), control: CGPoint(x: 6, y: 3))
            $0.closeSubpath()
        }
        paint(paper, in: context, color: color, opacity: 0.18)
        let fold = Path {
            $0.move(to: CGPoint(x: 19, y: 3))
            $0.addLine(to: CGPoint(x: 19, y: 10))
            $0.addLine(to: CGPoint(x: 26, y: 10))
            $0.closeSubpath()
        }
        paint(fold, in: context, color: color, opacity: 0.24)
        let glyph = context.resolve(Text(Image(systemName: symbol)).font(.system(size: 10, weight: .semibold)))
        var tintedGlyph = glyph
        tintedGlyph.shading = .color(color)
        context.draw(tintedGlyph, at: CGPoint(x: 16, y: 19))
    }

    /// 类别只影响图标。预览仍由独立的格式分类决定。
    private static func fileAppearance(_ name: String) -> (String, UInt32) {
        let ext = (name.lowercased() as NSString).pathExtension
        switch ext {
        case "pdf": return ("text.viewfinder", 0xB66B72)
        case "doc", "docx", "rtf": return ("text.alignleft", 0x5B82B2)
        case "xls", "xlsx", "csv", "tsv": return ("tablecells", 0x5E8F7C)
        case "ppt", "pptx": return ("chart.bar.xaxis", 0xB88260)
        case "zip", "gz", "tar", "7z", "rar": return ("archivebox", 0xAA895D)
        case "json": return ("curlybraces", 0xAB8751)
        case "apk", "aab", "exe", "msi", "dmg": return ("shippingbox", 0x7C9670)
        case "html", "htm", "xhtml": return ("globe", 0xBA795E)
        case "mp3", "aac", "wav", "m4a", "ogg", "flac": return ("music.note", 0xB2845F)
        default:
            switch PreviewFormat(name: name) {
            case .image: return ("photo", 0x5D927C)
            case .media: return ("play.rectangle", 0x8B78B2)
            case .markdown, .text: return ("text.alignleft", 0x7F8DA2)
            default: return ("doc", 0x7F8DA2)
            }
        }
    }

    /// 同一部件以浅填充和实色轮廓保持小尺寸可辨识度。
    private func paint(_ path: Path, in context: GraphicsContext, color: Color, opacity: Double) {
        context.fill(path, with: .color(color.opacity(opacity)))
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
    }
}
