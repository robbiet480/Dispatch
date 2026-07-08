import Foundation
import Testing
@testable import DispatchKit

@Suite("StateOfMindValence")
struct StateOfMindValenceTests {
    @Test("three-choice linear mapping: endpoints and middle")
    func threeChoiceLinearMapping() {
        let choices = ["Bad", "Meh", "Great"]

        #expect(StateOfMindValence.value(answer: "Bad", choices: choices, type: .multipleChoice) == -1)
        #expect(StateOfMindValence.value(answer: "Meh", choices: choices, type: .multipleChoice) == 0)
        #expect(StateOfMindValence.value(answer: "Great", choices: choices, type: .multipleChoice) == 1)
    }

    @Test("single choice maps to neutral")
    func singleChoiceIsNeutral() {
        let value = StateOfMindValence.value(answer: "Only", choices: ["Only"], type: .multipleChoice)
        #expect(value == 0)
    }

    @Test("implicit yes/no maps to +0.5 / -0.5")
    func implicitYesNo() {
        #expect(StateOfMindValence.value(answer: "Yes", choices: [], type: .yesNo) == 0.5)
        #expect(StateOfMindValence.value(answer: "No", choices: [], type: .yesNo) == -0.5)
    }

    @Test("unanswered returns nil")
    func unansweredIsNil() {
        let value = StateOfMindValence.value(answer: nil, choices: ["A", "B"], type: .multipleChoice)
        #expect(value == nil)
    }
}
