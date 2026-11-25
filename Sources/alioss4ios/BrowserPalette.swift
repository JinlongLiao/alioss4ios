// Copyright 2026 jinlongliao
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// Android 的 18 套主题主色，分别使用浅色和深色值。
enum BrowserPalette: String, CaseIterable, Identifiable {
    case `default`
    case gemini
    case summer_sky
    case celadon
    case dusk
    case sand
    case prism
    case aurora
    case glacier_glass
    case twilight_glass
    case monochrome
    case terminal
    case cyber
    case paper
    case sakura
    case forest
    case sea_salt
    case sunset

    var id: Self { self }

    var title: String { appText("palette." + rawValue) }

    /// 从原有强调色迁移，保留用户选择的绿色或暖色倾向。
    static func resolve(_ storedValue: String) -> Self {
        switch storedValue {
        case "orange": return .sunset
        case "green": return .forest
        default: return Self(rawValue: storedValue) ?? .default
        }
    }

    /// 相同主题在亮暗模式下分别使用 Android 的主色。
    func tint(dark: Bool) -> Color {
        let rgb: UInt32
        switch self {
        case .default: rgb = dark ? 0xA8C7FF : 0x355FA2
        case .gemini: rgb = dark ? 0x8AB4F8 : 0x185ABC
        case .summer_sky: rgb = dark ? 0xA7CFE8 : 0x2C6488
        case .celadon: rgb = dark ? 0x9AD7BF : 0x286C5C
        case .dusk: rgb = dark ? 0xCAB8E9 : 0x6B5793
        case .sand: rgb = dark ? 0xDDC09A : 0x805F39
        case .prism: rgb = dark ? 0xB8C4FF : 0x4B60A8
        case .aurora: rgb = dark ? 0x8CDCCB : 0x246D68
        case .glacier_glass: rgb = dark ? 0xA4D9F4 : 0x2B648B
        case .twilight_glass: rgb = dark ? 0xD1BCF8 : 0x705397
        case .monochrome: rgb = dark ? 0xF0F0F0 : 0x292929
        case .terminal: rgb = dark ? 0x8FE0A3 : 0x27623C
        case .cyber: rgb = dark ? 0x70E7DE : 0x146C70
        case .paper: rgb = dark ? 0xE3C8A1 : 0x755B3C
        case .sakura: rgb = dark ? 0xF1BCD0 : 0x975A75
        case .forest: rgb = dark ? 0xB8D5A3 : 0x516D3F
        case .sea_salt: rgb = dark ? 0x96D6E4 : 0x246E7D
        case .sunset: rgb = dark ? 0xFFC29E : 0x8E563B
        }
        return Self.color(rgb)
    }

    /// 完整色阶与 Android ThemeVisualStyle 同源；实色主题只提供一个颜色。
    private func backgroundStops(dark: Bool) -> [UInt32] {
        switch self {
        case .default: return dark ? [0x151A22] : [0xF6F8FC]
        case .gemini: return dark ? [0x132138, 0x172A24, 0x302819, 0x302126] : [0xEDF4FF, 0xEEF8F1, 0xFFF7E9, 0xFFF0F1]
        case .summer_sky: return dark ? [0x102738, 0x18374B, 0x223C48] : [0xCFEAFF, 0xE6F4FF, 0xF0F8FC]
        case .celadon: return dark ? [0x151D1A] : [0xF4F8F5]
        case .dusk: return dark ? [0x1C1922] : [0xF8F6FA]
        case .sand: return dark ? [0x201C17] : [0xFAF8F4]
        case .prism: return dark ? [0x182542, 0x32213B, 0x382B22] : [0xDBF2FF, 0xF0E2FF, 0xFFE5ED, 0xFFF0D2]
        case .aurora: return dark ? [0x082C31, 0x183144, 0x342548] : [0xD8F8EE, 0xDCF0FF, 0xEFE2FF]
        case .glacier_glass: return dark ? [0x183449, 0x253756, 0x383452] : [0xBCEEF5, 0xD4E4FF, 0xE7D6FA]
        case .twilight_glass: return dark ? [0x251A42, 0x35385C, 0x293F50] : [0xE7D6F8, 0xDDE4FB, 0xD6EDF1]
        case .monochrome: return dark ? [0x000000] : [0xF7F7F7]
        case .terminal: return dark ? [0x0D1710] : [0xF1F7F1]
        case .cyber: return dark ? [0x08232C, 0x181B39, 0x291735] : [0xDDF8F5, 0xE7EBFF, 0xF4E4FF]
        case .paper: return dark ? [0x221F19] : [0xFAF6EC]
        case .sakura: return dark ? [0x2C1C29, 0x302236] : [0xFCE6EE, 0xF7EEFA]
        case .forest: return dark ? [0x172117] : [0xF4F7EF]
        case .sea_salt: return dark ? [0x112329] : [0xF0F9FA]
        case .sunset: return dark ? [0x37232D, 0x382A30, 0x242B42] : [0xFFE1C5, 0xFFE7E3, 0xECE3FA]
        }
    }

    /// 顶部和底部系统栏分别衔接渐变的首色和末色。
    func browserSurface(dark: Bool, atBottom: Bool = false) -> Color {
        let stops = backgroundStops(dark: dark)
        return Self.color(stops[atBottom ? stops.count - 1 : 0])
    }

    /// 与 Android ThemeBackdrop 共用色阶、光晕和云团比例，按当前区域尺寸静态绘制。
    func browserBackdrop(dark: Bool) -> some View {
        let stops = backgroundStops(dark: dark).map(Self.color)
        return Canvas { context, size in
            let bounds = CGRect(origin: .zero, size: size)
            if stops.count == 1 {
                context.fill(Path(bounds), with: .color(stops[0]))
            } else {
                context.fill(Path(bounds), with: .linearGradient(
                    Gradient(colors: stops), startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)
                ))
                let center = CGPoint(x: size.width, y: size.height * 0.12)
                context.fill(Path(bounds), with: .radialGradient(
                    Gradient(colors: [stops[0].opacity(0.75), stops[0].opacity(0)]),
                    center: center, startRadius: 0, endRadius: size.width * 0.72
                ))
            }
            if self == .summer_sky {
                let cloud = Color.white.opacity(dark ? 0.045 : 0.5)
                for (x, y, radius) in [(0.82, 0.14, 0.25), (0.56, 0.18, 0.18), (0.98, 0.22, 0.22)] {
                    let circle = CGRect(
                        x: size.width * (x - radius), y: size.height * y - size.width * radius,
                        width: size.width * radius * 2, height: size.width * radius * 2
                    )
                    context.fill(Path(ellipseIn: circle), with: .color(cloud))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// 与 Android 主题一致的卡片圆角，Apple 控件保留各自的点击区域。
    var cardRadius: CGFloat {
        switch self {
        case .terminal, .cyber: return 6
        case .paper: return 8
        case .monochrome: return 10
        case .prism: return 24
        case .glacier_glass, .twilight_glass: return 22
        default: return 16
        }
    }

    /// 纸感和终端主题只调整字形家族，保留系统动态字号。
    var fontDesign: Font.Design {
        switch self {
        case .paper: return .serif
        case .terminal, .cyber: return .monospaced
        default: return .default
        }
    }

    private static func color(_ rgb: UInt32) -> Color {
        Color(
            red: Double((rgb >> 16) & 255) / 255,
            green: Double((rgb >> 8) & 255) / 255,
            blue: Double(rgb & 255) / 255
        )
    }
}
