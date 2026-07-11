import Foundation
import SwiftData

public enum CSVExporter {
    static let sensorColumns = [
        "date", "timeZone", "kind", "trigger", "latitude", "longitude", "place",
        "weather", "tempF", "altitudeMeters", "speedMPS", "courseDegrees", "headingDegrees",
        "audioAvg", "audioPeak", "battery", "steps", "photoCount", "connection",
    ]

    public static func exportCSV(from context: ModelContext) throws -> String {
        let questions = try context.fetch(
            FetchDescriptor<Question>(sortBy: [SortDescriptor(\.sortOrder)]))
        let reports = try context.fetch(
            FetchDescriptor<Report>(sortBy: [SortDescriptor(\.date)]))

        // One column per prompt, plus a "(day offset)" companion immediately
        // after every TIME question's column (plan 28): keeps the time value
        // cleanly machine-parseable ("HH:mm") and the offset numeric, without
        // disturbing column-by-prompt lookups for existing question types.
        var questionColumns: [String] = []
        for question in questions {
            questionColumns.append(question.prompt)
            if question.type == .time { questionColumns.append("\(question.prompt) (day offset)") }
        }

        var rows = [(sensorColumns + questionColumns).map(escape).joined(separator: ",")]

        let dateFormatter = ISO8601DateFormatter()
        for report in reports {
            let byPrompt = Dictionary((report.responses ?? []).map { ($0.questionPrompt, $0) },
                                      uniquingKeysWith: { first, _ in first })
            var fields: [String] = [
                dateFormatter.string(from: report.date),
                report.timeZoneIdentifier,
                report.kind.rawValue,
                report.trigger.rawValue,
                report.location?.latitude.map { String($0) } ?? "",
                report.location?.longitude.map { String($0) } ?? "",
                report.location?.placemark?.locality ?? "",
                report.weather?.condition ?? "",
                report.weather?.tempF.map { String($0) } ?? "",
                report.altitudeMeters.map { String($0) } ?? "",
                report.speedMPS.map { String($0) } ?? "",
                report.courseDegrees.map { String($0) } ?? "",
                report.headingDegrees.map { String($0) } ?? "",
                report.audio.map { String($0.avg) } ?? "",
                report.audio.map { String($0.peak) } ?? "",
                report.battery.map { String($0) } ?? "",
                report.health.first { $0.type == "steps" }.map { String(Int($0.value)) } ?? "",
                String(report.photos.count),
                report.connectionType?.displayName ?? "",
            ]
            for question in questions {
                let response = byPrompt[question.prompt]
                fields.append(flatten(response))
                if question.type == .time {
                    fields.append(response?.timeResponse.map { String($0.dayOffset) } ?? "")
                }
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
        if let time = response.timeResponse { return time.hhmm }
        if let numeric = response.numericResponse { return numeric }
        if let texts = response.textResponses { return texts.map(\.text).joined(separator: "|") }
        return ""
    }

    static func escape(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
