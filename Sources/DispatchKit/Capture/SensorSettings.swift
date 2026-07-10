import Foundation

/// Every capturable context source, each independently toggleable.
public enum SensorKind: String, Codable, CaseIterable, Sendable {
    case location, weather, altitude, photos, audio, battery, connection, focus, media
    case healthSteps, healthFlights, healthHeart, healthHRV, healthRestingHeart
    case healthSleep, healthWorkouts, healthCaffeine, healthMedications
    case healthActivityRings
}

public enum TemperatureUnit: String, Codable, Sendable { case fahrenheit, celsius }
public enum LengthUnit: String, Codable, Sendable { case feet, meters }

/// UserDefaults-backed sensor toggles and display units. All sensors
/// default to enabled; units default to imperial (matches the original app).
public final class SensorSettings: @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func key(_ kind: SensorKind) -> String { "sensor.enabled.\(kind.rawValue)" }

    public func isEnabled(_ kind: SensorKind) -> Bool {
        defaults.object(forKey: key(kind)) as? Bool ?? true
    }

    public func setEnabled(_ kind: SensorKind, _ value: Bool) {
        defaults.set(value, forKey: key(kind))
    }

    public var temperatureUnit: TemperatureUnit {
        get { defaults.string(forKey: "units.temperature").flatMap(TemperatureUnit.init(rawValue:)) ?? .fahrenheit }
        set { defaults.set(newValue.rawValue, forKey: "units.temperature") }
    }

    public var lengthUnit: LengthUnit {
        get { defaults.string(forKey: "units.length").flatMap(LengthUnit.init(rawValue:)) ?? .feet }
        set { defaults.set(newValue.rawValue, forKey: "units.length") }
    }
}
