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
            MediaProvider(spotify: SpotifyReaderFactory.current()),
            HealthMetricProvider(kind: .healthSteps, reader: health, since: since),
            HealthMetricProvider(kind: .healthFlights, reader: health, since: since),
            HealthMetricProvider(kind: .healthHeart, reader: health, since: since),
            HealthMetricProvider(kind: .healthHeartRange, reader: health, since: since),
            HealthMetricProvider(kind: .healthHRV, reader: health, since: since),
            HealthMetricProvider(kind: .healthRestingHeart, reader: health, since: since),
            HealthMetricProvider(kind: .healthSleep, reader: health, since: since),
            HealthMetricProvider(kind: .healthWorkouts, reader: health, since: since),
            HealthMetricProvider(kind: .healthCaffeine, reader: health, since: since),
            HealthMetricProvider(kind: .healthActivityRings, reader: health, since: since),
            // Medications (plan 14 T5): authorization is the dedicated
            // per-object call in the permission cascade — the type is still
            // NEVER in the bulk read set (device-crash history, see
            // HealthKitReader.readTypes).
            HealthMetricProvider(kind: .healthMedications, reader: health, since: since),
        ]
    }

    /// Capture-time context metadata (plan 44, #61): assembled alongside the
    /// sensor capture, stamped onto the report at save. Empty for backdated
    /// reports (no capture ran) and in the test environment (deterministic
    /// runs never touch UIKit/CoreMotion state).
    private(set) var metadata = CaptureMetadata()

    func startCapture(since: Date?) async {
        // Backdated reports skip sensor capture entirely — no providers run.
        guard overrideDate == nil else { return }
        let metadataTask: Task<CaptureMetadata, Never>? = isTestEnvironment ? nil : Task { [settings] in
            await CaptureMetadataReader.read(settings: settings)
        }
        let stream = CaptureCoordinator.capture(providers: Self.providers(since: since),
                                                settings: settings)
        for await event in stream {
            outcomes[event.kind] = event.outcome
        }
        if let metadataTask {
            // startCapture runs under a SwiftUI `.task`; if the view was
            // dismissed mid-capture, don't block teardown awaiting the metadata
            // reads (CoreMotion/UI) — cancel the task and skip the await, its
            // completion handlers resolve and are discarded (Copilot review
            // catch on PR #72).
            if Task.isCancelled {
                metadataTask.cancel()
            } else {
                metadata = await metadataTask.value
            }
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

    /// Returns the saved report so post-save hooks (webhook enqueue,
    /// plan 24) can reference its uniqueIdentifier.
    @discardableResult
    func save(in context: ModelContext) throws -> Report {
        let report = try ReportBuilder.save(kind: kind, trigger: trigger, date: overrideDate ?? Date(),
                                            timeZone: TimeZone.current, outcomes: outcomes,
                                            answers: survey.drafts(), in: context,
                                            isBackdated: isBackdated,
                                            promptGroupID: promptGroupID,
                                            metadata: metadata)

        SpotlightIndexer.index(report: report)

        guard !isTestEnvironment else { return report }
        // Widgets read the shared store directly but get no change
        // notifications — poke them after every report save.
        WidgetRefresher.reload()
        let savedQuestions = questions
        Task {
            await StateOfMindWriter.write(for: report, in: savedQuestions, context: context)
        }
        return report
    }
}

/// Deterministic providers for XCUITest (--mock-sensors).
///
/// Screenshot-review fix: this set must cover EVERY capture-checklist row —
/// a kind with no provider never gets an outcome, so its row spins
/// "GETTING …" forever (which photographed as a broken mid-collection
/// state). Medications mocks the granted-but-nothing-logged case (empty
/// readings), which hides its row — the checklist's documented behavior.
enum MockProviders {
    static let all: [any SensorProvider] = [
        Mock(kind: .location, payload: .location(sanFrancisco)),
        Mock(kind: .weather, payload: .weather(fog)),
        Mock(kind: .battery, payload: .battery(0.8)),
        Mock(kind: .audio, payload: .audio(AudioSample(avg: -52.8, peak: -40))),
        Mock(kind: .altitude, payload: .altitude(63)),
        Mock(kind: .connection, payload: .connection(1)),
        Mock(kind: .photos, payload: .photos(count: 3, records: [])),
        Mock(kind: .healthSteps, payload: .health([HealthReading(type: "steps", value: 27851, unit: "count")])),
        Mock(kind: .healthFlights, payload: .health([
            HealthReading(type: "flightsClimbed", value: 8, unit: "count"),
            HealthReading(type: "flightsDescended", value: 2, unit: "count"),
        ])),
        Mock(kind: .healthActivityRings, payload: .health([
            HealthReading(type: "activity.move", value: 346, unit: "kcal"),
            HealthReading(type: "activity.moveGoal", value: 500, unit: "kcal"),
            HealthReading(type: "activity.exercise", value: 36, unit: "min"),
            HealthReading(type: "activity.exerciseGoal", value: 30, unit: "min"),
            HealthReading(type: "activity.stand", value: 7, unit: "hours"),
            HealthReading(type: "activity.standGoal", value: 12, unit: "hours"),
        ])),
        Mock(kind: .healthMedications, payload: .health([])),
        // Plan 43: matches the acceptance-criteria detail line
        // "72 → 88 bpm (+16) · low 64 · high 112".
        Mock(kind: .healthHeartRange, payload: .health([
            HealthReading(type: HeartRateWindowFormatter.startType, value: 72, unit: "bpm"),
            HealthReading(type: HeartRateWindowFormatter.endType, value: 88, unit: "bpm"),
            HealthReading(type: HeartRateWindowFormatter.minType, value: 64, unit: "bpm"),
            HealthReading(type: HeartRateWindowFormatter.maxType, value: 112, unit: "bpm"),
        ])),
        Mock(kind: .media, payload: .media(MediaSample(source: .spotify, title: "Song 2", artist: "Blur"))),
    ]

    private static var sanFrancisco: LocationSnapshot {
        var snapshot = LocationSnapshot(latitude: 37.7764, longitude: -122.4231)
        var placemark = Placemark()
        placemark.locality = "San Francisco"
        placemark.administrativeArea = "CA"
        snapshot.placemark = placemark
        return snapshot
    }

    private static var fog: WeatherObservation {
        var weather = WeatherObservation()
        weather.condition = "Fog"
        weather.tempF = 61
        weather.tempC = 16.1
        return weather
    }

    struct Mock: SensorProvider {
        let kind: SensorKind
        let payload: SensorPayload
        func capture() async throws -> SensorPayload { payload }
    }
}
