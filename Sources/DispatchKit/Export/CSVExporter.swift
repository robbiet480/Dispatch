import Foundation
import SwiftData

public enum CSVExporter {
    static let sensorColumns = [
        "date", "timeZone", "kind", "trigger", "latitude", "longitude", "place",
        "weather", "tempF", "altitudeMeters", "audioAvg", "audioPeak",
        "battery", "steps", "photoCount",
    ]

    public static func exportCSV(from context: ModelContext) throws -> String {
        let questions = try context.fetch(
            FetchDescriptor<Question>(sortBy: [SortDescriptor(\.sortOrder)]))
        let prompts = questions.map(\.prompt)
        let reports = try context.fetch(
            FetchDescriptor<Report>(sortBy: [SortDescriptor(\.date)]))

        var rows = [(sensorColumns + prompts).map(escape).joined(separator: ",")]

        let dateFormatter = ISO8601DateFormatter()
        for report in reports {
            let byPrompt = Dictionary(report.responses.map { ($0.questionPrompt, $0) },
                                      uniquingKeysWith: { first, _ in first })
            var fields: [String] = [
                dateFormatter.string(from: report.date),
                report.timeZoneIdentifier,
                report.kind.rawValue,
                report.trigger.rawValue,
                report.location.map { String($0.latitude) } ?? "",
                report.location.map { String($0.longitude) } ?? "",
                report.location?.placemark?.locality ?? "",
                report.weather?.condition ?? "",
                report.weather?.tempF.map { String($0) } ?? "",
                report.altitudeMeters.map { String($0) } ?? "",
                report.audio.map { String($0.avg) } ?? "",
                report.audio.map { String($0.peak) } ?? "",
                report.battery.map { String($0) } ?? "",
                report.health.first { $0.type == "steps" }.map { String(Int($0.value)) } ?? "",
                String(report.photos.count),
            ]
            for prompt in prompts {
                fields.append(flatten(byPrompt[prompt]))
            }
            rows.append(fields.map(escape).joined(separator: ","))
        }
        return rows.joined(separator: "\n")
    }

    static func flatten(_ response: Response?) -> String {
        guard let response else { return "" }
        // Positional precedence assumes exactly one payload variant (tokens,
        // answeredOptions, locationResponse, numericResponse, textResponses)
        // is populated per response, matching a single question type's answer shape.
        if let tokens = response.tokens { return tokens.map(\.text).joined(separator: "|") }
        if let options = response.answeredOptions { return options.joined(separator: "|") }
        if let location = response.locationResponse { return location.text ?? "" }
        if let numeric = response.numericResponse { return numeric }
        if let texts = response.textResponses { return texts.map(\.text).joined(separator: "|") }
        return ""
    }

    static func escape(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
