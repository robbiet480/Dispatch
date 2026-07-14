import XCTest
@testable import DispatchKit

final class QuestionInputPreviewTests: XCTestCase {
    // Bounded number styles resolve to a mid value from the resolved config.
    func testSliderUsesMidpointOfResolvedRange() {
        let control = QuestionInputPreview.control(
            forType: .number, inputStyle: .slider, choices: [], allowsMultipleSelection: false,
            inputMin: 0, inputMax: 10, inputStep: 1, placeholder: nil, defaultAnswer: nil)
        XCTAssertEqual(control, .number(.slider(min: 0, max: 10, value: 5)))
    }

    func testScaleFillsMiddlePoint() {
        let control = QuestionInputPreview.control(
            forType: .number, inputStyle: .scale, choices: [], allowsMultipleSelection: false,
            inputMin: 1, inputMax: 5, inputStep: 1, placeholder: nil, defaultAnswer: nil)
        XCTAssertEqual(control, .number(.scale(points: [1, 2, 3, 4, 5], selected: 3)))
    }

    func testTextFieldPrefersPlaceholderThenDefault() {
        let control = QuestionInputPreview.control(
            forType: .number, inputStyle: .textField, choices: [], allowsMultipleSelection: false,
            inputMin: nil, inputMax: nil, inputStep: nil, placeholder: "kg", defaultAnswer: "0")
        XCTAssertEqual(control, .number(.textField(placeholder: "kg", value: "0")))
    }

    func testUnknownInputStyleFallsBackToTextField() {
        // An entry whose stored inputStyle raw is nil/unknown → textField.
        let entry = CatalogQuestion(
            recordName: "r", prompt: "How many?", typeRaw: QuestionType.number.rawValue,
            choices: [], approvedAt: Date(timeIntervalSince1970: 0), inputStyle: nil)
        XCTAssertEqual(QuestionInputPreview.control(for: entry), .number(.textField(placeholder: nil, value: nil)))
    }

    func testMultipleChoiceMarksFirstSelectedAndKeepsMultiSelectFlag() {
        let control = QuestionInputPreview.control(
            forType: .multipleChoice, inputStyle: .textField, choices: ["A", "B", "C"],
            allowsMultipleSelection: true, inputMin: nil, inputMax: nil, inputStep: nil,
            placeholder: nil, defaultAnswer: nil)
        XCTAssertEqual(control, .choices(options: ["A", "B", "C"], multiSelect: true, selected: 0))
    }

    // A "poison pill" catalog entry with an extreme numeric bound must not
    // trap the `Double`→`Int` cast in the tapCounter preview. A huge positive
    // min forces `sampleCount` past `Int.max`; `Int(hugeDouble)` would crash,
    // so the resolver clamps into range and yields an in-range Int instead.
    func testTapCounterWithExtremeBoundClampsInsteadOfTrapping() {
        let control = QuestionInputPreview.control(
            forType: .number, inputStyle: .tapCounter, choices: [], allowsMultipleSelection: false,
            inputMin: 1e20, inputMax: nil, inputStep: nil, placeholder: nil, defaultAnswer: nil)
        guard case .number(.tapCounter(let value)) = control else {
            return XCTFail("expected a tapCounter preview, got \(control)")
        }
        // In-range (didn't trap) and clamped to the ceiling for the poison bound.
        XCTAssertEqual(value, Int.max)
    }

    // The mirror poison bound (huge negative min) must likewise resolve without
    // trapping — here `sampleCount` clamps the friendly sample of 3 in-range.
    func testTapCounterWithExtremeNegativeBoundDoesNotTrap() {
        let control = QuestionInputPreview.control(
            forType: .number, inputStyle: .tapCounter, choices: [], allowsMultipleSelection: false,
            inputMin: -1e20, inputMax: nil, inputStep: nil, placeholder: nil, defaultAnswer: nil)
        guard case .number(.tapCounter(let value)) = control else {
            return XCTFail("expected a tapCounter preview, got \(control)")
        }
        XCTAssertEqual(value, 3)
    }

    func testYesNoNoteTokensPeopleLocationTime() {
        func c(_ t: QuestionType) -> QuestionPreviewControl {
            QuestionInputPreview.control(forType: t, inputStyle: .textField, choices: [],
                allowsMultipleSelection: false, inputMin: nil, inputMax: nil, inputStep: nil,
                placeholder: "Notes…", defaultAnswer: nil)
        }
        XCTAssertEqual(c(.yesNo), .yesNo(selected: nil))
        XCTAssertEqual(c(.note), .note(placeholder: "Notes…"))
        XCTAssertEqual(c(.location), .location)
        if case .tokens(let s) = c(.tokens) { XCTAssertFalse(s.isEmpty) } else { XCTFail("tokens") }
        if case .people(let s) = c(.people) { XCTAssertFalse(s.isEmpty) } else { XCTFail("people") }
        if case .time(let s) = c(.time) { XCTAssertFalse(s.isEmpty) } else { XCTFail("time") }
    }
}
