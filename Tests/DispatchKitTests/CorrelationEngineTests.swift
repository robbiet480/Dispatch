import Foundation
import Testing
@testable import DispatchKit

// MARK: - Fixture helpers (InsightsEngineTests style — mirrored, not shared)

private func day(_ offset: Int) -> Date {
    Date(timeIntervalSince1970: 1_780_000_000 + Double(offset) * 86_400)
}

private func makeQuestion(id: String, prompt: String, type: QuestionType,
                          choices: [String] = []) -> Question {
    let question = Question()
    question.uniqueIdentifier = id
    question.prompt = prompt
    question.type = type
    question.choices = choices
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

private func makeReport(date: Date, responses: [Response] = [],
                        health: [HealthReading] = [], connection: Int? = nil,
                        timeZone: String = "GMT", isDraft: Bool = false,
                        id: String? = nil) -> Report {
    let report = Report()
    report.uniqueIdentifier = id ?? "report-\(Int(date.timeIntervalSince1970))"
    report.date = date
    report.timeZoneIdentifier = timeZone
    report.responses = responses
    report.health = health
    report.connection = connection
    report.isDraft = isDraft
    for response in responses { response.report = report }
    return report
}

/// Deterministic fixture noise — never `Double.random` unseeded.
private struct SeededLCG {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state >> 33
    }
}

private func row(_ result: QuestionCorrelations?,
                 _ dimension: CorrelationRow.Dimension,
                 target: Int = 0) -> CorrelationRow? {
    guard let result, result.targets.indices.contains(target) else { return nil }
    return result.targets[target].rows.first { $0.dimension == dimension }
}

private func finding(_ row: CorrelationRow?) -> CorrelationFinding? {
    guard case .finding(let value) = row?.outcome else { return nil }
    return value
}

// MARK: - Threshold freeze

@Test func thresholdConstantsAreFrozen() {
    #expect(CorrelationEngine.minimumSideCount == 10)
    #expect(CorrelationEngine.minimumPairCount == 20)
    #expect(CorrelationEngine.minimumEligibleAnswers == 20)
    #expect(CorrelationEngine.minimumRateDelta == 0.15)
    #expect(CorrelationEngine.minimumStandardizedDifference == 0.35)
    #expect(CorrelationEngine.minimumPearsonR == 0.30)
    #expect(CorrelationEngine.falseDiscoveryRate == 0.05)
    #expect(CorrelationEngine.confidence == 0.95)
    #expect(CorrelationEngine.maximumTargets == 8)
    #expect(CorrelationEngine.maximumPeopleDimensions == 8)
    #expect(CorrelationEngine.maximumPlaceDimensions == 8)
}

// MARK: - Planted rate difference (binary target × binary dimension)

/// 60 reports, yesNo answered on all; Angela present on 25 (Yes on 18 = 72%),
/// absent on 35 (Yes on 8 = 23%) — a planted +49-point rate difference.
private func plantedRateFixture() -> ([Report], [Question]) {
    let questions = [
        makeQuestion(id: "q-yes", prompt: "Happy?", type: .yesNo, choices: ["Yes", "No"]),
        makeQuestion(id: "q-who", prompt: "Who are you with?", type: .people),
    ]
    var reports: [Report] = []
    for index in 0..<60 {
        let withAngela = index < 25
        let yes = index < 18 || (index >= 25 && index < 33)
        reports.append(makeReport(date: day(index), responses: [
            makeResponse(question: "q-yes", options: [yes ? "Yes" : "No"]),
            makeResponse(question: "q-who", tokens: withAngela ? ["Angela"] : []),
        ]))
    }
    return (reports, questions)
}

@Test func plantedRateDifferenceSurfacesAsStrongFinding() throws {
    let (reports, questions) = plantedRateFixture()
    let result = CorrelationEngine.compute(questionID: "q-yes", reports: reports,
                                           questions: questions)
    let personRow = try #require(row(result, .person(name: "Angela")))
    let found = try #require(finding(personRow), "expected a finding, got \(personRow.outcome)")
    #expect(found.kind == .rateDifference)
    // 18/25 − 8/35 = 0.72 − 0.2286 = +0.4914
    #expect(abs(found.effect - 0.4914) < 0.01)
    #expect(found.interval.lowerBound > 0)
    #expect(found.tier == .strong)
    #expect(found.withSummary.contains("72%"))
    #expect(found.withSummary.contains("25"))
    #expect(found.withoutSummary.contains("23%"))
    #expect(found.sampleCount == 60)
}

// MARK: - Planted mean difference (binary target × numeric dimension)

/// Yes-reports sleep ≈ 8 h, No-reports ≈ 6 h (two stage readings per report
/// so the sum-across-stages path is exercised), tight within-side spread.
private func plantedSleepFixture() -> ([Report], [Question]) {
    let questions = [makeQuestion(id: "q-yes", prompt: "Rested?", type: .yesNo,
                                  choices: ["Yes", "No"])]
    var reports: [Report] = []
    for index in 0..<40 {
        let yes = index < 20
        let baseHours = (yes ? 8.0 : 6.0) + Double(index % 5) * 0.25 - 0.5
        reports.append(makeReport(
            date: day(index),
            responses: [makeResponse(question: "q-yes", options: [yes ? "Yes" : "No"])],
            health: [
                HealthReading(type: "sleepCore", value: baseHours * 0.75 * 3600, unit: "s"),
                HealthReading(type: "sleepREM", value: baseHours * 0.25 * 3600, unit: "s"),
            ]))
    }
    return (reports, questions)
}

@Test func plantedSleepDifferenceSurfacesInHours() throws {
    let (reports, questions) = plantedSleepFixture()
    let result = CorrelationEngine.compute(questionID: "q-yes", reports: reports,
                                           questions: questions)
    let sleepRow = try #require(row(result, .sleepHours))
    let found = try #require(finding(sleepRow), "expected a finding, got \(sleepRow.outcome)")
    #expect(found.kind == .meanDifference)
    #expect(abs(found.effect - 2.0) < 0.1)
    #expect(found.interval.lowerBound > 0)
    #expect(found.sampleCount == 40)
}

// MARK: - Planted Pearson (numeric target × numeric dimension)

private func plantedPearsonFixture() -> ([Report], [Question]) {
    let questions = [makeQuestion(id: "q-num", prompt: "Hours focused?", type: .number)]
    var rng = SeededLCG(seed: 7)
    var reports: [Report] = []
    for index in 0..<40 {
        let answer = Double(index % 12) + 1
        let noise = Double(rng.next() % 400)
        reports.append(makeReport(
            date: day(index),
            responses: [makeResponse(question: "q-num", numeric: String(answer))],
            health: [HealthReading(type: "steps", value: 1_000 * answer + noise,
                                   unit: "count")]))
    }
    return (reports, questions)
}

@Test func plantedPearsonSurfacesAsStrongCorrelation() throws {
    let (reports, questions) = plantedPearsonFixture()
    let result = CorrelationEngine.compute(questionID: "q-num", reports: reports,
                                           questions: questions)
    // Number questions have exactly one target, labeled by the prompt.
    #expect(result?.targets.count == 1)
    #expect(result?.isTruncated == false)
    let stepsRow = try #require(row(result, .steps))
    let found = try #require(finding(stepsRow), "expected a finding, got \(stepsRow.outcome)")
    #expect(found.kind == .pearson)
    #expect(found.effect > 0.8)
    #expect(found.tier == .strong)
    #expect(found.sampleCount == 40)
}

// MARK: - Noise yields explicit nulls, never findings

@Test func seededNoiseYieldsExplicitNullsNotFindings() throws {
    let questions = [
        makeQuestion(id: "q-yes", prompt: "Happy?", type: .yesNo, choices: ["Yes", "No"]),
        makeQuestion(id: "q-who", prompt: "Who?", type: .people),
    ]
    var rng = SeededLCG(seed: 99)
    var reports: [Report] = []
    for index in 0..<80 {
        let yes = rng.next() % 2 == 0
        let present = rng.next() % 2 == 0
        let steps = 3_000 + Double(rng.next() % 4_000)
        reports.append(makeReport(
            date: day(index),
            responses: [
                makeResponse(question: "q-yes", options: [yes ? "Yes" : "No"]),
                makeResponse(question: "q-who", tokens: present ? ["Noise"] : []),
            ],
            health: [HealthReading(type: "steps", value: steps, unit: "count")]))
    }
    let result = try #require(CorrelationEngine.compute(questionID: "q-yes",
                                                        reports: reports,
                                                        questions: questions))
    var sawNull = false
    for target in result.targets {
        for correlationRow in target.rows {
            if case .finding = correlationRow.outcome {
                Issue.record("noise produced a finding on \(correlationRow.dimension)")
            }
            if case .noReliableLink = correlationRow.outcome { sawNull = true }
        }
    }
    #expect(sawNull, "met-minimum noise rows must be explicit nulls")
}

// MARK: - Benjamini–Hochberg multiplicity

/// One planted person effect (Angela, p ≈ 0.004) among a marginal one (Bob,
/// p ≈ 0.018 — uncorrected-significant AND above the effect floor) and six
/// balanced noise people. With 8 tested person rows, BH at q = 0.05 admits
/// Angela (rank 1: 0.004 ≤ 0.00625) and rejects Bob (rank 2: 0.018 > 0.0125).
/// This test fails if BH is ever swapped for naive per-comparison gating.
@Test func benjaminiHochbergAdmitsOnlyThePlantedEffect() throws {
    let questions = [
        makeQuestion(id: "q-yes", prompt: "Happy?", type: .yesNo, choices: ["Yes", "No"]),
        makeQuestion(id: "q-who", prompt: "Who?", type: .people),
    ]
    let noisePeople = ["Carol", "Dave", "Erin", "Frank", "Grace", "Henry"]
    var reports: [Report] = []
    for index in 0..<60 {
        let yes = index < 30
        var tokens: [String] = []
        // Angela: 25 present (18 yes / 7 no) → 72% vs 34% absent.
        if index < 18 || (index >= 30 && index < 37) { tokens.append("Angela") }
        // Bob: 25 present (17 yes / 8 no) → 68% vs 37% absent, p ≈ 0.018.
        if index < 17 || (index >= 30 && index < 38) { tokens.append("Bob") }
        // Balanced noise: 24 present (12 yes / 12 no) → 50% vs 50%.
        if (index >= 18 && index < 30) || (index >= 36 && index < 48) {
            tokens.append(contentsOf: noisePeople)
        }
        reports.append(makeReport(date: day(index), responses: [
            makeResponse(question: "q-yes", options: [yes ? "Yes" : "No"]),
            makeResponse(question: "q-who", tokens: tokens),
        ]))
    }
    let result = try #require(CorrelationEngine.compute(questionID: "q-yes",
                                                        reports: reports,
                                                        questions: questions))
    let personRows = result.targets[0].rows.filter {
        if case .person = $0.dimension { return true }
        return false
    }
    let findings = personRows.filter { if case .finding = $0.outcome { return true }
                                       return false }
    #expect(findings.count == 1)
    #expect(findings.first?.dimension == .person(name: "Angela"))
    let bob = try #require(row(result, .person(name: "Bob")))
    guard case .noReliableLink = bob.outcome else {
        Issue.record("Bob must be BH-rejected into an explicit null, got \(bob.outcome)")
        return
    }
}

// MARK: - Effect floor

@Test func belowEffectFloorStaysNullDespiteSignificance() throws {
    // Rate delta 0.08 (10% vs 2%) with 200 reports per side: p ≈ 0.0008 —
    // "significant" — but below the 0.15 floor, so it stays an explicit null.
    let questions = [
        makeQuestion(id: "q-yes", prompt: "Happy?", type: .yesNo, choices: ["Yes", "No"]),
        makeQuestion(id: "q-who", prompt: "Who?", type: .people),
    ]
    var reports: [Report] = []
    for index in 0..<400 {
        let present = index < 200
        let yes = present ? index < 20 : index < 204
        reports.append(makeReport(date: day(index), responses: [
            makeResponse(question: "q-yes", options: [yes ? "Yes" : "No"]),
            makeResponse(question: "q-who", tokens: present ? ["Angela"] : []),
        ]))
    }
    let result = CorrelationEngine.compute(questionID: "q-yes", reports: reports,
                                           questions: questions)
    let personRow = try #require(row(result, .person(name: "Angela")))
    guard case .noReliableLink(let sampleCount) = personRow.outcome else {
        Issue.record("below-floor effect must be a null, got \(personRow.outcome)")
        return
    }
    #expect(sampleCount == 400)
}

// MARK: - Insufficient data is explicit

@Test func insufficientDataRowsCarryHaveAndNeeded() throws {
    let questions = [
        makeQuestion(id: "q-yes", prompt: "Happy?", type: .yesNo, choices: ["Yes", "No"]),
        makeQuestion(id: "q-who", prompt: "Who?", type: .people),
    ]
    var reports: [Report] = []
    for index in 0..<60 {
        reports.append(makeReport(date: day(index), responses: [
            makeResponse(question: "q-yes", options: [index % 2 == 0 ? "Yes" : "No"]),
            makeResponse(question: "q-who", tokens: index < 4 ? ["Rare"] : []),
        ]))
    }
    let result = CorrelationEngine.compute(questionID: "q-yes", reports: reports,
                                           questions: questions)
    let rare = try #require(row(result, .person(name: "Rare")))
    #expect(rare.outcome == .insufficientData(have: 4, needed: 10))
}

@Test func insufficientPairsForPearsonAreExplicit() throws {
    // Sleep readings on only 12 of 40 answered reports: the numeric×numeric
    // pairing needs 20 jointly-defined reports.
    let questions = [makeQuestion(id: "q-num", prompt: "Hours focused?", type: .number)]
    var reports: [Report] = []
    for index in 0..<40 {
        let health = index < 12
            ? [HealthReading(type: "sleepCore", value: 7 * 3600, unit: "s")] : []
        reports.append(makeReport(
            date: day(index),
            responses: [makeResponse(question: "q-num", numeric: "\(index % 10)")],
            health: health))
    }
    let result = CorrelationEngine.compute(questionID: "q-num", reports: reports,
                                           questions: questions)
    let sleep = try #require(row(result, .sleepHours))
    #expect(sleep.outcome == .insufficientData(have: 12, needed: 20))
}

// MARK: - Missing data never masquerades as absence

@Test func missingSleepDataDoesNotFabricateADifference() throws {
    // Only Yes-reports carry sleep readings: the sleep universe is those 30
    // reports, so the No side is empty — insufficient, never a finding.
    let questions = [makeQuestion(id: "q-yes", prompt: "Rested?", type: .yesNo,
                                  choices: ["Yes", "No"])]
    var reports: [Report] = []
    for index in 0..<60 {
        let yes = index < 30
        let health = yes
            ? [HealthReading(type: "sleepCore", value: 8 * 3600, unit: "s")] : []
        reports.append(makeReport(
            date: day(index),
            responses: [makeResponse(question: "q-yes", options: [yes ? "Yes" : "No"])],
            health: health))
    }
    let result = CorrelationEngine.compute(questionID: "q-yes", reports: reports,
                                           questions: questions)
    let sleep = try #require(row(result, .sleepHours))
    #expect(sleep.outcome == .insufficientData(have: 0, needed: 10))
}

@Test func personEligibilityCountsOnlyAnsweredReports() throws {
    // The people question is adopted mid-history: the first 30 reports never
    // answered it, so the person comparison runs over the answered 30 only.
    let questions = [
        makeQuestion(id: "q-yes", prompt: "Happy?", type: .yesNo, choices: ["Yes", "No"]),
        makeQuestion(id: "q-who", prompt: "Who?", type: .people),
    ]
    var reports: [Report] = []
    for index in 0..<30 {  // pre-adoption: q-yes only
        reports.append(makeReport(date: day(index), responses: [
            makeResponse(question: "q-yes", options: [index % 2 == 0 ? "Yes" : "No"]),
        ]))
    }
    for index in 30..<60 {  // post-adoption, Zed balanced against the answer
        let yes = index % 2 == 0
        let zed = index < 42
        reports.append(makeReport(date: day(index), responses: [
            makeResponse(question: "q-yes", options: [yes ? "Yes" : "No"]),
            makeResponse(question: "q-who", tokens: zed ? ["Zed"] : []),
        ]))
    }
    let result = CorrelationEngine.compute(questionID: "q-yes", reports: reports,
                                           questions: questions)
    let zed = try #require(row(result, .person(name: "Zed")))
    guard case .noReliableLink(let sampleCount) = zed.outcome else {
        Issue.record("balanced person must be a null, got \(zed.outcome)")
        return
    }
    #expect(sampleCount == 30, "universe is the answered era, never all 60")
}

// MARK: - Self-pairing exclusion

@Test func peopleQuestionTargetSkipsItsOwnPersonDimensions() throws {
    let questions = [makeQuestion(id: "q-who", prompt: "Who?", type: .people)]
    var reports: [Report] = []
    for index in 0..<60 {
        reports.append(makeReport(date: day(index), responses: [
            makeResponse(question: "q-who", tokens: index % 2 == 0 ? ["Angela"] : ["Bob"]),
        ]))
    }
    let result = try #require(CorrelationEngine.compute(questionID: "q-who",
                                                        reports: reports,
                                                        questions: questions))
    #expect(!result.targets.isEmpty)
    for target in result.targets {
        for correlationRow in target.rows {
            if case .person = correlationRow.dimension {
                Issue.record("self-derived person dimension leaked: \(correlationRow.dimension)")
            }
        }
    }
}

// MARK: - Time zones (wall-clock honesty)

@Test func timeOfDayUsesTheReportsOwnTimeZone() throws {
    // All reports share one UTC instant (00:00Z): Tokyo files are 09:00
    // (Morning), Los Angeles files are 17:00 the previous day (Evening).
    // Yes iff Tokyo, so the Morning row is a perfect positive rate difference
    // and Evening its mirror — impossible unless buckets honor the report's
    // own zone.
    let questions = [makeQuestion(id: "q-yes", prompt: "Happy?", type: .yesNo,
                                  choices: ["Yes", "No"])]
    let midnightUTC = Date(timeIntervalSince1970: 1_780_012_800)
    var reports: [Report] = []
    for index in 0..<60 {
        let tokyo = index < 30
        reports.append(makeReport(
            date: midnightUTC.addingTimeInterval(Double(index)),
            responses: [makeResponse(question: "q-yes", options: [tokyo ? "Yes" : "No"])],
            timeZone: tokyo ? "Asia/Tokyo" : "America/Los_Angeles",
            id: "report-tz-\(index)"))
    }
    let result = CorrelationEngine.compute(questionID: "q-yes", reports: reports,
                                           questions: questions)
    let morning = try #require(finding(row(result, .timeOfDay(bucket: "Morning"))))
    #expect(abs(morning.effect - 1.0) < 0.001)
    let evening = try #require(finding(row(result, .timeOfDay(bucket: "Evening"))))
    #expect(abs(evening.effect - (-1.0)) < 0.001)
}

// MARK: - Connection categories (plan 26 taxonomy, merged)

@Test func connectionDimensionsUseDisplayNamesAndSkipUnknownRaws() throws {
    let questions = [makeQuestion(id: "q-yes", prompt: "Happy?", type: .yesNo,
                                  choices: ["Yes", "No"])]
    var reports: [Report] = []
    for index in 0..<60 {
        let connection: Int? = switch index {
        case 0..<20: 1     // Wi-Fi
        case 20..<40: 0    // Cellular
        case 40..<50: 5    // LTE (plan 26 granular raw)
        default: 99        // unknown raw — excluded, consistent with
        }                  // Report.connectionType returning nil
        reports.append(makeReport(
            date: day(index),
            responses: [makeResponse(question: "q-yes",
                                     options: [index % 2 == 0 ? "Yes" : "No"])],
            connection: connection))
    }
    let result = try #require(CorrelationEngine.compute(questionID: "q-yes",
                                                        reports: reports,
                                                        questions: questions))
    let labels = result.targets[0].rows.compactMap { correlationRow -> String? in
        if case .connection(let label) = correlationRow.dimension { return label }
        return nil
    }
    #expect(Set(labels) == ["Wi-Fi", "Cellular", "LTE"])
}

// MARK: - Eligibility + determinism

@Test func eligibleQuestionIDsFilterKindAndCountAndOrderDeterministically() {
    let questions = [
        makeQuestion(id: "q-a", prompt: "Zebra?", type: .yesNo, choices: ["Yes", "No"]),
        makeQuestion(id: "q-b", prompt: "Apples?", type: .yesNo, choices: ["Yes", "No"]),
        makeQuestion(id: "q-few", prompt: "Rarely answered?", type: .number),
        makeQuestion(id: "q-loc", prompt: "Where?", type: .location),
        makeQuestion(id: "q-note", prompt: "Notes?", type: .note),
        makeQuestion(id: "q-time", prompt: "When did you wake?", type: .time),
    ]
    var reports: [Report] = []
    for index in 0..<25 {
        var responses = [
            makeResponse(question: "q-a", options: ["Yes"]),
            makeResponse(question: "q-b", options: ["No"]),
            makeResponse(question: "q-loc", place: "Office"),
        ]
        if index < 19 { responses.append(makeResponse(question: "q-few", numeric: "3")) }
        reports.append(makeReport(date: day(index), responses: responses))
    }
    // A draft answering everything must not tip q-few over the threshold.
    reports.append(makeReport(date: day(100), responses: [
        makeResponse(question: "q-few", numeric: "4"),
    ], isDraft: true))

    let ids = CorrelationEngine.eligibleQuestionIDs(reports: reports, questions: questions)
    // Both yesNo questions have 25 answers — tie broken by prompt ascending.
    #expect(ids == ["q-b", "q-a"])
    #expect(CorrelationEngine.compute(questionID: "q-few", reports: reports,
                                      questions: questions) == nil)
    #expect(CorrelationEngine.compute(questionID: "q-loc", reports: reports,
                                      questions: questions) == nil)
    #expect(CorrelationEngine.compute(questionID: "unknown", reports: reports,
                                      questions: questions) == nil)
}

@Test func computeIsInputOrderInvariant() throws {
    let (reports, questions) = plantedRateFixture()
    let forward = CorrelationEngine.compute(questionID: "q-yes", reports: reports,
                                            questions: questions)
    let backward = CorrelationEngine.compute(questionID: "q-yes",
                                             reports: reports.reversed(),
                                             questions: questions)
    #expect(forward != nil)
    #expect(forward == backward)
}

@Test func multiAnswerTargetsAreCappedWithTruncationFlag() throws {
    let questions = [makeQuestion(id: "q-doing", prompt: "Doing?", type: .tokens)]
    let tokens = (0..<10).map { "token\($0)" }
    var reports: [Report] = []
    for index in 0..<40 {
        // Token k appears on 40 − k reports so the cap picks a deterministic
        // top 8 by answer count.
        let present = tokens.enumerated().compactMap { offset, token in
            index < 40 - offset ? token : nil
        }
        reports.append(makeReport(date: day(index), responses: [
            makeResponse(question: "q-doing", tokens: present),
        ]))
    }
    let result = try #require(CorrelationEngine.compute(questionID: "q-doing",
                                                        reports: reports,
                                                        questions: questions))
    #expect(result.targets.count == 8)
    #expect(result.isTruncated)
    #expect(result.targets.map(\.label) == (0..<8).map { "token\($0)" })
}

@Test func multipleChoiceYieldsOneTargetPerChoice() throws {
    let questions = [makeQuestion(id: "q-color", prompt: "Color?", type: .multipleChoice,
                                  choices: ["Red", "Green", "Blue"])]
    var reports: [Report] = []
    for index in 0..<30 {
        let choice = ["Red", "Green", "Blue"][index % 3]
        reports.append(makeReport(date: day(index), responses: [
            makeResponse(question: "q-color", options: [choice]),
        ]))
    }
    let result = try #require(CorrelationEngine.compute(questionID: "q-color",
                                                        reports: reports,
                                                        questions: questions))
    #expect(result.targets.count == 3)
    #expect(result.isTruncated == false)
    #expect(Set(result.targets.map(\.label)) == ["Red", "Green", "Blue"])
}

@Test func draftsAreExcludedFromCompute() {
    let (reports, questions) = plantedRateFixture()
    let drafted = reports.map { report -> Report in
        report.isDraft = true
        return report
    }
    #expect(CorrelationEngine.compute(questionID: "q-yes", reports: drafted,
                                      questions: questions) == nil)
}

// MARK: - Person registry resolution (plan 22)

@Test func personDimensionsResolveAliasesThroughRegistry() throws {
    let questions = [
        makeQuestion(id: "q-yes", prompt: "Happy?", type: .yesNo, choices: ["Yes", "No"]),
        makeQuestion(id: "q-who", prompt: "Who?", type: .people),
    ]
    var reports: [Report] = []
    for index in 0..<60 {
        let withHer = index < 25
        let yes = index < 18 || (index >= 25 && index < 33)
        // Alternate between the canonical name and the alias — each alone is
        // below the side guard; resolved they form one 25-report dimension.
        let name = index % 2 == 0 ? "Angela" : "Angie"
        reports.append(makeReport(date: day(index), responses: [
            makeResponse(question: "q-yes", options: [yes ? "Yes" : "No"]),
            makeResponse(question: "q-who", tokens: withHer ? [name] : []),
        ]))
    }
    let angela = PersonEntity()
    angela.text = "Angela"
    angela.alternateNames = ["Angie"]

    let resolved = CorrelationEngine.compute(questionID: "q-yes", reports: reports,
                                             questions: questions, people: [angela])
    #expect(finding(row(resolved, .person(name: "Angela"))) != nil)
    #expect(row(resolved, .person(name: "Angie")) == nil)
}
