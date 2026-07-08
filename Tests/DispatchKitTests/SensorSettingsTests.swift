import Foundation
import Testing
@testable import DispatchKit

private func freshDefaults() -> UserDefaults {
    let name = "test-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

@Test func sensorsDefaultToEnabled() {
    let settings = SensorSettings(defaults: freshDefaults())
    for kind in SensorKind.allCases {
        #expect(settings.isEnabled(kind))
    }
}

@Test func togglePersistsPerKind() {
    let defaults = freshDefaults()
    let settings = SensorSettings(defaults: defaults)
    settings.setEnabled(.weather, false)
    #expect(!settings.isEnabled(.weather))
    #expect(settings.isEnabled(.location))
    let reloaded = SensorSettings(defaults: defaults)
    #expect(!reloaded.isEnabled(.weather))
}

@Test func unitsDefaultToImperial() {
    let settings = SensorSettings(defaults: freshDefaults())
    #expect(settings.temperatureUnit == .fahrenheit)
    #expect(settings.lengthUnit == .feet)
    settings.temperatureUnit = .celsius
    settings.lengthUnit = .meters
    #expect(settings.temperatureUnit == .celsius)
    #expect(settings.lengthUnit == .meters)
}
