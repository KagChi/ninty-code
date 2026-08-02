import SwiftUI

/// opencode v2 dark theme tokens (packages/ui/src/theme/v2 mapping, OC-2 dark).
enum Theme {
    // Backgrounds (grey ramp)
    static let bgDeep = Color(red: 0x16 / 255, green: 0x16 / 255, blue: 0x16 / 255)      // grey-1100 — window chrome
    static let bgBase = Color(red: 0x24 / 255, green: 0x24 / 255, blue: 0x24 / 255)      // grey-1000 — panels/cards
    static let layer01 = Color(red: 0x3a / 255, green: 0x3a / 255, blue: 0x3a / 255)     // grey-800 — user bubble, hover fills
    static let layer02 = Color(red: 0x2e / 255, green: 0x2e / 255, blue: 0x2e / 255)     // grey-900 — code blocks, previews
    static let layer03 = Color(red: 0x4a / 255, green: 0x4a / 255, blue: 0x4a / 255)     // between grey-800/700 — secondary buttons

    // Text
    static let textBase = Color(red: 0xfa / 255, green: 0xfa / 255, blue: 0xfa / 255)    // grey-100
    static let textMuted = Color(red: 0xae / 255, green: 0xae / 255, blue: 0xae / 255)   // grey-500
    static let textFaint = Color(red: 0x80 / 255, green: 0x80 / 255, blue: 0x80 / 255)   // grey-600
    static let textAccent = Color(red: 0xa2 / 255, green: 0xbc / 255, blue: 0xff / 255)  // blue-400

    // Borders
    static let borderMuted = Color.white.opacity(0.08)
    static let borderBase = Color.white.opacity(0.10)
    static let borderStrong = Color.white.opacity(0.20)

    // Overlays
    static let overlayHover = Color.white.opacity(0.06)
    static let overlayPressed = Color.white.opacity(0.10)

    // Accent
    static let accent = Color(red: 0x3b / 255, green: 0x5c / 255, blue: 0xf6 / 255)      // blue-600
    static let accentSoft = Color(red: 0xa2 / 255, green: 0xbc / 255, blue: 0xff / 255)

    // States
    static let success = Color(red: 0x6b / 255, green: 0xd5 / 255, blue: 0x86 / 255)     // green-500
    static let warning = Color(red: 0xf2 / 255, green: 0xcf / 255, blue: 0x76 / 255)     // yellow-500
    static let danger = Color(red: 0xf1 / 255, green: 0x74 / 255, blue: 0x71 / 255)      // red-500
    static let dangerBg = Color(red: 0x46 / 255, green: 0x15 / 255, blue: 0x16 / 255)    // red-1200

    // Diff
    static let diffAdd = Color(red: 0x9b / 255, green: 0xcd / 255, blue: 0x97 / 255)
    static let diffDelete = danger
    static let diffAddBg = Color(red: 0x1a / 255, green: 0x29 / 255, blue: 0x19 / 255)
    static let diffDeleteBg = Color(red: 0x42 / 255, green: 0x12 / 255, blue: 0x0b / 255)

    // Agent colors
    static func agentColor(_ id: String) -> Color {
        switch id {
        case "build": return Color(red: 0x7f / 255, green: 0x9f / 255, blue: 0xfe / 255)   // blue-300
        case "plan": return Color(red: 0xf7 / 255, green: 0x99 / 255, blue: 0xc6 / 255)    // pink-400
        case "review": return Color(red: 0x9d / 255, green: 0xde / 255, blue: 0xa5 / 255)  // green-300
        case "explore": return Color(red: 0xf5 / 255, green: 0xdf / 255, blue: 0xa2 / 255) // yellow-300
        default: return Color(red: 0x9e / 255, green: 0x99 / 255, blue: 0xf7 / 255)        // purple-400
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
