import CoreLocation
import DispatchKit
import Foundation
import WeatherKit

/// WeatherKit current conditions at the report's location. Degrades to
/// unavailable when the entitlement, network, or fix is missing.
struct WeatherProvider: SensorProvider {
    let kind = SensorKind.weather

    func capture() async throws -> SensorPayload {
        var fix: CLLocation?
        for _ in 0..<20 {
            fix = await LocationFixStore.shared.lastFix
            if fix != nil { break }
            try await Task.sleep(for: .milliseconds(400))
        }
        guard let location = fix else { throw ProviderError("no location fix for weather") }

        let current = try await WeatherService.shared.weather(for: location, including: .current)
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
