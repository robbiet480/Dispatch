import Foundation
import SwiftData
import Testing
@testable import DispatchKit

// Device provenance (plan 19): stamped at creation by the shared filing
// path, carried verbatim through v2 export/import, tolerated when absent.
// Serialized: DeviceIdentity.deviceName is process-global injected state.
@Suite(.serialized)
struct DeviceProvenanceTests {
    private func makeYesNoQuestion(in context: ModelContext) throws -> Question {
        let question = Question()
        question.prompt = "Are you working?"
        question.typeRaw = QuestionType.yesNo.rawValue
        question.choices = ["Yes", "No"]
        question.isEnabled = true
        context.insert(question)
        try context.save()
        return question
    }

    @Test func deviceIdentityModelIsPresentAndMachineFormatted() {
        let model = DeviceIdentity.model
        #expect(model != nil)
        #expect(model?.isEmpty == false)
        // utsname.machine is a short ASCII identifier ("iPhone17,1",
        // "Watch7,4", "arm64" on the mac test host) — no whitespace, ASCII.
        #expect(model?.contains(" ") == false)
        #expect(model?.allSatisfy { $0.isASCII } == true)
    }

    @Test func reportBuilderStampsProvenanceAtCreation() throws {
        let container = try DispatchStore.inMemoryContainer()
        let context = ModelContext(container)
        let report = try DeviceIdentityGate.withDeviceName("Provenance Test Device") {
            try ReportBuilder.save(
                kind: .regular, trigger: .manual, date: Date(), timeZone: .current,
                outcomes: [:], answers: [], in: context
            )
        }
        #expect(report.sourceDeviceModel == DeviceIdentity.model)
        #expect(report.sourceDeviceName == "Provenance Test Device")
    }

    @Test func quickAnswerPathStampsProvenance() throws {
        let container = try DispatchStore.inMemoryContainer()
        let context = ModelContext(container)
        let question = try makeYesNoQuestion(in: context)
        let report = try DeviceIdentityGate.withDeviceName("Apple Watch") {
            try QuickAnswerFiler.file(
                question: question, choiceIndex: 0, trigger: .watch, in: context
            )
        }
        #expect(report.trigger == .watch)
        #expect(report.sourceDeviceModel == DeviceIdentity.model)
        #expect(report.sourceDeviceName == "Apple Watch")
    }

    @Test func uninjectedDeviceNameStampsNilNameButStillModel() throws {
        let container = try DispatchStore.inMemoryContainer()
        let context = ModelContext(container)
        let report = try DeviceIdentityGate.withDeviceName(nil) {
            try ReportBuilder.save(
                kind: .regular, trigger: .manual, date: Date(), timeZone: .current,
                outcomes: [:], answers: [], in: context
            )
        }
        #expect(report.sourceDeviceModel != nil)
        #expect(report.sourceDeviceName == nil)
    }

    // MARK: - v2 export/import

    @Test func v2RoundTripsProvenanceFields() throws {
        let container = try DispatchStore.inMemoryContainer()
        let context = ModelContext(container)
        let report = Report()
        report.date = Date(timeIntervalSince1970: 1_780_000_000)
        report.sourceDeviceModel = "Watch7,4"
        report.sourceDeviceName = "Apple Watch Ultra (49mm)"
        context.insert(report)
        try context.save()

        let data = try V2Exporter.exportData(from: context)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"Watch7,4\""))
        #expect(json.contains("\"Apple Watch Ultra (49mm)\""))

        let importContainer = try DispatchStore.inMemoryContainer()
        let importContext = ModelContext(importContainer)
        _ = try V2Importer.importExport(data, into: importContext)
        let imported = try importContext.fetch(FetchDescriptor<Report>())
        #expect(imported.count == 1)
        #expect(imported.first?.sourceDeviceModel == "Watch7,4")
        #expect(imported.first?.sourceDeviceName == "Apple Watch Ultra (49mm)")
    }

    @Test func v2OmitsAbsentProvenanceKeysFromJSON() throws {
        let container = try DispatchStore.inMemoryContainer()
        let context = ModelContext(container)
        let report = Report()
        report.date = Date(timeIntervalSince1970: 1_780_000_000)
        context.insert(report)
        try context.save()

        // A device-less stamp: this test pins the REPORT-level provenance
        // omission, so the top-level export stamp must not contribute keys.
        let stamp = V2ExportStamp(createdAt: Date(timeIntervalSince1970: 1_780_000_000))
        let json = String(decoding: try V2Exporter.exportData(from: context, stamp: stamp), as: UTF8.self)
        #expect(!json.contains("sourceDeviceModel"))
        #expect(!json.contains("sourceDeviceName"))
    }

    @Test func v2ImportToleratesAbsentProvenanceAndNeverRestamps() throws {
        // A pre-provenance v2 payload: no sourceDevice* keys anywhere.
        let json = """
        {"schemaVersion": 2, "questions": [], "reports": [
            {"uniqueIdentifier": "legacy-1", "date": "2026-06-01T12:00:00Z",
             "timeZone": "GMT", "kind": "regular", "trigger": "manual",
             "isBackdated": false, "isDraft": false, "wasInBackground": false}
        ]}
        """
        // Even with a live injected identity, import must keep nil — imported
        // reports are historical, never restamped with this device's.
        let container = try DispatchStore.inMemoryContainer()
        let context = ModelContext(container)
        let reports = try DeviceIdentityGate.withDeviceName("Should Not Appear") {
            _ = try V2Importer.importExport(Data(json.utf8), into: context)
            return try context.fetch(FetchDescriptor<Report>())
        }
        #expect(reports.count == 1)
        #expect(reports.first?.sourceDeviceModel == nil)
        #expect(reports.first?.sourceDeviceName == nil)
    }

    // MARK: - .watch trigger tolerance (same discipline as .widget)

    @Test func v2RoundTripsWatchTriggeredReport() throws {
        let container = try DispatchStore.inMemoryContainer()
        let context = ModelContext(container)
        let question = try makeYesNoQuestion(in: context)
        try QuickAnswerFiler.file(question: question, choiceIndex: 0, trigger: .watch, in: context)

        let data = try V2Exporter.exportData(from: context)
        #expect(String(decoding: data, as: UTF8.self).contains("\"watch\""))

        let importContainer = try DispatchStore.inMemoryContainer()
        let importContext = ModelContext(importContainer)
        _ = try V2Importer.importExport(data, into: importContext)
        let reports = try importContext.fetch(FetchDescriptor<Report>())
        #expect(reports.count == 1)
        #expect(reports.first?.trigger == .watch)
    }

    @Test func unknownTriggerRawValueStillFallsBackToManual() {
        // Forward tolerance unchanged by the new case: raw values that are
        // NOT in the enum still resolve .manual.
        let report = Report()
        report.triggerRaw = "watch"
        #expect(report.trigger == .watch)
        report.triggerRaw = "hologram"
        #expect(report.trigger == .manual)
    }
}
