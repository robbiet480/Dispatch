import Foundation
import SwiftData
import Testing
@testable import DispatchKit

/// Plan 36: Markdown/Obsidian export — one `.md` file per report with YAML
/// front matter (ISO-8601 date, sensor scalars, tokens/people as YAML lists)
/// and prompt-heading body sections. Pure `[(filename, contents)]` contract;
/// writing to disk is the caller's job.
private func makeContext() throws -> ModelContext {
    ModelContext(try DispatchStore.inMemoryContainer())
}

/// A UTC report at 2023-11-14 22:13:20Z; filename minutes derive from the
/// report's own time zone (GMT default here).
private func makeReport(id: String = "r-1",
                        interval: TimeInterval = 1_700_000_000,
                        timeZone: String = "GMT") -> Report {
    let report = Report()
    report.uniqueIdentifier = id
    report.date = Date(timeIntervalSince1970: interval)
    report.timeZoneIdentifier = timeZone
    return report
}

private func respond(_ report: Report, prompt: String, _ configure: (Response) -> Void) {
    let response = Response()
    response.questionPrompt = prompt
    configure(response)
    response.report = report
    report.responses = (report.responses ?? []) + [response]
}

@Test func markdownFilenameIsReportLocalDateAndTime() throws {
    let context = try makeContext()
    context.insert(makeReport(timeZone: "America/Los_Angeles")) // 14:13 local
    let files = MarkdownExporter.export(reports: try context.fetch(FetchDescriptor<Report>()))
    #expect(files.map(\.filename) == ["2023-11-14 1413.md"])
}

@Test func markdownSameMinuteReportsGetDeterministicCollisionSuffixes() throws {
    let context = try makeContext()
    context.insert(makeReport(id: "r-b", interval: 1_700_000_000))
    context.insert(makeReport(id: "r-a", interval: 1_700_000_030)) // same minute, 30s later
    context.insert(makeReport(id: "r-c", interval: 1_700_000_035)) // 22:13:55, still same minute
    let files = MarkdownExporter.export(reports: try context.fetch(FetchDescriptor<Report>()))
    #expect(files.map(\.filename) == [
        "2023-11-14 2213.md", "2023-11-14 2213 2.md", "2023-11-14 2213 3.md",
    ])
}

@Test func markdownFrontMatterCarriesDateKindAndSensorScalars() throws {
    let context = try makeContext()
    let report = makeReport()
    report.kind = .wake
    var weather = WeatherObservation()
    weather.condition = "Sunny"
    weather.tempF = 72
    report.weather = weather
    report.battery = 0.8
    report.altitudeMeters = 12.5
    report.health = [HealthReading(type: "steps", value: 481, unit: "count")]
    var snapshot = LocationSnapshot(latitude: 37.7749, longitude: -122.4194)
    var placemark = Placemark()
    placemark.locality = "San Francisco"
    snapshot.placemark = placemark
    report.location = snapshot
    context.insert(report)

    let contents = try #require(MarkdownExporter.export(
        reports: try context.fetch(FetchDescriptor<Report>())).first?.contents)

    #expect(contents.hasPrefix("---\n"))
    let frontMatter = try #require(contents.components(separatedBy: "\n---\n").first)
    #expect(frontMatter.contains("date: 2023-11-14T22:13:20Z"))
    #expect(frontMatter.contains("kind: wake"))
    #expect(frontMatter.contains("weather: Sunny"))
    #expect(frontMatter.contains("temperature_f: 72"))
    #expect(frontMatter.contains("battery: 0.8"))
    #expect(frontMatter.contains("altitude_m: 12.5"))
    #expect(frontMatter.contains("steps: 481"))
    #expect(frontMatter.contains("latitude: 37.7749"))
    #expect(frontMatter.contains("longitude: -122.4194"))
    #expect(frontMatter.contains("place: San Francisco"))
}

@Test func markdownTokensAndPeopleEmitAsFrontMatterLists() throws {
    let context = try makeContext()
    let report = makeReport()
    respond(report, prompt: "What are you doing?") {
        $0.tokens = [TokenValue(text: "Working"), TokenValue(text: "Coding")]
    }
    respond(report, prompt: "Who are you with?") {
        $0.tokens = [TokenValue(text: "Ada Lovelace")]
    }
    context.insert(report)

    let contents = try #require(MarkdownExporter.export(
        reports: try context.fetch(FetchDescriptor<Report>())).first?.contents)
    let frontMatter = try #require(contents.components(separatedBy: "\n---\n").first)

    #expect(frontMatter.contains("what-are-you-doing:\n  - Working\n  - Coding"))
    #expect(frontMatter.contains("who-are-you-with:\n  - Ada Lovelace"))
}

@Test func markdownBodyRendersAnsweredPromptsAsHeadings() throws {
    let context = try makeContext()
    let report = makeReport()
    respond(report, prompt: "Are you working?") { $0.answeredOptions = ["Yes"] }
    respond(report, prompt: "Notes?") { $0.textResponses = [TokenValue(text: "A fine day.")] }
    respond(report, prompt: "When did you eat?") {
        $0.timeResponse = TimeAnswer(minutesSinceMidnight: 555)
    }
    respond(report, prompt: "Skipped?") { _ in }
    context.insert(report)

    let contents = try #require(MarkdownExporter.export(
        reports: try context.fetch(FetchDescriptor<Report>())).first?.contents)
    let body = try #require(contents.components(separatedBy: "\n---\n").last)

    #expect(body.contains("## Are you working?\n\nYes"))
    #expect(body.contains("## Notes?\n\nA fine day."))
    #expect(body.contains("## When did you eat?\n\n09:15"))
    #expect(!body.contains("Skipped?"))
}

@Test func markdownYAMLEscapesQuotesAndColons() throws {
    let context = try makeContext()
    let report = makeReport()
    respond(report, prompt: "Mood: how so?") {
        $0.tokens = [TokenValue(text: #"said "hi": twice"#)]
    }
    var weather = WeatherObservation()
    weather.condition = "Rain: heavy"
    report.weather = weather
    context.insert(report)

    let contents = try #require(MarkdownExporter.export(
        reports: try context.fetch(FetchDescriptor<Report>())).first?.contents)
    let frontMatter = try #require(contents.components(separatedBy: "\n---\n").first)

    // Values containing YAML-special characters are double-quoted with
    // interior quotes escaped; the prompt key is slugged to safe characters.
    #expect(frontMatter.contains(#"weather: "Rain: heavy""#))
    #expect(frontMatter.contains(#"  - "said \"hi\": twice""#))
    #expect(frontMatter.contains("mood-how-so:"))
}

@Test func markdownHasNoTrailingWhitespaceDamage() throws {
    let context = try makeContext()
    let report = makeReport()
    respond(report, prompt: "Are you working?") { $0.answeredOptions = ["Yes"] }
    context.insert(report)

    let contents = try #require(MarkdownExporter.export(
        reports: try context.fetch(FetchDescriptor<Report>())).first?.contents)

    for line in contents.components(separatedBy: "\n") {
        #expect(line == line.replacingOccurrences(of: #"[ \t]+$"#, with: "", options: .regularExpression))
    }
    #expect(contents.hasSuffix("\n"))
    #expect(!contents.hasSuffix("\n\n"))
}

/// Prompt headings render in stable alphabetical order regardless of the order
/// responses were attached. Byte-for-byte determinism across all four
/// exporters is covered by ExporterDeterminismTests.
@Test func markdownSortsPromptHeadingsAlphabetically() throws {
    let context = try makeContext()
    let report = makeReport()
    for prompt in ["Zebra?", "Apple?", "Mango?"] {
        respond(report, prompt: prompt) { $0.tokens = [TokenValue(text: "x")] }
    }
    context.insert(report)

    let files = MarkdownExporter.export(reports: try context.fetch(FetchDescriptor<Report>()))
    let body = try #require(files.first?.contents)
    let apple = try #require(body.range(of: "## Apple?"))
    let mango = try #require(body.range(of: "## Mango?"))
    let zebra = try #require(body.range(of: "## Zebra?"))
    #expect(apple.lowerBound < mango.lowerBound)
    #expect(mango.lowerBound < zebra.lowerBound)
}
