import Foundation

/// Pure per-question aggregation of a question's answers across a set of reports.
/// No SwiftUI/HealthKit imports — DispatchKit stays a data/logic layer.
public enum QuestionVisualization: Equatable, Sendable {
    /// Yes/No + multiple choice: share of answered responses per option. Shares sum to 1.0.
    /// Options ordered by the question's `choices` order first, then any unlisted answered
    /// options by descending frequency (ties broken alphabetically).
    case optionShares([(option: String, share: Double)])
    /// Number questions: chronologically sorted points plus their average.
    case numericSeries(points: [(date: Date, value: Double)], average: Double)
    /// Tokens + people: descending count, alphabetical tiebreak, top 20.
    case frequency([(text: String, count: Int)])
    /// Location questions: grouped by `LocationAnswer.text`, descending count, top 20.
    case places([(name: String, count: Int)])
    /// Note questions: newest first, top 20.
    case recentNotes([(date: Date, text: String)])
    /// No answered responses for this question.
    case empty

    public static func == (lhs: QuestionVisualization, rhs: QuestionVisualization) -> Bool {
        switch (lhs, rhs) {
        case (.optionShares(let l), .optionShares(let r)):
            l.count == r.count && zip(l, r).allSatisfy { $0.option == $1.option && abs($0.share - $1.share) < 0.0001 }
        case (.numericSeries(let lp, let la), .numericSeries(let rp, let ra)):
            lp.count == rp.count && zip(lp, rp).allSatisfy { $0.date == $1.date && $0.value == $1.value } && abs(la - ra) < 0.0001
        case (.frequency(let l), .frequency(let r)):
            l.count == r.count && zip(l, r).allSatisfy { $0.text == $1.text && $0.count == $1.count }
        case (.places(let l), .places(let r)):
            l.count == r.count && zip(l, r).allSatisfy { $0.name == $1.name && $0.count == $1.count }
        case (.recentNotes(let l), .recentNotes(let r)):
            l.count == r.count && zip(l, r).allSatisfy { $0.date == $1.date && $0.text == $1.text }
        case (.empty, .empty):
            true
        default:
            false
        }
    }
}

public enum VisualizationData {
    private static let topLimit = 20

    /// Builds the visualization for `question` over `reports`, dispatching on question type.
    /// Responses join by `questionIdentifier` first; when a response's identifier is nil, it
    /// falls back to matching by `questionPrompt` (mirrors QuestionSettingsView's response count).
    public static func build(for question: Question, reports: [Report]) -> QuestionVisualization {
        let responses = matchingResponses(for: question, reports: reports)

        // Per-question style override, honored only when compatible with the
        // question type; incompatible or nil falls through to the type default.
        if let style = question.visualization, style.isCompatible(with: question.type) {
            switch style {
            case .proportion:
                return buildOptionShares(question: question, responses: responses)
            case .graph:
                return buildNumericSeries(responses: responses, reports: reports)
            case .frequency:
                return buildFrequency(responses: responses)
            }
        }

        switch question.type {
        case .yesNo, .multipleChoice:
            return buildOptionShares(question: question, responses: responses)
        case .number:
            return buildNumericSeries(responses: responses, reports: reports)
        case .tokens, .people:
            return buildFrequency(responses: responses)
        case .location:
            return buildPlaces(responses: responses)
        case .note:
            return buildRecentNotes(responses: responses, reports: reports)
        }
    }

    private static func matchingResponses(for question: Question, reports: [Report]) -> [Response] {
        reports.flatMap { $0.responses ?? [] }.filter { response in
            if let responseQuestionIdentifier = response.questionIdentifier {
                return responseQuestionIdentifier == question.uniqueIdentifier
            }
            return response.questionPrompt == question.prompt
        }
    }

    private static func buildOptionShares(question: Question, responses: [Response]) -> QuestionVisualization {
        let answered = responses.compactMap(\.answeredOptions).filter { !$0.isEmpty }
        guard !answered.isEmpty else { return .empty }

        var counts: [String: Int] = [:]
        var total = 0
        for options in answered {
            for option in options {
                counts[option, default: 0] += 1
                total += 1
            }
        }
        guard total > 0 else { return .empty }

        var orderedOptions: [String] = []
        var seen: Set<String> = []

        // Use question.choices, or implicit ["Yes", "No"] for empty yesNo questions
        let choicesToConsider = question.type == .yesNo && question.choices.isEmpty
            ? ["Yes", "No"]
            : question.choices

        for choice in choicesToConsider where counts[choice] != nil {
            orderedOptions.append(choice)
            seen.insert(choice)
        }
        let unlisted = counts.keys.filter { !seen.contains($0) }
            .sorted { lhs, rhs in
                let lhsCount = counts[lhs] ?? 0
                let rhsCount = counts[rhs] ?? 0
                if lhsCount != rhsCount { return lhsCount > rhsCount }
                return lhs < rhs
            }
        orderedOptions.append(contentsOf: unlisted)

        let shares = orderedOptions.map { option in
            (option: option, share: Double(counts[option] ?? 0) / Double(total))
        }
        return .optionShares(shares)
    }

    private static func buildNumericSeries(responses: [Response], reports: [Report]) -> QuestionVisualization {
        let responseToReport = Dictionary(uniqueKeysWithValues: reports.flatMap { report in
            (report.responses ?? []).map { (ObjectIdentifier($0), report) }
        })

        var points: [(date: Date, value: Double)] = []
        for response in responses {
            guard let numericString = response.numericResponse,
                  let value = Double(numericString),
                  let report = responseToReport[ObjectIdentifier(response)] else { continue }
            points.append((date: report.date, value: value))
        }
        guard !points.isEmpty else { return .empty }

        points.sort { $0.date < $1.date }
        let average = points.reduce(0.0) { $0 + $1.value } / Double(points.count)
        return .numericSeries(points: points, average: average)
    }

    private static func buildFrequency(responses: [Response]) -> QuestionVisualization {
        var counts: [String: Int] = [:]
        for response in responses {
            for token in response.tokens ?? [] {
                counts[token.text, default: 0] += 1
            }
        }
        guard !counts.isEmpty else { return .empty }

        let items = counts
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key < rhs.key
            }
            .prefix(topLimit)
            .map { (text: $0.key, count: $0.value) }
        return .frequency(Array(items))
    }

    private static func buildPlaces(responses: [Response]) -> QuestionVisualization {
        // Group by venue ID (if present) or text, following ReportsOverview.secondaryStats convention:
        // - foursquareVenueId gets "venue:" prefix and takes precedence
        // - text gets "text:" prefix as fallback
        // Track grouping key -> (count, most frequent or first-seen text)
        var groupedByKey: [String: (count: Int, text: String)] = [:]

        for response in responses {
            guard let location = response.locationResponse else { continue }

            let key: String
            let displayText: String

            if let venue = location.foursquareVenueId {
                key = "venue:\(venue)"
                displayText = location.text?.isEmpty == false ? location.text! : "Unknown place"
            } else if let text = location.text, !text.isEmpty {
                key = "text:\(text)"
                displayText = text
            } else {
                continue
            }

            if var existing = groupedByKey[key] {
                existing.count += 1
                // Keep the most frequent (or first-seen) text for this key
                // For simplicity with the current data model, keep the existing text unless new is non-empty and old is empty
                if existing.text.isEmpty && !displayText.isEmpty {
                    existing.text = displayText
                }
                groupedByKey[key] = existing
            } else {
                groupedByKey[key] = (count: 1, text: displayText)
            }
        }

        guard !groupedByKey.isEmpty else { return .empty }

        let items = groupedByKey
            .sorted { lhs, rhs in
                if lhs.value.count != rhs.value.count { return lhs.value.count > rhs.value.count }
                return lhs.value.text < rhs.value.text
            }
            .prefix(topLimit)
            .map { (name: $0.value.text, count: $0.value.count) }
        return .places(Array(items))
    }

    private static func buildRecentNotes(responses: [Response], reports: [Report]) -> QuestionVisualization {
        let responseToReport = Dictionary(uniqueKeysWithValues: reports.flatMap { report in
            (report.responses ?? []).map { (ObjectIdentifier($0), report) }
        })

        var notes: [(date: Date, text: String)] = []
        for response in responses {
            guard let text = response.textResponses?.first?.text, !text.isEmpty,
                  let report = responseToReport[ObjectIdentifier(response)] else { continue }
            notes.append((date: report.date, text: text))
        }
        guard !notes.isEmpty else { return .empty }

        notes.sort { $0.date > $1.date }
        return .recentNotes(Array(notes.prefix(topLimit)))
    }
}
