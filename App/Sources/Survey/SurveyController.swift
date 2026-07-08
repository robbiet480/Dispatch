import DispatchKit
import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class SurveyController {
    let survey: SurveyViewModel
    private(set) var outcomes: [SensorKind: SensorOutcome] = [:]
    private let kind: ReportKind
    private let trigger: ReportTrigger
    private let settings: SensorSettings
    private let questions: [Question]

    /// --mock-sensors/--ui-testing gate the State of Mind write so UI tests
    /// never trigger a HealthKit share-authorization dialog.
    private let isTestEnvironment = ProcessInfo.processInfo.arguments.contains("--mock-sensors")
        || ProcessInfo.processInfo.arguments.contains("--ui-testing")

    init(questions: [Question], kind: ReportKind, trigger: ReportTrigger, appDefaults: UserDefaults = .standard) {
        self.survey = SurveyViewModel(questions: questions, kind: kind)
        self.kind = kind
        self.trigger = trigger
        self.settings = SensorSettings(defaults: appDefaults)
        self.questions = questions
    }

    static func providers(since: Date?) -> [any SensorProvider] {
        if ProcessInfo.processInfo.arguments.contains("--mock-sensors") {
            return MockProviders.all
        }
        let health = HealthKitReader()
        // One fix store per capture session — no cross-report reuse.
        let fixStore = LocationFixStore()
        return [
            LocationProvider(store: fixStore),
            AltitudeFromLocationProvider(store: fixStore),
            WeatherProvider(store: fixStore),
            BatteryProvider(), ConnectionProvider(), AudioProvider(),
            PhotosProvider(since: since), FocusProvider(),
            HealthMetricProvider(kind: .healthSteps, reader: health, since: since),
            HealthMetricProvider(kind: .healthFlights, reader: health, since: since),
            HealthMetricProvider(kind: .healthHeart, reader: health, since: since),
            HealthMetricProvider(kind: .healthHRV, reader: health, since: since),
            HealthMetricProvider(kind: .healthRestingHeart, reader: health, since: since),
            HealthMetricProvider(kind: .healthSleep, reader: health, since: since),
            HealthMetricProvider(kind: .healthWorkouts, reader: health, since: since),
            HealthMetricProvider(kind: .healthCaffeine, reader: health, since: since),
            HealthMetricProvider(kind: .healthMedications, reader: health, since: since),
        ]
    }

    func startCapture(since: Date?) async {
        let stream = CaptureCoordinator.capture(providers: Self.providers(since: since),
                                                settings: settings)
        for await event in stream {
            outcomes[event.kind] = event.outcome
        }
    }

    func save(in context: ModelContext) throws {
        let report = try ReportBuilder.save(kind: kind, trigger: trigger, date: Date(),
                                            timeZone: TimeZone.current, outcomes: outcomes,
                                            answers: survey.drafts(), in: context)

        guard !isTestEnvironment else { return }
        let savedQuestions = questions
        Task {
            await StateOfMindWriter.write(for: report, in: savedQuestions, context: context)
        }
    }
}

/// Deterministic providers for XCUITest (--mock-sensors).
enum MockProviders {
    static let all: [any SensorProvider] = [
        Mock(kind: .battery, payload: .battery(0.8)),
        Mock(kind: .audio, payload: .audio(AudioSample(avg: -52.8, peak: -40))),
        Mock(kind: .altitude, payload: .altitude(63)),
        Mock(kind: .connection, payload: .connection(1)),
        Mock(kind: .healthSteps, payload: .health([HealthReading(type: "steps", value: 27851, unit: "count")])),
    ]

    struct Mock: SensorProvider {
        let kind: SensorKind
        let payload: SensorPayload
        func capture() async throws -> SensorPayload { payload }
    }
}
