import Foundation
import Testing
@testable import DispatchKit

/// Fixed export stamp for byte-identical assertions: the default
/// `.current()` stamp captures Date() (and process-global DeviceIdentity
/// state), so any test comparing two exports byte-for-byte must pin one.
let fixedStamp = V2ExportStamp(createdAt: Date(timeIntervalSince1970: 1_780_000_000),
                               sourceDeviceModel: "TestDevice1,1",
                               sourceDeviceName: "Test Device")

func fixtureData(_ name: String) throws -> Data {
    let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "json")
        ?? Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")
    return try Data(contentsOf: try #require(url))
}

@Test func decodesV1Fixture() throws {
    let export = try V1Export.decode(from: try fixtureData("v1-sample"))
    #expect(export.questions.count == 7)
    #expect(export.snapshots.count == 3)
}

@Test func decodesQuestionTypes() throws {
    let export = try V1Export.decode(from: try fixtureData("v1-sample"))
    let types = Dictionary(uniqueKeysWithValues: export.questions.map { ($0.uniqueIdentifier, $0.questionType) })
    #expect(types["q-tokens"] == QuestionType.tokens.rawValue)
    #expect(types["q-multi"] == QuestionType.multipleChoice.rawValue)
    #expect(types["q-yesno"] == QuestionType.yesNo.rawValue)
    #expect(types["q-location"] == QuestionType.location.rawValue)
    #expect(types["q-people"] == QuestionType.people.rawValue)
    #expect(types["q-number"] == QuestionType.number.rawValue)
    #expect(types["q-note"] == QuestionType.note.rawValue)
}

@Test func decodesResponseVariants() throws {
    let export = try V1Export.decode(from: try fixtureData("v1-sample"))
    let snap1 = try #require(export.snapshots.first { $0.uniqueIdentifier == "snap-1" })
    #expect(snap1.responses?.first { $0.uniqueIdentifier == "r-1a" }?.tokens?.count == 2)
    #expect(snap1.responses?.first { $0.uniqueIdentifier == "r-1b" }?.answeredOptions == ["Yes"])
    #expect(snap1.responses?.first { $0.uniqueIdentifier == "r-1d" }?.numericResponse == "3")

    let snap2 = try #require(export.snapshots.first { $0.uniqueIdentifier == "snap-2" })
    #expect(snap2.responses?.first { $0.uniqueIdentifier == "r-2a" }?.locationResponse?.text == "The Plaza")
    #expect(snap2.responses?.first { $0.uniqueIdentifier == "r-2b" }?.textResponses?.first?.text == "SwiftData exists")
    let skipped = try #require(snap2.responses?.first { $0.uniqueIdentifier == "r-2c" })
    #expect(skipped.tokens == nil && skipped.answeredOptions == nil && skipped.numericResponse == nil)
    #expect(snap2.photoSet?.photos.count == 1)

    let snap3 = try #require(export.snapshots.first { $0.uniqueIdentifier == "snap-3" })
    #expect(snap3.location == nil && snap3.weather == nil)
}

@Test func parsesColonlessOffsetDates() throws {
    let parsed = try #require(V1DateParser.parse("2016-02-11T19:08:54-0400"))
    #expect(parsed.utcOffsetSeconds == -4 * 3600)
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(secondsFromGMT: 0)!
    #expect(cal.component(.hour, from: parsed.date) == 23) // 19:08 -0400 == 23:08 UTC
}

@Test func parsesColonOffsetDates() throws {
    let parsed = try #require(V1DateParser.parse("2016-02-11T19:08:54-04:00"))
    #expect(parsed.utcOffsetSeconds == -4 * 3600)
    let colonless = try #require(V1DateParser.parse("2016-02-11T19:08:54-0400"))
    #expect(parsed.date == colonless.date)
}

@Test func decodesLegacyVariants() throws {
    // Legacy exports: numeric dates (seconds since 2001-01-01 GMT),
    // bare-string tokens, singular textResponse (gist.github.com/dbreunig/9315705).
    let json = Data("""
    {"questions": [], "snapshots": [{
        "uniqueIdentifier": "legacy-1",
        "date": 415092465.0,
        "responses": [
            {"questionPrompt": "What are you doing?", "uniqueIdentifier": "lr-1", "tokens": ["Working"]},
            {"questionPrompt": "What did you learn today?", "uniqueIdentifier": "lr-2", "textResponse": "Old format"}
        ]
    }]}
    """.utf8)
    let export = try V1Export.decode(from: json)
    let snap = try #require(export.snapshots.first)
    let resolved = try #require(snap.date.resolved)
    #expect(resolved.date == Date(timeIntervalSinceReferenceDate: 415_092_465.0))
    #expect(resolved.utcOffsetSeconds == 0)
    #expect(snap.responses?.first?.tokens?.first?.text == "Working")
    #expect(snap.responses?.last?.textResponses?.first?.text == "Old format")
}

@Test func decodesRealExportIfPresent() throws {
    // Local-only: DISPATCH_V1_EXPORT=/path/to/reporter-export.json swift test
    guard let path = ProcessInfo.processInfo.environment["DISPATCH_V1_EXPORT"] else { return }
    let export = try V1Export.decode(from: try Data(contentsOf: URL(fileURLWithPath: path)))
    #expect(export.snapshots.count == 94)
    #expect(export.questions.count == 38)
}
