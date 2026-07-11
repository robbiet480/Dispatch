import Foundation

/// Markdown/Obsidian export (plan 36): one `.md` file per report, named
/// `YYYY-MM-DD HHmm.md` from the report's local date (deterministic ` 2.md`,
/// ` 3.md`… suffixes for same-minute collisions). Contents are YAML front
/// matter (ISO-8601 date, wake/sleep kind, sensor scalars, token/people
/// answers as list values for Obsidian dataview/graph) followed by a body of
/// `##` prompt headings with flattened answers.
///
/// Pure function — returns `[(filename, contents)]`; writing files into a
/// user-chosen folder is the caller's job, so this stays testable without I/O
/// and platform-neutral.
public enum MarkdownExporter {
    public static func export(reports: [Report]) -> [(filename: String, contents: String)] {
        let sorted = reports.sorted {
            ($0.date, $0.uniqueIdentifier) < ($1.date, $1.uniqueIdentifier)
        }
        var seen: [String: Int] = [:]
        return sorted.map { report in
            let base = baseFilename(for: report)
            let count = (seen[base] ?? 0) + 1
            seen[base] = count
            let filename = count == 1 ? "\(base).md" : "\(base) \(count).md"
            return (filename: filename, contents: contents(for: report))
        }
    }

    // MARK: - Filenames

    /// `YYYY-MM-DD HHmm` in the report's own time zone — filesystem-safe
    /// (no colon) and Obsidian-sortable. en_US_POSIX per the repo's stamp
    /// formatter convention.
    private static func baseFilename(for report: Report) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: report.timeZoneIdentifier) ?? .gmt
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        return formatter.string(from: report.date)
    }

    // MARK: - Contents

    private static func contents(for report: Report) -> String {
        var lines = ["---"]
        lines.append(contentsOf: frontMatterLines(for: report))
        lines.append("---")
        let body = bodySections(for: report)
        if !body.isEmpty {
            lines.append("")
            lines.append(body.joined(separator: "\n\n"))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func frontMatterLines(for report: Report) -> [String] {
        var lines: [String] = []
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        iso.timeZone = TimeZone(identifier: "UTC")
        lines.append("date: \(iso.string(from: report.date))")
        lines.append("timezone: \(yamlValue(report.timeZoneIdentifier))")
        if report.kind != .regular {
            lines.append("kind: \(report.kind.rawValue)")
        }
        if let weather = report.weather {
            if let condition = weather.condition, !condition.isEmpty {
                lines.append("weather: \(yamlValue(condition))")
            }
            if let tempF = weather.tempF {
                lines.append("temperature_f: \(number(tempF))")
            }
        }
        if let meters = report.altitudeMeters {
            lines.append("altitude_m: \(number(meters))")
        }
        if let mps = report.speedMPS {
            lines.append("speed_mps: \(number(mps))")
        }
        if let degrees = report.courseDegrees {
            lines.append("course_degrees: \(number(degrees))")
        }
        if let degrees = report.headingDegrees {
            lines.append("heading_degrees: \(number(degrees))")
        }
        if let audio = report.audio {
            lines.append("audio_db: \(number(AudioLevel.displayValue(fromRaw: audio.avg)))")
        }
        if let battery = report.battery {
            lines.append("battery: \(number(battery))")
        }
        if let steps = report.health.first(where: { $0.type == "steps" })?.value {
            lines.append("steps: \(number(steps))")
        }
        if let latitude = report.location?.latitude, let longitude = report.location?.longitude {
            lines.append("latitude: \(number(latitude))")
            lines.append("longitude: \(number(longitude))")
        }
        if let placemark = report.location?.placemark {
            let place = [placemark.name, placemark.locality]
                .compactMap { $0 }
                .first { !$0.isEmpty }
            if let place {
                lines.append("place: \(yamlValue(place))")
            }
        }
        if !report.photos.isEmpty {
            lines.append("photos: \(report.photos.count)")
        }
        if let connection = report.connectionType {
            lines.append("connection: \(yamlValue(connection.displayName))")
        }
        // Token/people answers as YAML lists (both live in `Response.tokens`;
        // the export has no question list to tell them apart, and both are
        // exactly what dataview/graph queries want). Prompt-alphabetized for
        // determinism — relationship order isn't guaranteed across fetches.
        let tokenResponses = (report.responses ?? [])
            .compactMap { response -> (key: String, values: [String])? in
                guard let tokens = response.tokens, !tokens.isEmpty else { return nil }
                return (slug(response.questionPrompt), tokens.map(\.text))
            }
            .sorted { $0.key < $1.key }
        for response in tokenResponses {
            lines.append("\(response.key):")
            lines.append(contentsOf: response.values.map { "  - \(yamlValue($0))" })
        }
        return lines
    }

    private static func bodySections(for report: Report) -> [String] {
        (report.responses ?? [])
            .compactMap { response in
                flattenedAnswer(response).map { (prompt: response.questionPrompt, answer: $0) }
            }
            .sorted { $0.prompt < $1.prompt }
            .map { "## \($0.prompt)\n\n\($0.answer)" }
    }

    /// Same per-type flattening as the Day One entry text — one
    /// representation per answer type, `CSVExporter.flatten` precedence.
    private static func flattenedAnswer(_ response: Response) -> String? {
        if let tokens = response.tokens, !tokens.isEmpty {
            return tokens.map(\.text).joined(separator: ", ")
        }
        if let options = response.answeredOptions, !options.isEmpty {
            return options.joined(separator: ", ")
        }
        if let location = response.locationResponse {
            guard let text = location.text, !text.isEmpty else { return nil }
            return text
        }
        if let time = response.timeResponse {
            return time.dayOffset == -1 ? "\(time.hhmm) (yesterday)" : time.hhmm
        }
        if let numeric = response.numericResponse, !numeric.isEmpty {
            return numeric
        }
        if let texts = response.textResponses, !texts.isEmpty {
            return texts.map(\.text).joined(separator: "\n\n")
        }
        return nil
    }

    // MARK: - YAML

    /// Prompts become front-matter keys: lowercase, alphanumerics kept,
    /// runs of anything else collapse to single hyphens ("Who are you
    /// with?" → "who-are-you-with").
    static func slug(_ prompt: String) -> String {
        let lowered = prompt.lowercased()
        var parts: [String] = []
        var current = ""
        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                parts.append(current)
                current = ""
            }
        }
        if !current.isEmpty { parts.append(current) }
        return parts.joined(separator: "-")
    }

    /// Double-quotes (with escaped interior quotes/backslashes) any value
    /// YAML could misparse — colons, quotes, leading/trailing space, YAML
    /// indicator characters. Plain values pass through unquoted.
    static func yamlValue(_ value: String) -> String {
        let needsQuoting = value.isEmpty
            || value.contains(":") || value.contains("\"") || value.contains("#")
            || value.contains("\n") || value.contains("\\")
            || value.hasPrefix(" ") || value.hasSuffix(" ")
            || "-?[]{}&*!|>%@`'".contains(value.first ?? " ")
        guard needsQuoting else { return value }
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }

    /// Integral doubles render without a trailing ".0" (steps: 481, not 481.0).
    private static func number(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0 && abs(value) < 1e15
            ? String(format: "%.0f", value)
            : "\(value)"
    }
}
