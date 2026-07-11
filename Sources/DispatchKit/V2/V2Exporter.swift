import Foundation
import SwiftData

/// Top-level provenance stamped onto an export (backup fix): capture time
/// plus the exporting device's identity. A value type so tests can pin a
/// fixed stamp and keep the byte-identical round-trip assertions meaningful.
public struct V2ExportStamp: Sendable {
    public var createdAt: Date
    public var sourceDeviceModel: String?
    public var sourceDeviceName: String?

    public init(createdAt: Date, sourceDeviceModel: String? = nil, sourceDeviceName: String? = nil) {
        self.createdAt = createdAt
        self.sourceDeviceModel = sourceDeviceModel
        self.sourceDeviceName = sourceDeviceName
    }

    /// Now, on this device (DeviceIdentity — model via uname, name injected
    /// by the platform target at launch; nil name in kit tests is expected).
    public static func current() -> V2ExportStamp {
        V2ExportStamp(createdAt: Date(),
                      sourceDeviceModel: DeviceIdentity.model,
                      sourceDeviceName: DeviceIdentity.deviceName)
    }
}

public enum V2Exporter {
    public static func export(from context: ModelContext,
                              stamp: V2ExportStamp = .current()) throws -> V2Export {
        var export = V2Export()
        export.createdAt = stamp.createdAt
        export.sourceDeviceModel = stamp.sourceDeviceModel
        export.sourceDeviceName = stamp.sourceDeviceName

        let questions = try context.fetch(
            FetchDescriptor<Question>(sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.uniqueIdentifier)]))
        export.questions = questions.map { q in
            V2Question(uniqueIdentifier: q.uniqueIdentifier, prompt: q.prompt,
                       questionType: q.typeRaw, placeholderString: q.placeholderString,
                       choices: q.choices.isEmpty ? nil : q.choices,
                       sortOrder: q.sortOrder, isEnabled: q.isEnabled,
                       stateOfMindKind: q.stateOfMindKind, reportKinds: q.reportKinds,
                       visualization: q.visualizationRaw,
                       defaultAnswerString: q.defaultAnswerString,
                       allowsMultipleSelection: q.allowsMultipleSelectionRaw,
                       inputStyle: q.inputStyleRaw,
                       inputMin: q.inputMin, inputMax: q.inputMax,
                       inputStep: q.inputStep)
        }

        let reports = try context.fetch(
            FetchDescriptor<Report>(sortBy: [SortDescriptor(\.date), SortDescriptor(\.uniqueIdentifier)]))
        export.reports = reports.map(reportDTO(_:))

        let groups = try context.fetch(
            FetchDescriptor<PromptGroup>(sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.uniqueIdentifier)]))
        let groupDTOs = groups.map { g in
            V2PromptGroup(uniqueIdentifier: g.uniqueIdentifier, name: g.name,
                          questionIDs: g.questionIDs.isEmpty ? nil : g.questionIDs,
                          scheduleKind: g.scheduleKindRaw,
                          scheduleHours: g.scheduleHours,
                          scheduleCount: g.scheduleCount,
                          scheduleDistribution: g.scheduleDistributionRaw,
                          scheduledTimes: g.scheduledTimeStrings.isEmpty ? nil : g.scheduledTimeStrings,
                          isEnabled: g.isEnabled, sortOrder: g.sortOrder,
                          // Calendar match rule (plan 31): omitted when nil
                          // (.allEvents stores all-nil fields); empty
                          // identifier lists collapse to nil.
                          calendarMatchKind: g.calendarMatchKindRaw,
                          calendarIdentifiers: {
                              let ids = CalendarEventMatchRule.identifiers(
                                  fromJSON: g.calendarIdentifiersJSON)
                              return ids.isEmpty ? nil : ids
                          }(),
                          calendarTitleFilter: g.calendarTitleFilter,
                          // CLMonitor place/beacon trigger (plan 45): the
                          // scalars ride verbatim; the JSON payloads decode
                          // back to their structs (exactly one present for a
                          // monitor group, both nil otherwise).
                          monitorDirection: g.monitorDirectionRaw,
                          monitorDelayMinutes: g.monitorDelayMinutes,
                          monitorCancelsOnContradiction: g.monitorCancelsOnContradiction,
                          placeRegion: MonitorPlaceRegion(json: g.placeRegionJSON),
                          beaconIdentity: MonitorBeaconIdentity(json: g.beaconIdentityJSON))
        }
        export.promptGroups = groupDTOs.isEmpty ? nil : groupDTOs

        // Person registry (plan 22): identity fields only — usage counts are
        // derived data the importer's next vocabulary rebuild recomputes.
        let people = try context.fetch(FetchDescriptor<PersonEntity>())
            .sorted { ($0.text, $0.uniqueIdentifier) < ($1.text, $1.uniqueIdentifier) }
        let personDTOs = people.map { p in
            V2Person(uniqueIdentifier: p.uniqueIdentifier, displayName: p.text,
                     alternateNames: p.alternateNames.isEmpty ? nil : p.alternateNames)
        }
        export.people = personDTOs.isEmpty ? nil : personDTOs
        return export
    }

    public static func exportData(from context: ModelContext,
                                  stamp: V2ExportStamp = .current()) throws -> Data {
        try JSONEncoder.v2.encode(try export(from: context, stamp: stamp))
    }

    /// Single-report model → DTO mapping, extracted so consumers that ship
    /// one report at a time (webhooks, plan 24) encode the exact same shape
    /// as a full export — byte-consistent with `exportData` for that report.
    public static func reportDTO(_ r: Report) -> V2Report {
        var dto = V2Report(uniqueIdentifier: r.uniqueIdentifier, date: r.date,
                           timeZone: r.timeZoneIdentifier, kind: r.kind, trigger: r.trigger)
        dto.legacyImpetus = r.legacyImpetus
        dto.legacySectionIdentifier = r.legacySectionIdentifier
        dto.isBackdated = r.isBackdated
        dto.isDraft = r.isDraft
        dto.wasInBackground = r.wasInBackground
        dto.battery = r.battery
        dto.altitudeMeters = r.altitudeMeters
        dto.connection = r.connection
        dto.audio = r.audio
        dto.location = r.location
        dto.weather = r.weather
        dto.photos = r.photos.isEmpty ? nil : r.photos
        dto.health = r.health.isEmpty ? nil : r.health
        dto.focus = r.focus
        dto.media = r.media
        dto.stateOfMindSampleIDs = r.stateOfMindSampleIDs.isEmpty ? nil : r.stateOfMindSampleIDs
        dto.promptGroupID = r.promptGroupID
        dto.sourceDeviceModel = r.sourceDeviceModel
        dto.sourceDeviceName = r.sourceDeviceName
        // Capture-time context metadata (plan 44, #61): grouped blocks in the
        // JSON, omitted entirely when every field is nil.
        var deviceState = V2DeviceState()
        deviceState.isLowPowerMode = r.isLowPowerMode
        deviceState.screenBrightness = r.screenBrightness
        deviceState.interfaceStyle = r.interfaceStyle
        deviceState.audioOutputRoute = r.audioOutputRoute
        dto.deviceState = deviceState.isEmpty ? nil : deviceState
        var motion = V2MotionState()
        motion.motionActivity = r.motionActivity
        motion.barometricPressureKPa = r.barometricPressureKPa
        dto.motion = motion.isEmpty ? nil : motion
        let responses = (r.responses ?? [])
            .sorted { $0.uniqueIdentifier < $1.uniqueIdentifier }
            .map { resp in
                var rdto = V2Response(uniqueIdentifier: resp.uniqueIdentifier,
                                      questionPrompt: resp.questionPrompt)
                rdto.questionIdentifier = resp.questionIdentifier
                rdto.tokens = resp.tokens
                rdto.answeredOptions = resp.answeredOptions
                rdto.locationResponse = resp.locationResponse
                rdto.numericResponse = resp.numericResponse
                rdto.textResponses = resp.textResponses
                rdto.timeResponse = resp.timeResponse
                return rdto
            }
        dto.responses = responses.isEmpty ? nil : responses
        return dto
    }
}
