import Foundation

/// Copy layer for correlation findings (plan 34, Task 3): headline + detail
/// templates keyed by kind × direction × dimension phrase. The language
/// contract extends the Insight contract — interval-forward, both sides of
/// every comparison, and NEVER causal. CorrelationCopyTests pins the exact
/// literals and bans causal phrasing over generated output.
extension CorrelationFinding {
    /// Headline sentence, e.g. "You answered Yes more often when Angela was
    /// around." For number questions `targetLabel` is the prompt itself.
    public func headline(targetLabel: String, prompt: String,
                         dimension: CorrelationRow.Dimension) -> String {
        switch kind {
        case .rateDifference:
            let direction = effect > 0 ? "more" : "less"
            return "You answered \(targetLabel) \(direction) often \(dimension.headlinePhrase)."
        case .meanDifference:
            if let metricHeadline = dimension.metricHeadline(rising: effect > 0) {
                // Binary target × health metric: the metric is the subject.
                return "\(metricHeadline) on reports where you answered \(targetLabel)."
            }
            // Numeric target × context dimension: the answer is the subject.
            let direction = effect > 0 ? "higher" : "lower"
            return "Your answers to “\(prompt)” tend to run \(direction) \(dimension.headlinePhrase)."
        case .pearson:
            let movement = effect > 0 ? "rise and fall with" : "move opposite to"
            return "Your answers to “\(prompt)” tend to \(movement) your \(dimension.metricNoun)."
        }
    }

    /// Supporting sentence carrying both sides + interval + n, e.g. "Yes on
    /// 72% of 25 reports with Angela vs 41% of 34 without — a 31-point
    /// difference (95% CI 8 to 52)."
    public func detail(targetLabel: String,
                       dimension: CorrelationRow.Dimension) -> String {
        switch kind {
        case .rateDifference:
            let points = CorrelationCopy.points(abs(effect))
            let lower = CorrelationCopy.points(interval.lowerBound)
            let upper = CorrelationCopy.points(interval.upperBound)
            return "\(targetLabel) on \(withSummary) reports \(dimension.detailWithPhrase) "
                + "vs \(withoutSummary) \(dimension.detailWithoutPhrase) — "
                + "a \(points)-point difference (95% CI \(lower) to \(upper))."
        case .meanDifference:
            // The difference carries the unit; the CI bounds are bare numbers
            // in the same unit ("difference 1.9 h (95% CI 1.2 to 2.6)").
            let bare = dimension.metricBareFormat
            return "Average \(withSummary) reports vs \(withoutSummary) — "
                + "difference \(dimension.metricFormat(abs(effect))) "
                + "(95% CI \(bare(interval.lowerBound)) to \(bare(interval.upperBound)))."
        case .pearson:
            return "r = \(CorrelationCopy.twoDecimal(effect)) "
                + "(95% CI \(CorrelationCopy.twoDecimal(interval.lowerBound)) "
                + "to \(CorrelationCopy.twoDecimal(interval.upperBound))) "
                + "over \(sampleCount) reports."
        }
    }
}

extension CorrelationRow.Dimension {
    /// Headline context, e.g. "when Angela was around" / "at Office" /
    /// "on Wi-Fi" / "in the morning" — the InsightsEngine place-honesty
    /// precedent: context dimensions phrase as context, never as claims
    /// about what the presence means.
    var headlinePhrase: String {
        switch self {
        case .person(let name): "when \(name) was around"
        case .place(let name): "at \(name)"
        case .connection(let label): "on \(label)"
        case .timeOfDay(let bucket): CorrelationCopy.timePhrase(bucket)
        case .sleepHours, .steps, .heartRateAvg, .restingHeartRate:
            "" // health metrics never appear as rate-difference context
        }
    }

    /// Detail "with" phrase, e.g. "with Angela" / "at Office".
    var detailWithPhrase: String {
        switch self {
        case .person(let name): "with \(name)"
        case .place(let name): "at \(name)"
        case .connection(let label): "on \(label)"
        case .timeOfDay(let bucket): CorrelationCopy.timePhrase(bucket)
        case .sleepHours, .steps, .heartRateAvg, .restingHeartRate: ""
        }
    }

    /// Detail "without" phrase, e.g. "without" / "elsewhere" / "otherwise".
    var detailWithoutPhrase: String {
        switch self {
        case .person: "without"
        case .place: "elsewhere"
        case .connection, .timeOfDay: "otherwise"
        case .sleepHours, .steps, .heartRateAvg, .restingHeartRate: ""
        }
    }

    /// Health-metric headline subject with direction, nil for context
    /// dimensions (which use the answer-as-subject template instead).
    func metricHeadline(rising: Bool) -> String? {
        switch self {
        case .sleepHours: rising ? "You slept longer" : "You slept less"
        case .steps: rising ? "You logged more steps" : "You logged fewer steps"
        case .heartRateAvg:
            "Your average heart rate ran \(rising ? "higher" : "lower")"
        case .restingHeartRate:
            "Your resting heart rate ran \(rising ? "higher" : "lower")"
        case .person, .place, .connection, .timeOfDay: nil
        }
    }

    /// Metric noun for Pearson headlines ("your steps", "your sleep").
    var metricNoun: String {
        switch self {
        case .sleepHours: "sleep"
        case .steps: "steps"
        case .heartRateAvg: "average heart rate"
        case .restingHeartRate: "resting heart rate"
        case .person(let name): name
        case .place(let name): name
        case .connection(let label): label
        case .timeOfDay(let bucket): bucket
        }
    }

    /// Formats an interval bound as a bare number in the metric's unit
    /// (the unit is stated once, on the difference).
    var metricBareFormat: (Double) -> String {
        switch self {
        case .steps: { CorrelationCopy.grouped($0) }
        case .heartRateAvg, .restingHeartRate: { CorrelationCopy.grouped($0) }
        case .sleepHours, .person, .place, .connection, .timeOfDay:
            { CorrelationCopy.oneDecimal($0) }
        }
    }

    /// Formats an effect/interval value in this metric's own unit for
    /// mean-difference details.
    var metricFormat: (Double) -> String {
        switch self {
        case .sleepHours: { "\(CorrelationCopy.oneDecimal($0)) h" }
        case .steps: { CorrelationCopy.grouped($0) }
        case .heartRateAvg, .restingHeartRate: { "\(CorrelationCopy.grouped($0)) bpm" }
        case .person, .place, .connection, .timeOfDay:
            { CorrelationCopy.oneDecimal($0) }
        }
    }
}

/// Locale-pinned formatting shared by the correlation copy templates.
enum CorrelationCopy {
    static func timePhrase(_ bucket: String) -> String {
        bucket == "Night" ? "at night" : "in the \(bucket.lowercased())"
    }

    /// Rate values as signed integer percentage points ("31", "-8").
    static func points(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))"
    }

    static func grouped(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value.rounded()))
            ?? String(Int(value.rounded()))
    }

    static func oneDecimal(_ value: Double) -> String {
        String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    static func twoDecimal(_ value: Double) -> String {
        String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}
