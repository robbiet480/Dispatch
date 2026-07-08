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
    /// Serializes handleObserverFire: it reads the last-seen marker and then
    /// SUSPENDS at the workout fetch, so a second observer fire interleaving
    /// on the main actor would read the same stale marker and double-post
    /// delivered banners. While set, subsequent fires are skipped (their
    /// completion handlers still run in start()'s wrapper).
    @ObservationIgnored private var isHandlingFire = false

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
        guard !isHandlingFire else {
            observerLog.info("workout observer fire skipped — a fire is already being handled")
            return
        }
        isHandlingFire = true
        defer { isHandlingFire = false }

        let lastSeen = Date(timeIntervalSince1970: defaults.double(forKey: Self.lastSeenKey))
        // ALL workouts past the marker, oldest first — a single fire can
        // cover several workouts (e.g. batched background delivery), and
        // handling only the newest would silently swallow the others.
        let workouts = await workouts(endingAfter: lastSeen)
        guard let newestEndDate = workouts.last?.endDate else { return }

        // Persist BEFORE posting so a rapid second observer fire can't
        // duplicate the prompts for the same workouts.
        defaults.set(newestEndDate.timeIntervalSince1970, forKey: Self.lastSeenKey)

        guard awakeStore.isAwake else {
            observerLog.info("\(workouts.count, privacy: .public) workout(s) ended while asleep — no prompt")
            return
        }

        let groups = enabledWorkoutEndGroups()
        guard !groups.isEmpty else { return }

        let context = ModelContext(container)
        let center = UNUserNotificationCenter.current()
        for workout in workouts {
            observerLog.info("handling workout \(workout.uuid, privacy: .public) ended \(workout.endDate, privacy: .public)")
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
    }

    /// The (up to 5) most recent workouts ending after `lastSeen`, oldest
    /// first so prompts post in workout order.
    private func workouts(endingAfter lastSeen: Date) async -> [HKWorkout] {
        await withCheckedContinuation { continuation in
            let sort = [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]
            let query = HKSampleQuery(sampleType: .workoutType(), predicate: nil, limit: 5,
                                      sortDescriptors: sort) { _, samples, error in
                if let error {
                    observerLog.error("workout fetch failed: \(error, privacy: .public)")
                    continuation.resume(returning: [])
                    return
                }
                let now = Date()
                let workouts = (samples ?? [])
                    .compactMap { $0 as? HKWorkout }
                    .filter { $0.endDate > lastSeen && $0.endDate <= now }
                    .sorted { $0.endDate < $1.endDate }
                continuation.resume(returning: workouts)
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
