import Foundation
import Testing
@testable import DispatchKit

@Test func unknownRawValuesFallBackToDefaults() {
    let report = Report()
    report.kindRaw = "definitely-not-a-kind"
    report.triggerRaw = "definitely-not-a-trigger"
    report.connection = 99
    #expect(report.kind == .regular)
    #expect(report.trigger == .manual)
    #expect(report.connectionType == nil)

    let question = Question()
    question.typeRaw = 99
    question.reportKindsRaw = ["nope", "wake"]
    #expect(question.type == .tokens)
    #expect(question.reportKinds == [.wake])
}
