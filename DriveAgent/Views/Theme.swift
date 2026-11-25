import SwiftUI

/// Calm graphite palette, as in the Android app: one accent, and status colors used only for status.
enum Theme {
    static let background = Color(hex: 0x0F1215)
    static let surface = Color(hex: 0x171B20)
    static let surfaceHigh = Color(hex: 0x1F252B)
    static let line = Color(hex: 0x2C333B)
    static let accent = Color(hex: 0x8AA9C7)
    static let onAccent = Color(hex: 0x10151A)
    static let positive = Color(hex: 0x6FAE8B)
    static let negative = Color(hex: 0xD4726F)
    static let caution = Color(hex: 0xC9A45C)
    static let text = Color(hex: 0xE8EAED)
    static let muted = Color(hex: 0x98A1AB)

    static let corner: CGFloat = 8

    static func color(_ state: LightState) -> Color {
        switch state {
        case .ok: positive
        case .error: negative
        case .offline: caution
        case .unknown: muted
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

/// A rounded, outlined card in the app's colors.
struct Card<Content: View>: View {
    var border: Color = Theme.line
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.corner))
            .overlay(RoundedRectangle(cornerRadius: Theme.corner).stroke(border, lineWidth: 1))
    }
}

struct Light: View {
    let color: Color
    var size: CGFloat = 8

    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
    }
}
