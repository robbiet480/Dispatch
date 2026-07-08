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
    /// When set, this is a backdated report: capture is skipped entirely and
    /// the report is saved at this date with `isBackdated = true`.
    let overrideDate: Date?
    /// Group-scoped survey (plan 12): recorded on the saved report.
    private let promptGroupID: String?
    /// The HKWorkout UUID that fired a workout-end prompt (plan 12
    /// amendment); when set, capture attaches that workout's details.
    private let triggeringWorkoutID: String?

    var isBackdated: Bool { overrideDate != nil }

    /// --mock-sensors/--ui-testing gate the State of Mind write so UI tests
    /// never trigger a HealthKit share-authorization dialog.
    private let isTestEnvironment = ProcessInfo.processInfo.arguments.contains("--mock-sensors")
        || ProcessInfo.processInfo.arguments.contains("--ui-testing")

    init(questions: [Question], kind: ReportKind, trigger: ReportTrigger, overrideDate: Date? = nil,
         promptGroupID: String? = nil, groupQuestionIDs: [String]? = nil,
         triggeringWorkoutID: String? = nil,
         appDefaults: UserDefaults = .standard) {
        self.survey = SurveyViewModel(questions: questions, kind: kind, groupQuestionIDs: groupQuestionIDs)
        self.kind = kind
        self.trigger = trigger
        self.settings = SensorSettings(defaults: appDefaults)
        self.questions = questions
        self.overrideDate = overrideDate
        self.promptGroupID = promptGroupID
        self.triggeringWorkoutID = triggeringWorkoutID
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
            HealthMetricProvider(kind: .healthActivityRings, reader: health, since: since),
            // .healthMedications intentionally not composed: its read type is
            // rejected by bulk requestAuthorization (device crash) — see
            // HealthKitReader.readTypes.
        ]
    }

    func startCapture(since: Date?) async {
        // Backdated reports skip sensor capture entirely — no providers run.
        guard overrideDate == nil else { return }
        let stream = CaptureCoordinator.capture(providers: Self.providers(since: since),
                                                settings: settings)
        for await event in stream {
            outcomes[event.kind] = event.outcome
        }
        await attachTriggeringWorkoutIfNeeded()
    }

    /// Workout-end prompts (plan 12 amendment): re-fetch the triggering
    /// workout and fold its `workout.trigger.*` readings into the workouts
    /// outcome. Empty readings (workout deleted, permissions revoked) or
    /// test mode degrade to the plain workoutEnd trigger — no extra rows.
    private func attachTriggeringWorkoutIfNeeded() async {
        guard let triggeringWorkoutID, !isTestEnvironment else { return }
        let readings = await HealthKitReader().triggeredWorkoutReadings(workoutID: triggeringWorkoutID)
        guard !readings.isEmpty else { return }
        if case .captured(.health(let existing)) = outcomes[.healthWorkouts] {
            outcomes[.healthWorkouts] = .captured(.health(existing + readings))
        } else {
            outcomes[.healthWorkouts] = .captured(.health(readings))
        }
    }

    func save(in context: ModelContext) throws {
        let report = try ReportBuilder.save(kind: kind, trigger: trigger, date: overrideDate ?? Date(),
                                            timeZone: TimeZone.current, outcomes: outcomes,
                                            answers: survey.drafts(), in: context,
                                            isBackdated: isBackdated,
                                            promptGroupID: promptGroupID)

        SpotlightIndexer.index(report: report)

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
