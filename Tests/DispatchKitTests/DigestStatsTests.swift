import Foundation
import Testing
@testable import DispatchKit

private var utcCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}

/// The digest's "week ending" moment — noon on the last day of the window.
private let weekEnding = Date(timeIntervalSince1970: 1_781_524_800)

private func day(_ daysAgo: Int, hour: Int = 10) -> Date {
    let calendar = utcCalendar
    let start = calendar.date(byAdding: .day, value: -daysAgo,
                              to: calendar.startOfDay(for: weekEnding))!
    return calendar.date(byAdding: .hour, value: hour, to: start)!
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
    report.date = date
    report.responses = responses
    report.health = health
    report.isDraft = isDraft
    for response in responses { response.report = report }
    return report
}

private var fixtureQuestions: [Question] {
    [
        makeQuestion(id: "q-doing", prompt: "Doing?", type: .tokens),
        makeQuestion(id: "q-people", prompt: "Who are you with?", type: .people),
        makeQuestion(id: "q-where", prompt: "Where?", type: .location),
        makeQuestion(id: "q-coffee", prompt: "Coffees?", type: .number),
        makeQuestion(id: "q-mood", prompt: "Anxious?", type: .yesNo, stateOfMindKind: "anxiety"),
    ]
}

private var fixtureWeek: [Report] {
    [
        makeReport(date: day(0), responses: [
            makeResponse(question: "q-doing", tokens: ["Working"]),
            makeResponse(question: "q-people", tokens: ["Sarah"]),
            makeResponse(question: "q-where", place: "Home"),
            makeResponse(question: "q-coffee", numeric: "2"),
            makeResponse(question: "q-mood", options: ["No"]),
        ], health: [
            HealthReading(type: "steps", value: 4000, unit: "count"),
            HealthReading(type: "workout.37", value: 1800, unit: "s", startDate: day(0, hour: 7)),
        ]),
        makeReport(date: day(1), responses: [
            makeResponse(question: "q-doing", tokens: ["Working", "Reading"]),
            makeResponse(question: "q-people", tokens: ["Sarah", "Alex"]),
            makeResponse(question: "q-where", place: "Office"),
            makeResponse(question: "q-coffee", numeric: "4"),
            makeResponse(question: "q-mood", options: ["No"]),
        ], health: [
            HealthReading(type: "steps", value: 6000, unit: "count"),
            // Same workout re-listed by a later report — must dedupe.
            HealthReading(type: "workout.37", value: 1800, unit: "s", startDate: day(0, hour: 7)),
            HealthReading(type: "workout.13", value: 900, unit: "s", startDate: day(1, hour: 6)),
        ]),
        makeReport(date: day(2), responses: [
            makeResponse(question: "q-doing", tokens: ["Working"]),
        ]),
    ]
}

private var fixturePriorWeek: [Report] {
    [
        makeReport(date: day(8), responses: [makeResponse(question: "q-mood", options: ["Yes"])]),
        makeReport(date: day(9)),
    ]
}

@Test func computeCountsReportsAndPriorWeekDelta() {
    let stats = DigestStats.compute(reports: fixtureWeek + fixturePriorWeek,
                                    questions: fixtureQuestions,
                                    weekEnding: weekEnding, calendar: utcCalendar)
    #expect(stats.reportCount == 3)
    #expect(stats.priorPeriodReportCount == 2)
}

@Test func computeExcludesDraftsAndOutOfWindowReports() {
    let draft = makeReport(date: day(0), isDraft: true)
    let ancient = makeReport(date: day(30))
    let stats = DigestStats.compute(reports: fixtureWeek + [draft, ancient],
                                    questions: fixtureQuestions,
                                    weekEnding: weekEnding, calendar: utcCalendar)
    #expect(stats.reportCount == 3)
    #expect(stats.priorPeriodReportCount == 0)
}

@Test func computeRanksTokensPeopleAndPlaces() {
    let stats = DigestStats.compute(reports: fixtureWeek, questions: fixtureQuestions,
                                    weekEnding: weekEnding, calendar: utcCalendar)
    #expect(stats.topTokens == [.init(text: "Working", count: 3), .init(text: "Reading", count: 1)])
    #expect(stats.topPeople == [.init(text: "Sarah", count: 2), .init(text: "Alex", count: 1)])
    #expect(stats.topPlaces == [.init(text: "Home", count: 1), .init(text: "Office", count: 1)])
}

@Test func computeAveragesNumericQuestions() {
    let stats = DigestStats.compute(reports: fixtureWeek, questions: fixtureQuestions,
                                    weekEnding: weekEnding, calendar: utcCalendar)
    #expect(stats.numericAverages.count == 1)
    let coffee = stats.numericAverages[0]
    #expect(coffee.prompt == "Coffees?")
    #expect(abs(coffee.average - 3.0) < 0.0001)
    #expect(coffee.sampleCount == 2)
}

@Test func computeValenceAveragesBothWeeks() {
    let stats = DigestStats.compute(reports: fixtureWeek + fixturePriorWeek,
                                    questions: fixtureQuestions,
                                    weekEnding: weekEnding, calendar: utcCalendar)
    // This week: two "No" answers → -0.5 each. Prior week: one "Yes" → +0.5.
    #expect(stats.valenceAverage == -0.5)
    #expect(stats.priorValenceAverage == 0.5)
}

@Test func computeSumsStepsAndDedupesWorkouts() {
    let stats = DigestStats.compute(reports: fixtureWeek, questions: fixtureQuestions,
                                    weekEnding: weekEnding, calendar: utcCalendar)
    #expect(stats.stepsTotal == 10000)
    #expect(stats.workoutCount == 2)
    #expect(stats.workoutSeconds == 2700)
}

@Test func computeStreakUsesAllReports() {
    let stats = DigestStats.compute(reports: fixtureWeek, questions: fixtureQuestions,
                                    weekEnding: weekEnding, calendar: utcCalendar)
    #expect(stats.streakDays == 3)
}

@Test func templateSummaryIsDeterministicAndCompletePhrasing() {
    let stats = DigestStats.compute(reports: fixtureWeek + fixturePriorWeek,
                                    questions: fixtureQuestions,
                                    weekEnding: weekEnding, calendar: utcCalendar)
    let expected = "You filed 3 reports this week, 1 more than the week before. "
        + "Your most frequent answers were Working (3), Reading (1). "
        + "You mentioned Sarah (2), Alex (1) most often. "
        + "Top places: Home (1), Office (1). "
        + "Your mood trended down from the week before. "
        + "You logged 10,000 steps and 2 workouts. "
        + "Your report streak stands at 3 days."
    #expect(stats.templateSummary == expected)
    // Stable across invocations.
    #expect(stats.templateSummary == stats.templateSummary)
}

@Test func templateSummaryEmptyWeekStillReadsSensibly() {
    let stats = DigestStats.compute(reports: [], questions: [],
                                    weekEnding: weekEnding, calendar: utcCalendar)
    #expect(stats.templateSummary == "You filed 0 reports this week, the same as the week before.")
}

// MARK: - Period generalization (plan 40)

@Test func monthPeriodIncludesReportsBeyondTheWeekWindow() {
    // A report ~15 days before `weekEnding` is outside the 7-day week window
    // but inside the trailing 1-month window.
    let recent = makeReport(date: day(3))
    let midMonth = makeReport(date: day(15))
    let priorMonth = makeReport(date: day(40))

    let month = DigestStats.compute(reports: [recent, midMonth, priorMonth],
                                    questions: fixtureQuestions,
                                    period: .month, ending: weekEnding, calendar: utcCalendar)
    #expect(month.period == .month)
    #expect(month.reportCount == 2)          // recent + midMonth in-window
    #expect(month.priorPeriodReportCount == 1) // priorMonth in the month before

    let week = DigestStats.compute(reports: [recent, midMonth, priorMonth],
                                   questions: fixtureQuestions,
                                   weekEnding: weekEnding, calendar: utcCalendar)
    #expect(week.reportCount == 1)           // week excludes the 15-days-ago report
}

@Test func quarterPeriodSpansThreeMonths() {
    let inQuarter = makeReport(date: day(75))
    let priorQuarter = makeReport(date: day(120))
    let stats = DigestStats.compute(reports: [inQuarter, priorQuarter],
                                    questions: fixtureQuestions,
                                    period: .quarter, ending: weekEnding, calendar: utcCalendar)
    #expect(stats.period == .quarter)
    #expect(stats.reportCount == 1)
    #expect(stats.priorPeriodReportCount == 1)
}

@Test func weekEntryPointsAgree() {
    // The kept `weekEnding:` wrapper and the explicit `.week` period must
    // produce byte-identical stats — the weekly contract.
    let viaWrapper = DigestStats.compute(reports: fixtureWeek + fixturePriorWeek,
                                         questions: fixtureQuestions,
                                         weekEnding: weekEnding, calendar: utcCalendar)
    let viaPeriod = DigestStats.compute(reports: fixtureWeek + fixturePriorWeek,
                                        questions: fixtureQuestions,
                                        period: .week, ending: weekEnding, calendar: utcCalendar)
    #expect(viaWrapper == viaPeriod)
    #expect(viaWrapper.period == .week)
}

@Test func templateSummaryUsesPeriodNouns() {
    // A report in the prior-month window makes the delta clause read
    // "…than the month before" rather than the first-reports opener.
    let priorMonth = makeReport(date: day(40),
                                responses: [makeResponse(question: "q-doing", tokens: ["X"])])
    let monthStats = DigestStats.compute(reports: fixtureWeek + fixturePriorWeek + [priorMonth],
                                         questions: fixtureQuestions,
                                         period: .month, ending: weekEnding, calendar: utcCalendar)
    #expect(monthStats.templateSummary.contains("this month"))
    #expect(monthStats.templateSummary.contains("the month before"))
    #expect(!monthStats.templateSummary.contains("this week"))
}

@Test func periodBoundaryFieldsPopulated() {
    for period in DigestPeriod.allCases {
        let stats = DigestStats.compute(reports: fixtureWeek, questions: fixtureQuestions,
                                        period: period, ending: weekEnding, calendar: utcCalendar)
        let expected = period.interval(ending: weekEnding, calendar: utcCalendar)
        #expect(stats.periodStart == expected.start)
        #expect(stats.periodEnd == expected.end)
        #expect(stats.period == period)
    }
}

// MARK: - Insight dedupe (review fix: the digest repeated a sentence)

@Test func dedupedTopInsightsSkipInsightsSharingASourceKey() {
    let officeWorking = Insight(
        title: "You answer Yes to “Are you working?” on 85% of reports at Office.",
        detail: "Compared with 30% of other reports — based on 40 reports.",
        kind: .cooccurrence, strength: 0.9, sampleCount: 40,
        sourceKeys: ["question:q-working", "place:text:Office"])
    let laptopWorking = Insight(
        title: "You answer Yes to “Are you working?” on 82% of reports when you mention “laptop”.",
        detail: "Compared with 31% of other reports — based on 40 reports.",
        kind: .cooccurrence, strength: 0.85, sampleCount: 40,
        sourceKeys: ["question:q-working", "token:laptop"])
    let gymSteps = Insight(
        title: "Reports where you mention “gym” average 2,400 more steps.",
        detail: "Average 8,400 vs 6,000 otherwise — based on 40 reports.",
        kind: .categoricalNumeric, strength: 0.8, sampleCount: 40,
        sourceKeys: ["token:gym", "health:steps"])

    // laptopWorking restates q-working — skipped in favor of the next
    // distinct insight, so the two digest sentences never repeat a question.
    let selected = DigestStats.dedupedTopInsights(
        from: [officeWorking, laptopWorking, gymSteps])
    #expect(selected == [officeWorking, gymSteps])
}

@Test func questionContributesAtMostOneSummarySentence() {
    // One yes/no question conditioned by TWO places produces two ranked
    // co-occurrence insights that both cite “Are you working?” — the
    // template summary must quote the question at most once.
    let questions = [
        makeQuestion(id: "q-working", prompt: "Are you working?", type: .yesNo,
                     choices: ["Yes", "No"]),
        makeQuestion(id: "q-where", prompt: "Where are you?", type: .location),
    ]
    var reports: [Report] = []
    for index in 0..<20 {
        reports.append(makeReport(date: day(index), responses: [
            makeResponse(question: "q-working", options: [index < 17 ? "Yes" : "No"]),
            makeResponse(question: "q-where", place: "Office"),
        ]))
        reports.append(makeReport(date: day(index, hour: 18), responses: [
            makeResponse(question: "q-working", options: [index < 6 ? "Yes" : "No"]),
            makeResponse(question: "q-where", place: "Home"),
        ]))
    }

    // Precondition: without dedupe the engine really does rank 2+ insights
    // that all reference the question (otherwise this test proves nothing).
    let ranked = InsightsEngine.compute(reports: reports, questions: questions)
    #expect(ranked.filter { $0.sourceKeys.contains("question:q-working") }.count >= 2)

    let stats = DigestStats.compute(reports: reports, questions: questions,
                                    weekEnding: weekEnding, calendar: utcCalendar)
    #expect(stats.topInsights.count == 1)
    let summary = stats.templateSummary
    let mentions = summary.components(separatedBy: "Are you working?").count - 1
    #expect(mentions == 1)
}
