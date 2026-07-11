import Foundation

/// Pure, deliberately modest statistics over report data: pairwise
/// associations between categorical signals (yes/no answers, choice options,
/// token/people/place presence, weather condition, Focus name, workout
/// presence) and numeric signals (number answers, steps, ambient dB,
/// State-of-Mind valence, workout minutes, flights climbed).
///
/// Methods: difference of means for categorical×numeric (the delta is
/// reported, not a test statistic) and co-occurrence rates for
/// categorical×categorical.
///
/// THE HONESTY GUARDS ARE THE FEATURE:
/// - minimum sample sizes: ≥10 reports on EACH side of every split;
/// - minimum effect thresholds: trivial deltas are skipped, silence over noise;
/// - capped output: top 8 by normalized effect;
/// - plain "tends to" / "average" language — associations, never causal claims;
/// - deterministic ordering (strength, then sample count, then title).
///
/// DECISION (logged): insights always compute over ALL filed reports, never
/// the home screen's filtered visualization subset — filtering first invites
/// spurious conclusions from tiny subsets, defeating the sample-size guards.
public enum InsightsEngine {
    // MARK: - Guards

    /// Minimum reports on each side of a split (with/without the signal).
    static let minimumSideCount = 10
    /// Minimum standardized mean difference (|Δ| / combined-sample SD — both
    /// sides pooled into ONE sample, not the classic pooled-variance SD) for
    /// categorical×numeric — a "medium" effect; smaller deltas stay silent.
    /// `strength` divides the effect by 2 so two combined-sample SDs map to
    /// full strength.
    static let minimumMeanEffect = 0.5
    /// Minimum absolute rate difference for co-occurrence pairs.
    static let minimumRateDelta = 0.25
    /// Output cap: top insights by normalized effect.
    static let maximumInsights = 8
    /// Bound on categorical signals entering pairwise comparison (top by
    /// presence count, deterministic tiebreak) so the pair space stays O(1).
    static let maximumCategoricalSignals = 24

    // MARK: - Signals

    private struct CategoricalSignal {
        var id: String
        /// Signals sharing a source (e.g. a workout-presence split and the
        /// workout-minutes metric) never pair — they'd only restate themselves.
        var sourceKey: String
        /// Verb phrase for "answer" roles, e.g. `mention “coffee”`,
        /// `answer Yes to “Working?”`, `see Angela`. Nil for context-only
        /// signals (places).
        var verbPhrase: String?
        /// Context phrase for "condition" roles, e.g. `at Office`,
        /// `when the weather is Rain`, `in the Work Focus`.
        var contextPhrase: String?
        /// Report indices where the signal is present / where it could
        /// meaningfully be present (answered, sensor captured, …). Absence is
        /// only counted inside `eligible` so missing data never masquerades
        /// as a "no".
        var present: Set<Int>
        var eligible: Set<Int>
    }

    private struct NumericSignal {
        var id: String
        var sourceKey: String
        /// Unit noun for count-like metrics ("steps", "flights climbed") —
        /// phrased as "average 2,400 more steps". Nil metrics use the
        /// higher/lower phrasing via `subject`.
        var noun: String?
        /// Subject for higher/lower phrasing, e.g. `Your mood valence`,
        /// `Your answer to “Hours slept?”`.
        var subject: String
        var values: [Int: Double]
        var format: @Sendable (Double) -> String
    }

    // MARK: - Compute

    /// Computes insights over ALL reports (drafts excluded). `questions`
    /// supplies the type split and choice labels, exactly as in DigestStats.
    /// `people` is the person registry (plan 22): person signals resolve
    /// alternate names to one canonical person, displayed by current name.
    public static func compute(reports: [Report], questions: [Question],
                               people: [PersonEntity] = []) -> [Insight] {
        // Stable report order so indices (and therefore every set/dictionary
        // downstream) are reproducible for identical input.
        let filed = reports.filter { !$0.isDraft }
            .sorted { lhs, rhs in
                if lhs.date != rhs.date { return lhs.date < rhs.date }
                return lhs.uniqueIdentifier < rhs.uniqueIdentifier
            }
        guard filed.count >= minimumSideCount * 2 else { return [] }

        let byIdentifier = Dictionary(questions.map { ($0.uniqueIdentifier, $0) },
                                      uniquingKeysWith: { first, _ in first })
        let byPrompt = Dictionary(questions.map { ($0.prompt, $0) },
                                  uniquingKeysWith: { first, _ in first })
        func question(for response: Response) -> Question? {
            if let identifier = response.questionIdentifier { return byIdentifier[identifier] }
            return byPrompt[response.questionPrompt]
        }

        // Deterministic resolution order regardless of fetch order.
        let registry = people.sorted { $0.uniqueIdentifier < $1.uniqueIdentifier }
        var categoricals = buildCategoricalSignals(filed: filed, question: question(for:),
                                                   people: registry)
        let numerics = buildNumericSignals(filed: filed, question: question(for:))

        // Prefilter + cap: keep signals that can possibly pass the side
        // guards, then bound the pair space (most-present first, id tiebreak).
        // `present ⊆ eligible` by construction for every signal kind, so the
        // "without" side is plain count arithmetic — no set allocation.
        categoricals = categoricals.filter {
            $0.present.count >= minimumSideCount &&
            $0.eligible.count - $0.present.count >= minimumSideCount
        }
        categoricals.sort { lhs, rhs in
            if lhs.present.count != rhs.present.count { return lhs.present.count > rhs.present.count }
            return lhs.id < rhs.id
        }
        categoricals = Array(categoricals.prefix(maximumCategoricalSignals))

        var insights: [Insight] = []
        insights += meanDifferenceInsights(categoricals: categoricals, numerics: numerics)
        insights += cooccurrenceInsights(categoricals: categoricals)

        insights.sort { lhs, rhs in
            if lhs.strength != rhs.strength { return lhs.strength > rhs.strength }
            if lhs.sampleCount != rhs.sampleCount { return lhs.sampleCount > rhs.sampleCount }
            if lhs.title != rhs.title { return lhs.title < rhs.title }
            return lhs.detail < rhs.detail
        }

        // Per-kind quota: co-occurrence candidates grow combinatorially
        // (every token↔token pair), so one kind could flood all
        // `maximumInsights` slots and crowd the other out entirely. Each kind
        // may take at most the cap minus the slots the OTHER kind can actually
        // fill (itself capped at half), so mixed candidates keep kind
        // diversity (≥ half the slots per kind when both are plentiful) while
        // single-kind candidates still fill every slot.
        var availableByKind: [Insight.Kind: Int] = [:]
        for insight in insights { availableByKind[insight.kind, default: 0] += 1 }
        func quota(for kind: Insight.Kind) -> Int {
            let others = insights.count - (availableByKind[kind] ?? 0)
            return maximumInsights - min(others, maximumInsights / 2)
        }
        var takenByKind: [Insight.Kind: Int] = [:]
        var selected: [Insight] = []
        for insight in insights {
            guard selected.count < maximumInsights else { break }
            guard takenByKind[insight.kind, default: 0] < quota(for: insight.kind) else { continue }
            takenByKind[insight.kind, default: 0] += 1
            selected.append(insight)
        }
        return selected
    }

    // MARK: - Signal extraction

    /// State-of-Mind questions share the `mood` source with the valence
    /// metric: "mood valence runs higher when you answer Good to Mood?" would
    /// only restate the valence mapping, so same-source pairing silences it.
    private static func sourceKey(for question: Question) -> String {
        question.stateOfMindKind != nil ? "mood" : "question:\(question.uniqueIdentifier)"
    }

    private static func buildCategoricalSignals(
        filed: [Report], question: (Response) -> Question?, people: [PersonEntity] = []
    ) -> [CategoricalSignal] {
        let allIndices = Set(filed.indices)

        var yesNoEligible: [String: Set<Int>] = [:]
        var yesNoPresent: [String: Set<Int>] = [:]
        var yesNoMeta: [String: (prompt: String, yesLabel: String, sourceKey: String)] = [:]

        var choiceEligible: [String: Set<Int>] = [:]
        var choicePresent: [String: Set<Int>] = [:]  // key "qid|choice"
        var choiceMeta: [String: (prompt: String, choice: String, questionKey: String,
                                  sourceKey: String)] = [:]

        // Token/person/place eligibility mirrors `yesNoEligible`: a report is
        // eligible only when the OWNING question has a response there, so a
        // question adopted mid-history never counts its pre-question era as
        // "without" — missing data must not masquerade as absence. Owners map
        // each signal to the question(s) it appeared under; eligibility is the
        // union of those questions' response sets.
        var questionResponded: [String: Set<Int>] = [:]
        var tokenPresent: [String: Set<Int>] = [:]
        var tokenOwners: [String: Set<String>] = [:]
        var personPresent: [String: Set<Int>] = [:]
        var personOwners: [String: Set<String>] = [:]
        var placePresent: [String: (indices: Set<Int>, text: String)] = [:]
        var placeOwners: [String: Set<String>] = [:]

        var weatherEligible: Set<Int> = []
        var weatherPresent: [String: Set<Int>] = [:]
        var focusEligible: Set<Int> = []
        var focusPresent: [String: Set<Int>] = [:]
        var workoutPresent: Set<Int> = []

        for (index, report) in filed.enumerated() {
            for response in report.responses ?? [] {
                let resolved = question(response)
                let type = resolved?.type
                // Deleted questions fall back to the prompt so their token
                // signals still get honest eligibility.
                let questionKey = resolved?.uniqueIdentifier
                    ?? "prompt:\(response.questionPrompt)"
                switch type {
                case .yesNo:
                    guard let resolved, let answer = response.answeredOptions?.first else { break }
                    let key = resolved.uniqueIdentifier
                    let yesLabel = resolved.choices.first ?? "Yes"
                    yesNoEligible[key, default: []].insert(index)
                    if answer == yesLabel { yesNoPresent[key, default: []].insert(index) }
                    yesNoMeta[key] = (prompt: resolved.prompt, yesLabel: yesLabel,
                                      sourceKey: Self.sourceKey(for: resolved))
                case .multipleChoice:
                    guard let resolved, let answers = response.answeredOptions, !answers.isEmpty
                    else { break }
                    let questionKey = resolved.uniqueIdentifier
                    choiceEligible[questionKey, default: []].insert(index)
                    for choice in answers {
                        let key = "\(questionKey)|\(choice)"
                        choicePresent[key, default: []].insert(index)
                        choiceMeta[key] = (prompt: resolved.prompt, choice: choice,
                                           questionKey: questionKey,
                                           sourceKey: Self.sourceKey(for: resolved))
                    }
                case .people:
                    // Person registry resolution (plan 22): alias →
                    // canonical person, so "Angie" and "Angela" merge into
                    // one signal keyed and displayed by the CURRENT display
                    // name. Unresolved names stay themselves.
                    questionResponded[questionKey, default: []].insert(index)
                    for token in response.tokens ?? [] {
                        let name = PersonResolver.person(matching: token.text, in: people)?.text
                            ?? token.text
                        personPresent[name, default: []].insert(index)
                        personOwners[name, default: []].insert(questionKey)
                    }
                default:
                    // Untyped responses (question deleted) count as tokens —
                    // matches the digest's catch-all behavior.
                    questionResponded[questionKey, default: []].insert(index)
                    for token in response.tokens ?? [] {
                        tokenPresent[token.text, default: []].insert(index)
                        tokenOwners[token.text, default: []].insert(questionKey)
                    }
                }
                if let location = response.locationResponse {
                    questionResponded[questionKey, default: []].insert(index)
                    // Group by venue ID, else text — ReportsOverview convention.
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
            if let condition = report.weather?.condition, !condition.isEmpty {
                weatherEligible.insert(index)
                weatherPresent[condition, default: []].insert(index)
            }
            if let focus = report.focus {
                focusEligible.insert(index)
                if focus.isFocused, let label = focus.label, !label.isEmpty {
                    focusPresent[label, default: []].insert(index)
                }
            }
            if report.health.contains(where: {
                $0.type.hasPrefix("workout.") && !$0.type.hasPrefix("workout.trigger")
            }) {
                workoutPresent.insert(index)
            }
        }

        var signals: [CategoricalSignal] = []
        for (key, present) in yesNoPresent.sorted(by: { $0.key < $1.key }) {
            guard let meta = yesNoMeta[key], let eligible = yesNoEligible[key] else { continue }
            signals.append(CategoricalSignal(
                id: "yesno:\(key)", sourceKey: meta.sourceKey,
                verbPhrase: "answer \(meta.yesLabel) to “\(meta.prompt)”",
                contextPhrase: "when you answer \(meta.yesLabel) to “\(meta.prompt)”",
                present: present, eligible: eligible))
        }
        for (key, present) in choicePresent.sorted(by: { $0.key < $1.key }) {
            guard let meta = choiceMeta[key],
                  let eligible = choiceEligible[meta.questionKey] else { continue }
            signals.append(CategoricalSignal(
                id: "choice:\(key)", sourceKey: meta.sourceKey,
                verbPhrase: "answer “\(meta.choice)” to “\(meta.prompt)”",
                contextPhrase: "when you answer “\(meta.choice)” to “\(meta.prompt)”",
                present: present, eligible: eligible))
        }
        func owningEligible(_ owners: Set<String>?) -> Set<Int> {
            (owners ?? []).reduce(into: Set<Int>()) { union, key in
                union.formUnion(questionResponded[key] ?? [])
            }
        }
        for (text, present) in tokenPresent.sorted(by: { $0.key < $1.key }) {
            signals.append(CategoricalSignal(
                id: "token:\(text)", sourceKey: "token:\(text)",
                verbPhrase: "mention “\(text)”",
                contextPhrase: "when you mention “\(text)”",
                present: present, eligible: owningEligible(tokenOwners[text])))
        }
        for (name, present) in personPresent.sorted(by: { $0.key < $1.key }) {
            signals.append(CategoricalSignal(
                id: "person:\(name)", sourceKey: "person:\(name)",
                verbPhrase: "see \(name)",
                contextPhrase: "when you see \(name)",
                present: present, eligible: owningEligible(personOwners[name])))
        }
        for (key, entry) in placePresent.sorted(by: { $0.key < $1.key }) {
            // Context-only: "Reports at Office …" reads honestly; a verb
            // phrase for places would overclaim what a location answer means.
            signals.append(CategoricalSignal(
                id: "place:\(key)", sourceKey: "place:\(key)",
                verbPhrase: nil,
                contextPhrase: "at \(entry.text)",
                present: entry.indices, eligible: owningEligible(placeOwners[key])))
        }
        for (condition, present) in weatherPresent.sorted(by: { $0.key < $1.key }) {
            // Eligible = reports with any recorded condition, so the "other"
            // side is other weather, never missing weather data.
            signals.append(CategoricalSignal(
                id: "weather:\(condition)", sourceKey: "weather",
                verbPhrase: nil,
                contextPhrase: "when the weather is \(condition)",
                present: present, eligible: weatherEligible))
        }
        for (label, present) in focusPresent.sorted(by: { $0.key < $1.key }) {
            signals.append(CategoricalSignal(
                id: "focus:\(label)", sourceKey: "focus",
                verbPhrase: nil,
                contextPhrase: "in the \(label) Focus",
                present: present, eligible: focusEligible))
        }
        if !workoutPresent.isEmpty {
            signals.append(CategoricalSignal(
                id: "workout:any", sourceKey: "workout",
                verbPhrase: "log a workout",
                contextPhrase: "when you log a workout",
                present: workoutPresent, eligible: allIndices))
        }
        return signals
    }

    private static func buildNumericSignals(
        filed: [Report], question: (Response) -> Question?
    ) -> [NumericSignal] {
        var numberValues: [String: (prompt: String, values: [Int: Double])] = [:]
        var steps: [Int: Double] = [:]
        var flights: [Int: Double] = [:]
        var decibels: [Int: Double] = [:]
        var valence: [Int: Double] = [:]
        var valenceCounts: [Int: Int] = [:]
        var workoutMinutes: [Int: Double] = [:]

        for (index, report) in filed.enumerated() {
            for response in report.responses ?? [] {
                guard let resolved = question(response) else { continue }
                if resolved.type == .number,
                   let numeric = response.numericResponse, let value = Double(numeric) {
                    var entry = numberValues[resolved.uniqueIdentifier]
                        ?? (prompt: resolved.prompt, values: [:])
                    entry.values[index] = value
                    numberValues[resolved.uniqueIdentifier] = entry
                }
                if resolved.stateOfMindKind != nil,
                   let answer = response.answeredOptions?.first,
                   let value = StateOfMindValence.value(answer: answer,
                                                        choices: resolved.choices,
                                                        type: resolved.type) {
                    // Per-report mean when several state-of-mind questions land
                    // on one report: accumulate then average below.
                    valence[index] = (valence[index] ?? 0) + value
                    valenceCounts[index, default: 0] += 1
                }
            }
            // Average the accumulated valence over the report's MAPPED
            // state-of-mind answers only — an answer the valence mapping
            // can't place (edited/stale choice labels) contributes nothing to
            // the sum, so it must not inflate the divisor either.
            if let count = valenceCounts[index], count > 1, let sum = valence[index] {
                valence[index] = sum / Double(count)
            }

            var hasHealth = false
            var reportWorkoutSeconds = 0.0
            for reading in report.health {
                hasHealth = true
                switch reading.type {
                case "steps": steps[index] = (steps[index] ?? 0) + reading.value
                case "flightsClimbed": flights[index] = (flights[index] ?? 0) + reading.value
                default:
                    if reading.type.hasPrefix("workout."),
                       !reading.type.hasPrefix("workout.trigger") {
                        reportWorkoutSeconds += reading.value
                    }
                }
            }
            // Workout minutes are defined (possibly 0) whenever health capture
            // produced anything — a report with no health readings is missing
            // data, not a zero-minute day.
            if hasHealth { workoutMinutes[index] = reportWorkoutSeconds / 60 }
            if let audio = report.audio { decibels[index] = audio.avg }
        }

        var signals: [NumericSignal] = []
        for (key, entry) in numberValues.sorted(by: { $0.key < $1.key }) {
            signals.append(NumericSignal(
                id: "number:\(key)", sourceKey: "question:\(key)",
                noun: nil, subject: "Your answer to “\(entry.prompt)”",
                values: entry.values, format: { Self.oneDecimal($0) }))
        }
        if !steps.isEmpty {
            signals.append(NumericSignal(
                id: "health:steps", sourceKey: "health:steps",
                noun: "steps", subject: "Your step count",
                values: steps, format: { Self.grouped($0) }))
        }
        if !flights.isEmpty {
            signals.append(NumericSignal(
                id: "health:flights", sourceKey: "health:flights",
                noun: "flights climbed", subject: "Your flights climbed",
                values: flights, format: { Self.grouped($0) }))
        }
        if !decibels.isEmpty {
            signals.append(NumericSignal(
                id: "audio:db", sourceKey: "audio",
                noun: "dB of ambient noise", subject: "Ambient noise",
                values: decibels, format: { Self.oneDecimal($0) }))
        }
        if !valence.isEmpty {
            signals.append(NumericSignal(
                id: "mood:valence", sourceKey: "mood",
                noun: nil, subject: "Your mood valence",
                values: valence, format: { Self.twoDecimal($0) }))
        }
        if !workoutMinutes.isEmpty {
            signals.append(NumericSignal(
                id: "health:workoutMinutes", sourceKey: "workout",
                noun: "workout minutes", subject: "Your workout minutes",
                values: workoutMinutes, format: { Self.grouped($0) }))
        }
        return signals
    }

    // MARK: - Categorical × numeric (difference of means)

    private static func meanDifferenceInsights(
        categoricals: [CategoricalSignal], numerics: [NumericSignal]
    ) -> [Insight] {
        var insights: [Insight] = []
        for categorical in categoricals {
            for numeric in numerics {
                guard categorical.sourceKey != numeric.sourceKey else { continue }
                let measured = Set(numeric.values.keys).intersection(categorical.eligible)
                let withSide = measured.intersection(categorical.present)
                let withoutSide = measured.subtracting(categorical.present)
                guard withSide.count >= minimumSideCount,
                      withoutSide.count >= minimumSideCount else { continue }

                let withValues = withSide.map { numeric.values[$0]! }
                let withoutValues = withoutSide.map { numeric.values[$0]! }
                let withMean = StatsMath.mean(withValues)
                let withoutMean = StatsMath.mean(withoutValues)
                let delta = withMean - withoutMean
                // Combined-sample SD: both sides pooled into ONE sample (not
                // the classic pooled-variance SD, which averages the per-side
                // variances). It runs a bit larger when means differ, so the
                // effect reads conservatively; `strength` divides by 2 to
                // re-normalize — two combined-sample SDs = full strength.
                let spread = StatsMath.standardDeviation(withValues + withoutValues)
                guard spread > 1e-9 else { continue }
                let effect = abs(delta) / spread
                guard effect >= minimumMeanEffect else { continue }

                let sampleCount = measured.count
                let strength = min(effect / 2, 1)
                let title: String
                if let noun = numeric.noun {
                    let phrase = categorical.verbPhrase.map { "where you \($0)" }
                        ?? categorical.contextPhrase ?? ""
                    let direction = delta > 0 ? "more" : "fewer"
                    title = "Reports \(phrase) average \(numeric.format(abs(delta))) \(direction) \(noun)."
                } else {
                    let phrase = categorical.verbPhrase.map { "when you \($0)" }
                        ?? categorical.contextPhrase ?? ""
                    let direction = delta > 0 ? "higher" : "lower"
                    title = "\(numeric.subject) tends to run \(direction) \(phrase)."
                }
                let detail = "Average \(numeric.format(withMean)) vs \(numeric.format(withoutMean)) otherwise — based on \(sampleCount) reports."
                insights.append(Insight(title: title, detail: detail,
                                        kind: .categoricalNumeric,
                                        strength: strength, sampleCount: sampleCount,
                                        sourceKeys: [categorical.sourceKey, numeric.sourceKey]))
            }
        }
        return insights
    }

    // MARK: - Categorical × categorical (co-occurrence rates)

    private static func cooccurrenceInsights(
        categoricals: [CategoricalSignal]
    ) -> [Insight] {
        // Context (place/weather/Focus/…) conditions an answer
        // (yes-no/choice/token/…): ordered roles so each association reads one
        // way. Signals carrying BOTH phrases (tokens, persons, yes-no,
        // choices, workout) still produce mirror pairs (A conditions B and B
        // conditions A), so results are deduped on the UNORDERED signal-id
        // pair below — keep the direction with the larger |rate delta|; on an
        // exact tie the lexicographically smaller context id wins.
        struct Candidate {
            var insight: Insight
            var contextID: String
            var absDelta: Double
        }
        let contexts = categoricals.filter { $0.contextPhrase != nil }
        let answers = categoricals.filter { $0.verbPhrase != nil }
        var bestByPair: [String: Candidate] = [:]
        for context in contexts {
            for answer in answers {
                guard context.id != answer.id,
                      context.sourceKey != answer.sourceKey else { continue }
                let eligible = context.eligible.intersection(answer.eligible)
                let inContext = eligible.intersection(context.present)
                let outsideContext = eligible.subtracting(context.present)
                guard inContext.count >= minimumSideCount,
                      outsideContext.count >= minimumSideCount else { continue }

                let rateWith = Double(inContext.intersection(answer.present).count)
                    / Double(inContext.count)
                let rateWithout = Double(outsideContext.intersection(answer.present).count)
                    / Double(outsideContext.count)
                let delta = rateWith - rateWithout
                guard abs(delta) >= minimumRateDelta else { continue }

                let sampleCount = eligible.count
                let strength = min(abs(delta) / 0.5, 1)
                let title = "You \(answer.verbPhrase!) on \(percent(rateWith)) of reports \(context.contextPhrase!)."
                let detail = "Compared with \(percent(rateWithout)) of other reports — based on \(sampleCount) reports."
                let candidate = Candidate(
                    insight: Insight(title: title, detail: detail,
                                     kind: .cooccurrence,
                                     strength: strength, sampleCount: sampleCount,
                                     sourceKeys: [context.sourceKey, answer.sourceKey]),
                    contextID: context.id,
                    absDelta: abs(delta))
                let pairKey = context.id < answer.id
                    ? "\(context.id)|\(answer.id)" : "\(answer.id)|\(context.id)"
                if let existing = bestByPair[pairKey] {
                    if candidate.absDelta > existing.absDelta
                        || (candidate.absDelta == existing.absDelta
                            && candidate.contextID < existing.contextID) {
                        bestByPair[pairKey] = candidate
                    }
                } else {
                    bestByPair[pairKey] = candidate
                }
            }
        }
        // Dictionary order is arbitrary; the caller's deterministic sort
        // restores a stable ranking.
        return bestByPair.values.map(\.insight)
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
        return formatter.string(from: NSNumber(value: value.rounded())) ?? String(Int(value.rounded()))
    }

    private static func oneDecimal(_ value: Double) -> String {
        String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func twoDecimal(_ value: Double) -> String {
        String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}
