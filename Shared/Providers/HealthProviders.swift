import DispatchKit
import Foundation
import HealthKit

/// Accumulates streaming query results and guards the continuation against
/// double-resume (HKUserAnnotatedMedicationQuery's resultsHandler is invoked
/// repeatedly; an error after `done` must not resume twice). HealthKit calls
/// the handler serially, hence the unchecked Sendable + plain vars.
private final class ResultsBox<Element>: @unchecked Sendable {
    private(set) var results: [Element] = []
    private var finished = false

    func append(_ element: Element) {
        results.append(element)
    }

    /// Returns true exactly once — the caller may resume the continuation.
    func finish() -> Bool {
        guard !finished else { return false }
        finished = true
        return true
    }
}

/// Shared HealthKit access for all health sensor providers.
final class HealthKitReader: Sendable {
    let store = HKHealthStore()

    // NOTE: the medication types (medicationDoseEventType,
    // userAnnotatedMedicationType) are deliberately ABSENT and must NEVER be
    // added here. Including one in a bulk requestAuthorization read set
    // throws an uncatchable ObjC NSInvalidArgumentException on device
    // ("Authorization to read the following types is disallowed") — it
    // crashed a real device on day one, and Swift cannot catch NSExceptions.
    // Medications use the dedicated per-object call instead
    // (`requestPerObjectReadAuthorization(for: .userAnnotatedMedicationType())`,
    // sequenced in PermissionCascade.requestMedications) — the iOS 26 SDK
    // headers mark HKUserAnnotatedMedicationType as "the set of authorizeable
    // HKUserAnnotatedMedications" and requestPerObjectReadAuthorization as
    // the prompt "for types that support per object authorization".
    static let readTypes: Set<HKObjectType> = [
        HKQuantityType(.stepCount), HKQuantityType(.flightsClimbed),
        HKQuantityType(.heartRate), HKQuantityType(.heartRateVariabilitySDNN),
        HKQuantityType(.restingHeartRate), HKQuantityType(.dietaryCaffeine),
        HKCategoryType(.sleepAnalysis), HKObjectType.workoutType(),
        HKObjectType.activitySummaryType(),
    ]

    func authorize() async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw ProviderError("health data unavailable on this device")
        }
        try await store.requestAuthorization(toShare: [], read: Self.readTypes)
    }

    func sum(_ id: HKQuantityTypeIdentifier, unit: HKUnit, since: Date) async throws -> Double {
        let type = HKQuantityType(id)
        return try await withCheckedThrowingContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(withStart: since, end: nil)
            let query = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate,
                                          options: .cumulativeSum) { _, stats, error in
                if let error {
                    // HKStatisticsQuery completes with HKError.errorNoData (code 11)
                    // instead of returning empty stats when zero samples match the
                    // predicate window (e.g. short report intervals with no steps
                    // logged yet). That's a legitimate "0", not a failure — do NOT
                    // rethrow it, or short windows will report "unavailable"
                    // instead of 0. Any other error still propagates.
                    if (error as? HKError)?.code == .errorNoData {
                        continuation.resume(returning: 0)
                    } else {
                        continuation.resume(throwing: error)
                    }
                    return
                }
                continuation.resume(returning: stats?.sumQuantity()?.doubleValue(for: unit) ?? 0)
            }
            store.execute(query)
        }
    }

    func average(_ id: HKQuantityTypeIdentifier, unit: HKUnit, since: Date) async throws -> Double? {
        let type = HKQuantityType(id)
        return try await withCheckedThrowingContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(withStart: since, end: nil)
            let query = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate,
                                          options: .discreteAverage) { _, stats, error in
                if let error {
                    // Same errorNoData semantics as sum(): zero matching samples is
                    // "no reading" (nil), not an error to surface/throw.
                    if (error as? HKError)?.code == .errorNoData {
                        continuation.resume(returning: nil)
                    } else {
                        continuation.resume(throwing: error)
                    }
                    return
                }
                continuation.resume(returning: stats?.averageQuantity()?.doubleValue(for: unit))
            }
            store.execute(query)
        }
    }

    /// Min and max over `[start, end]` in one statistics query (plan 43).
    /// `errorNoData` (zero samples in the window) is "no reading" — nil, not
    /// an error — matching `average`.
    ///
    /// Strict edges (Copilot review, PR #64): without the strict options,
    /// `predicateForSamples` matches any sample that merely OVERLAPS the
    /// interval, so a long sample spanning a window edge (e.g. a workout-
    /// average HR written across the previous report's date) could
    /// contribute extremes from OUTSIDE the window. "Since the last report"
    /// means samples fully inside the window — edge-spanning samples belong
    /// to the neighboring window. Untestable at the kit layer (HealthKit
    /// predicate), hence pinned by comment.
    func minMax(_ id: HKQuantityTypeIdentifier, unit: HKUnit,
                from start: Date, to end: Date) async throws -> (min: Double, max: Double)? {
        let type = HKQuantityType(id)
        return try await withCheckedThrowingContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(withStart: start, end: end,
                                                        options: [.strictStartDate, .strictEndDate])
            let query = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate,
                                          options: [.discreteMin, .discreteMax]) { _, stats, error in
                if let error {
                    if (error as? HKError)?.code == .errorNoData {
                        continuation.resume(returning: nil)
                    } else {
                        continuation.resume(throwing: error)
                    }
                    return
                }
                guard let min = stats?.minimumQuantity()?.doubleValue(for: unit),
                      let max = stats?.maximumQuantity()?.doubleValue(for: unit) else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: (min, max))
            }
            store.execute(query)
        }
    }

    /// The first (`newest: false`) or last (`newest: true`) sample strictly
    /// inside `[start, end]` — the window's boundary readings (plan 43).
    /// Strict edges for the same reason as `minMax` (Copilot review,
    /// PR #64): an overlap-matched edge-spanning sample would make the
    /// window's "start"/"end" reading one that isn't actually inside the
    /// window at all.
    func boundarySample(_ id: HKQuantityTypeIdentifier, unit: HKUnit,
                        from start: Date, to end: Date,
                        newest: Bool) async throws -> (value: Double, date: Date)? {
        let type = HKQuantityType(id)
        return try await withCheckedThrowingContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(withStart: start, end: end,
                                                        options: [.strictStartDate, .strictEndDate])
            let sort = [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: !newest)]
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: 1,
                                      sortDescriptors: sort) { _, samples, error in
                if let error { continuation.resume(throwing: error); return }
                guard let sample = samples?.first as? HKQuantitySample else {
                    continuation.resume(returning: nil); return
                }
                continuation.resume(returning: (sample.quantity.doubleValue(for: unit), sample.endDate))
            }
            store.execute(query)
        }
    }

    func latest(_ id: HKQuantityTypeIdentifier, unit: HKUnit) async throws -> (value: Double, date: Date)? {
        let type = HKQuantityType(id)
        // Bound to the last 24h so HRV/resting/latest-HR can't surface
        // weeks-old samples when today has no reading.
        let start = Date().addingTimeInterval(-24 * 60 * 60)
        return try await withCheckedThrowingContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(withStart: start, end: nil)
            let sort = [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: 1,
                                      sortDescriptors: sort) { _, samples, error in
                if let error { continuation.resume(throwing: error); return }
                guard let sample = samples?.first as? HKQuantitySample else {
                    continuation.resume(returning: nil); return
                }
                continuation.resume(returning: (sample.quantity.doubleValue(for: unit), sample.endDate))
            }
            store.execute(query)
        }
    }

    func sleepSeconds(sinceYesterdayEvening now: Date) async throws -> [String: Double] {
        let start = Calendar.current.date(byAdding: .hour, value: -18,
                                          to: Calendar.current.startOfDay(for: now))!
        return try await withCheckedThrowingContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(withStart: start, end: now)
            let query = HKSampleQuery(sampleType: HKCategoryType(.sleepAnalysis), predicate: predicate,
                                      limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, error in
                if let error { continuation.resume(throwing: error); return }
                var byStage: [String: Double] = [:]
                for case let sample as HKCategorySample in samples ?? [] {
                    guard let stage = HKCategoryValueSleepAnalysis(rawValue: sample.value),
                          HKCategoryValueSleepAnalysis.allAsleepValues.contains(stage) else { continue }
                    let key: String = switch stage {
                    case .asleepDeep: "sleepDeep"
                    case .asleepREM: "sleepREM"
                    case .asleepCore: "sleepCore"
                    default: "sleepUnspecified"
                    }
                    byStage[key, default: 0] += sample.endDate.timeIntervalSince(sample.startDate)
                }
                continuation.resume(returning: byStage)
            }
            store.execute(query)
        }
    }

    /// The per-object authorization prompt for medications (plan 14 T5) —
    /// the ONLY legal way to request medication read access; see the
    /// readTypes note above for the bulk-request crash history.
    func authorizeMedications() async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw ProviderError("health data unavailable on this device")
        }
        try await store.requestPerObjectReadAuthorization(
            for: .userAnnotatedMedicationType(), predicate: nil
        )
    }

    /// The user's tracked medications the app has been granted (per-object
    /// authorization) — used to resolve dose events to display names.
    private func userAnnotatedMedications() async throws -> [HKUserAnnotatedMedication] {
        let box = ResultsBox<HKUserAnnotatedMedication>()
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKUserAnnotatedMedicationQuery(
                predicate: nil, limit: HKObjectQueryNoLimit
            ) { _, medication, done, error in
                if let error {
                    if box.finish() { continuation.resume(throwing: error) }
                    return
                }
                if let medication { box.append(medication) }
                if done, box.finish() { continuation.resume(returning: box.results) }
            }
            store.execute(query)
        }
    }

    /// Today's LOGGED medication dose events (taken/skipped — reminder
    /// bookkeeping statuses are dropped) as `medication.<status>.<name>`
    /// readings. Unauthorized/denied states surface as thrown query errors
    /// (the provider degrades to `.unavailable`, never crashes); granted with
    /// nothing logged returns an EMPTY array, which the provider treats as a
    /// zero-reading success.
    func medicationDosesToday(now: Date) async throws -> [HealthReading] {
        let medications = try await userAnnotatedMedications()
        var nameByConcept: [String: String] = [:]
        for annotated in medications {
            let name = annotated.nickname ?? annotated.medication.displayText
            nameByConcept[annotated.medication.identifier.description] = name
        }

        let start = Calendar.current.startOfDay(for: now)
        let events: [HKMedicationDoseEvent] = try await withCheckedThrowingContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(withStart: start, end: now)
            let query = HKSampleQuery(sampleType: HKObjectType.medicationDoseEventType(),
                                      predicate: predicate,
                                      limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, error in
                if let error { continuation.resume(throwing: error); return }
                continuation.resume(returning: (samples ?? []).compactMap { $0 as? HKMedicationDoseEvent })
            }
            store.execute(query)
        }

        return events.compactMap { event -> HealthReading? in
            let status: String
            switch event.logStatus {
            case .taken: status = "taken"
            case .skipped: status = "skipped"
            default: return nil
            }
            let name = nameByConcept[event.medicationConceptIdentifier.description] ?? "Medication"
            return HealthReading(
                type: MedicationReading.type(status: status, name: name),
                value: event.doseQuantity ?? 1,
                unit: event.unit.unitString,
                startDate: event.startDate, endDate: event.endDate
            )
        }
    }

    /// The Activity Ring summary for `now`'s calendar day as six numeric
    /// readings (move/exercise/stand actual + goal). Throws when no summary
    /// exists (e.g. no Apple Watch) — the provider surfaces that as
    /// `unavailable`, not a failure.
    func activityRings(now: Date, calendar: Calendar = .current) async throws -> [HealthReading] {
        var components = calendar.dateComponents([.era, .year, .month, .day], from: now)
        components.calendar = calendar
        let predicate = HKQuery.predicateForActivitySummary(with: components)
        let summary: HKActivitySummary? = try await withCheckedThrowingContinuation { continuation in
            let query = HKActivitySummaryQuery(predicate: predicate) { _, summaries, error in
                if let error {
                    // Same errorNoData semantics as sum(): no summary for the
                    // day is "unavailable", not an error to propagate.
                    if (error as? HKError)?.code == .errorNoData {
                        continuation.resume(returning: nil)
                    } else {
                        continuation.resume(throwing: error)
                    }
                    return
                }
                continuation.resume(returning: summaries?.first)
            }
            store.execute(query)
        }
        guard let summary else { throw ProviderError("no activity summary for today") }

        let kcal = HKUnit.kilocalorie()
        let minute = HKUnit.minute()
        let count = HKUnit.count()
        let start = calendar.startOfDay(for: now)
        func reading(_ type: String, _ value: Double, _ unit: String) -> HealthReading {
            HealthReading(type: type, value: value, unit: unit, startDate: start, endDate: now)
        }
        return [
            reading("activity.move", summary.activeEnergyBurned.doubleValue(for: kcal), "kcal"),
            reading("activity.moveGoal", summary.activeEnergyBurnedGoal.doubleValue(for: kcal), "kcal"),
            reading("activity.exercise", summary.appleExerciseTime.doubleValue(for: minute), "min"),
            reading("activity.exerciseGoal", summary.appleExerciseTimeGoal.doubleValue(for: minute), "min"),
            reading("activity.stand", summary.appleStandHours.doubleValue(for: count), "hours"),
            reading("activity.standGoal", summary.appleStandHoursGoal.doubleValue(for: count), "hours"),
        ]
    }

    /// Re-fetches the workout that fired a workout-end trigger and maps it to
    /// the `workout.trigger.*` readings (plan 12 amendment). Returns [] when
    /// the workout can't be re-fetched (deleted, permissions) — the report
    /// degrades to the plain workoutEnd trigger.
    func triggeredWorkoutReadings(workoutID: String) async -> [HealthReading] {
        guard let uuid = UUID(uuidString: workoutID) else { return [] }
        let workout: HKWorkout? = await withCheckedContinuation { continuation in
            let predicate = HKQuery.predicateForObject(with: uuid)
            let query = HKSampleQuery(sampleType: .workoutType(), predicate: predicate, limit: 1,
                                      sortDescriptors: nil) { _, samples, _ in
                continuation.resume(returning: samples?.first as? HKWorkout)
            }
            store.execute(query)
        }
        guard let workout else { return [] }

        func reading(_ type: String, _ value: Double, _ unit: String) -> HealthReading {
            HealthReading(type: type, value: value, unit: unit,
                          startDate: workout.startDate, endDate: workout.endDate)
        }
        var readings = [
            reading(TriggeredWorkoutSummary.typeReading,
                    Double(workout.workoutActivityType.rawValue), "raw"),
            reading(TriggeredWorkoutSummary.durationReading, workout.duration, "s"),
        ]
        if let energy = workout.statistics(for: HKQuantityType(.activeEnergyBurned))?
            .sumQuantity()?.doubleValue(for: .kilocalorie()) {
            readings.append(reading(TriggeredWorkoutSummary.energyReading, energy, "kcal"))
        }
        let distanceTypes: [HKQuantityTypeIdentifier] = [
            .distanceWalkingRunning, .distanceCycling, .distanceSwimming, .distanceWheelchair,
        ]
        for identifier in distanceTypes {
            if let meters = workout.statistics(for: HKQuantityType(identifier))?
                .sumQuantity()?.doubleValue(for: .meter()) {
                readings.append(reading(TriggeredWorkoutSummary.distanceReading, meters, "m"))
                break
            }
        }
        if let bpm = workout.statistics(for: HKQuantityType(.heartRate))?
            .averageQuantity()?.doubleValue(for: .count().unitDivided(by: .minute())) {
            readings.append(reading(TriggeredWorkoutSummary.avgHeartRateReading, bpm, "bpm"))
        }
        return readings
    }

    func workoutsToday(now: Date) async throws -> [HealthReading] {
        let start = Calendar.current.startOfDay(for: now)
        return try await withCheckedThrowingContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(withStart: start, end: now)
            let query = HKSampleQuery(sampleType: .workoutType(), predicate: predicate,
                                      limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, error in
                if let error { continuation.resume(throwing: error); return }
                let readings = (samples ?? []).compactMap { sample -> HealthReading? in
                    guard let workout = sample as? HKWorkout else { return nil }
                    return HealthReading(type: "workout.\(workout.workoutActivityType.rawValue)",
                                         value: workout.duration, unit: "s",
                                         startDate: workout.startDate, endDate: workout.endDate)
                }
                continuation.resume(returning: readings)
            }
            store.execute(query)
        }
    }
}

/// One SensorProvider per health metric so each is independently
/// toggleable and independently timeout-raced.
struct HealthMetricProvider: SensorProvider {
    let kind: SensorKind
    let reader: HealthKitReader
    let since: Date?

    func capture() async throws -> SensorPayload {
        try await reader.authorize()
        let now = Date()
        let window = since ?? Calendar.current.startOfDay(for: now)
        switch kind {
        case .healthSteps:
            let steps = try await reader.sum(.stepCount, unit: .count(), since: window)
            return .health([HealthReading(type: "steps", value: steps, unit: "count",
                                          startDate: window, endDate: now)])
        case .healthFlights:
            let flights = try await reader.sum(.flightsClimbed, unit: .count(), since: window)
            var readings = [HealthReading(type: "flightsClimbed", value: flights, unit: "count",
                                          startDate: window, endDate: now)]
            // Descended comes from CMPedometer (HealthKit has no descended
            // metric) over the SAME window; nil (no hardware, Motion denied,
            // query error) degrades to climbed-only with unchanged display.
            // Phone-only (plan 19 design §v1-scope-3): the flights-down
            // pairing is deferred on watch and PedometerReader stays
            // app-side — watch reports carry climbed-only, rendered as
            // "not captured on Apple Watch" via provenance, not a failure.
            #if !os(watchOS)
            if let descended = await PedometerReader.floorsDescended(from: window, to: now) {
                readings.append(HealthReading(type: "flightsDescended", value: descended,
                                              unit: "count", startDate: window, endDate: now))
            }
            #endif
            return .health(readings)
        case .healthHeart:
            var readings: [HealthReading] = []
            let bpm = HKUnit.count().unitDivided(by: .minute())
            // avg and latest are independent reads: fetch both even if one
            // fails/has-no-data, so a no-data average doesn't destroy an
            // otherwise-valid latest reading (and vice versa).
            let avg = try? await reader.average(.heartRate, unit: bpm, since: window)
            let latest = try? await reader.latest(.heartRate, unit: bpm)
            if let avg = avg ?? nil {
                readings.append(HealthReading(type: "heartRateAvg", value: avg, unit: "bpm",
                                              startDate: window, endDate: now))
            }
            if let latest = latest ?? nil {
                readings.append(HealthReading(type: "heartRateLatest", value: latest.value, unit: "bpm",
                                              endDate: latest.date))
            }
            guard !readings.isEmpty else { throw ProviderError("no heart rate samples") }
            return .health(readings)
        case .healthHeartRange:
            // Change-since-last-report window (plan 43, issue #48). Degrades
            // to absent — never a fake zero — when there's no previous report
            // (nil since) or no samples landed in the window. Windows over
            // 24h are clamped by CaptureWindow; the readings' startDate
            // carries the CLAMPED start so display never overstates coverage.
            guard let captureWindow = CaptureWindow.compute(anchor: since, now: now) else {
                throw ProviderError("no previous report to measure from")
            }
            let bpm = HKUnit.count().unitDivided(by: .minute())
            var readings: [HealthReading] = []
            func windowReading(_ type: String, _ value: Double) -> HealthReading {
                HealthReading(type: type, value: value, unit: "bpm",
                              startDate: captureWindow.start, endDate: captureWindow.end)
            }
            // The three queries are independent reads (the healthHeart
            // precedent): a no-data min/max must not destroy valid
            // boundary samples, and vice versa.
            if let extremes = try? await reader.minMax(.heartRate, unit: bpm,
                                                       from: captureWindow.start,
                                                       to: captureWindow.end) ?? nil {
                readings.append(windowReading(HeartRateWindowFormatter.minType, extremes.min))
                readings.append(windowReading(HeartRateWindowFormatter.maxType, extremes.max))
            }
            if let first = try? await reader.boundarySample(.heartRate, unit: bpm,
                                                            from: captureWindow.start,
                                                            to: captureWindow.end,
                                                            newest: false) ?? nil {
                readings.append(HealthReading(type: HeartRateWindowFormatter.startType,
                                              value: first.value, unit: "bpm",
                                              startDate: captureWindow.start, endDate: first.date))
            }
            if let last = try? await reader.boundarySample(.heartRate, unit: bpm,
                                                           from: captureWindow.start,
                                                           to: captureWindow.end,
                                                           newest: true) ?? nil {
                readings.append(HealthReading(type: HeartRateWindowFormatter.endType,
                                              value: last.value, unit: "bpm",
                                              startDate: captureWindow.start, endDate: last.date))
            }
            guard !readings.isEmpty else {
                throw ProviderError("no heart rate samples since the last report")
            }
            return .health(readings)
        case .healthHRV:
            guard let latest = try await reader.latest(.heartRateVariabilitySDNN, unit: .secondUnit(with: .milli)) else {
                throw ProviderError("no HRV samples")
            }
            return .health([HealthReading(type: "hrvSDNN", value: latest.value, unit: "ms", endDate: latest.date)])
        case .healthRestingHeart:
            guard let latest = try await reader.latest(.restingHeartRate,
                                                       unit: .count().unitDivided(by: .minute())) else {
                throw ProviderError("no resting heart rate samples")
            }
            return .health([HealthReading(type: "restingHeartRate", value: latest.value, unit: "bpm",
                                          endDate: latest.date)])
        case .healthCaffeine:
            let mg = try await reader.sum(.dietaryCaffeine, unit: .gramUnit(with: .milli),
                                          since: Calendar.current.startOfDay(for: now))
            return .health([HealthReading(type: "caffeine", value: mg, unit: "mg", endDate: now)])
        case .healthSleep:
            let stages = try await reader.sleepSeconds(sinceYesterdayEvening: now)
            guard !stages.isEmpty else { throw ProviderError("no sleep samples") }
            return .health(stages.map { HealthReading(type: $0.key, value: $0.value, unit: "s") }
                .sorted { $0.type < $1.type })
        case .healthWorkouts:
            let workouts = try await reader.workoutsToday(now: now)
            return .health(workouts)
        case .healthActivityRings:
            let rings = try await reader.activityRings(now: now)
            return .health(rings)
        case .healthMedications:
            // Authorization happened (if ever) via the dedicated per-object
            // call in the permission cascade — NEVER via the bulk read set
            // above (crash history; see readTypes). Denial/auth errors
            // degrade to unavailable via thrown query errors, but granted
            // with ZERO doses logged today is SUCCESS with zero readings —
            // the sensor is default-ON, so for every non-medication user an
            // empty day is the normal case, not a detection failure. The
            // checklist and report detail render nothing for an empty
            // success.
            return .health(try await reader.medicationDosesToday(now: now))
        default:
            throw ProviderError("not a health metric: \(kind.rawValue)")
        }
    }
}
