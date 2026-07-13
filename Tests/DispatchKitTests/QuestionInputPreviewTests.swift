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
