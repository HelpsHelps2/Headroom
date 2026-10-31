import SwiftUI

/// Design tokens from docs/design/utility-round-2.html. One accent (amber); neutrals carry everything else.
struct Theme {
    let dark: Bool
    let ink, muted, dim, line, surface, surfaceStroke, track, used, accent, accentInk, accentSoft, segment, segmentOn, sheet: Color

    static let dark = Theme(
        dark: true,
        ink: Color(hex: 0xE8E9EB), muted: Color(hex: 0x8B9099), dim: Color(hex: 0x5F646C),
        line: .white.opacity(0.07), surface: .white.opacity(0.04), surfaceStroke: .white.opacity(0.06),
        track: Color(hex: 0x24272D), used: Color(hex: 0x474C55),
        accent: Color(hex: 0xE6A243), accentInk: Color(hex: 0x1B1306), accentSoft: Color(hex: 0xE6A243).opacity(0.1),
        segment: .white.opacity(0.05), segmentOn: Color(hex: 0x2B2F36), sheet: Color(hex: 0x181A1F))

    static let light = Theme(
        dark: false,
        ink: Color(hex: 0x18181B), muted: Color(hex: 0x71717A), dim: Color(hex: 0xA1A1AA),
        line: Color(hex: 0xE8E8EB), surface: .white, surfaceStroke: Color(hex: 0x18181B).opacity(0.06),
        track: Color(hex: 0xECECEE), used: Color(hex: 0xC9C9CF),
        accent: Color(hex: 0xC27A17), accentInk: .white, accentSoft: Color(hex: 0xC27A17).opacity(0.09),
        segment: Color(hex: 0xEBEBEC), segmentOn: .white, sheet: .white)

    @ViewBuilder var background: some View {
        if dark {
            RadialGradient(colors: [Color(hex: 0x1F2228), Color(hex: 0x15171B), Color(hex: 0x101215)],
                           center: UnitPoint(x: 0.5, y: 0.24), startRadius: 0, endRadius: 520)
        } else {
            Color(hex: 0xF7F7F6)
        }
    }
    var success: Color { Color(hex: dark ? 0x69D69A : 0x187844) }

    var coreFill: RadialGradient {
        dark ? RadialGradient(colors: [Color(hex: 0x2C3037), Color(hex: 0x1C1F24)], center: UnitPoint(x: 0.5, y: 0.3), startRadius: 0, endRadius: 110)
             : RadialGradient(colors: [.white, Color(hex: 0xF5F5F4)], center: UnitPoint(x: 0.5, y: 0.28), startRadius: 0, endRadius: 120)
    }
}

extension EnvironmentValues {
    @Entry var theme: Theme = .dark
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

extension Font {
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight, design: .monospaced) }
    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight) }
}

/// Applies the theme for the current appearance to everything below it.
struct Themed<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    @ViewBuilder var content: Content
    var body: some View {
        let theme: Theme = scheme == .dark ? .dark : .light
        content.environment(\.theme, theme).foregroundStyle(theme.ink)
    }
}
