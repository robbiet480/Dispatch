import Foundation
import Testing
@testable import DispatchKit

private func freshSuite() -> UserDefaults {
    UserDefaults(suiteName: "viz-test-\(UUID().uuidString)")!
}

private func makeQuestion(id: String = UUID().uuidString, prompt: String, type: QuestionType, choices: [String] = []) -> Question {
    let question = Question()
    question.uniqueIdentifier = id
    question.prompt = prompt
    question.type = type
    question.choices = choices
    return question
}

private func makeReport(date: Date = Date(), responses: [Response]) -> Report {
    let report = Report()
    report.date = date
    report.responses = responses
    for response in responses {
        response.report = report
    }
    return report
}

private func location(_ text: String) -> LocationAnswer {
    var answer = LocationAnswer()
    answer.text = text
    return answer
}

private func makeResponse(questionIdentifier: String? = nil, questionPrompt: String = "",
                           answeredOptions: [String]? = nil, tokens: [TokenValue]? = nil,
                           numericResponse: String? = nil, textResponses: [TokenValue]? = nil,
                           locationResponse: LocationAnswer? = nil) -> Response {
    let response = Response()
    response.questionIdentifier = questionIdentifier
    response.questionPrompt = questionPrompt
    response.answeredOptions = answeredOptions
    response.tokens = tokens
    response.numericResponse = numericResponse
    response.textResponses = textResponses
    response.locationResponse = locationResponse
    return response
}

// MARK: - optionShares

@Test func optionSharesComputesMathWithSkippedExcluded() {
    let question = makeQuestion(id: "q-yesno", prompt: "Working?", type: .yesNo, choices: ["Yes", "No"])
    let reports = [
        makeReport(responses: [makeResponse(questionIdentifier: "q-yesno", answeredOptions: ["Yes"])]),
        makeReport(responses: [makeResponse(questionIdentifier: "q-yesno", answeredOptions: ["Yes"])]),
        makeReport(responses: [makeResponse(questionIdentifier: "q-yesno", answeredOptions: ["No"])]),
        // Skipped response — no answeredOptions payload — must be excluded from the denominator.
        makeReport(responses: [makeResponse(questionIdentifier: "q-yesno", answeredOptions: nil)]),
    ]

    let result = VisualizationData.build(for: question, reports: reports)

    guard case .optionShares(let shares) = result else {
        Issue.record("expected .optionShares, got \(result)")
        return
    }
    #expect(shares.count == 2)
    #expect(shares[0].option == "Yes")
    #expect(shares[1].option == "No")
    #expect(abs(shares[0].share - (2.0 / 3.0)) < 0.0001)
    #expect(abs(shares[1].share - (1.0 / 3.0)) < 0.0001)
}

@Test func optionSharesOrdersUnlistedOptionsByFrequencyAfterKnownChoices() {
    let question = makeQuestion(id: "q-mc", prompt: "Mood?", type: .multipleChoice, choices: ["Happy", "Sad"])
    let reports = [
        makeReport(responses: [makeResponse(questionIdentifier: "q-mc", answeredOptions: ["Happy"])]),
        makeReport(responses: [makeResponse(questionIdentifier: "q-mc", answeredOptions: ["Angry"])]),
        makeReport(responses: [makeResponse(questionIdentifier: "q-mc", answeredOptions: ["Angry"])]),
        makeReport(responses: [makeResponse(questionIdentifier: "q-mc", answeredOptions: ["Confused"])]),
    ]

    let result = VisualizationData.build(for: question, reports: reports)

    guard case .optionShares(let shares) = result else {
        Issue.record("expected .optionShares, got \(result)")
        return
    }
    // Known choices first (Happy, Sad — Sad has zero answers but is still listed order-wise... but plan
    // says "options ordered by the question's choices order, then any unlisted answered options by
    // frequency" — Sad has no answers, so it is not an "answered option"; only answered options appear.
    let optionNames = shares.map(\.option)
    #expect(optionNames == ["Happy", "Angry", "Confused"])
    #expect(shares.first(where: { $0.option == "Angry" })?.share == 0.5)
}

@Test func optionSharesPromptFallbackWhenIdentifierNil() {
    let question = makeQuestion(id: "q-yesno-2", prompt: "Working?", type: .yesNo, choices: ["Yes", "No"])
    let reports = [
        makeReport(responses: [makeResponse(questionIdentifier: nil, questionPrompt: "Working?", answeredOptions: ["Yes"])]),
        makeReport(responses: [makeResponse(questionIdentifier: "different-id", questionPrompt: "Working?", answeredOptions: ["No"])]),
    ]

    let result = VisualizationData.build(for: question, reports: reports)

    guard case .optionShares(let shares) = result else {
        Issue.record("expected .optionShares, got \(result)")
        return
    }
    // Only the nil-identifier response should join via prompt fallback; the response with a
    // *different* non-nil identifier must NOT match even though prompts are equal.
    #expect(shares.count == 1)
    #expect(shares[0].option == "Yes")
    #expect(shares[0].share == 1.0)
}

@Test func optionSharesYesNoImplicitOrderingWhenChoicesEmpty() {
    let question = makeQuestion(id: "q-implicit-yesno", prompt: "Working?", type: .yesNo, choices: [])
    let reports = [
        makeReport(responses: [makeResponse(questionIdentifier: "q-implicit-yesno", answeredOptions: ["Yes"])]),
        makeReport(responses: [makeResponse(questionIdentifier: "q-implicit-yesno", answeredOptions: ["No"])]),
        makeReport(responses: [makeResponse(questionIdentifier: "q-implicit-yesno", answeredOptions: ["No"])]),
    ]

    let result = VisualizationData.build(for: question, reports: reports)

    guard case .optionShares(let shares) = result else {
        Issue.record("expected .optionShares, got \(result)")
        return
    }
    // Even though No has the majority (2/3), the implicit yes/no ordering ["Yes", "No"] must be preserved.
    #expect(shares.count == 2)
    #expect(shares[0].option == "Yes")
    #expect(shares[1].option == "No")
    #expect(abs(shares[0].share - (1.0 / 3.0)) < 0.0001)
    #expect(abs(shares[1].share - (2.0 / 3.0)) < 0.0001)
}

// MARK: - numericSeries

@Test func numericSeriesSortsByDateAndComputesAverage() {
    let question = makeQuestion(id: "q-num", prompt: "Coffees?", type: .number)
    let day1 = Date(timeIntervalSince1970: 1_000_000)
    let day2 = Date(timeIntervalSince1970: 2_000_000)
    let day3 = Date(timeIntervalSince1970: 3_000_000)
    let reports = [
        makeReport(date: day3, responses: [makeResponse(questionIdentifier: "q-num", numericResponse: "5")]),
        makeReport(date: day1, responses: [makeResponse(questionIdentifier: "q-num", numericResponse: "1")]),
        makeReport(date: day2, responses: [makeResponse(questionIdentifier: "q-num", numericResponse: "3")]),
    ]

    let result = VisualizationData.build(for: question, reports: reports)

    guard case .numericSeries(let points, let average) = result else {
        Issue.record("expected .numericSeries, got \(result)")
        return
    }
    #expect(points.map(\.date) == [day1, day2, day3])
    #expect(points.map(\.value) == [1, 3, 5])
    #expect(abs(average - 3.0) < 0.0001)
}

@Test func numericSeriesExcludesUnanswered() {
    let question = makeQuestion(id: "q-num2", prompt: "Coffees?", type: .number)
    let reports = [
        makeReport(responses: [makeResponse(questionIdentifier: "q-num2", numericResponse: "4")]),
        makeReport(responses: [makeResponse(questionIdentifier: "q-num2", numericResponse: nil)]),
    ]

    let result = VisualizationData.build(for: question, reports: reports)

    guard case .numericSeries(let points, let average) = result else {
        Issue.record("expected .numericSeries, got \(result)")
        return
    }
    #expect(points.count == 1)
    #expect(average == 4.0)
}

// MARK: - frequency (tokens + people)

@Test func frequencyOrdersByCountDescendingThenAlphabetical() {
    let question = makeQuestion(id: "q-tok", prompt: "Doing?", type: .tokens)
    let reports = [
        makeReport(responses: [makeResponse(questionIdentifier: "q-tok", tokens: [TokenValue(text: "Reading")])]),
        makeReport(responses: [makeResponse(questionIdentifier: "q-tok", tokens: [TokenValue(text: "Coding")])]),
        makeReport(responses: [makeResponse(questionIdentifier: "q-tok", tokens: [TokenValue(text: "Coding")])]),
        makeReport(responses: [makeResponse(questionIdentifier: "q-tok", tokens: [TokenValue(text: "Baking")])]),
        makeReport(responses: [makeResponse(questionIdentifier: "q-tok", tokens: [TokenValue(text: "Baking")])]),
    ]

    let result = VisualizationData.build(for: question, reports: reports)

    guard case .frequency(let items) = result else {
        Issue.record("expected .frequency, got \(result)")
        return
    }
    // Coding and Baking tie at count 2 — alphabetical tiebreak puts Baking before Coding.
    #expect(items.map(\.text) == ["Baking", "Coding", "Reading"])
    #expect(items.map(\.count) == [2, 2, 1])
}

@Test func frequencyCapsAtTop20() {
    let question = makeQuestion(id: "q-tok2", prompt: "Doing?", type: .tokens)
    let reports = (0..<25).map { index in
        makeReport(responses: [makeResponse(questionIdentifier: "q-tok2", tokens: [TokenValue(text: "word\(index)")])])
    }

    let result = VisualizationData.build(for: question, reports: reports)

    guard case .frequency(let items) = result else {
        Issue.record("expected .frequency, got \(result)")
        return
    }
    #expect(items.count == 20)
}

// MARK: - places

@Test func placesGroupsByLocationTextDescendingCount() {
    let question = makeQuestion(id: "q-loc", prompt: "Where?", type: .location)
    let reports = [
        makeReport(responses: [makeResponse(questionIdentifier: "q-loc", locationResponse: location("Home"))]),
        makeReport(responses: [makeResponse(questionIdentifier: "q-loc", locationResponse: location("Home"))]),
        makeReport(responses: [makeResponse(questionIdentifier: "q-loc", locationResponse: location("Work"))]),
    ]

    let result = VisualizationData.build(for: question, reports: reports)

    guard case .places(let items) = result else {
        Issue.record("expected .places, got \(result)")
        return
    }
    #expect(items.map(\.name) == ["Home", "Work"])
    #expect(items.map(\.count) == [2, 1])
}

@Test func placesGroupsByVenueIdFirst() {
    let question = makeQuestion(id: "q-loc-venue", prompt: "Where?", type: .location)

    // Helper to create LocationAnswer with both venueId and text
    let locationWithVenue: (String, String) -> LocationAnswer = { text, venue in
        var answer = LocationAnswer()
        answer.text = text
        answer.foursquareVenueId = venue
        return answer
    }

    let reports = [
        // Same venue ID but different text — should group as 1 place
        makeReport(responses: [makeResponse(questionIdentifier: "q-loc-venue", locationResponse: locationWithVenue("Starbucks Downtown", "venue-123"))]),
        makeReport(responses: [makeResponse(questionIdentifier: "q-loc-venue", locationResponse: locationWithVenue("Starbucks Coffee", "venue-123"))]),
        // Different venue ID, same text — should be 2 places
        makeReport(responses: [makeResponse(questionIdentifier: "q-loc-venue", locationResponse: locationWithVenue("Coffee Shop", "venue-456"))]),
    ]

    let result = VisualizationData.build(for: question, reports: reports)

    guard case .places(let items) = result else {
        Issue.record("expected .places, got \(result)")
        return
    }
    // Should have 2 places: the shared venue-123 (count 2) and venue-456 (count 1)
    #expect(items.count == 2)
    let venues = items.map(\.count).sorted(by: >)
    #expect(venues == [2, 1])
}

// MARK: - recentNotes

@Test func recentNotesOrdersNewestFirstAndCaps20() {
    let question = makeQuestion(id: "q-note", prompt: "Learned?", type: .note)
    let old = Date(timeIntervalSince1970: 1_000_000)
    let new = Date(timeIntervalSince1970: 2_000_000)
    let reports = [
        makeReport(date: old, responses: [makeResponse(questionIdentifier: "q-note", textResponses: [TokenValue(text: "Old note")])]),
        makeReport(date: new, responses: [makeResponse(questionIdentifier: "q-note", textResponses: [TokenValue(text: "New note")])]),
    ]

    let result = VisualizationData.build(for: question, reports: reports)

    guard case .recentNotes(let notes) = result else {
        Issue.record("expected .recentNotes, got \(result)")
        return
    }
    #expect(notes.map(\.text) == ["New note", "Old note"])
    #expect(notes.map(\.date) == [new, old])
}

// MARK: - empty

@Test func emptyWhenNoAnsweredResponses() {
    let question = makeQuestion(id: "q-empty", prompt: "Anything?", type: .tokens)
    let reports = [
        makeReport(responses: [makeResponse(questionIdentifier: "q-empty", tokens: nil)]),
        makeReport(responses: []),
    ]

    let result = VisualizationData.build(for: question, reports: reports)

    guard case .empty = result else {
        Issue.record("expected .empty, got \(result)")
        return
    }
}

@Test func emptyWhenNoReportsAtAll() {
    let question = makeQuestion(id: "q-empty2", prompt: "Anything?", type: .yesNo, choices: ["Yes", "No"])
    let result = VisualizationData.build(for: question, reports: [])
    guard case .empty = result else {
        Issue.record("expected .empty, got \(result)")
        return
    }
}

// MARK: - VisualizationFilterStore

@Test func filterStoreDefaultsToVisible() {
    let store = VisualizationFilterStore(defaults: freshSuite())
    #expect(store.isVisible("some-question-id"))
}

@Test func filterStorePersistsHiddenIDsRoundTrip() {
    let defaults = freshSuite()
    let store = VisualizationFilterStore(defaults: defaults)
    store.setVisible("q-1", false)

    #expect(!store.isVisible("q-1"))
    #expect(store.isVisible("q-2"))

    let reloaded = VisualizationFilterStore(defaults: defaults)
    #expect(!reloaded.isVisible("q-1"))
    #expect(reloaded.isVisible("q-2"))

    reloaded.setVisible("q-1", true)
    #expect(reloaded.isVisible("q-1"))
    #expect(VisualizationFilterStore(defaults: defaults).isVisible("q-1"))
}
