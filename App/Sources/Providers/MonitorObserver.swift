import CoreLocation
import DispatchKit
import Foundation
import Observation
import os
import SwiftData
import UserNotifications

private let monitorLog = Logger(subsystem: "io.robbie.Dispatch", category: "monitor-trigger")

/// Place (#56) and beacon (#60) prompt triggers via the modern **`CLMonitor`**
/// API (plan 45). One monitor owns BOTH condition kinds — a
/// `CircularGeographicCondition` for places and a `BeaconIdentityCondition`
/// for beacons — and a single async `events` stream reports each condition's
/// state (`.satisfied` / `.unsatisfied` / `.unknown`) with background wake.
///
/// Why CLMonitor and not region delegates: `CLCircularRegion` /
/// `CLBeaconRegion` and the `CLLocationManagerDelegate` region-monitoring
/// callbacks are DEPRECATED as of iOS 26; `CLMonitor` (iOS 17+) is the
/// supported replacement for both geofences and beacons.
///
/// Delay/cancel: the arrival/departure DECISION and the fire date are pure
/// kit (`MonitorTriggerEngine`, TDD'd); this observer only executes it. On a
/// fire event it schedules an `mprompt-` local notification whose delay is
/// held by the OS (a `UNTimeIntervalNotificationTrigger` survives suspension /
/// termination — an in-process `Task.sleep` would not). On the contradicting
/// event (the app is woken by CLMonitor for it) it removes that pending
/// request. `mprompt-` is a DISTINCT identifier family from `gprompt-` so the
/// replan's remove-before-add batch never wipes a pending delayed prompt.
///
/// Lifecycle mirrors VisitObserver: launch-registered, refreshed on group
/// edits / scene-active / remote-change sync, entirely test-gated (no
/// CoreLocation, no CLMonitor under `--mock-sensors`/`--ui-testing`).
/// Authorization is the SAME editor-contextual Always upgrade plan 16 already
/// ships (no new purpose string, no new entitlement); beacon and geographic
/// conditions both need Always to wake in the background.
///
/// watchOS: iPhone-only (issue #60) — CLMonitor beacon support on watch is
/// limited; the scheduled `mprompt-` forwards to the watch like any prompt.
@MainActor
@Observable
final class MonitorObserver {
    private static let monitorName = "DispatchMonitor"

    @ObservationIgnored private let container: ModelContainer
    @ObservationIgnored private let awakeStore: AwakeStore
    @ObservationIgnored private let focusFilterDefaults: UserDefaults
    @ObservationIgnored private let isTestEnvironment: Bool

    @ObservationIgnored private var monitor: CLMonitor?
    @ObservationIgnored private var eventLoopTask: Task<Void, Never>?
    @ObservationIgnored private var reconcileTask: Task<Void, Never>?
    @ObservationIgnored private var pendingReconcile = false
    /// Condition-payload hash per registered identifier, so an edited region /
    /// beacon (same group ID) is detected and the condition re-registered.
    @ObservationIgnored private var registeredHashes: [String: Int] = [:]

    @ObservationIgnored private var authManager: CLLocationManager?
    @ObservationIgnored private var authProxy: MonitorAuthProxy?
    /// Alive only while an Always upgrade request is in flight (must outlive
    /// the await — CLLocationManager drops a deallocated delegate).
    @ObservationIgnored private var authRequester: AlwaysAuthorizationRequester?

    /// Last-seen state per condition identifier — powers the Beacons settings
    /// "in range?" indicator. Observable so that view updates live.
    private var lastState: [String: MonitorConditionState] = [:]
    /// Enabled monitor groups dropped past the ~20-condition budget, in
    /// sortOrder priority — the editor/list show a "not monitored" hint.
    private(set) var droppedGroupIDs: Set<String> = []

    /// Current location authorization, kept fresh by the auth delegate so the
    /// editor hint updates live. Test environments read authorized (no
    /// CoreLocation touched).
    private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined

    var hasAlwaysAuthorization: Bool {
        isTestEnvironment || authorizationStatus == .authorizedAlways
    }

    init(container: ModelContainer, awakeStore: AwakeStore,
         focusFilterDefaults: UserDefaults, isTestEnvironment: Bool) {
        self.container = container
        self.awakeStore = awakeStore
        self.focusFilterDefaults = focusFilterDefaults
        self.isTestEnvironment = isTestEnvironment
    }

    // MARK: - Lifecycle

    /// Re-registers CLMonitor conditions to match the enabled place/beacon
    /// groups (budget-capped) and sweeps orphaned pending prompts. Called at
    /// launch, onAppear, scene-active, group edits, remote-change sync.
    /// Idempotent; the async reconcile is coalesced.
    func refresh() {
        guard !isTestEnvironment else { return }
        ensureAuthManager()
        scheduleReconcile()
    }

    /// Editor-contextual Always upgrade (the VisitObserver twin): requested
    /// ONLY when the user configures a place/beacon group. `.notDetermined`
    /// runs Apple's provisional-Always flow; `.authorizedWhenInUse` shows the
    /// upgrade prompt (a "Keep Only While Using" tap yields no delegate
    /// callback, documented — the observable status just doesn't change).
    func requestAlwaysAuthorization() async {
        guard !isTestEnvironment else { return }
        ensureAuthManager()
        switch authorizationStatus {
        case .notDetermined:
            let requester = AlwaysAuthorizationRequester()
            authRequester = requester
            authorizationStatus = await requester.request()
            authRequester = nil
            refresh()
        case .authorizedWhenInUse:
            authManager?.requestAlwaysAuthorization()
        default:
            break
        }
    }

    /// Known beacons (from enabled beacon groups) with a live in-range
    /// reading for the Beacons settings surface. `nil` in-range ⇒ not yet
    /// evaluated (or monitoring off).
    func beacons() -> [(id: String, name: String, inRange: Bool?)] {
        enabledMonitorGroups().compactMap { group in
            guard case .beaconTrigger(let trigger) = group.schedule else { return nil }
            let name = trigger.beacon.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            let display = (name?.isEmpty ?? true) ? group.name : name!
            let inRange: Bool? = switch lastState[group.uniqueIdentifier] {
            case .satisfied: true
            case .unsatisfied: false
            default: nil
            }
            return (group.uniqueIdentifier,
                    display.isEmpty ? trigger.beacon.uuid : display,
                    inRange)
        }
    }

    // MARK: - Authorization plumbing

    private func ensureAuthManager() {
        guard authManager == nil else { return }
        let proxy = MonitorAuthProxy { [weak self] status in
            Task { @MainActor in
                self?.authorizationStatus = status
                self?.refresh()
            }
        }
        let manager = CLLocationManager()
        manager.delegate = proxy
        authProxy = proxy
        authManager = manager
        authorizationStatus = manager.authorizationStatus
    }

    // MARK: - Reconcile (coalesced)

    private func scheduleReconcile() {
        guard reconcileTask == nil else { pendingReconcile = true; return }
        reconcileTask = Task { [weak self] in
            await self?.reconcile()
            self?.finishReconcile()
        }
    }

    private func finishReconcile() {
        reconcileTask = nil
        if pendingReconcile {
            pendingReconcile = false
            scheduleReconcile()
        }
    }

    private func reconcile() async {
        let groups = enabledMonitorGroups()
        let allocation = MonitorConditionBudget.allocate(groupIDs: groups.map(\.uniqueIdentifier))
        droppedGroupIDs = Set(allocation.dropped)

        // Sweep pending mprompt- for groups no longer registered (disabled,
        // deleted, or over budget).
        await sweepOrphanPrompts(keeping: Set(allocation.registered))

        guard authorizationStatus == .authorizedAlways else {
            await teardown()
            return
        }

        let monitor = await ensureMonitor()
        let registered = Set(allocation.registered)
        let groupsByID = Dictionary(uniqueKeysWithValues: groups.map { ($0.uniqueIdentifier, $0) })

        // Remove conditions that are no longer desired OR whose payload
        // changed (an edited region/beacon), then (re-)add the current set.
        let existing = Set(await monitor.identifiers)
        for identifier in existing where !registered.contains(identifier)
            || registeredHashes[identifier] != groupsByID[identifier].map(conditionHash) {
            await monitor.remove(identifier)
            registeredHashes[identifier] = nil
        }
        for identifier in registered {
            guard let group = groupsByID[identifier],
                  registeredHashes[identifier] == nil,
                  let condition = condition(for: group) else { continue }
            await monitor.add(condition, identifier: identifier)
            registeredHashes[identifier] = conditionHash(group)
        }

        startEventLoop(on: monitor)
    }

    private func teardown() async {
        guard let monitor else { return }
        for identifier in await monitor.identifiers {
            await monitor.remove(identifier)
        }
        registeredHashes.removeAll()
        // Monitoring is now inactive (e.g. Always was revoked). Drop the cached
        // per-condition states so the Beacons settings surface stops showing a
        // stale "in range / out of range" reading that no longer reflects reality.
        lastState.removeAll()
    }

    private func ensureMonitor() async -> CLMonitor {
        if let monitor { return monitor }
        let monitor = await CLMonitor(Self.monitorName)
        self.monitor = monitor
        return monitor
    }

    // MARK: - Conditions

    private func condition(for group: PromptGroup) -> CLCondition? {
        switch group.schedule {
        case .placeTrigger(let trigger):
            return CLMonitor.CircularGeographicCondition(
                center: CLLocationCoordinate2D(
                    latitude: trigger.region.latitude, longitude: trigger.region.longitude),
                radius: trigger.region.radius)
        case .beaconTrigger(let trigger):
            guard let uuid = UUID(uuidString: trigger.beacon.uuid) else { return nil }
            // major/minor arrive as `Int?` from decoded JSON — a corrupt/hand-
            // edited import could hold an out-of-range value. `CLBeaconMajorValue`
            // / `CLBeaconMinorValue` are UInt16, so the plain `UInt16(x)` init
            // traps on anything outside 0…65535. `exactly:` yields nil instead,
            // and we simply drop that refinement (minor requires major, so a bad
            // major also drops minor) rather than crashing during reconcile.
            let major = trigger.beacon.major.flatMap { CLBeaconMajorValue(exactly: $0) }
            let minor = trigger.beacon.minor.flatMap { CLBeaconMinorValue(exactly: $0) }
            switch (major, minor) {
            case let (major?, minor?):
                return CLMonitor.BeaconIdentityCondition(uuid: uuid, major: major, minor: minor)
            case let (major?, nil):
                return CLMonitor.BeaconIdentityCondition(uuid: uuid, major: major)
            default:
                return CLMonitor.BeaconIdentityCondition(uuid: uuid)
            }
        default:
            return nil
        }
    }

    /// Hash of the CONDITION-defining fields only (region / beacon identity);
    /// direction/delay/cancel don't affect the CLMonitor condition.
    private func conditionHash(_ group: PromptGroup) -> Int {
        var hasher = Hasher()
        switch group.schedule {
        case .placeTrigger(let trigger):
            hasher.combine(trigger.region.latitude)
            hasher.combine(trigger.region.longitude)
            hasher.combine(trigger.region.radius)
        case .beaconTrigger(let trigger):
            hasher.combine(trigger.beacon.uuid)
            hasher.combine(trigger.beacon.major)
            hasher.combine(trigger.beacon.minor)
        default:
            break
        }
        return hasher.finalize()
    }

    // MARK: - Event loop

    private func startEventLoop(on monitor: CLMonitor) {
        guard eventLoopTask == nil else { return }
        eventLoopTask = Task { [weak self] in
            do {
                for try await event in await monitor.events {
                    await self?.handle(event: event)
                }
            } catch {
                monitorLog.error("monitor event stream failed: \(error, privacy: .public)")
            }
            // The stream finished or threw. Clear the handle so the NEXT
            // refresh() (scene-active, group edit, remote-change) restarts the
            // loop — otherwise a transient stream failure would silently stop
            // monitoring until relaunch.
            self?.eventLoopTask = nil
        }
    }

    private func handle(event: CLMonitor.Event) async {
        let identifier = event.identifier
        let state = Self.mapState(event.state)
        lastState[identifier] = state

        guard let group = monitorGroup(withID: identifier),
              let config = MonitorTriggerConfig(group: group) else { return }

        let outcome = MonitorTriggerEngine.outcome(
            direction: config.direction, delayMinutes: config.delayMinutes,
            cancelOnContradiction: config.cancelOnContradiction,
            state: state, eventDate: Date())

        switch outcome {
        case .schedule(let fireDate):
            await schedulePrompt(for: group, config: config, fireDate: fireDate)
        case .cancelPending:
            await cancelPrompt(forGroupID: identifier)
        case .ignore:
            break
        }
    }

    private static func mapState(_ state: CLMonitor.Event.State) -> MonitorConditionState {
        switch state {
        case .satisfied: .satisfied
        case .unsatisfied: .unsatisfied
        case .unknown: .unknown
        @unknown default: .unknown
        }
    }

    // MARK: - Prompt scheduling / cancellation

    private func schedulePrompt(
        for group: PromptGroup, config: MonitorTriggerConfig, fireDate: Date
    ) async {
        guard awakeStore.isAwake else {
            monitorLog.info("monitor fire while asleep — no prompt")
            return
        }
        // Focus filter (plan 15): a muted group doesn't fire.
        let focusFilter = FocusFilterState.read(from: focusFilterDefaults)
        guard focusFilter?.allows(groupID: group.uniqueIdentifier) ?? true else {
            monitorLog.info("monitor fire for focus-muted group — skipped")
            return
        }
        let context = ModelContext(container)
        let request = NotificationScheduler.makeMonitorPromptRequest(
            group: group, in: context, fireDate: fireDate,
            extraUserInfo: [config.markerKey: "1"])
        do {
            try await UNUserNotificationCenter.current().add(request)
            monitorLog.info("scheduled monitor prompt \(request.identifier, privacy: .public)")
        } catch {
            monitorLog.error("failed to schedule monitor prompt: \(error, privacy: .public)")
        }
    }

    private func cancelPrompt(forGroupID groupID: String) async {
        let prefix = NotificationScheduler.monitorPromptIdentifierPrefix(forGroupID: groupID)
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let identifiers = pending.map(\.identifier).filter { $0.hasPrefix(prefix) }
        guard !identifiers.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        monitorLog.info("cancelled \(identifiers.count) pending monitor prompt(s) for group")
    }

    /// Removes pending `mprompt-` requests for groups NOT in `keeping` — a
    /// group disabled/deleted/over-budget must not still fire its delayed
    /// prompt.
    private func sweepOrphanPrompts(keeping: Set<String>) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let orphans = pending.map(\.identifier).filter { identifier in
            guard identifier.hasPrefix(NotificationIdentifiers.monitorPromptPrefix) else { return false }
            let stamp = identifier.dropFirst(NotificationIdentifiers.monitorPromptPrefix.count)
            let segments = stamp.split(separator: "-")
            guard segments.count > 2 else { return false }
            let groupID = segments.dropLast(2).joined(separator: "-")
            return !keeping.contains(groupID)
        }
        guard !orphans.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: orphans)
        monitorLog.info("swept \(orphans.count) orphaned monitor prompt(s)")
    }

    // MARK: - Groups

    private func enabledMonitorGroups() -> [PromptGroup] {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<PromptGroup>(
            sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.uniqueIdentifier)])
        guard let groups = try? context.fetch(descriptor) else { return [] }
        return groups.filter { group in
            guard group.isEnabled else { return false }
            switch group.schedule {
            case .placeTrigger, .beaconTrigger: return true
            default: return false
            }
        }
    }

    private func monitorGroup(withID id: String) -> PromptGroup? {
        let context = ModelContext(container)
        var descriptor = FetchDescriptor<PromptGroup>(
            predicate: #Predicate { $0.uniqueIdentifier == id })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }
}

/// The shared direction/delay/cancel knobs of a place or beacon group plus the
/// userInfo marker key that maps its tap-through report to the right
/// `ReportTrigger`. Resolved from `PromptGroup.schedule`; nil for non-monitor
/// (or `.disabled`) groups.
private struct MonitorTriggerConfig {
    let direction: MonitorDirection
    let delayMinutes: Int
    let cancelOnContradiction: Bool
    let markerKey: String

    init?(group: PromptGroup) {
        switch group.schedule {
        case .placeTrigger(let trigger):
            direction = trigger.direction
            delayMinutes = trigger.delayMinutes
            cancelOnContradiction = trigger.cancelOnContradiction
            markerKey = trigger.direction == .arrival
                ? NotificationIdentifiers.placeArrivalKey
                : NotificationIdentifiers.placeDepartureKey
        case .beaconTrigger(let trigger):
            direction = trigger.direction
            delayMinutes = trigger.delayMinutes
            cancelOnContradiction = trigger.cancelOnContradiction
            markerKey = trigger.direction == .arrival
                ? NotificationIdentifiers.beaconArrivalKey
                : NotificationIdentifiers.beaconDepartureKey
        default:
            return nil
        }
    }
}

/// Tracks location-authorization changes so the editor hint updates live
/// (the VisitDelegateProxy twin, auth-only — CLMonitor delivers its own
/// events through the async stream, not this delegate).
private final class MonitorAuthProxy: NSObject, CLLocationManagerDelegate {
    private let onChange: (CLAuthorizationStatus) -> Void

    init(onChange: @escaping (CLAuthorizationStatus) -> Void) {
        self.onChange = onChange
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        onChange(manager.authorizationStatus)
    }
}
