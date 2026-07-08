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
