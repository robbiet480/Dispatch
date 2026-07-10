import Foundation

/// Pure period aggregation feeding the digest screen: everything the
/// FoundationModels prompt (and the deterministic template fallback) is
/// allowed to talk about. Foundation-only, no HealthKit/SwiftUI.
///
/// Window: a trailing `DigestPeriod` interval ending at (and excluding) the
/// start of the day after `ending` — for `.week`, the 7 local calendar days
/// whose last day is `ending`'s (the exact plan-14 rule); `.month`/`.quarter`
/// swap the trailing-step unit. The prior window is the same-length interval
/// immediately before.
///
/// Wrapped (plan 33) computes calendar-aligned periods (THE March, THE 2026);
/// its implementer should reuse this interval-parameterized `compute` (or
/// helpers extracted from it) instead of duplicating the aggregation — see the
/// plan-40 shared-period-surface decision.
public struct DigestStats: Equatable, Sendable {
    public struct RankedItem: Equatable, Sendable {
        public var text: String
        public var count: Int
        public init(text: String, count: Int) {
            self.text = text
            self.count = count
        }
    }

    public struct NumericAverage: Equatable, Sendable {
        public var prompt: String
        public var average: Double
        public var sampleCount: Int
        public init(prompt: String, average: Double, sampleCount: Int) {
            self.prompt = prompt
            self.average = average
            self.sampleCount = sampleCount
        }
    }

    /// Which trailing window these stats cover.
    public var period: DigestPeriod
    public var periodStart: Date
    public var periodEnd: Date
    public var reportCount: Int
    public var priorPeriodReportCount: Int
    /// Top 5 token answers (questions of type `.tokens`), descending count,
    /// alphabetical tiebreak.
    public var topTokens: [RankedItem]
    /// Top 5 people answers (questions of type `.people`), same ordering.
    public var topPeople: [RankedItem]
    /// Top 5 places (grouped by venue ID, else text — ReportsOverview convention).
    public var topPlaces: [RankedItem]
    /// Weekly average per numeric question with ≥1 parsed answer, ordered by prompt.
    public var numericAverages: [NumericAverage]
    /// Mean State-of-Mind valence [-1, +1] across the week's answered
    /// state-of-mind questions; nil when none were answered.
    public var valenceAverage: Double?
    /// Same, for the prior week — the pair gives the trend.
    public var priorValenceAverage: Double?
    /// Sum of the week's `steps` health readings (each covers the window since
    /// the previous report, so the sum approximates the weekly total).
    public var stepsTotal: Double
    /// Distinct workouts seen in the week's `workout.<raw>` readings
    /// (deduplicated by type + start date — every report re-lists today's workouts).
    public var workoutCount: Int
    public var workoutSeconds: Double
    /// Report streak as of `weekEnding` (see `ReportStreak`).
    public var streakDays: Int
    /// The top 2 insights, computed over ALL filed reports (all-time, not the
    /// week — long-run patterns need the full sample to be honest). Only
    /// populated when the InsightsEngine's stability guards pass (sample
    /// sizes, effect thresholds); usually empty for young datasets. These are
    /// precomputed sentences: the LLM prompt may weave them in verbatim but
    /// never derives its own, and the template appends them deterministically.
    public var topInsights: [Insight]

    // MARK: - Compute

    private static let topLimit = 5
    private static let insightLimit = 2

    /// Thin `.week` wrapper preserving plan-14's call shape (and its
    /// byte-identical output). New callers pass an explicit `period`.
    public static func compute(reports: [Report], questions: [Question],
                               weekEnding: Date, calendar: Calendar = .current) -> DigestStats {
        compute(reports: reports, questions: questions,
                period: .week, ending: weekEnding, calendar: calendar)
    }

    /// `questions` supplies what responses alone can't: the tokens/people type
    /// split, choice order for valence mapping, and `stateOfMindKind` flags.
    /// The window is derived from `DigestPeriod.interval(ending:calendar:)`;
    /// every aggregation below is period-agnostic — only the two window
    /// filters change source.
    public static func compute(reports: [Report], questions: [Question],
                               period: DigestPeriod, ending: Date,
                               calendar: Calendar = .current) -> DigestStats {
        let window = period.interval(ending: ending, calendar: calendar)
        let periodStart = window.start
        let dayAfterEnd = window.end
        let priorStart = window.priorStart

        let filed = reports.filter { !$0.isDraft }
        let week = filed.filter { $0.date >= periodStart && $0.date < dayAfterEnd }
        let prior = filed.filter { $0.date >= priorStart && $0.date < periodStart }

        let byIdentifier = Dictionary(questions.map { ($0.uniqueIdentifier, $0) },
                                      uniquingKeysWith: { first, _ in first })
        let byPrompt = Dictionary(questions.map { ($0.prompt, $0) },
                                  uniquingKeysWith: { first, _ in first })
        func question(for response: Response) -> Question? {
            if let identifier = response.questionIdentifier { return byIdentifier[identifier] }
            return byPrompt[response.questionPrompt]
        }

        var tokenCounts: [String: Int] = [:]
        var peopleCounts: [String: Int] = [:]
        var placeGroups: [String: (count: Int, text: String)] = [:]
        var numericSums: [String: (sum: Double, count: Int)] = [:]

        for report in week {
            for response in report.responses ?? [] {
                let questionType = question(for: response)?.type
                for token in response.tokens ?? [] {
                    // Untyped responses (question deleted) count as tokens —
                    // matches the token page's catch-all behavior.
                    if questionType == .people {
                        peopleCounts[token.text, default: 0] += 1
                    } else {
                        tokenCounts[token.text, default: 0] += 1
                    }
                }
                if let location = response.locationResponse {
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
                    var group = placeGroups[key] ?? (count: 0, text: text)
                    group.count += 1
                    placeGroups[key] = group
                }
                if questionType == .number,
                   let numericString = response.numericResponse,
                   let value = Double(numericString) {
                    let prompt = question(for: response)?.prompt ?? response.questionPrompt
                    var entry = numericSums[prompt] ?? (sum: 0, count: 0)
                    entry.sum += value
                    entry.count += 1
                    numericSums[prompt] = entry
                }
            }
        }

        func ranked(_ counts: [String: Int]) -> [RankedItem] {
            counts.sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key < rhs.key
            }
            .prefix(topLimit)
            .map { RankedItem(text: $0.key, count: $0.value) }
        }

        let places = placeGroups.values
            .sorted { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs.text < rhs.text
            }
            .prefix(topLimit)
            .map { RankedItem(text: $0.text, count: $0.count) }

        func meanValence(_ reports: [Report]) -> Double? {
            var values: [Double] = []
            for report in reports {
                for response in report.responses ?? [] {
                    guard let question = question(for: response),
                          question.stateOfMindKind != nil,
                          let answer = response.answeredOptions?.first,
                          let valence = StateOfMindValence.value(answer: answer,
                                                                 choices: question.choices,
                                                                 type: question.type)
                    else { continue }
                    values.append(valence)
                }
            }
            guard !values.isEmpty else { return nil }
            return values.reduce(0, +) / Double(values.count)
        }

        var stepsTotal = 0.0
        var workouts: Set<String> = []
        var workoutSeconds = 0.0
        for report in week {
            for reading in report.health {
                if reading.type == "steps" {
                    stepsTotal += reading.value
                } else if reading.type.hasPrefix("workout."), !reading.type.hasPrefix("workout.trigger") {
                    let start = reading.startDate?.timeIntervalSinceReferenceDate ?? 0
                    let key = "\(reading.type)|\(start)"
                    if workouts.insert(key).inserted {
                        workoutSeconds += reading.value
                    }
                }
            }
        }

        return DigestStats(
            period: period,
            periodStart: periodStart,
            periodEnd: dayAfterEnd,
            reportCount: week.count,
            priorPeriodReportCount: prior.count,
            topTokens: ranked(tokenCounts),
            topPeople: ranked(peopleCounts),
            topPlaces: Array(places),
            numericAverages: numericSums
                .sorted { $0.key < $1.key }
                .map { NumericAverage(prompt: $0.key,
                                      average: $0.value.sum / Double($0.value.count),
                                      sampleCount: $0.value.count) },
            valenceAverage: meanValence(week),
            priorValenceAverage: meanValence(prior),
            stepsTotal: stepsTotal,
            workoutCount: workouts.count,
            workoutSeconds: workoutSeconds,
            streakDays: ReportStreak.days(reports: filed, now: ending, calendar: calendar),
            topInsights: Array(InsightsEngine.compute(reports: filed, questions: questions)
                .prefix(insightLimit))
        )
    }

    // MARK: - Template fallback

    /// Deterministic prose fallback rendered when the on-device language model
    /// is unavailable. Built from the same stats the LLM prompt gets; stable
    /// output for a given DigestStats (locale-pinned formatting).
    public var templateSummary: String {
        var sentences: [String] = []

        let noun = period.noun
        let delta = reportCount - priorPeriodReportCount
        let deltaClause: String
        if priorPeriodReportCount == 0 && reportCount > 0 {
            deltaClause = "your first reports in two \(noun)s"
        } else if delta > 0 {
            deltaClause = "\(delta) more than the \(noun) before"
        } else if delta < 0 {
            deltaClause = "\(-delta) fewer than the \(noun) before"
        } else {
            deltaClause = "the same as the \(noun) before"
        }
        sentences.append("You filed \(reportCount) \(reportCount == 1 ? "report" : "reports") this \(noun), \(deltaClause).")

        if !topTokens.isEmpty {
            sentences.append("Your most frequent answers were \(Self.joined(topTokens)).")
        }
        if !topPeople.isEmpty {
            sentences.append("You mentioned \(Self.joined(topPeople)) most often.")
        }
        if !topPlaces.isEmpty {
            sentences.append("Top places: \(Self.joined(topPlaces)).")
        }
        if let valence = valenceAverage {
            if let prior = priorValenceAverage {
                let difference = valence - prior
                if difference > 0.05 {
                    sentences.append("Your mood trended up from the \(noun) before.")
                } else if difference < -0.05 {
                    sentences.append("Your mood trended down from the \(noun) before.")
                } else {
                    sentences.append("Your mood held steady \(noun) over \(noun).")
                }
            } else {
                sentences.append(valence >= 0
                    ? "Your mood readings leaned positive."
                    : "Your mood readings leaned negative.")
            }
        }
        var activity: [String] = []
        if stepsTotal > 0 {
            activity.append("\(Self.grouped(Int(stepsTotal))) steps")
        }
        if workoutCount > 0 {
            activity.append("\(workoutCount) \(workoutCount == 1 ? "workout" : "workouts")")
        }
        if !activity.isEmpty {
            sentences.append("You logged \(activity.joined(separator: " and ")).")
        }
        if streakDays > 1 {
            sentences.append("Your report streak stands at \(streakDays) days.")
        }
        // Insight sentences are already presentation-ready and honest
        // ("tends to"/"average", sample-guarded) — append them verbatim.
        for insight in topInsights {
            sentences.append("Looking across all your reports: \(insight.title)")
        }
        return sentences.joined(separator: " ")
    }

    private static func joined(_ items: [RankedItem]) -> String {
        items.map { "\($0.text) (\($0.count))" }.joined(separator: ", ")
    }

    private static func grouped(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        // POSIX locale disables grouping by default — re-enable it explicitly
        // so "10000" renders as the stable "10,000" regardless of device locale.
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}
