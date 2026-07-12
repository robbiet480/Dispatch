import Foundation

/// Day One JSON export (plan 36). Produces Day One's import format: a
/// top-level `{"metadata": {"version": "1.0"}, "entries": [...]}` envelope,
/// one entry per report. Each entry carries `creationDate` (ISO-8601 UTC),
/// `timeZone`, Markdown `text` (each answered prompt as a `##` heading with
/// the flattened answer, then a trailing sensor-snapshot section), plus the
/// native `location`/`weather` fields where Day One has them and a kind tag
/// for wake/sleep reports.
///
/// Pure function — no I/O, no platform conditionals; writing the Data to disk
/// is the caller's job. Output is deterministic (sorted keys, entries oldest
/// first with identifier tie-break, prompts alphabetized within an entry) so
/// tests can compare full strings. NOTE: format derived from Day One's
/// published JSON import/export shape; verifying a real Day One import of
/// this output is a manual step recorded in the plan wrap.
public enum DayOneExporter {
    public static func export(reports: [Report]) throws -> Data {
        let sorted = reports.sorted {
            ($0.date, $0.uniqueIdentifier) < ($1.date, $1.uniqueIdentifier)
        }
        let envelope = Envelope(
            metadata: Metadata(version: "1.0"),
            entries: sorted.map(entry(for:))
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(envelope)
    }

    // MARK: - Wire DTOs

    private struct Envelope: Encodable {
        var metadata: Metadata
        var entries: [Entry]
    }

    private struct Metadata: Encodable {
        var version: String
    }

    private struct Entry: Encodable {
        var creationDate: String
        var timeZone: String
        var text: String
        var tags: [String]?
        var location: Location?
        var weather: Weather?
    }

    private struct Location: Encodable {
        var latitude: Double
        var longitude: Double
        var placeName: String?
    }

    private struct Weather: Encodable {
        var conditionsDescription: String?
        var temperatureCelsius: Double?
    }

    // MARK: - Entry construction

    private static func entry(for report: Report) -> Entry {
        Entry(
            creationDate: iso8601UTC.string(from: report.date),
            timeZone: report.timeZoneIdentifier,
            text: text(for: report),
            tags: report.kind == .regular ? nil : [report.kind.rawValue],
            location: location(for: report),
            weather: weather(for: report)
        )
    }

    /// Swift 6: ISO8601DateFormatter isn't Sendable, so build per call rather
    /// than share a static instance (export is a one-shot pass, not hot).
    private static var iso8601UTC: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }

    private static func location(for report: Report) -> Location? {
        guard let snapshot = report.location,
              let latitude = snapshot.latitude, let longitude = snapshot.longitude else { return nil }
        let placeName = [snapshot.placemark?.name, snapshot.placemark?.locality]
            .compactMap { $0 }
            .first { !$0.isEmpty }
        return Location(latitude: latitude, longitude: longitude, placeName: placeName)
    }

    private static func weather(for report: Report) -> Weather? {
        guard let observation = report.weather else { return nil }
        let condition = observation.condition.flatMap { $0.isEmpty ? nil : $0 }
        guard condition != nil || observation.tempC != nil else { return nil }
        return Weather(conditionsDescription: condition, temperatureCelsius: observation.tempC)
    }

    // MARK: - Markdown text

    private static func text(for report: Report) -> String {
        var sections: [String] = []
        // Prompts alphabetized: `Report.responses` is a SwiftData to-many
        // relationship whose order isn't guaranteed across fetches, and the
        // pure `export(reports:)` contract has no question list to impose
        // survey order — alphabetical is the deterministic choice.
        let answered = (report.responses ?? [])
            .compactMap { response in
                flattenedAnswer(response).map { (prompt: response.questionPrompt, answer: $0) }
            }
            .sorted { $0.prompt < $1.prompt }
        for item in answered {
            sections.append("## \(item.prompt)\n\n\(item.answer)")
        }
        let sensors = sensorLines(for: report)
        if !sensors.isEmpty {
            let block = sections.isEmpty ? "" : "---\n\n"
            sections.append(block + "### Sensors\n\n" + sensors.map { "- \($0)" }.joined(separator: "\n"))
        }
        return sections.joined(separator: "\n\n")
    }

    /// One representation per answer type — same positional precedence as
    /// `CSVExporter.flatten` (exactly one payload variant populated per
    /// response), joined for prose rather than machine parsing. Returns nil
    /// for skipped questions so they produce no phantom sections.
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
            // Plan 28 convention: locale-independent HH:mm; the yesterday
            // offset reads inline (no companion column in journal text).
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

    /// The report's sensor snapshot as trailing metadata lines — mirrors the
    /// report-detail screen's sensor rows, kit-side and platform-neutral.
    private static func sensorLines(for report: Report) -> [String] {
        var lines: [String] = []
        if let placemark = report.location?.placemark {
            let parts = [placemark.name, placemark.locality, placemark.administrativeArea]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
            if !parts.isEmpty { lines.append("Place: \(parts.joined(separator: ", "))") }
        }
        if let weather = report.weather {
            var parts: [String] = []
            if let condition = weather.condition, !condition.isEmpty { parts.append(condition) }
            if let tempF = weather.tempF { parts.append(String(format: "%.0f°F", tempF)) }
            if !parts.isEmpty { lines.append("Weather: \(parts.joined(separator: ", "))") }
        }
        if let meters = report.altitudeMeters {
            lines.append(String(format: "Altitude: %.0f m", meters))
        }
        if let audio = report.audio {
            lines.append(String(format: "Sound: %.1f dB avg", AudioLevel.displayValue(fromRaw: audio.avg)))
        }
        if let steps = report.health.first(where: { $0.type == "steps" }) {
            lines.append(String(format: "Steps: %.0f", steps.value))
        }
        if let battery = report.battery {
            lines.append(String(format: "Battery: %.0f%%", battery * 100))
        }
        if let focus = report.focus {
            lines.append("Focus: \(focus.isFocused ? (focus.label ?? "On") : "Off")")
        }
        if let connection = report.connectionType {
            lines.append("Connection: \(connection.displayName)")
        }
        if let media = report.media {
            lines.append("Media: \(media.detailLine)")
        }
        if !report.photos.isEmpty {
            lines.append("Photos: \(report.photos.count)")
        }
        return lines
    }
}
