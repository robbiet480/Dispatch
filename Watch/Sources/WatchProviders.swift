import DispatchKit
import Foundation

/// The watch's sensor provider set (plan 19 design §v1-scope-3): location
/// (+altitude), weather, battery, and every health kind — all doc-cited
/// watch-native. Phone-only sensors (photos, audio, connection, focus,
/// pedometer flights-down) are simply ABSENT from this array, so watch
/// reports carry nil for them — provenance lets detail UI render that as
/// "not captured on Apple Watch" rather than a failure.
///
/// Permissions are the watch's own: LocationProvider requests when-in-use
/// and HealthKitReader.authorize() requests HealthKit read access lazily at
/// first capture — Apple: frameworks supporting independent watch apps
/// "display their authorization form directly on Apple Watch"
/// (https://developer.apple.com/documentation/watchos-apps/creating-independent-watchos-apps).
/// Ungranted sensors resolve `unavailable` and never block filing.
enum WatchProviders {
    /// The sensor kinds the watch can capture — drives both the provider
    /// array and the settings screen's toggle list.
    static let watchCapableKinds: [SensorKind] = [
        .location, .altitude, .weather, .battery,
        .healthSteps, .healthFlights, .healthHeart, .healthHRV,
        .healthRestingHeart, .healthSleep, .healthWorkouts, .healthCaffeine,
        .healthMedications, .healthActivityRings,
    ]

    /// Test-gated exactly like the phone (`SurveyController.providers`):
    /// `--mock-sensors`/`--ui-testing` runs never touch system frameworks.
    static func all(since: Date?) -> [any SensorProvider] {
        if ProcessInfo.processInfo.arguments.contains("--mock-sensors")
            || ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            return mocks
        }
        let health = HealthKitReader()
        // One fix store per capture session — no cross-report reuse
        // (same rule as the phone's SurveyController).
        let fixStore = LocationFixStore()
        return [
            LocationProvider(store: fixStore),
            AltitudeFromLocationProvider(store: fixStore),
            WeatherProvider(store: fixStore),
            BatteryProvider(),
            HealthMetricProvider(kind: .healthSteps, reader: health, since: since),
            HealthMetricProvider(kind: .healthFlights, reader: health, since: since),
            HealthMetricProvider(kind: .healthHeart, reader: health, since: since),
            HealthMetricProvider(kind: .healthHRV, reader: health, since: since),
            HealthMetricProvider(kind: .healthRestingHeart, reader: health, since: since),
            HealthMetricProvider(kind: .healthSleep, reader: health, since: since),
            HealthMetricProvider(kind: .healthWorkouts, reader: health, since: since),
            HealthMetricProvider(kind: .healthCaffeine, reader: health, since: since),
            HealthMetricProvider(kind: .healthActivityRings, reader: health, since: since),
            // Medications: the type stays OUT of the bulk read set (see
            // HealthKitReader.readTypes' device-crash history); without the
            // per-object grant this resolves unavailable, never blocking.
            HealthMetricProvider(kind: .healthMedications, reader: health, since: since),
        ]
    }

    /// Deterministic providers for test launches (mirrors the phone's
    /// MockProviders with watch-capable kinds only).
    private static let mocks: [any SensorProvider] = [
        Mock(kind: .battery, payload: .battery(0.8)),
        Mock(kind: .altitude, payload: .altitude(63)),
        Mock(kind: .healthSteps, payload: .health([HealthReading(type: "steps", value: 27851, unit: "count")])),
    ]

    private struct Mock: SensorProvider {
        let kind: SensorKind
        let payload: SensorPayload
        func capture() async throws -> SensorPayload { payload }
    }
}

extension SensorKind {
    /// Watch-side mirror of the phone settings screen's display names
    /// (App/Sources/Settings/SensorSettingsView.swift) for the watch-capable
    /// subset.
    var watchDisplayName: String {
        switch self {
        case .location: "Location"
        case .weather: "Weather"
        case .altitude: "Elevation"
        case .photos: "Photos"
        case .audio: "Audio"
        case .battery: "Battery"
        case .connection: "Connection"
        case .focus: "Focus"
        case .healthSteps: "Steps"
        case .healthFlights: "Stairs"
        case .healthHeart: "Heart Rate"
        case .healthHRV: "HRV"
        case .healthRestingHeart: "Resting Heart Rate"
        case .healthSleep: "Sleep"
        case .healthWorkouts: "Workouts"
        case .healthCaffeine: "Caffeine"
        case .healthMedications: "Medications"
        case .healthActivityRings: "Activity Rings"
        // Media is phone-only in v1 (plan 26) — named here only because the
        // switch is exhaustive; no watch provider exists for it.
        case .media: "Media"
        }
    }
}
