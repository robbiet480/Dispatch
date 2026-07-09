import Foundation
import SwiftData

public enum V2Exporter {
    public static func export(from context: ModelContext) throws -> V2Export {
        var export = V2Export()

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
                       allowsMultipleSelection: q.allowsMultipleSelectionRaw)
        }

        let reports = try context.fetch(
            FetchDescriptor<Report>(sortBy: [SortDescriptor(\.date), SortDescriptor(\.uniqueIdentifier)]))
        export.reports = reports.map { r in
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
            dto.stateOfMindSampleIDs = r.stateOfMindSampleIDs.isEmpty ? nil : r.stateOfMindSampleIDs
            dto.promptGroupID = r.promptGroupID
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
                    return rdto
                }
            dto.responses = responses.isEmpty ? nil : responses
            return dto
        }

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
                          isEnabled: g.isEnabled, sortOrder: g.sortOrder)
        }
        export.promptGroups = groupDTOs.isEmpty ? nil : groupDTOs
        return export
    }

    public static func exportData(from context: ModelContext) throws -> Data {
        try JSONEncoder.v2.encode(try export(from: context))
    }
}
