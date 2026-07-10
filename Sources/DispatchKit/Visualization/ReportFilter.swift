import Foundation

/// Content filters for the Home visualizations, mirroring the original
/// Reporter's filter sheet: results are only shown for entries (reports)
/// matching ALL active criteria.
public enum ReportFilter {
    /// Ambient-audio bucket, reusing the `AudioLevel` display thresholds:
    /// quiet < 50 ≤ moderate < 70 ≤ loud (the two EXTREMELY labels fold into
    /// their neighbors).
    public enum AudioBucket: String, Codable, CaseIterable, Sendable {
        case quiet, moderate, loud

        public static func bucket(forDisplay display: Double) -> AudioBucket {
            switch display {
            case ..<50: .quiet
            case ..<70: .moderate
            default: .loud
            }
        }

        public var displayName: String {
            switch self {
            case .quiet: "Quiet"
            case .moderate: "Moderate"
            case .loud: "Loud"
            }
        }
    }

    /// Step-count bucket for the Steps criterion.
    public enum StepsBucket: String, Codable, CaseIterable, Sendable {
        case under5k, from5kTo10k, over10k

        public static func bucket(forSteps steps: Double) -> StepsBucket {
            switch steps {
            case ..<5000: .under5k
            case ...10000: .from5kTo10k
            default: .over10k
            }
        }

        public var displayName: String {
            switch self {
            case .under5k: "Fewer than 5,000"
            case .from5kTo10k: "5,000–10,000"
            case .over10k: "More than 10,000"
            }
        }
    }

    /// One active filter. A report matches a criterion when the described
    /// content is present in that report.
    public enum FilterCriterion: Hashable, Codable, Sendable {
        case person(String)
        case place(String)
        case token(String)
        /// 1–12
        case month(Int)
        case year(Int)
        case ambientAudio(AudioBucket)
        case steps(StepsBucket)
        /// Weather condition string (e.g. "Clear").
        case weather(String)

        public var displayText: String {
            switch self {
            case .person(let name): name
            case .place(let name): name
            case .token(let text): text
            case .month(let month):
                Calendar(identifier: .gregorian).monthSymbols[max(0, min(11, month - 1))]
            case .year(let year): String(year)
            case .ambientAudio(let bucket): bucket.displayName
            case .steps(let bucket): "\(bucket.displayName) steps"
            case .weather(let condition): condition
            }
        }

        /// Stable, kind-aware encoding (e.g. "person:Alice", "month:3").
        /// Used for chip identity and memo keys — `displayText` alone
        /// collides when e.g. a person and a token share the same text.
        public var canonicalKey: String {
            switch self {
            case .person(let name): "person:\(name)"
            case .place(let name): "place:\(name)"
            case .token(let text): "token:\(text)"
            case .month(let month): "month:\(month)"
            case .year(let year): "year:\(year)"
            case .ambientAudio(let bucket): "ambientAudio:\(bucket.rawValue)"
            case .steps(let bucket): "steps:\(bucket.rawValue)"
            case .weather(let condition): "weather:\(condition)"
            }
        }
    }

    /// True when `report` satisfies EVERY criterion ("Results are only shown
    /// for entries matching all filters."). An empty criteria list matches all.
    ///
    /// `peopleQuestionIDs` narrows person-name matching to responses of people
    /// questions; when empty (unknown), person criteria match any token text.
    ///
    /// `people` is the person registry (plan 22): a person criterion resolves
    /// through it so a filter on the current display name also matches
    /// reports filed under the person's alternate (pre-rename/merge) names.
    public static func matches(report: Report, criteria: [FilterCriterion],
                               peopleQuestionIDs: Set<String> = [],
                               people: [PersonEntity] = []) -> Bool {
        // Deterministic resolution order, sorted ONCE here — not per
        // criterion per report (callers evaluate this over every report).
        let registry = people.sorted { $0.uniqueIdentifier < $1.uniqueIdentifier }
        return criteria.allSatisfy {
            matches(report: report, criterion: $0,
                    peopleQuestionIDs: peopleQuestionIDs, people: registry)
        }
    }

    /// `people` must already be deterministically sorted (see `matches`).
    private static func matches(report: Report, criterion: FilterCriterion,
                                peopleQuestionIDs: Set<String>, people: [PersonEntity]) -> Bool {
        switch criterion {
        case .person(let name):
            // Every name the criterion stands for: the resolved person's
            // display name + alternates, or just the literal when unresolved.
            let acceptedNames: Set<String>
            if let person = PersonResolver.person(matching: name, in: people) {
                acceptedNames = Set(([person.text] + person.alternateNames)
                    .map(PersonResolver.normalize))
            } else {
                acceptedNames = [PersonResolver.normalize(name)]
            }
            return (report.responses ?? []).contains { response in
                guard peopleQuestionIDs.isEmpty
                        || response.questionIdentifier.map(peopleQuestionIDs.contains) == true else { return false }
                return (response.tokens ?? []).contains {
                    acceptedNames.contains(PersonResolver.normalize($0.text))
                }
            }
        case .token(let text):
            // Mirror of the person criterion: when people questions are
            // known, their responses are EXCLUDED here so a name filed under
            // "Who are you with?" doesn't satisfy a token filter.
            return (report.responses ?? []).contains { response in
                if !peopleQuestionIDs.isEmpty,
                   let questionID = response.questionIdentifier,
                   peopleQuestionIDs.contains(questionID) {
                    return false
                }
                return (response.tokens ?? []).contains { $0.text.caseInsensitiveCompare(text) == .orderedSame }
            }
        case .place(let name):
            let answered = (report.responses ?? []).contains { response in
                response.locationResponse?.text?.caseInsensitiveCompare(name) == .orderedSame
            }
            let sensed = report.location?.placemark?.name?.caseInsensitiveCompare(name) == .orderedSame
            return answered || sensed
        case .month(let month):
            return calendar(for: report).component(.month, from: report.date) == month
        case .year(let year):
            return calendar(for: report).component(.year, from: report.date) == year
        case .ambientAudio(let bucket):
            guard let audio = report.audio else { return false }
            return AudioBucket.bucket(forDisplay: AudioLevel.displayValue(fromRaw: audio.avg)) == bucket
        case .steps(let bucket):
            guard let steps = report.health.first(where: { $0.type == "steps" })?.value else { return false }
            return StepsBucket.bucket(forSteps: steps) == bucket
        case .weather(let condition):
            guard let reportCondition = report.weather?.condition else { return false }
            return reportCondition.caseInsensitiveCompare(condition) == .orderedSame
        }
    }

    /// Calendar in the report's own time zone, so month/year criteria bucket
    /// the entry the way the user experienced it.
    private static func calendar(for report: Report) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: report.timeZoneIdentifier) ?? .gmt
        return calendar
    }
}
