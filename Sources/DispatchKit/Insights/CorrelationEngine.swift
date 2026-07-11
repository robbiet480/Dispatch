import Foundation

/// Per-question correlation drill-in (plan 34, issue #19). Exhaustive over
/// context dimensions with EXPLICIT nulls: every dimension yields a finding,
/// a no-reliable-link row, or an insufficient-data row. THE HONESTY GUARDS
/// ARE THE FEATURE — see the threshold constants; nothing surfaces as a
/// finding below them, and nothing below them is silently hidden either.
///
/// Methods by target × dimension type (all closed-form, deterministic):
/// - binary × binary → rate difference, Newcombe MOVER 95% CI, pooled
///   two-proportion z p-value;
/// - binary × numeric (either orientation) → difference of means, Welch's t
///   CI/p, effect floor on the standardized difference (|Δ| / combined-sample
///   SD — the InsightsEngine convention);
/// - numeric × numeric → Pearson r with Fisher-z CI/p.
/// All p-values within one drill-in pass Benjamini–Hochberg at
/// `falseDiscoveryRate` — a drill-in tests dozens of dimensions, and
/// uncorrected gating would manufacture ≈1.5 false findings per question.
///
/// DECISION (logged, same as InsightsEngine): correlations always compute
/// over ALL filed reports, never the home screen's filtered subset —
/// filtering first invites spurious conclusions from tiny subsets, defeating
/// the sample-size guards.
public enum CorrelationEngine {
    // MARK: - Honesty guards (documented thresholds — tests pin the literals)

    /// Reports required on EACH side of every binary split.
    public static let minimumSideCount = 10
    /// Jointly-defined reports required for numeric×numeric Pearson.
    public static let minimumPairCount = 20
    /// Answered filed reports before a question is drill-in eligible at all.
    public static let minimumEligibleAnswers = 20
    /// Effect floors — below floor is an explicit null, never a finding.
    public static let minimumRateDelta = 0.15
    public static let minimumStandardizedDifference = 0.35
    public static let minimumPearsonR = 0.30
    /// Benjamini–Hochberg false discovery rate (q).
    public static let falseDiscoveryRate = 0.05
    /// Interval level (display + gate).
    public static let confidence = 0.95
    /// Cap per multi-answer question (choices/tokens/people targets).
    public static let maximumTargets = 8
    public static let maximumPeopleDimensions = 8
    public static let maximumPlaceDimensions = 8

    /// Standing correlation-≠-causation copy — rendered verbatim by every UI.
    public static let causationDisclaimer =
        "These are correlations in your own history, not causes. Filing "
        + "patterns, seasons, and habits all move together — no comparison "
        + "here can say which one is behind the other."

    /// Question kinds that can be drill-in targets in v1. `location`/`note`
    /// have no natural scalar or binary reading; `time` (plan 28) needs
    /// circular statistics — logged as a follow-up.
    private static let targetKinds: Set<QuestionType> =
        [.yesNo, .number, .multipleChoice, .tokens, .people]

    // MARK: - Eligibility

    /// Question IDs with ≥ `minimumEligibleAnswers` answered filed reports,
    /// v1 target kinds only, deterministic order (answer count descending,
    /// prompt ascending, id tiebreak).
    public static func eligibleQuestionIDs(reports: [Report],
                                           questions: [Question]) -> [String] {
        eligibleQuestions(reports: reports, questions: questions).map(\.id)
    }

    /// Eligible questions WITH their answered-report counts, in the same
    /// deterministic order as `eligibleQuestionIDs`. A single pass over all
    /// responses builds every count — callers (the Insights drill-in list)
    /// use these directly instead of re-scanning reports per question, and
    /// the caption count is exactly the count that decided eligibility.
    public static func eligibleQuestions(reports: [Report],
                                         questions: [Question]) -> [(id: String, count: Int)] {
        let filed = sortedFiled(reports)
        let resolve = questionResolver(questions)
        var counts: [String: Int] = [:]
        for report in filed {
            for response in report.responses ?? [] {
                guard let question = resolve(response),
                      targetKinds.contains(question.type),
                      isAnswered(response, type: question.type) else { continue }
                counts[question.uniqueIdentifier, default: 0] += 1
            }
        }
        let byID = Dictionary(questions.map { ($0.uniqueIdentifier, $0) },
                              uniquingKeysWith: { first, _ in first })
        return counts.filter { $0.value >= minimumEligibleAnswers }
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                let lhsPrompt = byID[lhs.key]?.prompt ?? ""
                let rhsPrompt = byID[rhs.key]?.prompt ?? ""
                if lhsPrompt != rhsPrompt { return lhsPrompt < rhsPrompt }
                return lhs.key < rhs.key
            }
            .map { (id: $0.key, count: $0.value) }
    }

    // MARK: - Compute

    /// nil when the question is unknown, not a v1 target kind, or under the
    /// `minimumEligibleAnswers` gate.
    public static func compute(questionID: String, reports: [Report],
                               questions: [Question],
                               people: [PersonEntity] = []) -> QuestionCorrelations? {
        let filed = sortedFiled(reports)
        let resolve = questionResolver(questions)
        guard let question = questions.first(where: { $0.uniqueIdentifier == questionID }),
              targetKinds.contains(question.type) else { return nil }

        let registry = people.sorted { $0.uniqueIdentifier < $1.uniqueIdentifier }
        let (targets, isTruncated) = buildTargets(question: question, filed: filed,
                                                  resolve: resolve, people: registry)
        guard !targets.isEmpty,
              targets[0].eligible.count >= minimumEligibleAnswers else { return nil }

        let dimensions = buildDimensions(filed: filed, resolve: resolve,
                                         people: registry,
                                         excludingOwner: questionID)

        // Phase 1: test every target × dimension pair that clears the sample
        // minimums; collect all p-values for the drill-in-wide BH pass.
        struct Tested {
            var target: Int
            var dimension: Dimension
            var finding: CorrelationFinding
            var standardizedMagnitude: Double
        }
        var tested: [Tested] = []
        var insufficient: [(target: Int, dimension: Dimension,
                            have: Int, needed: Int)] = []
        for (targetIndex, target) in targets.enumerated() {
            for dimension in dimensions {
                switch evaluate(target: target, dimension: dimension) {
                case .tested(let finding, let magnitude):
                    tested.append(Tested(target: targetIndex,
                                         dimension: dimension,
                                         finding: finding,
                                         standardizedMagnitude: magnitude))
                case .insufficient(let have, let needed):
                    insufficient.append((targetIndex, dimension, have, needed))
                }
            }
        }

        // Phase 2: Benjamini–Hochberg over every computed p-value, then
        // classify — a finding requires BH significance AND the effect floor.
        let significant = StatsMath.benjaminiHochberg(pValues: tested.map(\.finding.pValue),
                                                      q: falseDiscoveryRate)
        var rowsByTarget: [[(row: CorrelationRow, sortKey: Double)]] =
            Array(repeating: [], count: targets.count)
        for (index, entry) in tested.enumerated() {
            let magnitude = entry.standardizedMagnitude
            let clearsFloor = clearsEffectFloor(entry.finding)
            let outcome: CorrelationRow.Outcome
            var sortKey = -1.0
            if significant.contains(index) && clearsFloor {
                outcome = .finding(entry.finding)
                sortKey = magnitude
            } else {
                outcome = .noReliableLink(sampleCount: entry.finding.sampleCount)
            }
            rowsByTarget[entry.target].append(
                (CorrelationRow(dimension: entry.dimension.publicDimension,
                                outcome: outcome), sortKey))
        }
        for entry in insufficient {
            rowsByTarget[entry.target].append(
                (CorrelationRow(dimension: entry.dimension.publicDimension,
                                outcome: .insufficientData(have: entry.have,
                                                           needed: entry.needed)), -2))
        }

        // Findings first (standardized magnitude desc, label asc), then
        // explicit nulls, then insufficient rows — each group alphabetical.
        let targetResults = targets.enumerated().map { index, target in
            let rows = rowsByTarget[index].sorted { lhs, rhs in
                if lhs.sortKey != rhs.sortKey { return lhs.sortKey > rhs.sortKey }
                return lhs.row.dimension.displayLabel < rhs.row.dimension.displayLabel
            }
            return TargetCorrelations(label: target.label, rows: rows.map(\.row))
        }
        return QuestionCorrelations(questionID: questionID, prompt: question.prompt,
                                    targets: targetResults, isTruncated: isTruncated)
    }

    // MARK: - Targets

    /// A target is what "the answer" means for one comparison: a binary set
    /// (Yes; chose Red; mentioned coffee; saw Angela) or numeric values.
    private struct Target {
        var label: String
        /// Reports where the owning question was answered.
        var eligible: Set<Int>
        /// Binary targets: reports where the target answer holds.
        var present: Set<Int>
        /// Numeric targets: answer value per report index (empty for binary).
        var values: [Int: Double]
        var isNumeric: Bool
    }

    private static func buildTargets(
        question: Question, filed: [Report],
        resolve: (Response) -> Question?, people: [PersonEntity]
    ) -> (targets: [Target], isTruncated: Bool) {
        var eligible: Set<Int> = []
        var values: [Int: Double] = [:]
        var yesPresent: Set<Int> = []
        var presentByLabel: [String: Set<Int>] = [:]

        for (index, report) in filed.enumerated() {
            for response in report.responses ?? [] {
                guard resolve(response)?.uniqueIdentifier == question.uniqueIdentifier,
                      isAnswered(response, type: question.type) else { continue }
                eligible.insert(index)
                switch question.type {
                case .yesNo:
                    let yesLabel = question.choices.first ?? "Yes"
                    if response.answeredOptions?.first == yesLabel {
                        yesPresent.insert(index)
                    }
                case .number:
                    if let numeric = response.numericResponse,
                       let value = Double(numeric) {
                        values[index] = value
                    }
                case .multipleChoice:
                    for choice in response.answeredOptions ?? [] {
                        presentByLabel[choice, default: []].insert(index)
                    }
                case .people:
                    for token in response.tokens ?? [] {
                        let name = PersonResolver.person(matching: token.text,
                                                         in: people)?.text ?? token.text
                        presentByLabel[name, default: []].insert(index)
                    }
                case .tokens:
                    for token in response.tokens ?? [] {
                        presentByLabel[token.text, default: []].insert(index)
                    }
                default:
                    break
                }
            }
        }

        switch question.type {
        case .yesNo:
            let label = question.choices.first ?? "Yes"
            return ([Target(label: label, eligible: eligible, present: yesPresent,
                            values: [:], isNumeric: false)], false)
        case .number:
            return ([Target(label: question.prompt, eligible: eligible, present: [],
                            values: values, isNumeric: true)], false)
        default:
            // Top targets by answer count, label tiebreak — deterministic.
            let ranked = presentByLabel.sorted { lhs, rhs in
                if lhs.value.count != rhs.value.count {
                    return lhs.value.count > rhs.value.count
                }
                return lhs.key < rhs.key
            }
            let capped = ranked.prefix(maximumTargets).map { label, present in
                Target(label: label, eligible: eligible, present: present,
                       values: [:], isNumeric: false)
            }
            return (Array(capped), ranked.count > maximumTargets)
        }
    }

    // MARK: - Dimensions

    /// Internal dimension: identity + presence/value sets. `publicDimension`
    /// is the wire shape rows carry.
    private struct Dimension {
        var publicDimension: CorrelationRow.Dimension
        /// Binary dimensions: reports where the dimension could meaningfully
        /// be observed (owning question answered / sensor captured / always).
        var eligible: Set<Int>
        /// Binary dimensions: reports where it holds.
        var present: Set<Int>
        /// Numeric dimensions: metric value per report index.
        var values: [Int: Double]
        var isNumeric: Bool
        /// Formats a value of this metric for with/without summaries.
        var format: @Sendable (Double) -> String

        static func binary(_ dimension: CorrelationRow.Dimension,
                           eligible: Set<Int>, present: Set<Int>) -> Dimension {
            Dimension(publicDimension: dimension, eligible: eligible,
                      present: present, values: [:], isNumeric: false,
                      format: { oneDecimal($0) })
        }

        static func numeric(_ dimension: CorrelationRow.Dimension,
                            values: [Int: Double],
                            format: @escaping @Sendable (Double) -> String) -> Dimension {
            Dimension(publicDimension: dimension, eligible: Set(values.keys),
                      present: [], values: values, isNumeric: true, format: format)
        }
    }

    private static let timeBuckets = ["Morning", "Afternoon", "Evening", "Night"]

    private static func timeBucket(hour: Int) -> String {
        switch hour {
        case 5...11: "Morning"
        case 12...16: "Afternoon"
        case 17...21: "Evening"
        default: "Night"
        }
    }

    private static func buildDimensions(
        filed: [Report], resolve: (Response) -> Question?,
        people: [PersonEntity], excludingOwner targetQuestionID: String
    ) -> [Dimension] {
        let allIndices = Set(filed.indices)

        var questionResponded: [String: Set<Int>] = [:]
        var personPresent: [String: Set<Int>] = [:]
        var personOwners: [String: Set<String>] = [:]
        var placePresent: [String: (indices: Set<Int>, text: String)] = [:]
        var placeOwners: [String: Set<String>] = [:]
        var connectionEligible: Set<Int> = []
        var connectionPresent: [ConnectionType: Set<Int>] = [:]
        var bucketPresent: [String: Set<Int>] = [:]
        var sleepHours: [Int: Double] = [:]
        var steps: [Int: Double] = [:]
        var heartRateAvg: [Int: (sum: Double, count: Int)] = [:]
        var restingHeartRate: [Int: (sum: Double, count: Int)] = [:]

        for (index, report) in filed.enumerated() {
            for response in report.responses ?? [] {
                let questionKey = resolve(response)?.uniqueIdentifier
                    ?? "prompt:\(response.questionPrompt)"
                // A payload-less (skipped) people Response — persisted by
                // ReportBuilder with `tokens == nil` — is MISSING the answer,
                // not evidence of absence. Gate on the same `tokens != nil`
                // predicate as `isAnswered` so a skip never masquerades as a
                // person being away and fabricates an absent side.
                if resolve(response)?.type == .people, response.tokens != nil {
                    questionResponded[questionKey, default: []].insert(index)
                    for token in response.tokens ?? [] {
                        let name = PersonResolver.person(matching: token.text,
                                                         in: people)?.text ?? token.text
                        personPresent[name, default: []].insert(index)
                        personOwners[name, default: []].insert(questionKey)
                    }
                }
                if let location = response.locationResponse {
                    questionResponded[questionKey, default: []].insert(index)
                    // Group by venue ID, else text — ReportsOverview/
                    // InsightsEngine convention.
                    let key: String
                    let text: String
                    if let venue = location.foursquareVenueId {
                        key = "venue:\(venue)"
                        text = location.text?.isEmpty == false ? location.text! : "Unknown place"
                    } else if let locationText = location.text, !locationText.isEmpty {
                        key = "text:\(locationText)"
                        text = locationText
                    } else {
                        continue
                    }
                    var entry = placePresent[key] ?? (indices: [], text: text)
                    entry.indices.insert(index)
                    placePresent[key] = entry
                    placeOwners[key, default: []].insert(questionKey)
                }
            }

            // Unknown raws are excluded — consistent with
            // Report.connectionType returning nil for them. Old coarse
            // values and new granular values (plan 26) coexist as distinct
            // categories; no reinterpretation.
            if let connection = report.connectionType {
                connectionEligible.insert(index)
                connectionPresent[connection, default: []].insert(index)
            }

            // Wall-clock honesty: the bucket comes from the report's OWN
            // time zone — a 9 AM report filed in Tokyo is Morning, whatever
            // the phone's current zone.
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: report.timeZoneIdentifier)
                ?? TimeZone(identifier: "GMT")!
            let hour = calendar.component(.hour, from: report.date)
            bucketPresent[timeBucket(hour: hour), default: []].insert(index)

            // Health metrics are defined only when the reading exists — a
            // report without a sleep reading is missing data, not a
            // zero-hour night (the workoutMinutes precedent).
            for reading in report.health {
                if reading.type.hasPrefix("sleep") {
                    sleepHours[index] = (sleepHours[index] ?? 0) + reading.value / 3600
                } else if reading.type == "steps" {
                    steps[index] = (steps[index] ?? 0) + reading.value
                } else if reading.type == "heartRateAvg" {
                    let entry = heartRateAvg[index] ?? (sum: 0, count: 0)
                    heartRateAvg[index] = (entry.sum + reading.value, entry.count + 1)
                } else if reading.type == "restingHeartRate" {
                    let entry = restingHeartRate[index] ?? (sum: 0, count: 0)
                    restingHeartRate[index] = (entry.sum + reading.value, entry.count + 1)
                }
            }
        }

        func owningEligible(_ owners: Set<String>?) -> Set<Int> {
            (owners ?? []).reduce(into: Set<Int>()) { union, key in
                union.formUnion(questionResponded[key] ?? [])
            }
        }

        var dimensions: [Dimension] = []

        // People — capped at the top maximumPeopleDimensions by presence
        // count (name tiebreak). Self-pairing exclusion: a person dimension
        // owned by the target question would only restate the identity
        // function, so it never appears in that question's drill-in.
        let rankedPeople = personPresent
            .filter { !(personOwners[$0.key] ?? []).contains(targetQuestionID) }
            .sorted { lhs, rhs in
                if lhs.value.count != rhs.value.count { return lhs.value.count > rhs.value.count }
                return lhs.key < rhs.key
            }
            .prefix(maximumPeopleDimensions)
        for (name, present) in rankedPeople {
            dimensions.append(.binary(.person(name: name),
                                      eligible: owningEligible(personOwners[name]),
                                      present: present))
        }

        // Places — same cap and self-pairing rule.
        let rankedPlaces = placePresent
            .filter { !(placeOwners[$0.key] ?? []).contains(targetQuestionID) }
            .sorted { lhs, rhs in
                if lhs.value.indices.count != rhs.value.indices.count {
                    return lhs.value.indices.count > rhs.value.indices.count
                }
                return lhs.key < rhs.key
            }
            .prefix(maximumPlaceDimensions)
        for (key, entry) in rankedPlaces {
            dimensions.append(.binary(.place(name: entry.text),
                                      eligible: owningEligible(placeOwners[key]),
                                      present: entry.indices))
        }

        // Connection — one dimension per observed known category, labeled by
        // ConnectionType.displayName (plan 26 merged).
        for connection in ConnectionType.allCases {
            guard let present = connectionPresent[connection] else { continue }
            dimensions.append(.binary(.connection(label: connection.displayName),
                                      eligible: connectionEligible,
                                      present: present))
        }

        // Time of day — every filed report is eligible; exactly one bucket
        // present per report.
        for bucket in timeBuckets {
            dimensions.append(.binary(.timeOfDay(bucket: bucket),
                                      eligible: allIndices,
                                      present: bucketPresent[bucket] ?? []))
        }

        // Health numerics. (hrvSDNN deliberately deferred — ms-scale HRV
        // needs its own literacy copy; logged as a follow-up.)
        dimensions.append(.numeric(.sleepHours, values: sleepHours,
                                   format: { "\(oneDecimal($0)) h" }))
        dimensions.append(.numeric(.steps, values: steps, format: { grouped($0) }))
        dimensions.append(.numeric(.heartRateAvg,
                                   values: heartRateAvg.mapValues { $0.sum / Double($0.count) },
                                   format: { "\(grouped($0)) bpm" }))
        dimensions.append(.numeric(.restingHeartRate,
                                   values: restingHeartRate.mapValues { $0.sum / Double($0.count) },
                                   format: { "\(grouped($0)) bpm" }))
        return dimensions
    }

    // MARK: - Evaluation

    private enum Evaluation {
        case tested(CorrelationFinding, standardizedMagnitude: Double)
        case insufficient(have: Int, needed: Int)
    }

    private static func evaluate(target: Target, dimension: Dimension) -> Evaluation {
        switch (target.isNumeric, dimension.isNumeric) {
        case (false, false):
            return rateDifference(target: target, dimension: dimension)
        case (false, true):
            return meanDifference(
                sideA: target.present,
                universe: target.eligible.intersection(dimension.eligible),
                values: dimension.values, format: dimension.format)
        case (true, false):
            return meanDifference(
                sideA: dimension.present,
                universe: dimension.eligible.intersection(Set(target.values.keys)),
                values: target.values, format: { oneDecimal($0) })
        case (true, true):
            return pearson(target: target, dimension: dimension)
        }
    }

    /// Binary target × binary dimension: P(target | in) − P(target | out).
    private static func rateDifference(target: Target, dimension: Dimension) -> Evaluation {
        let universe = target.eligible.intersection(dimension.eligible)
        let inSide = universe.intersection(dimension.present)
        let outSide = universe.subtracting(dimension.present)
        guard inSide.count >= minimumSideCount, outSide.count >= minimumSideCount else {
            return .insufficient(have: min(inSide.count, outSide.count),
                                 needed: minimumSideCount)
        }
        let inYes = inSide.intersection(target.present).count
        let outYes = outSide.intersection(target.present).count
        let rateIn = Double(inYes) / Double(inSide.count)
        let rateOut = Double(outYes) / Double(outSide.count)
        let effect = rateIn - rateOut
        let interval = StatsMath.newcombeDifferenceInterval(
            successes1: inYes, trials1: inSide.count,
            successes2: outYes, trials2: outSide.count, confidence: confidence)
        let pValue = StatsMath.twoProportionPValue(
            successes1: inYes, trials1: inSide.count,
            successes2: outYes, trials2: outSide.count)
        let finding = CorrelationFinding(
            kind: .rateDifference,
            tier: rateTier(abs(effect)),
            effect: effect,
            interval: interval,
            pValue: pValue,
            withSummary: "\(percent(rateIn)) of \(inSide.count)",
            withoutSummary: "\(percent(rateOut)) of \(outSide.count)",
            sampleCount: universe.count)
        // Normalize magnitudes across kinds by their "strong" tier bound so
        // the row sort compares like with like.
        return .tested(finding, standardizedMagnitude: abs(effect) / 0.40)
    }

    /// Difference of means: `sideA`-split of `values` over `universe`.
    /// Standardized by the combined-sample SD (both sides pooled into ONE
    /// sample — the InsightsEngine convention, conservative).
    private static func meanDifference(
        sideA: Set<Int>, universe: Set<Int>, values: [Int: Double],
        format: @Sendable (Double) -> String
    ) -> Evaluation {
        let measured = universe.intersection(Set(values.keys))
        let withSide = measured.intersection(sideA)
        let withoutSide = measured.subtracting(sideA)
        guard withSide.count >= minimumSideCount,
              withoutSide.count >= minimumSideCount else {
            return .insufficient(have: min(withSide.count, withoutSide.count),
                                 needed: minimumSideCount)
        }
        let withValues = withSide.sorted().map { values[$0]! }
        let withoutValues = withoutSide.sorted().map { values[$0]! }
        let withMean = StatsMath.mean(withValues)
        let withoutMean = StatsMath.mean(withoutValues)
        let delta = withMean - withoutMean
        let spread = StatsMath.standardDeviation(withValues + withoutValues)
        let standardized = spread > 1e-9 ? abs(delta) / spread : 0
        let welch = StatsMath.welch(withValues, withoutValues, confidence: confidence)
        let finding = CorrelationFinding(
            kind: .meanDifference,
            tier: standardizedTier(standardized),
            effect: delta,
            interval: welch.interval,
            pValue: welch.pValue,
            withSummary: "\(format(withMean)) over \(withSide.count)",
            withoutSummary: "\(format(withoutMean)) over \(withoutSide.count)",
            sampleCount: measured.count)
        return .tested(finding, standardizedMagnitude: standardized / 0.8)
    }

    /// Numeric target × numeric dimension: Pearson r over jointly-defined
    /// reports — the only pairing that is a "correlation coefficient" in the
    /// textbook sense.
    private static func pearson(target: Target, dimension: Dimension) -> Evaluation {
        let joint = Set(target.values.keys).intersection(Set(dimension.values.keys))
        guard joint.count >= minimumPairCount else {
            return .insufficient(have: joint.count, needed: minimumPairCount)
        }
        let pairs = joint.sorted().map { (target.values[$0]!, dimension.values[$0]!) }
        let r = StatsMath.pearsonR(pairs)
        let fisher = StatsMath.fisher(r: r, count: pairs.count, confidence: confidence)
        let finding = CorrelationFinding(
            kind: .pearson,
            tier: pearsonTier(abs(r)),
            effect: r,
            interval: fisher.interval,
            pValue: fisher.pValue,
            withSummary: "r = \(twoDecimal(r))",
            withoutSummary: "",
            sampleCount: pairs.count)
        return .tested(finding, standardizedMagnitude: abs(r) / 0.7)
    }

    private static func clearsEffectFloor(_ finding: CorrelationFinding) -> Bool {
        switch finding.kind {
        case .rateDifference: abs(finding.effect) >= minimumRateDelta
        case .meanDifference: finding.tier != .none
        case .pearson: abs(finding.effect) >= minimumPearsonR
        }
    }

    // MARK: - Tiers (weak / moderate / strong — the qualitative word sits
    // NEXT TO the real numbers, never instead of them)

    private static func rateTier(_ magnitude: Double) -> CorrelationFinding.Tier {
        if magnitude >= 0.40 { return .strong }
        if magnitude >= 0.25 { return .moderate }
        if magnitude >= minimumRateDelta { return .weak }
        return .none
    }

    private static func standardizedTier(_ magnitude: Double) -> CorrelationFinding.Tier {
        if magnitude >= 0.8 { return .strong }
        if magnitude >= 0.5 { return .moderate }
        if magnitude >= minimumStandardizedDifference { return .weak }
        return .none
    }

    private static func pearsonTier(_ magnitude: Double) -> CorrelationFinding.Tier {
        if magnitude >= 0.7 { return .strong }
        if magnitude >= 0.5 { return .moderate }
        if magnitude >= minimumPearsonR { return .weak }
        return .none
    }

    // MARK: - Shared plumbing

    private static func sortedFiled(_ reports: [Report]) -> [Report] {
        reports.filter { !$0.isDraft }
            .sorted { lhs, rhs in
                if lhs.date != rhs.date { return lhs.date < rhs.date }
                return lhs.uniqueIdentifier < rhs.uniqueIdentifier
            }
    }

    private static func questionResolver(_ questions: [Question])
        -> (Response) -> Question? {
        let byIdentifier = Dictionary(questions.map { ($0.uniqueIdentifier, $0) },
                                      uniquingKeysWith: { first, _ in first })
        let byPrompt = Dictionary(questions.map { ($0.prompt, $0) },
                                  uniquingKeysWith: { first, _ in first })
        return { response in
            if let identifier = response.questionIdentifier { return byIdentifier[identifier] }
            return byPrompt[response.questionPrompt]
        }
    }

    /// "Answered" for TARGET/eligibility purposes: yes/no needs an option,
    /// number a parseable value, choice a non-empty selection, and
    /// tokens/people at least one named token. An empty ("nobody") token list
    /// yields no per-token target, so counting it toward drill-in eligibility
    /// would surface a question as eligible that `compute` can't drill into
    /// (zero targets → nil). Requiring a named token keeps eligibility and
    /// drillability in lock-step. NOTE: the people-DIMENSION universe uses a
    /// different, looser gate (`tokens != nil` in buildDimensions) — there a
    /// "nobody" report is a valid observation of that person's absence.
    public static func isAnswered(_ response: Response, type: QuestionType) -> Bool {
        switch type {
        case .yesNo:
            response.answeredOptions?.first != nil
        case .number:
            response.numericResponse.flatMap(Double.init) != nil
        case .multipleChoice:
            response.answeredOptions?.isEmpty == false
        case .tokens, .people:
            response.tokens?.isEmpty == false
        default:
            false
        }
    }

    // MARK: - Formatting (locale-pinned, deterministic)

    private static func percent(_ rate: Double) -> String {
        "\(Int((rate * 100).rounded()))%"
    }

    private static func grouped(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value.rounded()))
            ?? String(Int(value.rounded()))
    }

    private static func oneDecimal(_ value: Double) -> String {
        String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func twoDecimal(_ value: Double) -> String {
        String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}

// MARK: - Output types

public struct QuestionCorrelations: Equatable, Sendable {
    public var questionID: String
    public var prompt: String
    /// One group per target (yesNo/number → exactly one; choices/tokens/
    /// people → top `maximumTargets` by answer count). `isTruncated` drives
    /// the "showing your N most common answers" caption.
    public var targets: [TargetCorrelations]
    public var isTruncated: Bool
}

public struct TargetCorrelations: Equatable, Sendable {
    /// e.g. "Yes", "Red", "coffee" — or the prompt itself for number questions.
    public var label: String
    public var rows: [CorrelationRow]
}

public struct CorrelationRow: Equatable, Sendable {
    public enum Dimension: Equatable, Sendable {
        case person(name: String)
        case place(name: String)
        case connection(label: String)
        /// "Morning" / "Afternoon" / "Evening" / "Night"
        case timeOfDay(bucket: String)
        case sleepHours, steps, heartRateAvg, restingHeartRate

        /// Row title in the drill-in (and the deterministic sort tiebreak).
        public var displayLabel: String {
            switch self {
            case .person(let name): name
            case .place(let name): name
            case .connection(let label): label
            case .timeOfDay(let bucket): bucket
            case .sleepHours: "Sleep"
            case .steps: "Steps"
            case .heartRateAvg: "Average heart rate"
            case .restingHeartRate: "Resting heart rate"
            }
        }
    }

    public var dimension: Dimension
    public var outcome: Outcome

    public enum Outcome: Equatable, Sendable {
        case finding(CorrelationFinding)
        /// Minimums met, tested, and nothing held up (below the effect floor
        /// and/or not BH-significant). `sampleCount` = reports compared.
        case noReliableLink(sampleCount: Int)
        /// Guards not met — have/needed for the binding constraint.
        case insufficientData(have: Int, needed: Int)
    }
}

public struct CorrelationFinding: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case rateDifference, meanDifference, pearson
    }

    /// `none` never leaves the engine — sub-floor comparisons classify as
    /// explicit nulls before rows are built.
    public enum Tier: String, Equatable, Sendable { case none, weak, moderate, strong }

    public var kind: Kind
    public var tier: Tier
    /// Signed raw effect: rate delta in [−1, 1], mean difference in the
    /// metric's unit, or Pearson r.
    public var effect: Double
    /// Confidence interval on `effect` at `CorrelationEngine.confidence`.
    public var interval: ClosedRange<Double>
    public var pValue: Double
    /// e.g. "72% of 25" or "7.2 h over 22"; empty for Pearson findings
    /// (the detail carries r, interval, and n directly).
    public var withSummary: String
    public var withoutSummary: String
    public var sampleCount: Int
}
