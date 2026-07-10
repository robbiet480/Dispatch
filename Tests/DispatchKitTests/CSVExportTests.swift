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
    #expect(header.hasPrefix("date,timeZone,kind,trigger,latitude,longitude,place,weather,tempF,altitudeMeters,audioAvg,audioPeak,battery,steps,photoCount"))
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
