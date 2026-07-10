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

    let exportA = try V2Exporter.exportData(from: contextA)

    let containerB = try DispatchStore.inMemoryContainer()
    let contextB = ModelContext(containerB)
    _ = try V2Importer.importExport(exportA, into: contextB)
    let imported = try #require(try contextB.fetch(FetchDescriptor<Question>()).first)
    #expect(imported.visualization == .graph)
    #expect(imported.defaultAnswerString == "0")
    #expect(imported.allowsMultipleSelectionRaw == false)

    let exportB = try V2Exporter.exportData(from: contextB)
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

@Test func exportIsDeterministic() throws {
    let container = try DispatchStore.inMemoryContainer()
    let context = ModelContext(container)
    _ = try V1Importer.importExport(try fixtureData("v1-sample"), into: context)
    let first = try V2Exporter.exportData(from: context)
    let second = try V2Exporter.exportData(from: context)
    #expect(first == second) // sorted keys + sorted records
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

    let export = try V2Exporter.exportData(from: contextA)
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
    let exportB = try V2Exporter.exportData(from: contextB)
    #expect(export == exportB)
}
