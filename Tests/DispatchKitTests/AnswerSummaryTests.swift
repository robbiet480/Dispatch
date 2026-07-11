import Foundation
import SwiftData
import Testing
@testable import DispatchKit

// AnswerSummary (plan 49): flatten one Response to a display string, and find
// the most recent answered response for a question across reports — the
// backing for the "last answer to a question" query intent. Report-centric:
// answers are read out of the reports they live in.

private func response(
    questionID: String,
    tokens: [String]? = nil,
    options: [String]? = nil,
    numeric: String? = nil,
    note: String? = nil,
    locationText: String? = nil,
    time: TimeAnswer? = nil
) -> Response {
    let r = Response()
    r.questionIdentifier = questionID
    r.questionPrompt = "Q-\(questionID)"
    if let tokens { r.tokens = tokens.map { TokenValue(text: $0) } }
    if let options { r.answeredOptions = options }
    if let numeric { r.numericResponse = numeric }
    if let note { r.textResponses = [TokenValue(text: note)] }
    if let locationText {
        var a = LocationAnswer()
        a.text = locationText
        r.locationResponse = a
    }
    if let time { r.timeResponse = time }
    return r
}

@Test func answerTextFlattensEachType() {
    #expect(AnswerSummary.text(for: response(questionID: "a", tokens: ["Coffee", "Tea"])) == "Coffee, Tea")
    #expect(AnswerSummary.text(for: response(questionID: "a", options: ["Yes"])) == "Yes")
    #expect(AnswerSummary.text(for: response(questionID: "a", numeric: "2")) == "2")
    #expect(AnswerSummary.text(for: response(questionID: "a", note: "long day")) == "long day")
    #expect(AnswerSummary.text(for: response(questionID: "a", locationText: "Home")) == "Home")
    #expect(AnswerSummary.text(for: response(questionID: "a", time: TimeAnswer(minutesSinceMidnight: 9 * 60))) == "09:00")
    #expect(AnswerSummary.text(for: response(questionID: "a", time: TimeAnswer(minutesSinceMidnight: 22 * 60 + 30, dayOffset: -1))) == "22:30 (yesterday)")
}

@Test func answerTextNilWhenPayloadless() {
    #expect(AnswerSummary.text(for: response(questionID: "a")) == nil)
    // Empty collections are not an answer.
    #expect(AnswerSummary.text(for: response(questionID: "a", tokens: [])) == nil)
    #expect(AnswerSummary.text(for: response(questionID: "a", options: [])) == nil)
}

private func report(id: String, date: Date, isDraft: Bool = false, responses: [Response]) -> Report {
    let r = Report()
    r.uniqueIdentifier = id
    r.date = date
    r.isDraft = isDraft
    for resp in responses { resp.report = r }
    r.responses = responses
    return r
}

@Test func lastAnswerPicksMostRecentAnsweredResponse() {
    let older = report(id: "1", date: Date(timeIntervalSince1970: 1_000),
                       responses: [response(questionID: "coffee", numeric: "1")])
    let newer = report(id: "2", date: Date(timeIntervalSince1970: 2_000),
                       responses: [response(questionID: "coffee", numeric: "3")])
    let result = AnswerSummary.lastAnswer(toQuestionID: "coffee", in: [older, newer])
    #expect(result?.text == "3")
    #expect(result?.date == Date(timeIntervalSince1970: 2_000))
}

@Test func lastAnswerSkipsDraftsAndPayloadlessAndOtherQuestions() {
    let draft = report(id: "d", date: Date(timeIntervalSince1970: 9_000), isDraft: true,
                       responses: [response(questionID: "coffee", numeric: "99")])
    let payloadless = report(id: "p", date: Date(timeIntervalSince1970: 8_000),
                             responses: [response(questionID: "coffee")])
    let otherQuestion = report(id: "o", date: Date(timeIntervalSince1970: 7_000),
                               responses: [response(questionID: "water", numeric: "5")])
    let answered = report(id: "a", date: Date(timeIntervalSince1970: 1_000),
                          responses: [response(questionID: "coffee", tokens: ["Latte"])])
    let result = AnswerSummary.lastAnswer(toQuestionID: "coffee",
                                          in: [draft, payloadless, otherQuestion, answered])
    #expect(result?.text == "Latte")
    #expect(result?.date == Date(timeIntervalSince1970: 1_000))
}

@Test func lastAnswerNilWhenNoAnswer() {
    #expect(AnswerSummary.lastAnswer(toQuestionID: "coffee", in: []) == nil)
    let onlyOther = report(id: "o", date: Date(), responses: [response(questionID: "water", numeric: "5")])
    #expect(AnswerSummary.lastAnswer(toQuestionID: "coffee", in: [onlyOther]) == nil)
}
