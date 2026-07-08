import Testing
@testable import DispatchKit

@Test func displayFormulaMatchesOriginal() {
    // Screenshot ground truth: raw −52.8 dBFS displays as 24.40 DB.
    #expect(abs(AudioLevel.displayValue(fromRaw: -52.8) - 24.4) < 0.001)
    #expect(AudioLevel.displayValue(fromRaw: -65) == 0)
}

@Test func labelScale() {
    #expect(AudioLevel.label(forDisplay: 24.4) == "EXTREMELY QUIET")
    #expect(AudioLevel.label(forDisplay: 30) == "QUIET")
    #expect(AudioLevel.label(forDisplay: 55) == "MODERATE")
    #expect(AudioLevel.label(forDisplay: 71) == "LOUD")
    #expect(AudioLevel.label(forDisplay: 95) == "EXTREMELY LOUD")
}
