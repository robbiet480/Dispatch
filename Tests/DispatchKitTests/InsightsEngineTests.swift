import Foundation
import Testing
@testable import DispatchKit

// MARK: - Fixture helpers

private func day(_ offset: Int) -> Date {
    Date(timeIntervalSince1970: 1_780_000_000 + Double(offset) * 86_400)
}

private func makeQuestion(id: String, prompt: String, type: QuestionType,
                          choices: [String] = [], stateOfMindKind: String? = nil) -> Question {
    let question = Question()
    question.uniqueIdentifier = id
    question.prompt = prompt
    question.type = type
    question.choices = choices
    question.stateOfMindKind = stateOfMindKind
    return question
}

private func makeResponse(question: String, tokens: [String]? = nil, numeric: String? = nil,
                          options: [String]? = nil, place: String? = nil) -> Response {
    let response = Response()
    response.questionIdentifier = question
    response.tokens = tokens?.map { TokenValue(text: $0) }
    response.numericResponse = numeric
    response.answeredOptions = options
    if let place {
        var answer = LocationAnswer()
        answer.text = place
        response.locationResponse = answer
    }
    return response
}

private func makeReport(date: Date, responses: [Response] = [], health: [HealthReading] = [],
                        isDraft: Bool = false) -> Report {
    let report = Report()
    report.uniqueIdentifier = "report-\(Int(date.timeIntervalSince1970))"
    report.date = date
    report.responses = responses
    report.health = health
    report.isDraft = isDraft
    for response in responses { response.report = report }
    return report
}

/// 24 reports: 12 mention "gym" with high steps, 12 without with low steps —
/// a planted association the engine must surface.
private func gymStepsFixture(withDrafts: Bool = false) -> ([Report], [Question]) {
    let questions = [makeQuestion(id: "q-doing", prompt: "Doing?", type: .tokens)]
    var reports: [Report] = []
    for index in 0..<12 {
        reports.append(makeReport(
            date: day(index),
            responses: [makeResponse(question: "q-doing", tokens: ["gym"])],
            health: [HealthReading(type: "steps", value: 9_000 + Double(index) * 10, unit: "count")],
            isDraft: withDrafts))
        reports.append(makeReport(
            date: day(100 + index),
            responses: [makeResponse(question: "q-doing", tokens: [])],
            health: [HealthReading(type: "steps", value: 3_000 + Double(index) * 10, unit: "count")]))
    }
    return (reports, questions)
}

// MARK: - Surfacing on planted signal

@Test func plantedStepDifferenceSurfacesWithHonestLanguage() throws {
    let (reports, questions) = gymStepsFixture()
    let insights = InsightsEngine.compute(reports: reports, questions: questions)

    #expect(insights.count == 1)
    let insight = try #require(insights.first)
    // Means: 9,055 with vs 3,055 without — delta exactly 6,000.
    #expect(insight.title == "Reports where you mention “gym” average 6,000 more steps.")
    #expect(insight.detail == "Average 9,055 vs 3,055 otherwise — based on 24 reports.")
    #expect(insight.kind == .categoricalNumeric)
    #expect(insight.sampleCount == 24)
    #expect(insight.strength > 0 && insight.strength <= 1)
}

@Test func valenceRunsHigherAroundPerson() {
    // "Angela days" answer the mood question Good (+1), others Bad (-1).
    let questions = [
        makeQuestion(id: "q-who", prompt: "Who are you with?", type: .people),
        makeQuestion(id: "q-mood", prompt: "Mood?", type: .multipleChoice,
                     choices: ["Bad", "OK", "Good"], stateOfMindKind: "mood"),
    ]
    var reports: [Report] = []
    for index in 0..<12 {
        reports.append(makeReport(date: day(index), responses: [
            makeResponse(question: "q-who", tokens: ["Angela"]),
            makeResponse(question: "q-mood", options: ["Good"]),
        ]))
        reports.append(makeReport(date: day(100 + index), responses: [
            makeResponse(question: "q-who", tokens: []),
            makeResponse(question: "q-mood", options: ["Bad"]),
        ]))
    }
    let insights = InsightsEngine.compute(reports: reports, questions: questions)
    #expect(insights.contains {
        $0.title == "Your mood valence tends to run higher when you see Angela."
    })
    // The SoM answer shares the valence metric's source, so the engine never
    // restates the mapping ("valence runs higher when you answer Good").
    #expect(!insights.contains {
        $0.title.hasPrefix("Your mood valence") && $0.title.contains("when you answer")
    })
}

@Test func cooccurrenceRateSurfacesForPlaceConditionedAnswer() throws {
    // At Office: Yes on 17/20 (85%). Elsewhere (Home): Yes on 6/20 (30%).
    let questions = [
        makeQuestion(id: "q-working", prompt: "Working?", type: .yesNo),
        makeQuestion(id: "q-where", prompt: "Where are you?", type: .location),
    ]
    var reports: [Report] = []
    for index in 0..<20 {
        reports.append(makeReport(date: day(index), responses: [
            makeResponse(question: "q-working", options: [index < 17 ? "Yes" : "No"]),
            makeResponse(question: "q-where", place: "Office"),
        ]))
        reports.append(makeReport(date: day(100 + index), responses: [
            makeResponse(question: "q-working", options: [index < 6 ? "Yes" : "No"]),
            makeResponse(question: "q-where", place: "Home"),
        ]))
    }
    let insights = InsightsEngine.compute(reports: reports, questions: questions)
    let office = insights.first {
        $0.title == "You answer Yes to “Working?” on 85% of reports at Office."
    }
    let insight = try #require(office)
    #expect(insight.detail == "Compared with 30% of other reports — based on 40 reports.")
    #expect(insight.kind == .cooccurrence)
    #expect(insight.sampleCount == 40)
}

// MARK: - Silence guards

@Test func noiseYieldsSilence() {
    // Identical step distributions on both sides of the token split, and a
    // yes/no answered independently of everything: nothing may surface.
    let questions = [
        makeQuestion(id: "q-doing", prompt: "Doing?", type: .tokens),
        makeQuestion(id: "q-happy", prompt: "Happy?", type: .yesNo),
    ]
    var reports: [Report] = []
    for index in 0..<15 {
        let steps = 4_000 + Double(index % 5) * 500
        reports.append(makeReport(
            date: day(index),
            responses: [
                makeResponse(question: "q-doing", tokens: ["work"]),
                makeResponse(question: "q-happy", options: [index % 2 == 0 ? "Yes" : "No"]),
            ],
            health: [HealthReading(type: "steps", value: steps, unit: "count")]))
        reports.append(makeReport(
            date: day(100 + index),
            responses: [
                makeResponse(question: "q-doing", tokens: []),
                makeResponse(question: "q-happy", options: [index % 2 == 0 ? "Yes" : "No"]),
            ],
            health: [HealthReading(type: "steps", value: steps, unit: "count")]))
    }
    #expect(InsightsEngine.compute(reports: reports, questions: questions).isEmpty)
}

@Test func belowMinimumSampleStaysSilent() {
    // Only 9 reports carry the token — one short of the ≥10 side guard —
    // despite a giant planted delta.
    let questions = [makeQuestion(id: "q-doing", prompt: "Doing?", type: .tokens)]
    var reports: [Report] = []
    for index in 0..<9 {
        reports.append(makeReport(
            date: day(index),
            responses: [makeResponse(question: "q-doing", tokens: ["gym"])],
            health: [HealthReading(type: "steps", value: 20_000, unit: "count")]))
    }
    for index in 0..<30 {
        reports.append(makeReport(
            date: day(100 + index),
            responses: [makeResponse(question: "q-doing", tokens: [])],
            health: [HealthReading(type: "steps", value: 1_000 + Double(index), unit: "count")]))
    }
    #expect(InsightsEngine.compute(reports: reports, questions: questions).isEmpty)
}

@Test func trivialDeltaStaysSilent() {
    // Wide spread (1,000–12,000 both sides), tiny +100 shift with the token:
    // standardized effect far below the threshold — silence, not a headline.
    let questions = [makeQuestion(id: "q-doing", prompt: "Doing?", type: .tokens)]
    var reports: [Report] = []
    for index in 0..<12 {
        let base = 1_000 + Double(index) * 1_000
        reports.append(makeReport(
            date: day(index),
            responses: [makeResponse(question: "q-doing", tokens: ["gym"])],
            health: [HealthReading(type: "steps", value: base + 100, unit: "count")]))
        reports.append(makeReport(
            date: day(100 + index),
            responses: [makeResponse(question: "q-doing", tokens: [])],
            health: [HealthReading(type: "steps", value: base, unit: "count")]))
    }
    #expect(InsightsEngine.compute(reports: reports, questions: questions).isEmpty)
}

@Test func balancedCooccurrenceStaysSilent() {
    // Yes-rate identical at Office and elsewhere: no rate insight.
    let questions = [
        makeQuestion(id: "q-working", prompt: "Working?", type: .yesNo),
        makeQuestion(id: "q-where", prompt: "Where are you?", type: .location),
    ]
    var reports: [Report] = []
    for index in 0..<20 {
        reports.append(makeReport(date: day(index), responses: [
            makeResponse(question: "q-working", options: [index % 2 == 0 ? "Yes" : "No"]),
            makeResponse(question: "q-where", place: "Office"),
        ]))
        reports.append(makeReport(date: day(100 + index), responses: [
            makeResponse(question: "q-working", options: [index % 2 == 0 ? "Yes" : "No"]),
            makeResponse(question: "q-where", place: "Home"),
        ]))
    }
    #expect(InsightsEngine.compute(reports: reports, questions: questions).isEmpty)
}

@Test func draftsAreExcluded() {
    // The entire "with gym" side is drafts, so the split loses one side and
    // the planted delta must NOT surface.
    let (reports, questions) = gymStepsFixture(withDrafts: true)
    #expect(InsightsEngine.compute(reports: reports, questions: questions).isEmpty)
}

@Test func questionAdoptedMidHistoryOnlyCountsAnsweredReports() {
    // The token question exists only for the second half of history; the
    // pre-question era has very low step counts. If "without the token"
    // wrongly included the unanswered pre-question reports, a huge spurious
    // delta (≈ +3,600 steps, effect ≈ 1.3) would surface. Honest eligibility
    // compares only answered reports, where the delta (200 steps against a
    // ~1,150-step spread) is far below the effect threshold: silence.
    let questions = [makeQuestion(id: "q-doing", prompt: "Doing?", type: .tokens)]
    var reports: [Report] = []
    for index in 0..<20 {  // pre-adoption: no q-doing response at all
        reports.append(makeReport(
            date: day(index),
            health: [HealthReading(type: "steps", value: 500, unit: "count")]))
    }
    for index in 0..<10 {  // post-adoption, token present
        reports.append(makeReport(
            date: day(100 + index),
            responses: [makeResponse(question: "q-doing", tokens: ["gym"])],
            health: [HealthReading(type: "steps",
                                   value: 4_000 + Double(index) * 400, unit: "count")]))
    }
    for index in 0..<10 {  // post-adoption, answered without the token
        reports.append(makeReport(
            date: day(200 + index),
            responses: [makeResponse(question: "q-doing", tokens: [])],
            health: [HealthReading(type: "steps",
                                   value: 3_800 + Double(index) * 400, unit: "count")]))
    }
    #expect(InsightsEngine.compute(reports: reports, questions: questions).isEmpty)
}

@Test func mirroredCooccurrencePairSurfacesOnce() {
    // "alpha" and "beta" always co-occur, so both directions clear every
    // guard — but the unordered pair must surface exactly once.
    let questions = [makeQuestion(id: "q-doing", prompt: "Doing?", type: .tokens)]
    var reports: [Report] = []
    for index in 0..<12 {
        reports.append(makeReport(date: day(index), responses: [
            makeResponse(question: "q-doing", tokens: ["alpha", "beta"]),
        ]))
        reports.append(makeReport(date: day(100 + index), responses: [
            makeResponse(question: "q-doing", tokens: []),
        ]))
    }
    let insights = InsightsEngine.compute(reports: reports, questions: questions)
    #expect(insights.count == 1)
    // Exact |delta| tie (100% vs 0% both ways): the lexicographically
    // smaller context id wins, so alpha conditions beta.
    #expect(insights.first?.title
        == "You mention “beta” on 100% of reports when you mention “alpha”.")
}

@Test func valenceAveragesOverMappedAnswersOnly() throws {
    // Each report answers two state-of-mind questions, but one answer ("Zen")
    // is no longer among the question's choices, so the valence mapping
    // returns nil for it. The per-report average must divide by the ONE
    // mapped answer — 1.00 vs -1.00 — not by two, which would halve it.
    let questions = [
        makeQuestion(id: "q-doing", prompt: "Doing?", type: .tokens),
        makeQuestion(id: "q-mood", prompt: "Mood?", type: .multipleChoice,
                     choices: ["Bad", "OK", "Good"], stateOfMindKind: "mood"),
        makeQuestion(id: "q-calm", prompt: "Calm?", type: .multipleChoice,
                     choices: ["Frazzled", "Settled"], stateOfMindKind: "calm"),
    ]
    var reports: [Report] = []
    for index in 0..<12 {
        reports.append(makeReport(date: day(index), responses: [
            makeResponse(question: "q-doing", tokens: ["gym"]),
            makeResponse(question: "q-mood", options: ["Good"]),
            makeResponse(question: "q-calm", options: ["Zen"]),
        ]))
        reports.append(makeReport(date: day(100 + index), responses: [
            makeResponse(question: "q-doing", tokens: []),
            makeResponse(question: "q-mood", options: ["Bad"]),
            makeResponse(question: "q-calm", options: ["Zen"]),
        ]))
    }
    let insights = InsightsEngine.compute(reports: reports, questions: questions)
    let valenceInsight = try #require(insights.first {
        $0.title == "Your mood valence tends to run higher when you mention “gym”."
    })
    #expect(valenceInsight.detail == "Average 1.00 vs -1.00 otherwise — based on 24 reports.")
}

@Test func tooFewReportsOverallStaysSilent() {
    let questions = [makeQuestion(id: "q-doing", prompt: "Doing?", type: .tokens)]
    let reports = (0..<19).map { index in
        makeReport(date: day(index),
                   responses: [makeResponse(question: "q-doing",
                                            tokens: index % 2 == 0 ? ["gym"] : [])],
                   health: [HealthReading(type: "steps",
                                          value: index % 2 == 0 ? 9_000 : 1_000, unit: "count")])
    }
    #expect(InsightsEngine.compute(reports: reports, questions: questions).isEmpty)
}

// MARK: - Cap, ordering, language

/// 12 high-step reports each carry ten distinct tokens; 12 low-step reports
/// carry none — every token yields a mean-difference insight and every token
/// pair a co-occurrence, far more than the cap.
private func manySignalsFixture() -> ([Report], [Question]) {
    let questions = [makeQuestion(id: "q-doing", prompt: "Doing?", type: .tokens)]
    let tokens = (0..<10).map { "token\($0)" }
    var reports: [Report] = []
    for index in 0..<12 {
        reports.append(makeReport(
            date: day(index),
            responses: [makeResponse(question: "q-doing", tokens: tokens)],
            health: [HealthReading(type: "steps", value: 9_000 + Double(index), unit: "count")]))
        reports.append(makeReport(
            date: day(100 + index),
            responses: [makeResponse(question: "q-doing", tokens: [])],
            health: [HealthReading(type: "steps", value: 1_000 + Double(index), unit: "count")]))
    }
    return (reports, questions)
}

@Test func outputIsCappedAtTopEightWithKindDiversity() {
    let (reports, questions) = manySignalsFixture()
    let insights = InsightsEngine.compute(reports: reports, questions: questions)
    #expect(insights.count == 8)
    // The fixture plants both kinds in abundance (10 mean-difference
    // candidates, 45 deduped co-occurrence pairs). The per-kind quota must
    // keep both represented instead of letting one flood every slot.
    let cooccurrenceCount = insights.filter { $0.kind == .cooccurrence }.count
    let meanDifferenceCount = insights.filter { $0.kind == .categoricalNumeric }.count
    #expect(cooccurrenceCount == 4)
    #expect(meanDifferenceCount == 4)
}

@Test func orderingIsDeterministicAndInputOrderInvariant() {
    let (reports, questions) = manySignalsFixture()
    let first = InsightsEngine.compute(reports: reports, questions: questions)
    let second = InsightsEngine.compute(reports: reports, questions: questions)
    let reversed = InsightsEngine.compute(reports: reports.reversed(), questions: questions)
    #expect(first == second)
    #expect(first == reversed)
    // Ranked: strength descending, then sample count, then title.
    let strengths = first.map(\.strength)
    #expect(strengths == strengths.sorted(by: >))
}

@Test func languageStaysAssociationalNeverCausal() {
    let fixtures = [gymStepsFixture(), manySignalsFixture()]
    for (reports, questions) in fixtures {
        let insights = InsightsEngine.compute(reports: reports, questions: questions)
        #expect(!insights.isEmpty)
        for insight in insights {
            let text = (insight.title + " " + insight.detail).lowercased()
            for forbidden in ["cause", "because", "leads to", "makes you", "results in",
                              "due to", "explains", "proves"] {
                #expect(!text.contains(forbidden),
                        "causal language \"\(forbidden)\" in: \(text)")
            }
            #expect(insight.detail.contains("based on"),
                    "every detail carries its sample count: \(insight.detail)")
            #expect(insight.title.contains("average") || insight.title.contains("tends")
                    || insight.title.contains("% of reports"),
                    "titles use average/tends/rate framing: \(insight.title)")
        }
    }
}

// MARK: - Person registry resolution (plan 22)

/// Half the "with" reports name "Angela", half "Angie" — each alone is below
/// the 10-report side guard, so no person insight surfaces. With the registry
/// resolving the alias, they unify into one 12-report signal displayed by the
/// current display name.
@Test func personSignalsResolveAliasesThroughRegistry() throws {
    let questions = [makeQuestion(id: "q-who", prompt: "Who are you with?", type: .people)]
    var reports: [Report] = []
    for index in 0..<12 {
        let name = index.isMultiple(of: 2) ? "Angela" : "Angie"
        reports.append(makeReport(
            date: day(index),
            responses: [makeResponse(question: "q-who", tokens: [name])],
            health: [HealthReading(type: "steps", value: 9_000 + Double(index) * 10, unit: "count")]))
        reports.append(makeReport(
            date: day(100 + index),
            responses: [makeResponse(question: "q-who", tokens: [])],
            health: [HealthReading(type: "steps", value: 3_000 + Double(index) * 10, unit: "count")]))
    }
    let angela = PersonEntity()
    angela.text = "Angela"
    angela.alternateNames = ["Angie"]

    let unresolved = InsightsEngine.compute(reports: reports, questions: questions)
    #expect(!unresolved.contains { $0.title.contains("Angela") || $0.title.contains("Angie") })

    let resolved = InsightsEngine.compute(reports: reports, questions: questions, people: [angela])
    #expect(resolved.contains { $0.title.contains("see Angela") })
    #expect(!resolved.contains { $0.title.contains("Angie") })
}
