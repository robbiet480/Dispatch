import Foundation
import Testing
@testable import DispatchKit

// MARK: - Template fixtures (hand-built findings — the copy layer is pure)

private func rateFinding(effect: Double, interval: ClosedRange<Double>,
                         withSummary: String, withoutSummary: String) -> CorrelationFinding {
    CorrelationFinding(kind: .rateDifference, tier: .moderate, effect: effect,
                       interval: interval, pValue: 0.004,
                       withSummary: withSummary, withoutSummary: withoutSummary,
                       sampleCount: 59)
}

// MARK: - Rate difference copy

@Test func rateDifferenceHeadlineAndDetailPositive() {
    let finding = rateFinding(effect: 0.31, interval: 0.08...0.52,
                              withSummary: "72% of 25", withoutSummary: "41% of 34")
    let dimension = CorrelationRow.Dimension.person(name: "Angela")
    #expect(finding.headline(targetLabel: "Yes", prompt: "Happy?", dimension: dimension)
        == "You answered Yes more often when Angela was around.")
    #expect(finding.detail(targetLabel: "Yes", dimension: dimension)
        == "Yes on 72% of 25 reports with Angela vs 41% of 34 without — a 31-point difference (95% CI 8 to 52).")
}

@Test func rateDifferenceHeadlineNegativeDirection() {
    let finding = rateFinding(effect: -0.31, interval: (-0.52)...(-0.08),
                              withSummary: "41% of 25", withoutSummary: "72% of 34")
    let dimension = CorrelationRow.Dimension.place(name: "Office")
    #expect(finding.headline(targetLabel: "Yes", prompt: "Happy?", dimension: dimension)
        == "You answered Yes less often at Office.")
    #expect(finding.detail(targetLabel: "Yes", dimension: dimension)
        == "Yes on 41% of 25 reports at Office vs 72% of 34 elsewhere — a 31-point difference (95% CI -52 to -8).")
}

@Test func rateDifferenceContextPhrasesForConnectionAndTimeOfDay() {
    let finding = rateFinding(effect: 0.2, interval: 0.05...0.35,
                              withSummary: "60% of 20", withoutSummary: "40% of 30")
    #expect(finding.headline(targetLabel: "Yes", prompt: "Happy?",
                             dimension: .connection(label: "Wi-Fi"))
        == "You answered Yes more often on Wi-Fi.")
    #expect(finding.headline(targetLabel: "Yes", prompt: "Happy?",
                             dimension: .timeOfDay(bucket: "Morning"))
        == "You answered Yes more often in the morning.")
    #expect(finding.headline(targetLabel: "Yes", prompt: "Happy?",
                             dimension: .timeOfDay(bucket: "Night"))
        == "You answered Yes more often at night.")
}

// MARK: - Mean difference copy (binary target × health metric)

@Test func meanDifferenceSleepHeadlineAndDetail() {
    let finding = CorrelationFinding(kind: .meanDifference, tier: .strong, effect: 1.9,
                                     interval: 1.2...2.6, pValue: 0.0001,
                                     withSummary: "8.0 h over 22",
                                     withoutSummary: "6.1 h over 30", sampleCount: 52)
    #expect(finding.headline(targetLabel: "Yes", prompt: "Rested?", dimension: .sleepHours)
        == "You slept longer on reports where you answered Yes.")
    #expect(finding.detail(targetLabel: "Yes", dimension: .sleepHours)
        == "Average 8.0 h over 22 reports vs 6.1 h over 30 — difference 1.9 h (95% CI 1.2 to 2.6).")
}

@Test func meanDifferenceStepsNegativeDirection() {
    let finding = CorrelationFinding(kind: .meanDifference, tier: .moderate,
                                     effect: -2_400, interval: (-3_600)...(-1_200),
                                     pValue: 0.001,
                                     withSummary: "5,200 over 20",
                                     withoutSummary: "7,600 over 25", sampleCount: 45)
    #expect(finding.headline(targetLabel: "Yes", prompt: "Tired?", dimension: .steps)
        == "You logged fewer steps on reports where you answered Yes.")
    #expect(finding.detail(targetLabel: "Yes", dimension: .steps)
        == "Average 5,200 over 20 reports vs 7,600 over 25 — difference 2,400 (95% CI -3,600 to -1,200).")
}

@Test func meanDifferenceHeartRateHeadlines() {
    let finding = CorrelationFinding(kind: .meanDifference, tier: .weak, effect: 4.2,
                                     interval: 1.0...7.4, pValue: 0.01,
                                     withSummary: "78 bpm over 15",
                                     withoutSummary: "74 bpm over 18", sampleCount: 33)
    #expect(finding.headline(targetLabel: "Yes", prompt: "Stressed?",
                             dimension: .heartRateAvg)
        == "Your average heart rate ran higher on reports where you answered Yes.")
    #expect(finding.headline(targetLabel: "Yes", prompt: "Stressed?",
                             dimension: .restingHeartRate)
        == "Your resting heart rate ran higher on reports where you answered Yes.")
}

// MARK: - Mean difference copy (numeric target × context dimension)

@Test func meanDifferenceNumericAnswerAcrossContext() {
    let finding = CorrelationFinding(kind: .meanDifference, tier: .moderate, effect: 1.1,
                                     interval: 0.3...1.9, pValue: 0.008,
                                     withSummary: "7.2 over 25",
                                     withoutSummary: "6.1 over 34", sampleCount: 59)
    let dimension = CorrelationRow.Dimension.person(name: "Angela")
    #expect(finding.headline(targetLabel: "Hours focused?", prompt: "Hours focused?",
                             dimension: dimension)
        == "Your answers to “Hours focused?” tend to run higher when Angela was around.")
    #expect(finding.detail(targetLabel: "Hours focused?", dimension: dimension)
        == "Average 7.2 over 25 reports vs 6.1 over 34 — difference 1.1 (95% CI 0.3 to 1.9).")
}

// MARK: - Pearson copy

@Test func pearsonHeadlineAndDetail() {
    let finding = CorrelationFinding(kind: .pearson, tier: .strong, effect: 0.84,
                                     interval: 0.71...0.92, pValue: 0.0001,
                                     withSummary: "r = 0.84", withoutSummary: "",
                                     sampleCount: 41)
    #expect(finding.headline(targetLabel: "Hours focused?", prompt: "Hours focused?",
                             dimension: .steps)
        == "Your answers to “Hours focused?” tend to rise and fall with your steps.")
    #expect(finding.detail(targetLabel: "Hours focused?", dimension: .steps)
        == "r = 0.84 (95% CI 0.71 to 0.92) over 41 reports.")
}

@Test func pearsonNegativeDirection() {
    let finding = CorrelationFinding(kind: .pearson, tier: .moderate, effect: -0.55,
                                     interval: (-0.75)...(-0.28), pValue: 0.001,
                                     withSummary: "r = -0.55", withoutSummary: "",
                                     sampleCount: 30)
    #expect(finding.headline(targetLabel: "Hours focused?", prompt: "Hours focused?",
                             dimension: .sleepHours)
        == "Your answers to “Hours focused?” tend to move opposite to your sleep.")
}

// MARK: - Banned language (the plan-34 analog of plan 37's privacy pin)

/// Correlation copy NEVER claims causation. Every headline and detail the
/// engine + copy layer can produce from the planted fixtures — plus the
/// standing disclaimer — must avoid causal phrasing. The ban is absolute:
/// the disclaimer itself is worded to pass the same check.
@Test func correlationLanguageStaysAssociationalNeverCausal() throws {
    let banned = ["2x", "twice as likely", "causes", "caused by", "because",
                  "leads to", "makes you", "proves", "drives"]

    // The disclaimer is held to the same ban with ONE documented carve-out:
    // its "not causes" denial — required by the disclaimer contract test —
    // is the anti-causal statement itself, not a causal claim.
    let disclaimer = CorrelationEngine.causationDisclaimer
        .replacingOccurrences(of: "not causes", with: "")
    var corpus: [String] = [disclaimer]

    // Planted rate difference (person dimension).
    do {
        let questions = [
            copyTestQuestion(id: "q-yes", prompt: "Happy?", type: .yesNo,
                             choices: ["Yes", "No"]),
            copyTestQuestion(id: "q-who", prompt: "Who?", type: .people),
        ]
        var reports: [Report] = []
        for index in 0..<60 {
            let withAngela = index < 25
            let yes = index < 18 || (index >= 25 && index < 33)
            reports.append(copyTestReport(offset: index, responses: [
                copyTestResponse(question: "q-yes", options: [yes ? "Yes" : "No"]),
                copyTestResponse(question: "q-who", tokens: withAngela ? ["Angela"] : []),
            ]))
        }
        let result = try #require(CorrelationEngine.compute(
            questionID: "q-yes", reports: reports, questions: questions))
        corpus += copyStrings(from: result)
    }

    // Planted mean difference (sleep) + planted Pearson (steps).
    do {
        let questions = [copyTestQuestion(id: "q-num", prompt: "Hours focused?",
                                          type: .number)]
        var reports: [Report] = []
        for index in 0..<40 {
            let answer = Double(index % 12) + 1
            reports.append(copyTestReport(offset: index, responses: [
                copyTestResponse(question: "q-num", numeric: String(answer)),
            ], health: [
                HealthReading(type: "steps", value: 1_000 * answer + Double(index % 7) * 50,
                              unit: "count"),
                HealthReading(type: "sleepCore",
                              value: (5 + answer * 0.3) * 3600, unit: "s"),
            ]))
        }
        let result = try #require(CorrelationEngine.compute(
            questionID: "q-num", reports: reports, questions: questions))
        corpus += copyStrings(from: result)
    }

    #expect(corpus.count > 3, "the corpus must include real generated findings")
    for text in corpus {
        let lowered = text.lowercased()
        for phrase in banned {
            #expect(!lowered.contains(phrase),
                    "causal language \"\(phrase)\" in: \(text)")
        }
    }
}

@Test func causationDisclaimerNamesCorrelationsNotCauses() {
    let disclaimer = CorrelationEngine.causationDisclaimer
    #expect(!disclaimer.isEmpty)
    #expect(disclaimer.contains("correlations"))
    #expect(disclaimer.contains("not causes"))
}

// MARK: - Corpus helpers

private func copyStrings(from result: QuestionCorrelations) -> [String] {
    var strings: [String] = []
    for target in result.targets {
        for row in target.rows {
            if case .finding(let finding) = row.outcome {
                strings.append(finding.headline(targetLabel: target.label,
                                                prompt: result.prompt,
                                                dimension: row.dimension))
                strings.append(finding.detail(targetLabel: target.label,
                                              dimension: row.dimension))
            }
        }
    }
    return strings
}

private func copyTestQuestion(id: String, prompt: String, type: QuestionType,
                              choices: [String] = []) -> Question {
    let question = Question()
    question.uniqueIdentifier = id
    question.prompt = prompt
    question.type = type
    question.choices = choices
    return question
}

private func copyTestResponse(question: String, tokens: [String]? = nil,
                              numeric: String? = nil,
                              options: [String]? = nil) -> Response {
    let response = Response()
    response.questionIdentifier = question
    response.tokens = tokens?.map { TokenValue(text: $0) }
    response.numericResponse = numeric
    response.answeredOptions = options
    return response
}

private func copyTestReport(offset: Int, responses: [Response],
                            health: [HealthReading] = []) -> Report {
    let report = Report()
    report.uniqueIdentifier = "copy-report-\(offset)"
    report.date = Date(timeIntervalSince1970: 1_780_000_000 + Double(offset) * 86_400)
    report.responses = responses
    report.health = health
    for response in responses { response.report = report }
    return report
}
