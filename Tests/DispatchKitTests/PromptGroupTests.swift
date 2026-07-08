import Foundation
import SwiftData
import Testing
@testable import DispatchKit

// MARK: - Schedule raw-value mapping

@Test func promptGroupScheduleRoundTripsEveryKind() throws {
    let group = PromptGroup()

    group.schedule = .everyNHours(3)
    #expect(group.schedule == .everyNHours(3))
    #expect(group.scheduleKindRaw == "everyNHours")

    group.schedule = .timesPerDay(count: 5, distribution: .random)
    #expect(group.schedule == .timesPerDay(count: 5, distribution: .random))

    var nine = DateComponents(); nine.hour = 9; nine.minute = 30
    var seventeen = DateComponents(); seventeen.hour = 17; seventeen.minute = 0
    group.schedule = .dailyAt([nine, seventeen])
    #expect(group.schedule == .dailyAt([nine, seventeen]))
    #expect(group.scheduledTimeStrings == ["09:30", "17:00"])

    group.schedule = .workoutEnd
    #expect(group.schedule == .workoutEnd)
}

@Test func promptGroupUnknownScheduleKindResolvesDisabledAndPreservesRaw() throws {
    let group = PromptGroup()
    group.scheduleKindRaw = "lunarPhase" // future kind synced from a newer build
    #expect(group.schedule == .disabled)
    // Writing .disabled back must not clobber the unknown raw value.
    group.schedule = .disabled
    #expect(group.scheduleKindRaw == "lunarPhase")
}

@Test func promptGroupScheduleFallsBackWhenParametersMissing() throws {
    let group = PromptGroup()
    group.scheduleKindRaw = GroupScheduleKind.everyNHours.rawValue
    group.scheduleHours = nil
    #expect(group.schedule == .everyNHours(4))

    group.scheduleKindRaw = GroupScheduleKind.timesPerDay.rawValue
    group.scheduleCount = nil
    group.scheduleDistributionRaw = "bogus"
    #expect(group.schedule == .timesPerDay(count: 4, distribution: .semiRandom))

    group.scheduleKindRaw = GroupScheduleKind.dailyAt.rawValue
    group.scheduledTimesJSON = "not json"
    #expect(group.schedule == .dailyAt([]))
}

@Test func timeStringCodecRejectsMalformedInput() throws {
    #expect(PromptGroup.timeComponents(fromString: "25:00") == nil)
    #expect(PromptGroup.timeComponents(fromString: "12:60") == nil)
    #expect(PromptGroup.timeComponents(fromString: "noon") == nil)
    let parsed = try #require(PromptGroup.timeComponents(fromString: "08:05"))
    #expect(parsed.hour == 8)
    #expect(parsed.minute == 5)
    #expect(PromptGroup.timeString(fromComponents: parsed) == "08:05")
}

// MARK: - v2 export/import

@Test func promptGroupsAndReportGroupIDRoundTripThroughV2() throws {
    let containerA = try DispatchStore.inMemoryContainer()
    let contextA = ModelContext(containerA)

    let group = PromptGroup()
    group.uniqueIdentifier = "pg-1"
    group.name = "Fitness"
    group.questionIDs = ["q-a", "q-b"]
    group.schedule = .everyNHours(2)
    group.sortOrder = 1
    contextA.insert(group)

    let eventGroup = PromptGroup()
    eventGroup.uniqueIdentifier = "pg-2"
    eventGroup.name = "Post-workout"
    eventGroup.schedule = .workoutEnd
    eventGroup.isEnabled = false
    eventGroup.sortOrder = 2
    contextA.insert(eventGroup)

    let report = Report()
    report.uniqueIdentifier = "r-1"
    report.date = Date(timeIntervalSince1970: 1_700_000_000)
    report.trigger = .workoutEnd
    report.promptGroupID = "pg-2"
    contextA.insert(report)
    try contextA.save()

    let exportA = try V2Exporter.exportData(from: contextA)

    let containerB = try DispatchStore.inMemoryContainer()
    let contextB = ModelContext(containerB)
    let summary = try V2Importer.importExport(exportA, into: contextB)
    #expect(summary.promptGroupsImported == 2)

    let groups = try contextB.fetch(
        FetchDescriptor<PromptGroup>(sortBy: [SortDescriptor(\.sortOrder)]))
    #expect(groups.count == 2)
    #expect(groups[0].name == "Fitness")
    #expect(groups[0].questionIDs == ["q-a", "q-b"])
    #expect(groups[0].schedule == .everyNHours(2))
    #expect(groups[1].schedule == .workoutEnd)
    #expect(groups[1].isEnabled == false)

    let imported = try #require(try contextB.fetch(FetchDescriptor<Report>()).first)
    #expect(imported.promptGroupID == "pg-2")
    #expect(imported.trigger == .workoutEnd)

    // Re-import is idempotent (dedupe by uniqueIdentifier).
    _ = try V2Importer.importExport(exportA, into: contextB)
    #expect(try contextB.fetch(FetchDescriptor<PromptGroup>()).count == 2)

    // Byte-identical re-export.
    let exportB = try V2Exporter.exportData(from: contextB)
    #expect(exportA == exportB)
}

/// A `.dailyAt` group's scheduledTimes wire format ("HH:mm" strings) must
/// survive export → import → export byte-identically.
@Test func dailyAtGroupScheduledTimesRoundTripThroughV2() throws {
    let containerA = try DispatchStore.inMemoryContainer()
    let contextA = ModelContext(containerA)

    var nineThirty = DateComponents(); nineThirty.hour = 9; nineThirty.minute = 30
    var seventeen = DateComponents(); seventeen.hour = 17; seventeen.minute = 0
    let group = PromptGroup()
    group.uniqueIdentifier = "pg-daily"
    group.name = "Daily check-in"
    group.questionIDs = ["q-a"]
    group.schedule = .dailyAt([nineThirty, seventeen])
    group.sortOrder = 1
    contextA.insert(group)
    try contextA.save()

    let exportA = try V2Exporter.exportData(from: contextA)
    let json = try #require(String(data: exportA, encoding: .utf8))
    #expect(json.contains("\"scheduledTimes\""))
    #expect(json.contains("09:30"))
    #expect(json.contains("17:00"))

    let containerB = try DispatchStore.inMemoryContainer()
    let contextB = ModelContext(containerB)
    let summary = try V2Importer.importExport(exportA, into: contextB)
    #expect(summary.promptGroupsImported == 1)

    let imported = try #require(try contextB.fetch(FetchDescriptor<PromptGroup>()).first)
    #expect(imported.schedule == .dailyAt([nineThirty, seventeen]))
    #expect(imported.scheduledTimeStrings == ["09:30", "17:00"])

    let exportB = try V2Exporter.exportData(from: contextB)
    #expect(exportA == exportB)
}

/// Groupless data must export WITHOUT the new keys — pre-plan-12 v2 exports
/// stay byte-identical, and reports without a group omit promptGroupID.
@Test func emptyPromptGroupsAndNilGroupIDAreOmittedFromExportedJSON() throws {
    let container = try DispatchStore.inMemoryContainer()
    let context = ModelContext(container)
    let report = Report()
    report.uniqueIdentifier = "r-plain"
    report.date = Date(timeIntervalSince1970: 1_700_000_000)
    context.insert(report)
    try context.save()

    let json = try #require(String(data: try V2Exporter.exportData(from: context), encoding: .utf8))
    #expect(!json.contains("\"promptGroups\""))
    #expect(!json.contains("\"promptGroupID\""))
}

/// Older v2 files (no promptGroups key, no report promptGroupID) import
/// unchanged.
@Test func v2ImportToleratesAbsentPromptGroupKeys() throws {
    let legacy = Data("""
    {"schemaVersion": 2, "questions": [], "reports": [{
        "uniqueIdentifier": "r-old", "date": "2024-01-01T00:00:00.000Z",
        "timeZone": "GMT", "kind": "regular", "trigger": "manual",
        "isBackdated": false, "isDraft": false, "wasInBackground": false
    }]}
    """.utf8)
    let container = try DispatchStore.inMemoryContainer()
    let context = ModelContext(container)
    let summary = try V2Importer.importExport(legacy, into: context)
    #expect(summary.reportsImported == 1)
    #expect(summary.promptGroupsImported == 0)
    let report = try #require(try context.fetch(FetchDescriptor<Report>()).first)
    #expect(report.promptGroupID == nil)
    #expect(try context.fetch(FetchDescriptor<PromptGroup>()).isEmpty)
}
