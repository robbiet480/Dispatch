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

    group.schedule = .visitArrival
    #expect(group.schedule == .visitArrival)
    #expect(group.scheduleKindRaw == "visitArrival")
}

@Test func promptGroupCalendarEventEndScheduleRoundTripsEveryRule() throws {
    let group = PromptGroup()

    group.schedule = .calendarEventEnd(.allEvents)
    #expect(group.schedule == .calendarEventEnd(.allEvents))
    #expect(group.scheduleKindRaw == "calendarEventEnd")
    // .allEvents is the nil-fields storage form.
    #expect(group.calendarMatchKindRaw == nil)
    #expect(group.calendarIdentifiersJSON == nil)
    #expect(group.calendarTitleFilter == nil)

    group.schedule = .calendarEventEnd(.calendars(["cal-1", "cal-2"]))
    #expect(group.schedule == .calendarEventEnd(.calendars(["cal-1", "cal-2"])))
    #expect(group.calendarMatchKindRaw == "calendars")
    #expect(group.calendarIdentifiersJSON != nil)
    #expect(group.calendarTitleFilter == nil)

    group.schedule = .calendarEventEnd(.titleContains("standup"))
    #expect(group.schedule == .calendarEventEnd(.titleContains("standup")))
    #expect(group.calendarMatchKindRaw == "titleContains")
    #expect(group.calendarTitleFilter == "standup")
    #expect(group.calendarIdentifiersJSON == nil)

    // Switching back to .allEvents nils the rule fields again.
    group.schedule = .calendarEventEnd(.allEvents)
    #expect(group.calendarMatchKindRaw == nil)
    #expect(group.calendarIdentifiersJSON == nil)
    #expect(group.calendarTitleFilter == nil)
}

/// A calendarEventEnd group whose match-kind raw is unknown (a future rule
/// synced from a newer build) resolves to `.disabled` — never fires rather
/// than misfires — and write-back preserves both raws (the `.disabled`
/// round-trip-safety precedent).
@Test func promptGroupUnknownCalendarMatchKindResolvesDisabledAndPreservesRaws() throws {
    let group = PromptGroup()
    group.scheduleKindRaw = "calendarEventEnd"
    group.calendarMatchKindRaw = "futureRule"
    group.calendarTitleFilter = "kept"
    #expect(group.schedule == .disabled)
    group.schedule = .disabled
    #expect(group.scheduleKindRaw == "calendarEventEnd")
    #expect(group.calendarMatchKindRaw == "futureRule")
    #expect(group.calendarTitleFilter == "kept")
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

    let exportA = try V2Exporter.exportData(from: contextA, stamp: fixedStamp)

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
    let exportB = try V2Exporter.exportData(from: contextB, stamp: fixedStamp)
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

    let exportA = try V2Exporter.exportData(from: contextA, stamp: fixedStamp)
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

    let exportB = try V2Exporter.exportData(from: contextB, stamp: fixedStamp)
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

/// A visit-arrival group and a `.visitArrival`-triggered report round-trip
/// through v2 byte-identically (plan 16).
@Test func visitArrivalGroupAndTriggerRoundTripThroughV2() throws {
    let containerA = try DispatchStore.inMemoryContainer()
    let contextA = ModelContext(containerA)

    let group = PromptGroup()
    group.uniqueIdentifier = "pg-visit"
    group.name = "Arrivals"
    group.schedule = .visitArrival
    contextA.insert(group)

    let report = Report()
    report.uniqueIdentifier = "r-visit"
    report.date = Date(timeIntervalSince1970: 1_700_000_000)
    report.trigger = .visitArrival
    report.promptGroupID = "pg-visit"
    contextA.insert(report)
    try contextA.save()

    let exportA = try V2Exporter.exportData(from: contextA, stamp: fixedStamp)
    let json = try #require(String(data: exportA, encoding: .utf8))
    #expect(json.contains("\"visitArrival\""))

    let containerB = try DispatchStore.inMemoryContainer()
    let contextB = ModelContext(containerB)
    _ = try V2Importer.importExport(exportA, into: contextB)

    let imported = try #require(try contextB.fetch(FetchDescriptor<PromptGroup>()).first)
    #expect(imported.schedule == .visitArrival)
    let importedReport = try #require(try contextB.fetch(FetchDescriptor<Report>()).first)
    #expect(importedReport.trigger == .visitArrival)

    let exportB = try V2Exporter.exportData(from: contextB, stamp: fixedStamp)
    #expect(exportA == exportB)
}

/// A calendar-event group (per match rule) and a `.calendarEventEnd`-triggered
/// report round-trip through v2 byte-identically (plan 31 — the plan-16
/// visitArrival precedent).
@Test func calendarEventEndGroupAndTriggerRoundTripThroughV2() throws {
    let containerA = try DispatchStore.inMemoryContainer()
    let contextA = ModelContext(containerA)

    let calendarsGroup = PromptGroup()
    calendarsGroup.uniqueIdentifier = "pg-cal-cals"
    calendarsGroup.name = "Work meetings"
    calendarsGroup.schedule = .calendarEventEnd(.calendars(["cal-1", "cal-2"]))
    calendarsGroup.sortOrder = 0
    contextA.insert(calendarsGroup)

    let titleGroup = PromptGroup()
    titleGroup.uniqueIdentifier = "pg-cal-title"
    titleGroup.name = "Standups"
    titleGroup.schedule = .calendarEventEnd(.titleContains("standup"))
    titleGroup.sortOrder = 1
    contextA.insert(titleGroup)

    let report = Report()
    report.uniqueIdentifier = "r-cal"
    report.date = Date(timeIntervalSince1970: 1_700_000_000)
    report.trigger = .calendarEventEnd
    report.promptGroupID = "pg-cal-title"
    contextA.insert(report)
    try contextA.save()

    let exportA = try V2Exporter.exportData(from: contextA, stamp: fixedStamp)
    let json = try #require(String(data: exportA, encoding: .utf8))
    #expect(json.contains("\"calendarEventEnd\""))
    #expect(json.contains("\"calendarMatchKind\""))
    #expect(json.contains("\"calendarIdentifiers\""))
    #expect(json.contains("\"calendarTitleFilter\""))

    let containerB = try DispatchStore.inMemoryContainer()
    let contextB = ModelContext(containerB)
    _ = try V2Importer.importExport(exportA, into: contextB)

    let groups = try contextB.fetch(
        FetchDescriptor<PromptGroup>(sortBy: [SortDescriptor(\.sortOrder)]))
    #expect(groups.count == 2)
    #expect(groups[0].schedule == .calendarEventEnd(.calendars(["cal-1", "cal-2"])))
    #expect(groups[1].schedule == .calendarEventEnd(.titleContains("standup")))
    let importedReport = try #require(try contextB.fetch(FetchDescriptor<Report>()).first)
    #expect(importedReport.trigger == .calendarEventEnd)

    let exportB = try V2Exporter.exportData(from: contextB, stamp: fixedStamp)
    #expect(exportA == exportB)
}

/// The three calendar-rule keys are omitted for `.allEvents` (nil-fields
/// storage form) and for non-calendar groups — pre-plan-31 v2 exports stay
/// byte-identical.
@Test func calendarRuleKeysOmittedForAllEventsAndNonCalendarGroups() throws {
    let container = try DispatchStore.inMemoryContainer()
    let context = ModelContext(container)

    let allEventsGroup = PromptGroup()
    allEventsGroup.uniqueIdentifier = "pg-cal-all"
    allEventsGroup.name = "Any event"
    allEventsGroup.schedule = .calendarEventEnd(.allEvents)
    context.insert(allEventsGroup)

    let timerGroup = PromptGroup()
    timerGroup.uniqueIdentifier = "pg-timer"
    timerGroup.name = "Timer"
    timerGroup.schedule = .everyNHours(2)
    timerGroup.sortOrder = 1
    context.insert(timerGroup)
    try context.save()

    let json = try #require(
        String(data: try V2Exporter.exportData(from: context, stamp: fixedStamp), encoding: .utf8))
    #expect(json.contains("\"calendarEventEnd\""))
    #expect(!json.contains("\"calendarMatchKind\""))
    #expect(!json.contains("\"calendarIdentifiers\""))
    #expect(!json.contains("\"calendarTitleFilter\""))
}

/// A v2 file authored by a newer build carrying the calendarEventEnd trigger,
/// schedule kind, and match-rule fields as plain JSON imports on this build;
/// an unknown FUTURE match-kind raw imports intact but resolves `.disabled`
/// (the tolerance-fixture pattern).
@Test func v2ImportAcceptsCalendarEventEndRawStrings() throws {
    let fixture = Data("""
    {"schemaVersion": 2, "questions": [], "reports": [{
        "uniqueIdentifier": "r-c", "date": "2026-07-10T12:00:00.000Z",
        "timeZone": "GMT", "kind": "regular", "trigger": "calendarEventEnd",
        "isBackdated": false, "isDraft": false, "wasInBackground": false
    }], "promptGroups": [{
        "uniqueIdentifier": "pg-c", "name": "Meetings",
        "scheduleKind": "calendarEventEnd", "calendarMatchKind": "titleContains",
        "calendarTitleFilter": "standup", "isEnabled": true, "sortOrder": 0
    }, {
        "uniqueIdentifier": "pg-f", "name": "Future rule",
        "scheduleKind": "calendarEventEnd", "calendarMatchKind": "futureRule",
        "isEnabled": true, "sortOrder": 1
    }]}
    """.utf8)
    let container = try DispatchStore.inMemoryContainer()
    let context = ModelContext(container)
    let summary = try V2Importer.importExport(fixture, into: context)
    #expect(summary.reportsImported == 1)
    #expect(summary.promptGroupsImported == 2)
    let report = try #require(try context.fetch(FetchDescriptor<Report>()).first)
    #expect(report.trigger == .calendarEventEnd)
    let groups = try context.fetch(
        FetchDescriptor<PromptGroup>(sortBy: [SortDescriptor(\.sortOrder)]))
    #expect(groups[0].schedule == .calendarEventEnd(.titleContains("standup")))
    // Unknown match-kind raw → .disabled, raw preserved for write-back.
    #expect(groups[1].schedule == .disabled)
    #expect(groups[1].calendarMatchKindRaw == "futureRule")
}

/// A v2 file authored by a newer build carrying the visitArrival trigger and
/// scheduleKind as plain strings imports on this build; the raw strings map
/// to the typed cases (forward-written fixture, hand-rolled JSON).
@Test func v2ImportAcceptsVisitArrivalRawStrings() throws {
    let fixture = Data("""
    {"schemaVersion": 2, "questions": [], "reports": [{
        "uniqueIdentifier": "r-v", "date": "2026-07-09T12:00:00.000Z",
        "timeZone": "GMT", "kind": "regular", "trigger": "visitArrival",
        "isBackdated": false, "isDraft": false, "wasInBackground": false
    }], "promptGroups": [{
        "uniqueIdentifier": "pg-v", "name": "Arrivals",
        "scheduleKind": "visitArrival", "isEnabled": true, "sortOrder": 0
    }]}
    """.utf8)
    let container = try DispatchStore.inMemoryContainer()
    let context = ModelContext(container)
    let summary = try V2Importer.importExport(fixture, into: context)
    #expect(summary.reportsImported == 1)
    #expect(summary.promptGroupsImported == 1)
    let report = try #require(try context.fetch(FetchDescriptor<Report>()).first)
    #expect(report.trigger == .visitArrival)
    let group = try #require(try context.fetch(FetchDescriptor<PromptGroup>()).first)
    #expect(group.schedule == .visitArrival)
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
