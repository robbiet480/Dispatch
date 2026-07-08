import CoreLocation
import DispatchKit
import Foundation
import OSLog
import WeatherKit

private let weatherLog = Logger(subsystem: "io.robbie.Dispatch", category: "weather")

/// WeatherKit current conditions at the report's location. Degrades to
/// unavailable when the entitlement, network, or fix is missing.
struct WeatherProvider: SensorProvider {
    let kind = SensorKind.weather
    let store: LocationFixStore

    func capture() async throws -> SensorPayload {
        // Awaits the shared session fix. If none ever arrives this hangs
        // cooperatively; the coordinator timeout (see CaptureCoordinator.resolve)
        // abandons the waiter and yields `.unavailable`.
        let location = await store.awaitFix()

        let current: CurrentWeather
        do {
            current = try await WeatherService.shared.weather(for: location, including: .current)
        } catch {
            // 0-for-3 on device with location present — log the real failure
            // (auth? attribution? network?) so it's diagnosable from Console.
            weatherLog.error("WeatherKit request failed: \(error, privacy: .public) — \(String(describing: error), privacy: .public)")
            throw error
        }
        var observation = WeatherObservation()
        observation.tempF = current.temperature.converted(to: .fahrenheit).value
        observation.tempC = current.temperature.converted(to: .celsius).value
        observation.feelslikeF = current.apparentTemperature.converted(to: .fahrenheit).value
        observation.feelslikeC = current.apparentTemperature.converted(to: .celsius).value
        observation.condition = current.condition.description
        observation.relativeHumidity = "\(Int(current.humidity * 100))%"
        observation.windMPH = current.wind.speed.converted(to: .milesPerHour).value
        observation.windKPH = current.wind.speed.converted(to: .kilometersPerHour).value
        observation.windGustMPH = current.wind.gust?.converted(to: .milesPerHour).value
        observation.windGustKPH = current.wind.gust?.converted(to: .kilometersPerHour).value
        observation.windDegrees = current.wind.direction.converted(to: .degrees).value
        observation.pressureIn = current.pressure.converted(to: .inchesOfMercury).value
        observation.pressureMb = current.pressure.converted(to: .millibars).value
        observation.visibilityMi = current.visibility.converted(to: .miles).value
        observation.visibilityKM = current.visibility.converted(to: .kilometers).value
        observation.dewpointC = current.dewPoint.converted(to: .celsius).value
        observation.uv = Double(current.uvIndex.value)
        return .weather(observation)
    }
}
