import Foundation
import SwiftData
import Testing
@testable import DispatchKit

// MARK: - Raw-value round-trip on Question

@Test func inputStyleDefaultsToTextFieldWhenRawIsNil() throws {
    let question = Question()
    #expect(question.inputStyleRaw == nil)
    #expect(question.inputStyle == .textField)
}

@Test func inputStyleFallsBackToTextFieldForUnknownRaw() throws {
    let question = Question()
    question.inputStyleRaw = "holographicKnob" // some future style
    #expect(question.inputStyle == .textField)
}

@Test func inputStyleSetterWritesRawAndTextFieldWritesNil() throws {
    let question = Question()
    question.inputStyle = .slider
    #expect(question.inputStyleRaw == "slider")
    question.inputStyle = .tapCounter
    #expect(question.inputStyleRaw == "tapCounter")
    question.inputStyle = .textField
    #expect(question.inputStyleRaw == nil)
}

@Test func inputStyleRawValuesMatchWireFormat() throws {
    #expect(NumberInputStyle.textField.rawValue == "textField")
    #expect(NumberInputStyle.slider.rawValue == "slider")
    #expect(NumberInputStyle.stepper.rawValue == "stepper")
    #expect(NumberInputStyle.dial.rawValue == "dial")
    #expect(NumberInputStyle.tapCounter.rawValue == "tapCounter")
    #expect(NumberInputStyle.scale.rawValue == "scale")
}

// MARK: - resolvedConfig defaults (spec §Styles table)

@Test func resolvedConfigDefaultsPerStyle() throws {
    let slider = NumberInputStyle.resolvedConfig(for: .slider, min: nil, max: nil, step: nil)
    #expect(slider == (0, 10, 1))

    let dial = NumberInputStyle.resolvedConfig(for: .dial, min: nil, max: nil, step: nil)
    #expect(dial == (0, 10, 1))

    let scale = NumberInputStyle.resolvedConfig(for: .scale, min: nil, max: nil, step: nil)
    #expect(scale == (1, 5, 1))

    let stepper = NumberInputStyle.resolvedConfig(for: .stepper, min: nil, max: nil, step: nil)
    #expect(stepper.min == 0)
    #expect(stepper.step == 1)
    #expect(stepper.max == .greatestFiniteMagnitude) // "no max"

    let counter = NumberInputStyle.resolvedConfig(for: .tapCounter, min: nil, max: nil, step: nil)
    #expect(counter.min == 0)
    #expect(counter.step == 1)
    #expect(counter.max == .greatestFiniteMagnitude) // "no max"
}

@Test func resolvedConfigKeepsValidOverrides() throws {
    let full = NumberInputStyle.resolvedConfig(for: .slider, min: 5, max: 50, step: 5)
    #expect(full == (5, 50, 5))

    // Partial overrides merge with style defaults.
    let partial = NumberInputStyle.resolvedConfig(for: .slider, min: 2, max: nil, step: nil)
    #expect(partial == (2, 10, 1))

    let scale = NumberInputStyle.resolvedConfig(for: .scale, min: nil, max: 7, step: nil)
    #expect(scale == (1, 7, 1))
}

// MARK: - resolvedConfig invalid combos clamp to style defaults

@Test func resolvedConfigClampsMinNotBelowMaxToDefaults() throws {
    // min == max
    #expect(NumberInputStyle.resolvedConfig(for: .slider, min: 4, max: 4, step: 1) == (0, 10, 1))
    // min > max
    #expect(NumberInputStyle.resolvedConfig(for: .slider, min: 20, max: 10, step: 1) == (0, 10, 1))
    // min above the DEFAULT max is just as invalid when max is nil
    #expect(NumberInputStyle.resolvedConfig(for: .slider, min: 20, max: nil, step: nil) == (0, 10, 1))
}

@Test func resolvedConfigClampsNonPositiveStepToDefaults() throws {
    #expect(NumberInputStyle.resolvedConfig(for: .dial, min: 0, max: 10, step: 0) == (0, 10, 1))
    #expect(NumberInputStyle.resolvedConfig(for: .dial, min: 0, max: 10, step: -2) == (0, 10, 1))
}

@Test func resolvedConfigClampsNonFiniteValuesToDefaults() throws {
    #expect(NumberInputStyle.resolvedConfig(for: .scale, min: .nan, max: nil, step: nil) == (1, 5, 1))
    #expect(NumberInputStyle.resolvedConfig(for: .slider, min: nil, max: .infinity, step: nil) == (0, 10, 1))
    #expect(NumberInputStyle.resolvedConfig(for: .slider, min: nil, max: nil, step: .nan) == (0, 10, 1))
}

// MARK: - Scale point / selection trap safety

/// Huge-but-finite bounds (e.g. `inputMax: 1e300` from a v2 import, which
/// passes resolvedConfig's finite check) must render a capped dot row, not
/// trap the Int conversion.
@Test func scalePointsSurviveHugeFiniteBounds() throws {
    let config = NumberInputStyle.resolvedConfig(for: .scale, min: -1e300, max: 1e300, step: 1)
    let points = NumberInputStyle.scalePoints(min: config.min, max: config.max)
    #expect(points.count == 20)
    #expect(points.first == -1_000_000)

    // Sane configs are untouched.
    #expect(NumberInputStyle.scalePoints(min: 1, max: 5) == [1, 2, 3, 4, 5])
    // Cap still applies.
    #expect(NumberInputStyle.scalePoints(min: 0, max: 1000).count == 20)
    // Inverted/degenerate input degrades to a single point rather than trapping.
    #expect(NumberInputStyle.scalePoints(min: 5, max: 2) == [5])
}

/// A previously-typed "nan" or overflowing answer string (question style
/// later switched to scale) yields no selection — never a trap.
@Test func scaleSelectionRejectsNonFiniteAndOverflowingValues() throws {
    #expect(NumberInputStyle.scaleSelection(for: Double("nan")) == nil)
    #expect(NumberInputStyle.scaleSelection(for: Double("inf")) == nil)
    #expect(NumberInputStyle.scaleSelection(for: Double("1e20")) == nil)
    #expect(NumberInputStyle.scaleSelection(for: nil) == nil)
    #expect(NumberInputStyle.scaleSelection(for: 3) == 3)
    #expect(NumberInputStyle.scaleSelection(for: 3.4) == 3)
}

// MARK: - v2 wire format

/// Input-style fields round-trip export → import → export byte-identically
/// when set, and import tolerates their absence (older v2 files).
@Test func inputStyleFieldsRoundTripThroughV2() throws {
    let containerA = try DispatchStore.inMemoryContainer()
    let contextA = ModelContext(containerA)
    let question = Question()
    question.uniqueIdentifier = "q-styled"
    question.prompt = "How loud?"
    question.type = .number
    question.inputStyle = .slider
    question.inputMin = 0
    question.inputMax = 100
    question.inputStep = 5
    contextA.insert(question)
    try contextA.save()

    let exportA = try V2Exporter.exportData(from: contextA, stamp: fixedStamp)

    let containerB = try DispatchStore.inMemoryContainer()
    let contextB = ModelContext(containerB)
    _ = try V2Importer.importExport(exportA, into: contextB)
    let imported = try #require(try contextB.fetch(FetchDescriptor<Question>()).first)
    #expect(imported.inputStyle == .slider)
    #expect(imported.inputStyleRaw == "slider")
    #expect(imported.inputMin == 0)
    #expect(imported.inputMax == 100)
    #expect(imported.inputStep == 5)

    let exportB = try V2Exporter.exportData(from: contextB, stamp: fixedStamp)
    #expect(exportA == exportB)
}

/// An unknown inputStyle string in a v2 file imports untouched (raw is
/// preserved for round-tripping) but resolves to .textField.
@Test func v2ImportPreservesUnknownInputStyleRawButResolvesTextField() throws {
    let json = Data("""
    {"schemaVersion": 2, "reports": [], "questions": [{
        "uniqueIdentifier": "q-future", "prompt": "Future?", "questionType": 2,
        "sortOrder": 0, "isEnabled": true, "reportKinds": ["regular"],
        "inputStyle": "holographicKnob"
    }]}
    """.utf8)
    let container = try DispatchStore.inMemoryContainer()
    let context = ModelContext(container)
    _ = try V2Importer.importExport(json, into: context)
    let imported = try #require(try context.fetch(FetchDescriptor<Question>()).first)
    #expect(imported.inputStyleRaw == "holographicKnob")
    #expect(imported.inputStyle == .textField)
}
