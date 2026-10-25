import SwiftUI

/// Cinefile design tokens — "Graphite & Gate", ported from design/tokens.css.
enum CF {
    // Surfaces: warm graphite, never pure black.
    static let bg0 = Color(hex: 0x0F1011)
    static let bg1 = Color(hex: 0x131416)
    static let bg2 = Color(hex: 0x18191C)
    static let bg3 = Color(hex: 0x1F2024)
    static let bgHover = Color(hex: 0x22242A)

    // Lines: hairlines only.
    static let line = Color(hex: 0x26282D)
    static let lineStrong = Color(hex: 0x383B41)

    // Text.
    static let text1 = Color(hex: 0xF2F0EB)
    static let text2 = Color(hex: 0xB7B5AE)
    static let text3 = Color(hex: 0x85857F)
    static let textOnAccent = Color(hex: 0x181204)

    // Accent: one amber family.
    static let accent = Color(hex: 0xE2A24C)
    static let accentStrong = Color(hex: 0xF59E0B)
    static let accentSoft = Color(hex: 0xE2A24C).opacity(0.12)

    // Viewing states.
    static let stateUnwatched = Color(hex: 0x6E8BA6)
    static let stateWatching = Color(hex: 0xE2A24C)
    static let stateWatched = Color(hex: 0x6C6E73)

    // Feedback.
    static let danger = Color(hex: 0xCF6E5A)
    static let success = Color(hex: 0x86A783)

    // Type.
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    static func ui(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }

    // Layout.
    static let radius: CGFloat = 12
    static let radiusSmall: CGFloat = 8
    static let pad: CGFloat = 20
    static let gap: CGFloat = 16
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

/// Small mono uppercase label ("FOLDER / LOCAL", "LIBRARY").
struct Eyebrow: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(CF.mono(10, weight: .medium))
            .tracking(0.8)
            .foregroundColor(CF.text3)
    }
}
