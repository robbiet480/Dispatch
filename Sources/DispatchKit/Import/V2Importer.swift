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

        for dto in export.questions {
            let id = dto.uniqueIdentifier
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
            report.stateOfMindSampleIDs = dto.stateOfMindSampleIDs ?? []
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
                response.questionIdentifier = rdto.questionIdentifier
                response.tokens = rdto.tokens
                response.answeredOptions = rdto.answeredOptions
                response.locationResponse = rdto.locationResponse
                response.numericResponse = rdto.numericResponse
                response.textResponses = rdto.textResponses
                response.report = report
                summary.responsesImported += 1
            }
        }

        try context.save()
        return summary
    }
}
