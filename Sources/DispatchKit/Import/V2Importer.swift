import Foundation
import SwiftData

public enum V2Importer {
    public enum ImportError: Error, Equatable {
        case unsupportedSchemaVersion(Int)
    }

    public static func importExport(_ data: Data, into context: ModelContext) throws -> ImportSummary {
        let export = try JSONDecoder.v2.decode(V2Export.self, from: data)
        guard export.schemaVersion == DispatchKitInfo.schemaVersion else {
            throw ImportError.unsupportedSchemaVersion(export.schemaVersion)
        }
        var summary = ImportSummary()

        // Build-5 exports carry legacy seeded identifiers
        // (`default-question-<N>`). Post-migration stores use deterministic
        // UUIDs, so map any legacy ID through the frozen migration table at
        // import time — otherwise the upsert-by-identifier below inserts
        // duplicate default questions (and dangling references) that sync
        // then propagates everywhere.
        func mapped(_ id: String) -> String {
            DefaultQuestions.migratedIdentifier(forLegacyID: id) ?? id
        }

        for dto in export.questions {
            let id = mapped(dto.uniqueIdentifier)
            var descriptor = FetchDescriptor<Question>(predicate: #Predicate { $0.uniqueIdentifier == id })
            descriptor.fetchLimit = 1
            let question = try context.fetch(descriptor).first ?? {
                let q = Question()
                q.uniqueIdentifier = id
                context.insert(q)
                return q
            }()
            question.prompt = dto.prompt
            question.typeRaw = dto.questionType
            question.placeholderString = dto.placeholderString
            question.choices = dto.choices ?? []
            question.sortOrder = dto.sortOrder
            question.isEnabled = dto.isEnabled
            question.stateOfMindKind = dto.stateOfMindKind
            question.reportKinds = dto.reportKinds
            question.visualizationRaw = dto.visualization
            question.defaultAnswerString = dto.defaultAnswerString
            question.allowsMultipleSelectionRaw = dto.allowsMultipleSelection
            question.inputStyleRaw = dto.inputStyle
            question.inputMin = dto.inputMin
            question.inputMax = dto.inputMax
            question.inputStep = dto.inputStep
            summary.questionsImported += 1
        }

        for dto in export.reports {
            let id = dto.uniqueIdentifier
            var descriptor = FetchDescriptor<Report>(predicate: #Predicate { $0.uniqueIdentifier == id })
            descriptor.fetchLimit = 1
            let report = try context.fetch(descriptor).first ?? {
                let r = Report()
                r.uniqueIdentifier = id
                context.insert(r)
                return r
            }()
            report.date = dto.date
            report.timeZoneIdentifier = dto.timeZone
            report.kind = dto.kind
            report.trigger = dto.trigger
            report.legacyImpetus = dto.legacyImpetus
            report.legacySectionIdentifier = dto.legacySectionIdentifier
            report.isBackdated = dto.isBackdated
            report.isDraft = dto.isDraft
            report.wasInBackground = dto.wasInBackground
            report.battery = dto.battery
            report.altitudeMeters = dto.altitudeMeters
            report.connection = dto.connection
            report.audio = dto.audio
            report.location = dto.location
            report.weather = dto.weather
            report.photos = dto.photos ?? []
            report.health = dto.health ?? []
            report.focus = dto.focus
            report.media = dto.media
            report.stateOfMindSampleIDs = dto.stateOfMindSampleIDs ?? []
            report.promptGroupID = dto.promptGroupID
            // Provenance travels verbatim (plan 19): imported reports keep
            // the exporting device's stamp (or nil for pre-provenance files);
            // they are never restamped with the importing device's identity.
            report.sourceDeviceModel = dto.sourceDeviceModel
            report.sourceDeviceName = dto.sourceDeviceName
            summary.reportsImported += 1

            for rdto in dto.responses ?? [] {
                let rid = rdto.uniqueIdentifier
                var rdescriptor = FetchDescriptor<Response>(predicate: #Predicate { $0.uniqueIdentifier == rid })
                rdescriptor.fetchLimit = 1
                let response = try context.fetch(rdescriptor).first ?? {
                    let resp = Response()
                    resp.uniqueIdentifier = rid
                    context.insert(resp)
                    return resp
                }()
                response.questionPrompt = rdto.questionPrompt
                response.questionIdentifier = rdto.questionIdentifier.map(mapped)
                response.tokens = rdto.tokens
                response.answeredOptions = rdto.answeredOptions
                response.locationResponse = rdto.locationResponse
                response.numericResponse = rdto.numericResponse
                response.textResponses = rdto.textResponses
                response.report = report
                summary.responsesImported += 1
            }
        }

        // Prompt groups (plan 12): deduped by uniqueIdentifier, same upsert
        // pattern as questions. Absent in older exports → no-op.
        for dto in export.promptGroups ?? [] {
            let id = dto.uniqueIdentifier
            var descriptor = FetchDescriptor<PromptGroup>(predicate: #Predicate { $0.uniqueIdentifier == id })
            descriptor.fetchLimit = 1
            let group = try context.fetch(descriptor).first ?? {
                let g = PromptGroup()
                g.uniqueIdentifier = id
                context.insert(g)
                return g
            }()
            group.name = dto.name
            group.questionIDs = (dto.questionIDs ?? []).map(mapped)
            group.scheduleKindRaw = dto.scheduleKind
            group.scheduleHours = dto.scheduleHours
            group.scheduleCount = dto.scheduleCount
            group.scheduleDistributionRaw = dto.scheduleDistribution
            group.scheduledTimeStrings = dto.scheduledTimes ?? []
            group.isEnabled = dto.isEnabled
            group.sortOrder = dto.sortOrder
            summary.promptGroupsImported += 1
        }

        // Person registry (plan 22): upsert by uniqueIdentifier. Absent in
        // older exports → no-op (vocabulary rebuild derives plain entries).
        for dto in export.people ?? [] {
            let id = dto.uniqueIdentifier
            var descriptor = FetchDescriptor<PersonEntity>(
                predicate: #Predicate { $0.uniqueIdentifier == id })
            descriptor.fetchLimit = 1
            let person = try context.fetch(descriptor).first ?? {
                let p = PersonEntity()
                p.uniqueIdentifier = id
                context.insert(p)
                return p
            }()
            person.text = dto.displayName
            person.alternateNames = dto.alternateNames ?? []
        }

        try context.save()
        return summary
    }
}
