import SwiftUI

/// Catppuccin Macchiato theme on the opencode v2 token structure.
enum Theme {
    // Backgrounds
    static let bgDeep = Color(red: 0x1e / 255, green: 0x20 / 255, blue: 0x30 / 255)      // mantle — window chrome
    static let bgBase = Color(red: 0x24 / 255, green: 0x27 / 255, blue: 0x3a / 255)      // base — panels/cards
    static let layer01 = Color(red: 0x36 / 255, green: 0x3a / 255, blue: 0x4f / 255)     // surface0 — user bubble, hover fills
    static let layer02 = Color(red: 0x18 / 255, green: 0x19 / 255, blue: 0x26 / 255)     // crust — code blocks, insets
    static let layer03 = Color(red: 0x49 / 255, green: 0x4d / 255, blue: 0x64 / 255)     // surface1 — secondary buttons

    // Text
    static let textBase = Color(red: 0xca / 255, green: 0xd3 / 255, blue: 0xf5 / 255)    // text
    static let textMuted = Color(red: 0xa5 / 255, green: 0xad / 255, blue: 0xcb / 255)   // subtext0
    static let textFaint = Color(red: 0x80 / 255, green: 0x87 / 255, blue: 0xa2 / 255)   // overlay1
    static let textAccent = Color(red: 0x8a / 255, green: 0xad / 255, blue: 0xf4 / 255)  // blue

    // Borders
    static let borderMuted = Color.white.opacity(0.08)
    static let borderBase = Color.white.opacity(0.10)
    static let borderStrong = Color.white.opacity(0.20)

    // Overlays
    static let overlayHover = Color.white.opacity(0.06)
    static let overlayPressed = Color.white.opacity(0.10)

    // Accent
    static let accent = Color(red: 0x8a / 255, green: 0xad / 255, blue: 0xf4 / 255)      // blue
    static let accentSoft = Color(red: 0x7d / 255, green: 0xc4 / 255, blue: 0xe4 / 255)  // sapphire

    // States
    static let success = Color(red: 0xa6 / 255, green: 0xda / 255, blue: 0x95 / 255)     // green
    static let warning = Color(red: 0xee / 255, green: 0xd4 / 255, blue: 0x9f / 255)     // yellow
    static let danger = Color(red: 0xed / 255, green: 0x87 / 255, blue: 0x96 / 255)      // red
    static let dangerBg = Color(red: 0x4c / 255, green: 0x3a / 255, blue: 0x4c / 255)    // red 20% over base

    // Diff
    static let diffAdd = Color(red: 0xa6 / 255, green: 0xda / 255, blue: 0x95 / 255)     // green
    static let diffDelete = danger
    static let diffAddBg = Color(red: 0x38 / 255, green: 0x42 / 255, blue: 0x47 / 255)   // green 15% over base
    static let diffDeleteBg = Color(red: 0x43 / 255, green: 0x33 / 255, blue: 0x45 / 255) // red 15% over base

    // Agent colors
    static func agentColor(_ id: String) -> Color {
        switch id {
        case "build": return Color(red: 0x8a / 255, green: 0xad / 255, blue: 0xf4 / 255)   // blue
        case "plan": return Color(red: 0xf5 / 255, green: 0xbd / 255, blue: 0xe6 / 255)    // pink
        case "review": return Color(red: 0xa6 / 255, green: 0xda / 255, blue: 0x95 / 255)  // green
        case "explore": return Color(red: 0xee / 255, green: 0xd4 / 255, blue: 0x9f / 255) // yellow
        default: return Color(red: 0xc6 / 255, green: 0xa0 / 255, blue: 0xf6 / 255)        // mauve
        }
    }

    // Typography
    static let sans = Font.system(size: 14)
    static let sansMedium = Font.system(size: 14, weight: .medium)
    static let small = Font.system(size: 13)
    static let smallMedium = Font.system(size: 13, weight: .medium)
    static let caption = Font.system(size: 12)
    static let captionMedium = Font.system(size: 12, weight: .medium)
    static let tiny = Font.system(size: 11, weight: .medium)
    static let mono = Font.system(size: 13, design: .monospaced)
    static let title = Font.system(size: 20, weight: .medium)

    // Radii
    static let radiusSmall: CGFloat = 6
    static let radiusMedium: CGFloat = 8
    static let radiusLarge: CGFloat = 10
    static let radiusXL: CGFloat = 12

    // Elevation (raised): subtle shadow + hairline ring
    static let raisedShadow = Color.black.opacity(0.3)
}

extension View {
    /// opencode v2 raised elevation: drop shadow + 0.5px light ring.
    func raisedElevation(cornerRadius: CGFloat) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(Theme.borderBase, lineWidth: 0.5)
            )
            .shadow(color: Theme.raisedShadow, radius: 2, x: 0, y: 1)
            .shadow(color: Theme.raisedShadow, radius: 4, x: 0, y: 2)
    }
}

/// Text shimmer for running tool titles / "Thinking..." (gradient sweep mask).
struct ShimmerText: View {
    let text: String
    var font: Font = Theme.sansMedium
    var color: Color = Theme.textMuted
    @State private var phase: CGFloat = -1

    var body: some View {
        Text(text)
            .font(font)
            .foregroundStyle(color)
            .overlay(
                LinearGradient(
                    colors: [.clear, .white.opacity(0.7), .clear],
                    startPoint: .leading, endPoint: .trailing
                )
                .offset(x: phase * 200)
                .mask(Text(text).font(font))
            )
            .onAppear {
                withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
    }
}
