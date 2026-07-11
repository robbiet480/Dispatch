import Foundation
import Testing
@testable import DispatchKit

/// Review fix: the option-blocks chart's index-0 tint (theme + 8% white) was
/// mathematically identical to the visualization card's `white.opacity(0.08)`
/// overlay, so the top block vanished into the card — worst on the
/// tomato/pink screenshots. These tests pin the kit-side shading contract.

private var themeBackgrounds: [(name: String, background: RGBValue)] {
    Theme.allCases.map { (name: $0.rawValue, background: RGBValue(hex: $0.backgroundHex)!) }
}

@Test func hexParsingRoundTripsThemeBackgrounds() {
    let tomato = RGBValue(hex: "#FA5B3D")
    #expect(tomato == RGBValue(red: 250 / 255, green: 91 / 255, blue: 61 / 255))
    #expect(RGBValue(hex: "FA5B3D") == tomato)
    #expect(RGBValue(hex: "#FA5B3") == nil)
    #expect(RGBValue(hex: "#GGGGGG") == nil)
    for theme in Theme.allCases {
        #expect(RGBValue(hex: theme.backgroundHex) != nil)
    }
}

@Test func indexZeroFillClearsTheCardBackgroundOnEveryTheme() {
    for (name, background) in themeBackgrounds {
        let card = BlockShading.cardBackground(over: background)
        let fill = BlockShading.fill(forIndex: 0, background: background)
        // The old fixed 8% lighten was EQUAL to the card (ratio 1.0). Every
        // theme must now clear a real step. Chartreuse is the documented
        // exception to the full 1.10 step: the lighten fraction caps at 0.25
        // to keep white labels legible on the brightest theme, landing ~1.08.
        let ratio = BlockShading.contrastRatio(fill, card)
        if name == Theme.chartreuse.rawValue {
            #expect(ratio >= 1.07, "chartreuse ratio \(ratio)")
        } else {
            #expect(ratio >= BlockShading.minimumContrastStep, "\(name) ratio \(ratio)")
        }
        #expect(fill != card, "\(name) index-0 fill must not equal the card")
    }
}

@Test func laterBlocksKeepPlan29DarkeningAndTheContrastStep() {
    for (name, background) in themeBackgrounds {
        let card = BlockShading.cardBackground(over: background)
        for index in 1...4 {
            let fill = BlockShading.fill(forIndex: index, background: background)
            // The 10%-per-index darkening already clears the step on all five
            // themes — the fix must NOT change the darker blocks' look.
            #expect(fill == background.blendedWithBlack(Double(index) * 0.10),
                    "\(name) index \(index) should keep the legacy darken fraction")
            #expect(BlockShading.contrastRatio(fill, card) >= BlockShading.minimumContrastStep,
                    "\(name) index \(index)")
        }
    }
}

@Test func fillsStayInTheThemeHueFamilyAndOrderedByLuminance() {
    for (name, background) in themeBackgrounds {
        // Same hue family: white/black blends preserve the channel ordering
        // of the base color (conservative, Reporter-parity requirement).
        let channels = [background.red, background.green, background.blue]
        let baseOrder = channels.enumerated().sorted { $0.element < $1.element }.map(\.offset)
        var previousLuminance = Double.greatestFiniteMagnitude
        for index in 0...4 {
            let fill = BlockShading.fill(forIndex: index, background: background)
            let fillChannels = [fill.red, fill.green, fill.blue]
            let fillOrder = fillChannels.enumerated().sorted { $0.element < $1.element }.map(\.offset)
            #expect(fillOrder == baseOrder, "\(name) index \(index) left the hue family")
            // Index 0 is the lightest; each later block strictly darker.
            let luminance = BlockShading.relativeLuminance(fill)
            #expect(luminance < previousLuminance, "\(name) index \(index) not darker than previous")
            previousLuminance = luminance
        }
    }
}
