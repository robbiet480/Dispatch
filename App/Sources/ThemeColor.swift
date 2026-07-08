import DispatchKit
import SwiftUI

enum ThemeColor {
    /// Parses a `#RRGGBB` hex string into a SwiftUI `Color`. Falls back to black on malformed input.
    static func color(fromHex hex: String) -> Color {
        var sanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if sanitized.hasPrefix("#") { sanitized.removeFirst() }
        guard sanitized.count == 6, let value = UInt32(sanitized, radix: 16) else {
            return .black
        }
        let red = Double((value >> 16) & 0xFF) / 255
        let green = Double((value >> 8) & 0xFF) / 255
        let blue = Double(value & 0xFF) / 255
        return Color(red: red, green: green, blue: blue)
    }

    static func color(_ theme: Theme) -> Color {
        color(fromHex: theme.backgroundHex)
    }
}

extension Color {
    static func themeBackground(_ theme: Theme) -> Color {
        ThemeColor.color(theme)
    }
}
