import DispatchKit
import Foundation
import HealthKit

/// Shared HealthKit access for all health sensor providers.
final class HealthKitReader: Sendable {
    let store = HKHealthStore()

    // NOTE: medicationDoseEventType is deliberately ABSENT. Including it in a
    // bulk requestAuthorization read set throws an uncatchable ObjC
    // NSInvalidArgumentException on device ("Authorization to read the
    // following types is disallowed") — medications require a separate
    // authorization flow that Dispatch does not implement yet.
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

    func medicationDosesToday(now: Date) async throws -> [HealthReading] {
        let start = Calendar.current.startOfDay(for: now)
        return try await withCheckedThrowingContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(withStart: start, end: now)
            let query = HKSampleQuery(sampleType: HKObjectType.medicationDoseEventType(), predicate: predicate,
                                      limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, error in
                if let error { continuation.resume(throwing: error); return }
                let readings = (samples ?? []).compactMap { sample -> HealthReading? in
                    guard let event = sample as? HKMedicationDoseEvent else { return nil }
                    // Use stable type string; per-medication identification awaits public name API
                    return HealthReading(type: "medicationDose",
                                         value: 1, unit: "dose",
                                         startDate: event.startDate, endDate: event.endDate)
                }
                continuation.resume(returning: readings)
            }
            store.execute(query)
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
            return .health([HealthReading(type: "flightsClimbed", value: flights, unit: "count",
                                          startDate: window, endDate: now)])
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
            // Reading dose events requires an authorization flow beyond the
            // bulk requestAuthorization (which rejects the type outright);
            // disabled until that flow is implemented. medicationDosesToday
            // is kept for that future work.
            throw ProviderError("medications reading not yet supported")
        default:
            throw ProviderError("not a health metric: \(kind.rawValue)")
        }
    }
}
