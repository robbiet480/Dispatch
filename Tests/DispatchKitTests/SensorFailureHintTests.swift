import Foundation
import Testing
@testable import DispatchKit

@Test func healthKindsHintAtHealthAppDataAccess() {
    let healthKinds: [SensorKind] = [
        .healthSteps, .healthFlights, .healthHeart, .healthHRV, .healthRestingHeart,
        .healthSleep, .healthWorkouts, .healthCaffeine, .healthMedications,
    ]
    for kind in healthKinds {
        #expect(SensorFailureHint.hint(for: kind, reason: "some error") == "Check Health → Data Access & Devices → Dispatch.")
    }
}

@Test func locationHintsAtSettings() {
    #expect(SensorFailureHint.hint(for: .location, reason: "denied") == "Allow location access for Dispatch in Settings.")
}

@Test func weatherHintsAtConnection() {
    #expect(SensorFailureHint.hint(for: .weather, reason: "timed out") == "Check your connection.")
    #expect(SensorFailureHint.hint(for: .weather, reason: nil) == "Check your connection.")
}

@Test func audioAndPhotosHintAtSettingsPaths() {
    #expect(SensorFailureHint.hint(for: .audio, reason: nil) == "Allow microphone access for Dispatch in Settings.")
    #expect(SensorFailureHint.hint(for: .photos, reason: nil) == "Allow photo access for Dispatch in Settings.")
}

@Test func focusHintsAtSettings() {
    #expect(SensorFailureHint.hint(for: .focus, reason: nil) == "Allow Focus status access for Dispatch in Settings.")
}

@Test func genericFallbackUsesCapturedReason() {
    #expect(SensorFailureHint.hint(for: .altitude, reason: "sensor unavailable") == "sensor unavailable")
    #expect(SensorFailureHint.hint(for: .battery, reason: "timed out") == "timed out")
    #expect(SensorFailureHint.hint(for: .connection, reason: nil) == "Unable to detect Connection.")
    #expect(SensorFailureHint.hint(for: .altitude, reason: "") == "Unable to detect Altitude.")
}

@Test func disabledHintPointsAtSensorSettings() {
    #expect(SensorFailureHint.disabledHint(for: .weather) == "Turn Weather back on in Settings → Sensors.")
    #expect(SensorFailureHint.disabledHint(for: .healthSteps) == "Turn Steps back on in Settings → Sensors.")
}

@Test func mediaHintPassesReasonThrough() {
    #expect(SensorFailureHint.hint(for: .media, reason: "Nothing playing") == "Nothing playing")
    #expect(SensorFailureHint.hint(for: .media, reason: nil) == "Unable to detect Media.")
    #expect(SensorFailureHint.disabledHint(for: .media) == "Turn Media back on in Settings → Sensors.")
}
