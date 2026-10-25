import SwiftUI

/// Cinefile design tokens — "Graphite & Gate", tuned for iPad reading distance.
enum CF {
    // Surfaces: lifted graphite. The desktop palette (#0F1011) reads as a black
    // box on iPad, so every level is raised and the steps between levels are
    // smaller; panels read as panels instead of holes.
    static let bg0 = Color(hex: 0x17181B)
    static let bg1 = Color(hex: 0x1D1E22)
    static let bg2 = Color(hex: 0x24262B)
    static let bg3 = Color(hex: 0x2C2E34)
    static let bgHover = Color(hex: 0x32343B)

    // Lines: hairlines only, and faint.
    static let line = Color(hex: 0x2F3138)
    static let lineStrong = Color(hex: 0x3E4149)

    // Text.
    static let text1 = Color(hex: 0xF2F0EB)
    static let text2 = Color(hex: 0xC2C0B9)
    static let text3 = Color(hex: 0x8E8D87)
    static let textOnAccent = Color(hex: 0x181204)

    // Accent: one amber family.
    static let accent = Color(hex: 0xE2A24C)
    static let accentStrong = Color(hex: 0xF59E0B)
    static let accentSoft = Color(hex: 0xE2A24C).opacity(0.14)

    // Viewing states.
    static let stateUnwatched = Color(hex: 0x7C9AB8)
    static let stateWatching = Color(hex: 0xE2A24C)
    static let stateWatched = Color(hex: 0x7A7C82)

    // Feedback.
    static let danger = Color(hex: 0xD97A66)
    static let success = Color(hex: 0x8FB28C)

    // Type scale — iPad reading distance needs 15pt body, not 12pt.
    static let fontDisplay: CGFloat = 34
    static let fontTitle: CGFloat = 26
    static let fontBody: CGFloat = 15
    static let fontSmall: CGFloat = 13
    static let fontCaption: CGFloat = 11

    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    static func ui(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }

    // Layout.
    static let radius: CGFloat = 12
    static let radiusSmall: CGFloat = 8
    static let pad: CGFloat = 18
    static let gap: CGFloat = 14
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: 1.0
        )
    }
}

/// A hairline divider that matches the design system.
struct Hairline: View {
    var body: some View {
        Rectangle()
            .fill(CF.line)
            .frame(height: 1)
    }
}

/// Small mono uppercase label ("LIBRARIES · 片库").
struct Eyebrow: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(CF.mono(CF.fontCaption, weight: .medium))
            .tracking(0.8)
            .foregroundColor(CF.text3)
    }
}
