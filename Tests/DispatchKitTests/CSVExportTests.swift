import Foundation
import SwiftData
import Testing
@testable import DispatchKit

@Test func exportsCSVWithQuestionColumns() throws {
    let container = try DispatchStore.inMemoryContainer()
    let context = ModelContext(container)
    _ = try V1Importer.importExport(try fixtureData("v1-sample"), into: context)

    let csv = try CSVExporter.exportCSV(from: context)
    let lines = csv.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

    // Header: fixed sensor columns then question prompts in sortOrder.
    let header = lines[0]
    #expect(header.hasPrefix("date,timeZone,kind,trigger,latitude,longitude,place,weather,tempF,altitudeMeters,speedMPS,courseDegrees,headingDegrees,audioAvg,audioPeak,battery,steps,photoCount"))
    #expect(header.contains("What are you doing?"))
    #expect(header.contains("Who are you with?"))

    // 3 reports → 4 lines (header + 3), oldest first.
    #expect(lines.count == 4)
    let snap1Row = try #require(lines.first { $0.contains("2016-02-11") })
    #expect(snap1Row.contains("Working|Coding")) // tokens joined with |
    #expect(snap1Row.contains(",Yes,"))          // answeredOptions joined
    #expect(snap1Row.contains(",481,"))          // steps from health array

    // snap-2 files at 20:10 -0400 == 00:10Z the NEXT day; CSV dates are UTC ISO8601.
    let snap2Row = try #require(lines.first { $0.contains("2015-10-22") })
    #expect(snap2Row.contains("The Plaza"))      // locationResponse text

    let snap1Row2 = try #require(lines.first { $0.contains("2016-02-11") })
    #expect(snap1Row2.contains(#""Commas, and ""quotes"" happen""#))
}

/// Plan 28: a time question grows a "(day offset)" companion column immediately
/// after its prompt column. Time answers render "HH:mm" + numeric offset; both
/// columns are empty when unanswered; non-time columns are untouched.
@Test func csvTimeQuestionAddsDayOffsetCompanionColumn() throws {
    let container = try DispatchStore.inMemoryContainer()
    let context = ModelContext(container)

    let eat = Question()
    eat.uniqueIdentifier = "q-eat"
    eat.prompt = "What time did you last eat?"
    eat.type = .time
    eat.sortOrder = 0
    let doing = Question()
    doing.uniqueIdentifier = "q-doing"
    doing.prompt = "Doing?"
    doing.type = .tokens
    doing.sortOrder = 1
    context.insert(eat)
    context.insert(doing)

    func report(_ id: String, at date: Date, time: TimeAnswer?, doing text: String?) {
        let report = Report()
        report.uniqueIdentifier = id
        report.date = date
        var responses: [Response] = []
        if let time {
            let r = Response()
            r.questionPrompt = "What time did you last eat?"
            r.questionIdentifier = "q-eat"
            r.timeResponse = time
            responses.append(r)
        }
        if let text {
            let r = Response()
            r.questionPrompt = "Doing?"
            r.questionIdentifier = "q-doing"
            r.tokens = [TokenValue(text: text)]
            responses.append(r)
        }
        report.responses = responses
        for r in responses { r.report = report }
        context.insert(report)
    }

    let base = Date(timeIntervalSince1970: 1_700_000_000)
    report("r-1", at: base, time: TimeAnswer(minutesSinceMidnight: 555), doing: "Working")           // 09:15, offset 0
    report("r-2", at: base.addingTimeInterval(60), time: TimeAnswer(minutesSinceMidnight: 1410, dayOffset: -1), doing: "Sleeping") // 23:30, -1
    report("r-3", at: base.addingTimeInterval(120), time: nil, doing: "Idle")                          // unanswered
    try context.save()

    let csv = try CSVExporter.exportCSV(from: context)
    let lines = csv.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let header = lines[0].split(separator: ",", omittingEmptySubsequences: false).map(String.init)

    let eatIndex = try #require(header.firstIndex(of: "What time did you last eat?"))
    #expect(header[eatIndex + 1] == "What time did you last eat? (day offset)")
    #expect(header.contains("Doing?"))

    let r1 = lines[1].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
    #expect(r1[eatIndex] == "09:15")
    #expect(r1[eatIndex + 1] == "0")
    let r2 = lines[2].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
    #expect(r2[eatIndex] == "23:30")
    #expect(r2[eatIndex + 1] == "-1")
    let r3 = lines[3].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
    #expect(r3[eatIndex] == "")
    #expect(r3[eatIndex + 1] == "")
    // Non-time column stays intact.
    let doingIndex = try #require(header.firstIndex(of: "Doing?"))
    #expect(r1[doingIndex] == "Working")
}

@Test func escapesCSVFields() {
    #expect(CSVExporter.escape(#"say "hi", ok"#) == #""say ""hi"", ok""#)
    #expect(CSVExporter.escape("plain") == "plain")
    #expect(CSVExporter.escape("line\nbreak") == "\"line\nbreak\"")
}

/// Plan 26: `connection` is APPENDED to the end of the sensor columns (after
/// photoCount, before question prompts) so consumers' column prefix is stable.
@Test func csvIncludesTrailingConnectionColumn() throws {
    let container = try DispatchStore.inMemoryContainer()
    let context = ModelContext(container)
    let fiveG = Report()
    fiveG.uniqueIdentifier = "r-5g"
    fiveG.connection = 4
    context.insert(fiveG)
    let noConnection = Report()
    noConnection.uniqueIdentifier = "r-nil-connection"
    noConnection.date = fiveG.date.addingTimeInterval(60)
    context.insert(noConnection)
    try context.save()

    let csv = try CSVExporter.exportCSV(from: context)
    let lines = csv.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    #expect(lines[0].hasSuffix("photoCount,connection"))

    let columns = lines[0].split(separator: ",").map(String.init)
    let connectionIndex = try #require(columns.firstIndex(of: "connection"))
    #expect(lines[1].split(separator: ",", omittingEmptySubsequences: false).map(String.init)[connectionIndex] == "5G")
    #expect(lines[2].split(separator: ",", omittingEmptySubsequences: false).map(String.init)[connectionIndex] == "")
}
