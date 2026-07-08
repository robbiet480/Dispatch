import DispatchKit
import Foundation
import HealthKit
import Observation
import os
import SwiftData
import UserNotifications

private let observerLog = Logger(subsystem: "io.robbie.Dispatch", category: "workout-end")

/// Carries a non-Sendable value across an isolation boundary the caller has
/// verified is safe (HealthKit's observer completion handler).
private struct UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
}

/// Fires workout-end group prompts (plan 12): an HKObserverQuery on workout
/// samples plus HealthKit background delivery (entitlement
/// `com.apple.developer.healthkit.background-delivery`, archive-proven).
/// On observer fire, any workout ending after the persisted last-seen end
/// date posts one immediate `gprompt-` notification per enabled workout-end
/// group (while awake). Entirely test-gated: under `--mock-sensors` /
/// `--ui-testing` this never touches HealthKit or notifications.
@MainActor
@Observable
final class WorkoutEndObserver {
    static let lastSeenKey = "workoutEnd.lastSeenEndDate"

    @ObservationIgnored private let container: ModelContainer
    @ObservationIgnored private let awakeStore: AwakeStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let isTestEnvironment: Bool
    @ObservationIgnored private let store = HKHealthStore()
    @ObservationIgnored private var query: HKObserverQuery?

    init(container: ModelContainer, awakeStore: AwakeStore, defaults: UserDefaults,
         isTestEnvironment: Bool) {
        self.container = container
        self.awakeStore = awakeStore
        self.defaults = defaults
        self.isTestEnvironment = isTestEnvironment
    }

    /// Starts the observer when any enabled workout-end group exists, stops
    /// it otherwise. Called at launch and after every group edit/replan.
    func refresh() {
        guard !isTestEnvironment else { return }
        if hasEnabledWorkoutEndGroup() {
            start()
        } else {
            stop()
        }
    }

    private func hasEnabledWorkoutEndGroup() -> Bool {
        !enabledWorkoutEndGroups().isEmpty
    }

    private func enabledWorkoutEndGroups() -> [PromptGroup] {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<PromptGroup>(
            sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.uniqueIdentifier)])
        guard let groups = try? context.fetch(descriptor) else { return [] }
        return groups.filter { $0.isEnabled && $0.schedule == .workoutEnd }
    }

    private func start() {
        guard query == nil, HKHealthStore.isHealthDataAvailable() else { return }

        // First start ever: baseline the last-seen marker to now so
        // pre-existing workouts don't fire a prompt storm.
        if defaults.double(forKey: Self.lastSeenKey) == 0 {
            defaults.set(Date().timeIntervalSince1970, forKey: Self.lastSeenKey)
        }

        let observerQuery = HKObserverQuery(sampleType: .workoutType(), predicate: nil) {
            [weak self] _, completionHandler, error in
            // The completion handler MUST be called on every path — missing
            // it makes HealthKit throttle background delivery. HealthKit's
            // handler type predates Sendable; the box just carries it across
            // to the main actor (calling it from any context is documented
            // as safe).
            let box = UncheckedSendableBox(value: completionHandler)
            Task { @MainActor in
                if let error {
                    observerLog.error("workout observer fired with error: \(error, privacy: .public)")
                } else {
                    await self?.handleObserverFire()
                }
                box.value()
            }
        }
        store.execute(observerQuery)
        query = observerQuery

        store.enableBackgroundDelivery(for: .workoutType(), frequency: .immediate) { enabled, error in
            if let error {
                observerLog.error("background delivery enable failed: \(error, privacy: .public)")
            } else {
                observerLog.info("workout background delivery enabled: \(enabled, privacy: .public)")
            }
        }
    }

    private func stop() {
        guard let query else { return }
        store.stop(query)
        self.query = nil
        store.disableBackgroundDelivery(for: .workoutType()) { _, error in
            if let error {
                observerLog.error("background delivery disable failed: \(error, privacy: .public)")
            }
        }
    }

    private func handleObserverFire() async {
        let lastSeen = Date(timeIntervalSince1970: defaults.double(forKey: Self.lastSeenKey))
        guard let workout = await latestWorkout(endingAfter: lastSeen) else { return }

        // Persist BEFORE posting so a rapid second observer fire can't
        // duplicate the prompts for the same workout.
        defaults.set(workout.endDate.timeIntervalSince1970, forKey: Self.lastSeenKey)

        guard awakeStore.isAwake else {
            observerLog.info("workout ended while asleep — no prompt")
            return
        }

        let groups = enabledWorkoutEndGroups()
        guard !groups.isEmpty else { return }

        let context = ModelContext(container)
        let center = UNUserNotificationCenter.current()
        for group in groups {
            let content = NotificationScheduler.makeGroupContent(
                groupID: group.uniqueIdentifier,
                body: NotificationScheduler.groupBody(for: group, in: context))
            var userInfo = content.userInfo
            userInfo[NotificationIdentifiers.triggeringWorkoutIDKey] = workout.uuid.uuidString
            content.userInfo = userInfo
            let stamp = Self.stampFormatter.string(from: workout.endDate)
            let identifier = "\(NotificationIdentifiers.groupPromptPrefix)\(group.uniqueIdentifier)-\(stamp)"
            // nil trigger ⇒ deliver immediately.
            let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
            do {
                try await center.add(request)
                observerLog.info("posted workout-end prompt \(identifier, privacy: .public)")
            } catch {
                observerLog.error("failed to post workout-end prompt \(identifier, privacy: .public): \(error, privacy: .public)")
            }
        }
    }

    private func latestWorkout(endingAfter lastSeen: Date) async -> HKWorkout? {
        await withCheckedContinuation { continuation in
            let sort = [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]
            let query = HKSampleQuery(sampleType: .workoutType(), predicate: nil, limit: 5,
                                      sortDescriptors: sort) { _, samples, error in
                if let error {
                    observerLog.error("workout fetch failed: \(error, privacy: .public)")
                    continuation.resume(returning: nil)
                    return
                }
                let now = Date()
                let workout = (samples ?? [])
                    .compactMap { $0 as? HKWorkout }
                    .first { $0.endDate > lastSeen && $0.endDate <= now }
                continuation.resume(returning: workout)
            }
            store.execute(query)
        }
    }

    /// Same `yyyyMMdd-HHmm` shape as the scheduler's prompt stamps so the
    /// nag/stamp parsing helpers treat these identifiers uniformly.
    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        return formatter
    }()
}
