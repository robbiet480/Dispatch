import Foundation

/// A plain sRGB triple (components 0...1) — DispatchKit has no SwiftUI, so
/// the block-chart color math lives here as pure numbers and the app layer
/// converts to `Color` at the edge.
public struct RGBValue: Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// Parses `#RRGGBB` (leading `#` optional). Nil on malformed input.
    public init?(hex: String) {
        var sanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if sanitized.hasPrefix("#") { sanitized.removeFirst() }
        guard sanitized.count == 6, let value = UInt32(sanitized, radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }

    /// Blends toward white by `fraction` (0...1), same math as compositing
    /// `Color.white.opacity(fraction)` over this color.
    public func blendedWithWhite(_ fraction: Double) -> RGBValue {
        let amount = min(max(fraction, 0), 1)
        return RGBValue(red: red + (1 - red) * amount,
                        green: green + (1 - green) * amount,
                        blue: blue + (1 - blue) * amount)
    }

    /// Blends toward black by `fraction` (0...1).
    public func blendedWithBlack(_ fraction: Double) -> RGBValue {
        let amount = min(max(fraction, 0), 1)
        return RGBValue(red: red * (1 - amount),
                        green: green * (1 - amount),
                        blue: blue * (1 - amount))
    }
}

/// Per-index fills for the option-blocks chart (the marquee stacked bars),
/// derived from the theme background with a GUARANTEED contrast step.
///
/// Why (visual review fix): the old app-side tint lightened index 0 by a
/// fixed 8% — exactly the dashboard card's `white.opacity(0.08)` overlay, so
/// the first block was mathematically identical to the card behind it and
/// the chart read nearly invisible on the tomato/pink screenshots. Fills now
/// keep the plan-29 shading direction (index 0 lighter, later blocks darker
/// per index) but each blend fraction grows until the fill clears a minimum
/// WCAG-style contrast ratio against the card background. Hue families are
/// unchanged — only the step size adapts, and the lighten fraction is capped
/// so white labels stay legible on already-light themes (chartreuse).
public enum BlockShading {
    /// The visualization card overlay: `Color.white.opacity(0.08)` over the
    /// theme background (HomeView grid / MacDashboardView grid).
    public static let cardOverlayWhiteFraction = 0.08
    /// Minimum contrast ratio every fill must keep against the card.
    static let minimumContrastStep = 1.10
    /// Plan-29 baselines: index 0 lightens 8%, each later index darkens 10%.
    static let baseLightenFraction = 0.08
    static let darkenFractionPerIndex = 0.10
    /// Lighten no further than this even if the step isn't reached — white
    /// block labels must stay legible on bright themes.
    static let maximumLightenFraction = 0.25

    /// The card background a fill must read against.
    public static func cardBackground(over background: RGBValue) -> RGBValue {
        background.blendedWithWhite(cardOverlayWhiteFraction)
    }

    /// Fill for block `index` (0-based, top block first) over `background`.
    public static func fill(forIndex index: Int, background: RGBValue) -> RGBValue {
        let card = cardBackground(over: background)
        if index == 0 {
            var fraction = baseLightenFraction
            var fill = background.blendedWithWhite(fraction)
            while contrastRatio(fill, card) < minimumContrastStep,
                  fraction < maximumLightenFraction {
                fraction = min(fraction + 0.01, maximumLightenFraction)
                fill = background.blendedWithWhite(fraction)
            }
            return fill
        }
        var fraction = Double(index) * darkenFractionPerIndex
        var fill = background.blendedWithBlack(min(fraction, 0.9))
        while contrastRatio(fill, card) < minimumContrastStep, fraction < 0.9 {
            fraction = min(fraction + 0.01, 0.9)
            fill = background.blendedWithBlack(fraction)
        }
        return fill
    }

    /// WCAG contrast ratio (relative luminance with sRGB linearization).
    public static func contrastRatio(_ first: RGBValue, _ second: RGBValue) -> Double {
        let lighter = max(relativeLuminance(first), relativeLuminance(second))
        let darker = min(relativeLuminance(first), relativeLuminance(second))
        return (lighter + 0.05) / (darker + 0.05)
    }

    static func relativeLuminance(_ color: RGBValue) -> Double {
        func linear(_ component: Double) -> Double {
            component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.red) + 0.7152 * linear(color.green)
            + 0.0722 * linear(color.blue)
    }
}
