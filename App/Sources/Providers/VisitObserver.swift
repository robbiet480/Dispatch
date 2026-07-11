import CoreLocation
import DispatchKit
import Foundation
import Observation
import os
import SwiftData
import UserNotifications

private let visitLog = Logger(subsystem: "io.robbie.Dispatch", category: "visit-arrival")

/// Fires visit-arrival group prompts (plan 16): classic
/// `CLLocationManager.startMonitoringVisits()` monitoring, mirroring
/// WorkoutEndObserver's lifecycle (registered at launch, refreshed on group
/// edits and remote-change sync, last-handled dedupe, entirely test-gated).
///
/// Background modes: NONE required, verified against current Apple docs
/// (2026-07-09). The `startMonitoringVisits()` reference states "If your app
/// is terminated while this service is active, the system relaunches your
/// app when new visit events are ready to be delivered. Upon relaunch,
/// recreate your location manager object and assign a delegate to begin
/// receiving visit events." — relaunch delivery is intrinsic to the service,
/// with no UIBackgroundModes precondition mentioned. Apple's "Handling
/// location updates in the background" article ties the `location`
/// background-mode capability to CONTINUOUS live updates
/// (CLBackgroundActivitySession / the standard service), not visits; and
/// "Getting the current location of a device" describes Visits as the
/// deferred, most power-efficient service. Hence no UIBackgroundModes entry
/// is added (hard plan-16 constraint: no entitlement/profile churn — and per
/// the docs none is needed). Launch-time registration below is what the
/// relaunch contract requires.
///
/// Authorization: visits need Always to be delivered in the background. The
/// Always upgrade is requested lazily and contextually — only from the group
/// editor when the user picks the visit-arrival schedule (never onboarding).
/// Without Always the observer simply doesn't monitor and the editor/list
/// show a "needs Always location" hint.
@MainActor
@Observable
final class VisitObserver {
    static let lastHandledKey = "visitArrival.lastHandledArrivalDate"

    @ObservationIgnored private let container: ModelContainer
    @ObservationIgnored private let awakeStore: AwakeStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let focusFilterDefaults: UserDefaults
    @ObservationIgnored private let isTestEnvironment: Bool
    @ObservationIgnored private var manager: CLLocationManager?
    @ObservationIgnored private var delegateProxy: VisitDelegateProxy?
    @ObservationIgnored private var isMonitoring = false
    /// Alive only while an Always upgrade request is in flight (it must
    /// outlive the await — CLLocationManager drops a deallocated delegate).
    @ObservationIgnored private var authRequester: AlwaysAuthorizationRequester?

    /// Current location authorization, kept fresh by the delegate callback so
    /// the editor hint updates live when the user grants/denies. Test
    /// environments read as authorized (no CoreLocation touched, no hint —
    /// the UI tests exercise the editor flow, not the system dialog).
    private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined

    var hasAlwaysAuthorization: Bool {
        isTestEnvironment || authorizationStatus == .authorizedAlways
    }

    init(container: ModelContainer, awakeStore: AwakeStore, defaults: UserDefaults,
         focusFilterDefaults: UserDefaults, isTestEnvironment: Bool) {
        self.container = container
        self.awakeStore = awakeStore
        self.defaults = defaults
        self.focusFilterDefaults = focusFilterDefaults
        self.isTestEnvironment = isTestEnvironment
    }

    /// Starts visit monitoring when any enabled visit-arrival group exists
    /// AND Always authorization is granted; stops it otherwise. Called at
    /// launch (the relaunch contract — see the type doc), after every group
    /// edit, and on remote-change sync. Idempotent.
    func refresh() {
        guard !isTestEnvironment else { return }
        ensureManager()
        if hasEnabledVisitGroup(), authorizationStatus == .authorizedAlways {
            start()
        } else {
            stop()
        }
    }

    /// Editor-contextual Always upgrade (plan 16): requested ONLY when the
    /// user configures a visit-arrival group. From `.notDetermined` the
    /// system runs the provisional-Always two-prompt flow and the delegate
    /// reports the outcome; from `.authorizedWhenInUse` the upgrade prompt
    /// shows but "Keep Only While Using" produces NO delegate callback
    /// (documented), so this fires the request and returns — the observable
    /// `authorizationStatus` updates via the delegate if the user upgrades.
    func requestAlwaysAuthorization() async {
        guard !isTestEnvironment else { return }
        ensureManager()
        switch authorizationStatus {
        case .notDetermined:
            let requester = AlwaysAuthorizationRequester()
            authRequester = requester
            authorizationStatus = await requester.request()
            authRequester = nil
            refresh()
        case .authorizedWhenInUse:
            manager?.requestAlwaysAuthorization()
        default:
            break // Already Always, or denied/restricted (Settings-only).
        }
    }

    // MARK: - Monitoring

    private func ensureManager() {
        guard manager == nil else { return }
        let proxy = VisitDelegateProxy { [weak self] event in
            Task { @MainActor in
                switch event {
                case .authorizationChanged(let status):
                    self?.authorizationChanged(to: status)
                case .visit(let visit):
                    await self?.handleVisit(visit)
                }
            }
        }
        let manager = CLLocationManager()
        manager.delegate = proxy
        delegateProxy = proxy
        self.manager = manager
        authorizationStatus = manager.authorizationStatus
    }

    private func authorizationChanged(to status: CLAuthorizationStatus) {
        authorizationStatus = status
        // Granting Always from the editor (or Settings) must arm monitoring
        // without a relaunch; a revoke must disarm it.
        refresh()
    }

    private func start() {
        guard let manager, !isMonitoring else { return }
        // First start ever: baseline the last-handled marker to now so a
        // visit already in progress when the feature is enabled doesn't
        // fire a prompt storm (same pattern as WorkoutEndObserver).
        if defaults.double(forKey: Self.lastHandledKey) == 0 {
            defaults.set(Date().timeIntervalSince1970, forKey: Self.lastHandledKey)
        }
        manager.startMonitoringVisits()
        isMonitoring = true
        visitLog.info("visit monitoring started")
    }

    private func stop() {
        guard let manager, isMonitoring else { return }
        manager.stopMonitoringVisits()
        isMonitoring = false
        visitLog.info("visit monitoring stopped")
    }

    private func hasEnabledVisitGroup() -> Bool {
        !enabledVisitGroups().isEmpty
    }

    private func enabledVisitGroups() -> [PromptGroup] {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<PromptGroup>(
            sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.uniqueIdentifier)])
        guard let groups = try? context.fetch(descriptor) else { return [] }
        return groups.filter { $0.isEnabled && $0.schedule == .visitArrival }
    }

    // MARK: - Visit handling

    private func handleVisit(_ visit: CLVisit) async {
        // Arrival events carry distantFuture as the (not yet known)
        // departure; departure events are not this feature.
        guard visit.departureDate == .distantFuture else {
            visitLog.info("visit departure event — ignored")
            return
        }
        // An arrival of distantPast means the system couldn't date the
        // arrival (visit already in progress when monitoring began) — stale
        // by definition, skip rather than prompt for old presence.
        let arrival = visit.arrivalDate
        guard arrival != .distantPast else {
            visitLog.info("visit arrival with unknown date — skipped as stale")
            return
        }
        // KNOWN BIAS (accepted, build-13 review minor): the system can
        // deliver several queued visits in one burst (e.g. relaunch after
        // termination), not necessarily in arrival order. This monotonic
        // last-handled guard keeps only the visits it sees with ascending
        // arrival dates — once a newer arrival is handled, any older visit
        // delivered later in the burst is dropped. That's the intended
        // trade: the prompt asks about where the user is NOW, so the newest
        // arrival is the only one worth prompting for, and the guard doubles
        // as the duplicate-delivery defense. A full ledger of handled visit
        // dates would prompt for stale arrivals, which is worse.
        let lastHandled = Date(timeIntervalSince1970: defaults.double(forKey: Self.lastHandledKey))
        guard arrival > lastHandled else {
            visitLog.info("visit arrival \(arrival, privacy: .public) at/before last-handled — skipped")
            return
        }
        // Persist BEFORE posting so a duplicate delivery of the same visit
        // can't double-post (the content-addressed identifier is the second
        // line of defense).
        defaults.set(arrival.timeIntervalSince1970, forKey: Self.lastHandledKey)

        guard awakeStore.isAwake else {
            visitLog.info("visit arrival while asleep — no prompt")
            return
        }

        // Focus filter (plan 15): a muted visit group doesn't fire. Same
        // presence-is-activity read the scheduler uses; the scheduler's
        // liveness gate only affects timer replans — for a stale blob the
        // next replan clears it, and skipping one arrival under a stale
        // filter fails quiet, never loud.
        let focusFilter = FocusFilterState.read(from: focusFilterDefaults)
        let groups = enabledVisitGroups().filter {
            focusFilter?.allows(groupID: $0.uniqueIdentifier) ?? true
        }
        guard !groups.isEmpty else {
            visitLog.info("visit arrival with no firing groups (none enabled or all focus-muted)")
            return
        }

        let context = ModelContext(container)
        let center = UNUserNotificationCenter.current()
        visitLog.info("handling visit arrival \(arrival, privacy: .public)")
        for group in groups {
            let request = NotificationScheduler.makeImmediateGroupPromptRequest(
                group: group, in: context, eventDate: arrival,
                extraUserInfo: [NotificationIdentifiers.visitArrivalKey: "1"])
            do {
                try await center.add(request)
                visitLog.info("posted visit-arrival prompt \(request.identifier, privacy: .public)")
            } catch {
                visitLog.error("failed to post visit-arrival prompt \(request.identifier, privacy: .public): \(error, privacy: .public)")
            }
        }
    }
}

// MARK: - Delegate plumbing

/// CLLocationManagerDelegate is an NSObject protocol; this tiny proxy keeps
/// VisitObserver a plain @Observable class and funnels the (main-run-loop)
/// callbacks into a single event closure.
private final class VisitDelegateProxy: NSObject, CLLocationManagerDelegate {
    enum Event {
        case authorizationChanged(CLAuthorizationStatus)
        case visit(CLVisit)
    }

    private let onEvent: (Event) -> Void

    init(onEvent: @escaping (Event) -> Void) {
        self.onEvent = onEvent
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        onEvent(.authorizationChanged(manager.authorizationStatus))
    }

    func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        onEvent(.visit(visit))
    }
}

/// One-shot Always authorization request from `.notDetermined`, on its own
/// CLLocationManager + delegate. `locationManagerDidChangeAuthorization`
/// fires both at delegate assignment AND on the user's decision (and has
/// double-fired on OS betas before — the build-8 crash) — so the
/// continuation is resumed through the shared OneShotResumeGuard, never
/// directly.
/// Shared by VisitObserver and MonitorObserver (plan 45) — both request the
/// Always upgrade the same way.
final class AlwaysAuthorizationRequester: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
    private let manager = CLLocationManager()
    private let resumeGuard = OneShotResumeGuard()
    private let state = OSAllocatedUnfairLock<CheckedContinuation<CLAuthorizationStatus, Never>?>(initialState: nil)

    func request() async -> CLAuthorizationStatus {
        await withCheckedContinuation { continuation in
            state.withLock { $0 = continuation }
            manager.delegate = self
            // From notDetermined this runs Apple's two-prompt provisional
            // Always flow; the first user decision arrives via the delegate.
            manager.requestAlwaysAuthorization()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        // The delegate-assignment callback reports the still-undetermined
        // status; the user hasn't decided yet — keep waiting.
        guard status != .notDetermined else { return }
        guard resumeGuard.claim() else { return }
        let continuation = state.withLock { s -> CheckedContinuation<CLAuthorizationStatus, Never>? in
            let c = s
            s = nil
            return c
        }
        continuation?.resume(returning: status)
    }
}
