import SwiftUI
import UIKit

/// Design tokens shared with Tutti (programme paper, ink, brass, garnet), adapted for dark mode.
enum Theme {
    static let paper = dynamic(light: 0xF2F1EC, dark: 0x15191C)
    static let surface = dynamic(light: 0xFFFFFF, dark: 0x1E2428)
    static let ink = dynamic(light: 0x1E2E37, dark: 0xE9ECEE)
    static let inkSoft = dynamic(light: 0x52636C, dark: 0xA9B4BA)
    static let inkFaint = dynamic(light: 0x8A989F, dark: 0x6F7C83)
    static let brass = dynamic(light: 0xB5832A, dark: 0xD9A54A)
    static let garnet = dynamic(light: 0x8C2F36, dark: 0xD96B61)
    static let teal = dynamic(light: 0x2E6E6A, dark: 0x5FB3AC)
    static let slate = dynamic(light: 0x3E5360, dark: 0x9FB2BE)

    static func displayFont(_ style: Font.TextStyle) -> Font {
        .system(style, design: .serif).weight(.semibold)
    }

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        let r = CGFloat((hex >> 16) & 0xFF) / 255
        let g = CGFloat((hex >> 8) & 0xFF) / 255
        let b = CGFloat(hex & 0xFF) / 255
        self.init(red: r, green: g, blue: b, alpha: 1)
    }
}

/// Small pill used for tiers, "Curated", "AI-generated", "Beta" etc.
struct TagPill: View {
    let text: String
    var color: Color = Theme.slate

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(color)
            .background(color.opacity(0.12), in: Capsule())
    }
}
