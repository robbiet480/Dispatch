import Foundation
import SwiftData
import Testing
@testable import DispatchKit

/// Plan 36: Day One JSON export. Format per Day One's import format —
/// top-level `{"metadata": {"version": "1.0"}, "entries": [...]}`, each entry
/// carrying `creationDate` (ISO-8601 UTC), `text` (Markdown), `timeZone`, and
/// optional `location`/`weather`/`tags` native fields.
private func makeContext() throws -> ModelContext {
    ModelContext(try DispatchStore.inMemoryContainer())
}

private func decode(_ data: Data) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func entries(_ data: Data) throws -> [[String: Any]] {
    try #require(try decode(data)["entries"] as? [[String: Any]])
}

@Test func dayOneEnvelopeHasMetadataVersionAndOneEntryPerReport() throws {
    let context = try makeContext()
    for (index, interval) in [1_700_000_000.0, 1_700_100_000.0].enumerated() {
        let report = Report()
        report.uniqueIdentifier = "r-\(index)"
        report.date = Date(timeIntervalSince1970: interval)
        context.insert(report)
    }

    let data = try DayOneExporter.export(reports: try context.fetch(FetchDescriptor<Report>()))
    let envelope = try decode(data)
    let metadata = try #require(envelope["metadata"] as? [String: Any])
    #expect(metadata["version"] as? String == "1.0")
    #expect(try entries(data).count == 2)
}

@Test func dayOneCreationDateIsISO8601UTCAndEntriesSortOldestFirst() throws {
    let context = try makeContext()
    let newer = Report()
    newer.uniqueIdentifier = "r-newer"
    newer.date = Date(timeIntervalSince1970: 1_700_100_000) // 2023-11-16T02:00:00Z
    newer.timeZoneIdentifier = "America/New_York"
    let older = Report()
    older.uniqueIdentifier = "r-older"
    older.date = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14T22:13:20Z
    older.timeZoneIdentifier = "America/Los_Angeles"
    context.insert(newer)
    context.insert(older)

    let data = try DayOneExporter.export(reports: try context.fetch(FetchDescriptor<Report>()))
    let list = try entries(data)
    #expect(list.map { $0["creationDate"] as? String } == [
        "2023-11-14T22:13:20Z", "2023-11-16T02:00:00Z",
    ])
    #expect(list.first?["timeZone"] as? String == "America/Los_Angeles")
}

@Test func dayOneTextRendersEachAnsweredPromptAsHeading() throws {
    let context = try makeContext()
    let report = Report()
    report.uniqueIdentifier = "r-1"
    report.date = Date(timeIntervalSince1970: 1_700_000_000)

    func respond(_ prompt: String, _ configure: (Response) -> Void) {
        let response = Response()
        response.questionPrompt = prompt
        configure(response)
        response.report = report
        report.responses = (report.responses ?? []) + [response]
    }

    respond("What are you doing?") { $0.tokens = [TokenValue(text: "Working"), TokenValue(text: "Coding")] }
    respond("Are you working?") { $0.answeredOptions = ["Yes"] }
    respond("How happy are you?") { $0.numericResponse = "7" }
    respond("Pick one") { $0.answeredOptions = ["Blue", "Green"] }
    respond("Where are you?") {
        var answer = LocationAnswer()
        answer.text = "The Plaza"
        $0.locationResponse = answer
    }
    respond("Notes?") { $0.textResponses = [TokenValue(text: "A fine day.")] }
    respond("Who are you with?") { $0.tokens = [TokenValue(text: "Ada")] }
    respond("When did you eat?") { $0.timeResponse = TimeAnswer(minutesSinceMidnight: 555) }
    context.insert(report)

    let data = try DayOneExporter.export(reports: try context.fetch(FetchDescriptor<Report>()))
    let text = try #require(try entries(data).first?["text"] as? String)

    #expect(text.contains("## What are you doing?\n\nWorking, Coding"))
    #expect(text.contains("## Are you working?\n\nYes"))
    #expect(text.contains("## How happy are you?\n\n7"))
    #expect(text.contains("## Pick one\n\nBlue, Green"))
    #expect(text.contains("## Where are you?\n\nThe Plaza"))
    #expect(text.contains("## Notes?\n\nA fine day."))
    #expect(text.contains("## Who are you with?\n\nAda"))
    #expect(text.contains("## When did you eat?\n\n09:15"))
}

@Test func dayOneTimeAnswerWithYesterdayOffsetSaysSo() throws {
    let context = try makeContext()
    let report = Report()
    report.uniqueIdentifier = "r-1"
    report.date = Date(timeIntervalSince1970: 1_700_000_000)
    let response = Response()
    response.questionPrompt = "When did you sleep?"
    response.timeResponse = TimeAnswer(minutesSinceMidnight: 1_380, dayOffset: -1) // 23:00 yesterday
    response.report = report
    report.responses = [response]
    context.insert(report)

    let data = try DayOneExporter.export(reports: try context.fetch(FetchDescriptor<Report>()))
    let text = try #require(try entries(data).first?["text"] as? String)
    #expect(text.contains("## When did you sleep?\n\n23:00 (yesterday)"))
}

@Test func dayOneLocationAnswerAndSnapshotMapToNativeLocationField() throws {
    let context = try makeContext()
    let report = Report()
    report.uniqueIdentifier = "r-1"
    report.date = Date(timeIntervalSince1970: 1_700_000_000)
    var snapshot = LocationSnapshot(latitude: 37.7749, longitude: -122.4194)
    var placemark = Placemark()
    placemark.name = "Ferry Building"
    placemark.locality = "San Francisco"
    snapshot.placemark = placemark
    report.location = snapshot
    context.insert(report)

    let data = try DayOneExporter.export(reports: try context.fetch(FetchDescriptor<Report>()))
    let location = try #require(try entries(data).first?["location"] as? [String: Any])
    #expect(location["latitude"] as? Double == 37.7749)
    #expect(location["longitude"] as? Double == -122.4194)
    #expect(location["placeName"] as? String == "Ferry Building")
}

@Test func dayOneWeatherMapsToNativeFieldAndSensorsTrailTheText() throws {
    let context = try makeContext()
    let report = Report()
    report.uniqueIdentifier = "r-1"
    report.date = Date(timeIntervalSince1970: 1_700_000_000)
    var weather = WeatherObservation()
    weather.condition = "Sunny"
    weather.tempF = 72
    weather.tempC = 22.2
    report.weather = weather
    report.battery = 0.8
    report.health = [HealthReading(type: "steps", value: 481, unit: "count")]
    context.insert(report)

    let data = try DayOneExporter.export(reports: try context.fetch(FetchDescriptor<Report>()))
    let entry = try #require(try entries(data).first)
    let native = try #require(entry["weather"] as? [String: Any])
    #expect(native["conditionsDescription"] as? String == "Sunny")
    #expect(native["temperatureCelsius"] as? Double == 22.2)

    let text = try #require(entry["text"] as? String)
    #expect(text.contains("Weather: Sunny, 72°F"))
    #expect(text.contains("Steps: 481"))
    #expect(text.contains("Battery: 80%"))
}

@Test func dayOneEmptyReportProducesNoPhantomSections() throws {
    let context = try makeContext()
    let report = Report()
    report.uniqueIdentifier = "r-1"
    report.date = Date(timeIntervalSince1970: 1_700_000_000)
    // One skipped question: a response with no answer payload at all.
    let skipped = Response()
    skipped.questionPrompt = "Skipped?"
    skipped.report = report
    report.responses = [skipped]
    context.insert(report)

    let data = try DayOneExporter.export(reports: try context.fetch(FetchDescriptor<Report>()))
    let entry = try #require(try entries(data).first)
    let text = try #require(entry["text"] as? String)
    #expect(!text.contains("##"))
    #expect(!text.contains("Skipped?"))
    #expect(!text.contains("Sensors"))
    #expect(entry["location"] == nil)
    #expect(entry["weather"] == nil)
}

@Test func dayOneNonRegularReportKindBecomesTag() throws {
    let context = try makeContext()
    let wake = Report()
    wake.uniqueIdentifier = "r-wake"
    wake.date = Date(timeIntervalSince1970: 1_700_000_000)
    wake.kind = .wake
    let regular = Report()
    regular.uniqueIdentifier = "r-regular"
    regular.date = Date(timeIntervalSince1970: 1_700_100_000)
    context.insert(wake)
    context.insert(regular)

    let data = try DayOneExporter.export(reports: try context.fetch(FetchDescriptor<Report>()))
    let list = try entries(data)
    #expect(list[0]["tags"] as? [String] == ["wake"])
    #expect(list[1]["tags"] == nil)
}

@Test func dayOneOutputIsDeterministic() throws {
    let context = try makeContext()
    let report = Report()
    report.uniqueIdentifier = "r-1"
    report.date = Date(timeIntervalSince1970: 1_700_000_000)
    // Responses deliberately attached in non-alphabetical order — the export
    // must impose its own stable ordering, not trust relationship order.
    for prompt in ["Zebra?", "Apple?", "Mango?"] {
        let response = Response()
        response.questionPrompt = prompt
        response.tokens = [TokenValue(text: "x")]
        response.report = report
        report.responses = (report.responses ?? []) + [response]
    }
    context.insert(report)

    let reports = try context.fetch(FetchDescriptor<Report>())
    let first = try DayOneExporter.export(reports: reports)
    let second = try DayOneExporter.export(reports: reports)
    #expect(first == second)

    let text = try #require(try entries(first).first?["text"] as? String)
    let zebra = try #require(text.range(of: "## Zebra?"))
    let apple = try #require(text.range(of: "## Apple?"))
    let mango = try #require(text.range(of: "## Mango?"))
    #expect(apple.lowerBound < mango.lowerBound)
    #expect(mango.lowerBound < zebra.lowerBound)
}
