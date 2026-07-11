import Foundation
import SwiftData
import Testing
@testable import DispatchKit

@Test func exportsV2JSON() throws {
    let container = try DispatchStore.inMemoryContainer()
    let context = ModelContext(container)
    _ = try V1Importer.importExport(try fixtureData("v1-sample"), into: context)

    let data = try V2Exporter.exportData(from: context)
    let decoded = try JSONDecoder.v2.decode(V2Export.self, from: data)

    #expect(decoded.schemaVersion == 2)
    #expect(decoded.questions.count == 7)
    #expect(decoded.reports.count == 3)

    let snap1 = try #require(decoded.reports.first { $0.uniqueIdentifier == "snap-1" })
    #expect(snap1.kind == .regular)
    #expect(snap1.trigger == .manual)
    #expect(snap1.legacyImpetus == 0)
    #expect(snap1.timeZone == TimeZone(secondsFromGMT: -4 * 3600)!.identifier)
    #expect(snap1.health?.first { $0.type == "steps" }?.value == 481)
    #expect(snap1.responses?.count == 5)

    let multi = try #require(decoded.questions.first { $0.uniqueIdentifier == "q-multi" })
    #expect(multi.questionType == QuestionType.multipleChoice.rawValue)
    #expect(multi.reportKinds == [.regular])
}

/// Nil plan-11 question fields must be OMITTED from exported JSON — not
/// serialized as null — so pre-existing v2 exports stay byte-identical.
@Test func nilQuestionFieldsAreOmittedFromExportedJSON() throws {
    let container = try DispatchStore.inMemoryContainer()
    let context = ModelContext(container)
    let question = Question()
    question.uniqueIdentifier = "q-plain"
    question.prompt = "Plain?"
    question.type = .multipleChoice
    context.insert(question)
    try context.save()

    let data = try V2Exporter.exportData(from: context)
    let json = try #require(String(data: data, encoding: .utf8))
    #expect(!json.contains("\"visualization\""))
    #expect(!json.contains("\"defaultAnswerString\""))
    #expect(!json.contains("\"allowsMultipleSelection\""))
    // Plan-21 input-style fields share the same nil-omission contract.
    #expect(!json.contains("\"inputStyle\""))
    #expect(!json.contains("\"inputMin\""))
    #expect(!json.contains("\"inputMax\""))
    #expect(!json.contains("\"inputStep\""))
}

/// Plan-11 fields round-trip through export → import → export when set, and
/// import tolerates their absence (older v2 files) by yielding nil.
@Test func questionParityFieldsRoundTripWhenSetAndDefaultWhenAbsent() throws {
    let containerA = try DispatchStore.inMemoryContainer()
    let contextA = ModelContext(containerA)
    let question = Question()
    question.uniqueIdentifier = "q-parity"
    question.prompt = "How many?"
    question.type = .number
    question.visualization = .graph
    question.defaultAnswerString = "0"
    question.allowsMultipleSelection = false
    contextA.insert(question)
    try contextA.save()

    let exportA = try V2Exporter.exportData(from: contextA, stamp: fixedStamp)

    let containerB = try DispatchStore.inMemoryContainer()
    let contextB = ModelContext(containerB)
    _ = try V2Importer.importExport(exportA, into: contextB)
    let imported = try #require(try contextB.fetch(FetchDescriptor<Question>()).first)
    #expect(imported.visualization == .graph)
    #expect(imported.defaultAnswerString == "0")
    #expect(imported.allowsMultipleSelectionRaw == false)

    let exportB = try V2Exporter.exportData(from: contextB, stamp: fixedStamp)
    #expect(exportA == exportB)

    // Absence tolerance: a v2 question JSON without the new keys imports as nil.
    let legacy = Data("""
    {"schemaVersion": 2, "reports": [], "questions": [{
        "uniqueIdentifier": "q-old", "prompt": "Old?", "questionType": 2,
        "sortOrder": 0, "isEnabled": true, "reportKinds": ["regular"]
    }]}
    """.utf8)
    let containerC = try DispatchStore.inMemoryContainer()
    let contextC = ModelContext(containerC)
    _ = try V2Importer.importExport(legacy, into: contextC)
    let old = try #require(try contextC.fetch(FetchDescriptor<Question>()).first)
    #expect(old.visualizationRaw == nil)
    #expect(old.defaultAnswerString == nil)
    #expect(old.allowsMultipleSelectionRaw == nil)
    #expect(old.inputStyleRaw == nil)
    #expect(old.inputMin == nil)
    #expect(old.inputMax == nil)
    #expect(old.inputStep == nil)
}

/// A report with no responses must export with the "responses" key OMITTED —
/// whether the (now CloudKit-optional) relationship is nil or an empty array —
/// so exports stay byte-identical to the pre-optional-relationship shape.
@Test func reportWithNoResponsesOmitsResponsesKey() throws {
    let container = try DispatchStore.inMemoryContainer()
    let context = ModelContext(container)
    let nilReport = Report()
    nilReport.uniqueIdentifier = "r-nil-responses"
    nilReport.responses = nil
    context.insert(nilReport)
    let emptyReport = Report()
    emptyReport.uniqueIdentifier = "r-empty-responses"
    emptyReport.responses = []
    context.insert(emptyReport)
    try context.save()

    let data = try V2Exporter.exportData(from: context)
    let json = try #require(String(data: data, encoding: .utf8))
    #expect(!json.contains("\"responses\""))

    let decoded = try JSONDecoder.v2.decode(V2Export.self, from: data)
    #expect(decoded.reports.count == 2)
    #expect(decoded.reports.allSatisfy { $0.responses == nil })
}

/// Plan 28: a time response round-trips both fields; a nil `timeResponse` is
/// OMITTED from the wire and imports back as nil (absence tolerance).
@Test func timeResponseRoundTripsAndOmitsWhenNil() throws {
    let containerA = try DispatchStore.inMemoryContainer()
    let contextA = ModelContext(containerA)
    let report = Report()
    report.uniqueIdentifier = "r-time"
    let timed = Response()
    timed.uniqueIdentifier = "resp-time"
    timed.questionPrompt = "What time did you last eat?"
    timed.timeResponse = TimeAnswer(minutesSinceMidnight: 555, dayOffset: -1)
    let plain = Response()
    plain.uniqueIdentifier = "resp-plain"
    plain.questionPrompt = "Doing?"
    plain.tokens = [TokenValue(text: "Working")]
    report.responses = [timed, plain]
    for response in report.responses ?? [] { response.report = report }
    contextA.insert(report)
    try contextA.save()

    let export = try V2Exporter.exportData(from: contextA, stamp: fixedStamp)
    let json = try #require(String(data: export, encoding: .utf8))
    // Only the timed response carries the key; the plain one omits it.
    #expect(json.contains("\"timeResponse\""))
    #expect(json.components(separatedBy: "\"timeResponse\"").count == 2)

    let containerB = try DispatchStore.inMemoryContainer()
    let contextB = ModelContext(containerB)
    _ = try V2Importer.importExport(export, into: contextB)
    let responses = try contextB.fetch(FetchDescriptor<Response>())
    let importedTimed = try #require(responses.first { $0.uniqueIdentifier == "resp-time" })
    #expect(importedTimed.timeResponse?.minutesSinceMidnight == 555)
    #expect(importedTimed.timeResponse?.dayOffset == -1)
    let importedPlain = try #require(responses.first { $0.uniqueIdentifier == "resp-plain" })
    #expect(importedPlain.timeResponse == nil)
}

/// A pre-plan-28 v2 payload (no `timeResponse` key) imports with nil.
@Test func timeResponseAbsenceImportsAsNil() throws {
    let container = try DispatchStore.inMemoryContainer()
    let context = ModelContext(container)
    let json = """
    {"schemaVersion": 2, "questions": [], "reports": [
      {"uniqueIdentifier": "r-old", "date": "2021-01-01T00:00:00Z", "timeZone": "GMT",
       "kind": "regular", "trigger": "manual",
       "isBackdated": false, "isDraft": false, "wasInBackground": false,
       "responses": [{"uniqueIdentifier": "resp-old", "questionPrompt": "Doing?"}]}
    ]}
    """
    _ = try V2Importer.importExport(Data(json.utf8), into: context)
    let responses = try context.fetch(FetchDescriptor<Response>())
    #expect(responses.first?.timeResponse == nil)
}

/// Plan-26 connection raws (and unknown future raws) travel the wire untouched:
/// `connection` is a raw Int? end-to-end, so no importer change is needed.
@Test func connectionRawsRoundTripThroughV2() throws {
    let containerA = try DispatchStore.inMemoryContainer()
    let contextA = ModelContext(containerA)
    let lte = Report()
    lte.uniqueIdentifier = "r-lte"
    lte.connection = 5
    contextA.insert(lte)
    let unknown = Report()
    unknown.uniqueIdentifier = "r-unknown-connection"
    unknown.connection = 99
    contextA.insert(unknown)
    try contextA.save()

    let export = try V2Exporter.exportData(from: contextA, stamp: fixedStamp)
    let containerB = try DispatchStore.inMemoryContainer()
    let contextB = ModelContext(containerB)
    _ = try V2Importer.importExport(export, into: contextB)
    let imported = try contextB.fetch(FetchDescriptor<Report>())

    let importedLTE = try #require(imported.first { $0.uniqueIdentifier == "r-lte" })
    #expect(importedLTE.connection == 5)
    #expect(importedLTE.connectionType == .cellularLTE)

    let importedUnknown = try #require(imported.first { $0.uniqueIdentifier == "r-unknown-connection" })
    #expect(importedUnknown.connection == 99)
    #expect(importedUnknown.connectionType == nil)

    // Unknown raw re-exports untouched.
    let exportB = try V2Exporter.exportData(from: contextB, stamp: fixedStamp)
    #expect(export == exportB)
}

/// Plan-26 media field: round-trips when set, OMITTED from JSON when nil,
/// and absent-key v2 payloads (pre-media exports) import with nil.
@Test func mediaFieldRoundTripsAndToleratesAbsence() throws {
    let containerA = try DispatchStore.inMemoryContainer()
    let contextA = ModelContext(containerA)
    let withMedia = Report()
    withMedia.uniqueIdentifier = "r-media"
    withMedia.media = MediaSample(source: .spotify, title: "Song", artist: "Artist",
                                  album: "Album", playbackState: .paused)
    contextA.insert(withMedia)
    let silent = Report()
    silent.uniqueIdentifier = "r-silent"
    contextA.insert(silent)
    try contextA.save()

    let export = try V2Exporter.exportData(from: contextA, stamp: fixedStamp)
    let containerB = try DispatchStore.inMemoryContainer()
    let contextB = ModelContext(containerB)
    _ = try V2Importer.importExport(export, into: contextB)
    let imported = try contextB.fetch(FetchDescriptor<Report>())

    let media = try #require(imported.first { $0.uniqueIdentifier == "r-media" }?.media)
    #expect(media.sourceType == .spotify)
    #expect(media.title == "Song")
    #expect(media.artist == "Artist")
    #expect(media.album == "Album")
    #expect(media.playbackStateType == .paused)
    #expect(imported.first { $0.uniqueIdentifier == "r-silent" }?.media == nil)

    // Nil media is omitted, not null — check via the silent report's JSON object.
    let json = try #require(String(data: export, encoding: .utf8))
    #expect(!json.contains("\"media\":null"))

    // Absence tolerance: a pre-media v2 report imports with nil media.
    let legacy = Data("""
    {"schemaVersion": 2, "questions": [], "reports": [{
        "uniqueIdentifier": "r-old", "date": "2026-07-10T00:00:00Z",
        "timeZone": "GMT", "kind": "regular", "trigger": "manual",
        "isBackdated": false, "isDraft": false, "wasInBackground": false
    }]}
    """.utf8)
    let containerC = try DispatchStore.inMemoryContainer()
    let contextC = ModelContext(containerC)
    _ = try V2Importer.importExport(legacy, into: contextC)
    let old = try #require(try contextC.fetch(FetchDescriptor<Report>()).first)
    #expect(old.media == nil)
}

/// Deep-link identifier fields (post-plan-26) round-trip through SwiftData +
/// v2 export/import — pinned separately because SwiftData composite storage
/// silently drops mis-keyed properties (the plan-26 sourceRaw lesson).
@Test func mediaIdentifiersRoundTripThroughStoreAndV2() throws {
    let containerA = try DispatchStore.inMemoryContainer()
    let contextA = ModelContext(containerA)
    let report = Report()
    report.uniqueIdentifier = "r-media-ids"
    report.media = MediaSample(source: .spotify, title: "Song", artist: "Artist",
                               spotifyTrackURI: "spotify:track:1AhDOtG9vPSOmsWgNW0BEY",
                               appleMusicStoreID: "1440857781")
    contextA.insert(report)
    try contextA.save()

    let export = try V2Exporter.exportData(from: contextA, stamp: fixedStamp)
    let containerB = try DispatchStore.inMemoryContainer()
    let contextB = ModelContext(containerB)
    _ = try V2Importer.importExport(export, into: contextB)
    let media = try #require(try contextB.fetch(FetchDescriptor<Report>()).first?.media)
    #expect(media.spotifyTrackURI == "spotify:track:1AhDOtG9vPSOmsWgNW0BEY")
    #expect(media.appleMusicStoreID == "1440857781")

    let exportB = try V2Exporter.exportData(from: contextB, stamp: fixedStamp)
    #expect(export == exportB)
}

/// Backup provenance metadata (createdAt + sourceDevice*): stamped at the top
/// level next to schemaVersion, round-trips through encode → decode, and —
/// like every v2 addition — import tolerates its absence (lenient decode).
@Test func exportMetadataRoundTripsAndToleratesAbsence() throws {
    let container = try DispatchStore.inMemoryContainer()
    let context = ModelContext(container)
    let data = try V2Exporter.exportData(from: context, stamp: fixedStamp)

    let decoded = try JSONDecoder.v2.decode(V2Export.self, from: data)
    #expect(decoded.createdAt == fixedStamp.createdAt)
    #expect(decoded.sourceDeviceModel == "TestDevice1,1")
    #expect(decoded.sourceDeviceName == "Test Device")

    // A nil device name is omitted, not encoded as null.
    let anonymous = V2ExportStamp(createdAt: fixedStamp.createdAt, sourceDeviceModel: "TestDevice1,1")
    let anonymousJSON = String(decoding: try V2Exporter.exportData(from: context, stamp: anonymous), as: UTF8.self)
    #expect(!anonymousJSON.contains("\"sourceDeviceName\""))

    // Absence tolerance: pre-metadata v2 files decode (and import) with nils.
    let legacy = Data(#"{"schemaVersion": 2, "questions": [], "reports": []}"#.utf8)
    let old = try JSONDecoder.v2.decode(V2Export.self, from: legacy)
    #expect(old.createdAt == nil)
    #expect(old.sourceDeviceModel == nil)
    #expect(old.sourceDeviceName == nil)
    let containerB = try DispatchStore.inMemoryContainer()
    _ = try V2Importer.importExport(legacy, into: ModelContext(containerB))
}
