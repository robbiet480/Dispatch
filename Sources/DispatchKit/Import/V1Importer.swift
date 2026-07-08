import Foundation
import SwiftData

public struct ImportSummary: Sendable, Equatable {
    public var questionsImported = 0
    public var reportsImported = 0
    public var responsesImported = 0
    public var skipped = 0
    public init() {}
}

public enum V1Importer {
    /// Idempotent: records are upserted by uniqueIdentifier; re-importing
    /// the same file changes nothing. Malformed records are skipped and
    /// counted, never fatal.
    public static func importExport(_ data: Data, into context: ModelContext) throws -> ImportSummary {
        let export = try V1Export.decode(from: data)
        var summary = ImportSummary()

        for (index, v1q) in export.questions.enumerated() {
            let question = try fetchOrCreateQuestion(id: v1q.uniqueIdentifier, in: context)
            question.prompt = v1q.prompt
            question.typeRaw = v1q.questionType
            question.placeholderString = v1q.placeholderString
            question.sortOrder = index
            summary.questionsImported += 1
        }

        for snapshot in export.snapshots {
            guard let parsed = snapshot.date.resolved else {
                summary.skipped += 1
                continue
            }
            let report = try fetchOrCreateReport(id: snapshot.uniqueIdentifier, in: context)
            report.date = parsed.date
            report.timeZoneIdentifier = TimeZone(secondsFromGMT: parsed.utcOffsetSeconds)?.identifier ?? "GMT"
            report.legacyImpetus = snapshot.reportImpetus
            // v1 impetus (gist.github.com/dbreunig/9315705): 0=button,
            // 1=button while asleep, 2=notification, 3=sleep report, 4=wake report.
            switch snapshot.reportImpetus ?? 0 {
            case 2:
                report.kind = .regular
                report.trigger = .notification
            case 3:
                report.kind = .sleep
                report.trigger = .manual
            case 4:
                report.kind = .wake
                report.trigger = .wake
            default:
                report.kind = .regular
                report.trigger = .manual
            }
            report.isDraft = snapshot.draft == 1
            report.wasInBackground = snapshot.background == 1
            report.battery = snapshot.battery
            // Extract Double from V1AltitudeValue enum
            report.altitudeMeters = snapshot.altitude.flatMap { altValue in
                switch altValue {
                case .simple(let double):
                    return double
                case .detailed(let data):
                    return data.gpsRawAltitude ?? data.gpsAltitudeFromLocation
                }
            }
            report.connection = snapshot.connection
            report.audio = snapshot.audio.map { AudioSample(avg: $0.avg, peak: $0.peak) }
            report.location = snapshot.location.map(mapLocation)
            report.weather = snapshot.weather.map(mapWeather)
            report.photos = snapshot.photoSet?.photos.map(mapPhoto) ?? []
            report.health = snapshot.steps.map {
                [HealthReading(type: "steps", value: Double($0), unit: "count")]
            } ?? []
            summary.reportsImported += 1

            for v1r in snapshot.responses ?? [] {
                let response = try fetchOrCreateResponse(id: v1r.uniqueIdentifier, in: context)
                response.questionPrompt = v1r.questionPrompt
                response.tokens = v1r.tokens?.map { TokenValue(uniqueIdentifier: $0.uniqueIdentifier, text: $0.text) }
                response.answeredOptions = v1r.answeredOptions
                response.numericResponse = v1r.numericResponse
                response.textResponses = v1r.textResponses?.map { TokenValue(uniqueIdentifier: $0.uniqueIdentifier, text: $0.text) }
                response.locationResponse = v1r.locationResponse.map { lr in
                    var answer = LocationAnswer()
                    answer.text = lr.text
                    answer.foursquareVenueId = lr.foursquareVenueId
                    answer.location = lr.location.map(mapLocation)
                    return answer
                }
                response.report = report
                summary.responsesImported += 1
            }
        }

        try context.save()
        return summary
    }

    private static func fetchOrCreateQuestion(id: String, in context: ModelContext) throws -> Question {
        var descriptor = FetchDescriptor<Question>(predicate: #Predicate { $0.uniqueIdentifier == id })
        descriptor.fetchLimit = 1
        if let existing = try context.fetch(descriptor).first { return existing }
        let question = Question()
        question.uniqueIdentifier = id
        context.insert(question)
        return question
    }

    private static func fetchOrCreateReport(id: String, in context: ModelContext) throws -> Report {
        var descriptor = FetchDescriptor<Report>(predicate: #Predicate { $0.uniqueIdentifier == id })
        descriptor.fetchLimit = 1
        if let existing = try context.fetch(descriptor).first { return existing }
        let report = Report()
        report.uniqueIdentifier = id
        context.insert(report)
        return report
    }

    private static func fetchOrCreateResponse(id: String, in context: ModelContext) throws -> Response {
        var descriptor = FetchDescriptor<Response>(predicate: #Predicate { $0.uniqueIdentifier == id })
        descriptor.fetchLimit = 1
        if let existing = try context.fetch(descriptor).first { return existing }
        let response = Response()
        response.uniqueIdentifier = id
        context.insert(response)
        return response
    }

    private static func mapLocation(_ v1: V1Location) -> LocationSnapshot {
        var snapshot = LocationSnapshot(latitude: v1.latitude, longitude: v1.longitude)
        snapshot.altitude = v1.altitude
        snapshot.horizontalAccuracy = v1.horizontalAccuracy
        snapshot.verticalAccuracy = v1.verticalAccuracy
        snapshot.speed = v1.speed
        snapshot.course = v1.course
        snapshot.timestamp = v1.timestamp?.resolved?.date
        snapshot.placemark = v1.placemark.map { pm in
            var placemark = Placemark()
            placemark.name = pm.name
            placemark.thoroughfare = pm.thoroughfare
            placemark.subThoroughfare = pm.subThoroughfare
            placemark.locality = pm.locality
            placemark.subLocality = pm.subLocality
            placemark.administrativeArea = pm.administrativeArea
            placemark.subAdministrativeArea = pm.subAdministrativeArea
            placemark.postalCode = pm.postalCode
            placemark.country = pm.country
            return placemark
        }
        return snapshot
    }

    private static func mapWeather(_ v1: V1Weather) -> WeatherObservation {
        var weather = WeatherObservation()
        weather.tempF = v1.tempF
        weather.tempC = v1.tempC
        weather.condition = v1.weather
        weather.relativeHumidity = v1.relativeHumidity
        weather.windMPH = v1.windMPH
        weather.windKPH = v1.windKPH
        weather.windGustMPH = v1.windGustMPH
        weather.windGustKPH = v1.windGustKPH
        weather.windDirection = v1.windDirection
        weather.windDegrees = v1.windDegrees
        weather.pressureIn = v1.pressureIn
        weather.pressureMb = v1.pressureMb
        weather.visibilityMi = v1.visibilityMi
        weather.visibilityKM = v1.visibilityKM
        weather.feelslikeF = v1.feelslikeF
        weather.feelslikeC = v1.feelslikeC
        weather.dewpointC = v1.dewpointC
        weather.precipTodayIn = v1.precipTodayIn
        weather.precipTodayMetric = v1.precipTodayMetric
        weather.uv = v1.uv
        weather.stationID = v1.stationID
        return weather
    }

    private static func mapPhoto(_ v1: V1Photo) -> PhotoRecord {
        var photo = PhotoRecord(uniqueIdentifier: v1.uniqueIdentifier)
        photo.assetUrl = v1.assetUrl
        photo.pixelWidth = v1.pixelWidth
        photo.pixelHeight = v1.pixelHeight
        photo.dateTime = v1.dateTime?.resolved?.date
        photo.latitude = v1.latitude
        photo.longitude = v1.longitude
        return photo
    }
}
