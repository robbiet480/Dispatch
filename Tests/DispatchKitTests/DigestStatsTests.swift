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
    #expect(stats.priorWeekReportCount == 2)
}

@Test func computeExcludesDraftsAndOutOfWindowReports() {
    let draft = makeReport(date: day(0), isDraft: true)
    let ancient = makeReport(date: day(30))
    let stats = DigestStats.compute(reports: fixtureWeek + [draft, ancient],
                                    questions: fixtureQuestions,
                                    weekEnding: weekEnding, calendar: utcCalendar)
    #expect(stats.reportCount == 3)
    #expect(stats.priorWeekReportCount == 0)
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
