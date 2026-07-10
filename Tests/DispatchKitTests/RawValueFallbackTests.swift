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

/// Plan-28 additive raw resolves; genuinely unknown raws still fall back to tokens.
@Test func plan28TimeQuestionRawResolves() {
    let question = Question()
    question.typeRaw = 7
    #expect(question.type == .time)
    question.typeRaw = 99
    #expect(question.type == .tokens)
}

/// Plan-26 additive raws resolve; genuinely unknown raws still fall back to nil.
@Test func plan26ConnectionRawsResolve() {
    let report = Report()
    report.connection = 8
    #expect(report.connectionType == .satellite)
    report.connection = 99
    #expect(report.connectionType == nil)
}
