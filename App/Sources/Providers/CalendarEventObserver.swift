import DispatchKit
import EventKit
import Foundation
import Observation
import os
import SwiftData

private let calendarLog = Logger(subsystem: "io.robbie.Dispatch", category: "calendar-event")

/// The scheduler's seam onto EventKit (plan 31): matched event-end candidates
/// within a plan window. `CalendarEventObserver` conforms; tests leave the
/// scheduler's source nil and the replan plans no calendar prompts —
/// `replanNow` never touches EventKit directly.
@MainActor
protocol CalendarEventEndProviding: AnyObject {
    func eventEndCandidates(start: Date, end: Date) -> [CalendarEventCandidate]
}

/// Calendar event-end prompt support (plan 31): authorization, calendar
/// listing for the group editor, the scheduler's candidate fetch, and
/// change-driven replans. Mirrors VisitObserver's lifecycle (launch
/// registration, refresh on group edits and remote-change sync, test-gated) —
/// with one honest divergence, forced by the platform: **EventKit never wakes
/// the app**, so unlike the visit/workout observers this one never posts a
/// prompt itself. Calendar prompts are SCHEDULED AHEAD by `replanNow` as
/// ordinary content-addressed `gprompt-` requests at matching events' end
/// dates; this observer only keeps that schedule fresh.
///
/// Platform contracts, verified against Apple's EventKit docs (2026-07-10):
/// - `.EKEventStoreChanged` is posted only "while your app is running"
///   ("Updating with notifications") — nothing relaunches a terminated app,
///   and there is no "event ended" callback at all. Hence schedule-ahead;
///   worst case a prompt fires for a meeting cancelled while Dispatch was
///   suspended — fails quiet, self-corrects at the next foregrounding replan.
/// - Reading events requires FULL access (`requestFullAccessToEvents`);
///   write-only access returns no events and a single virtual calendar, so
///   `.writeOnly` is treated like denied-for-reading throughout.
/// - On iOS 17+ a missing `NSCalendarsFullAccessUsageDescription` makes the
///   system AUTO-DENY the request — the key lives in project.yml.
/// - Per `requestFullAccessToEvents(completion:)`'s reference, an
///   `EKEventStore` created before the grant must be `reset()` after it.
///
/// Authorization is asked lazily and contextually (the plan-16 Always
/// precedent): ONLY from the group editor when the user picks the calendar
/// schedule. Denied/restricted/write-only → the editor and groups list show
/// a "needs calendar access" hint and the group simply doesn't fire.
@MainActor
@Observable
final class CalendarEventObserver: CalendarEventEndProviding {
    @ObservationIgnored private let container: ModelContainer
    @ObservationIgnored private let isTestEnvironment: Bool
    /// Debounced-replan hook, injected by DispatchApp (captures scheduler +
    /// prefs + awakeStore).
    @ObservationIgnored private let replan: () -> Void
    @ObservationIgnored private var store: EKEventStore?
    @ObservationIgnored private var changeObservation: (any NSObjectProtocol)?
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    /// Alive only while a full-access request is in flight.
    @ObservationIgnored private var isRequestingAccess = false

    /// Current calendar authorization, re-read on every refresh() (EventKit
    /// has no authorization-change callback, but refresh runs at launch,
    /// onAppear, and after every request) so the editor hint stays fresh.
    /// Test environments read as full access (no EventKit touched, no hint —
    /// the VisitObserver posture).
    private(set) var authorizationStatus: EKAuthorizationStatus = .notDetermined

    /// Full access is the only status that can READ events; `.writeOnly`
    /// (and the deprecated pre-17 `.authorized`) cannot.
    var hasFullAccess: Bool {
        isTestEnvironment || authorizationStatus == .fullAccess
    }

    init(container: ModelContainer, isTestEnvironment: Bool, replan: @escaping () -> Void) {
        self.container = container
        self.isTestEnvironment = isTestEnvironment
        self.replan = replan
        if !isTestEnvironment {
            authorizationStatus = EKEventStore.authorizationStatus(for: .event)
        }
    }

    /// Subscribes to `.EKEventStoreChanged` when any enabled calendar group
    /// exists AND full access is granted; unsubscribes otherwise. Called at
    /// launch, onAppear, after group edits, and on remote-change sync.
    /// Idempotent. (Subscription only matters while running — see type doc —
    /// so unlike the visit observer there is nothing to arm for relaunch.)
    func refresh() {
        guard !isTestEnvironment else { return }
        authorizationStatus = EKEventStore.authorizationStatus(for: .event)
        if hasEnabledCalendarGroup(), authorizationStatus == .fullAccess {
            subscribe()
        } else {
            unsubscribe()
        }
    }

    /// Editor-contextual full-access request (plan 31): fired ONLY when the
    /// user picks the calendar schedule in the group editor. `.notDetermined`
    /// only — every other status is Settings-only. The continuation is
    /// resumed through OneShotResumeGuard (the cascade/requester house
    /// discipline: EventKit's completion contract is once-only, but this
    /// codebase shipped a double-resume crash once and the guard costs
    /// nothing).
    func requestFullAccess() async {
        guard !isTestEnvironment, authorizationStatus == .notDetermined,
              !isRequestingAccess else { return }
        isRequestingAccess = true
        defer { isRequestingAccess = false }
        let store = ensureStore()
        let resumeGuard = OneShotResumeGuard()
        let granted = await withCheckedContinuation { continuation in
            store.requestFullAccessToEvents { granted, error in
                if let error {
                    calendarLog.error("calendar full-access request failed: \(error, privacy: .public)")
                }
                guard resumeGuard.claim() else { return }
                continuation.resume(returning: granted)
            }
        }
        authorizationStatus = EKEventStore.authorizationStatus(for: .event)
        calendarLog.info("calendar full-access request resolved: granted \(granted, privacy: .public)")
        if granted {
            // Doc-required: this store predates the grant, so reset it before
            // any fetch (requestFullAccessToEvents(completion:) reference).
            store.reset()
        }
        refresh()
        // A grant means calendar groups can enter the plan NOW — replan
        // rather than waiting for the next foregrounding/edit.
        if granted {
            replan()
        }
    }

    /// The user's event calendars for the editor's specific-calendars picker.
    /// Empty in the test environment (no EventKit) and without full access
    /// (write-only sees only a single virtual calendar — useless for rules).
    func eventCalendars() -> [(id: String, title: String)] {
        guard !isTestEnvironment, authorizationStatus == .fullAccess else { return [] }
        return ensureStore().calendars(for: .event)
            .map { (id: $0.calendarIdentifier, title: $0.title) }
            .sorted { ($0.title, $0.id) < ($1.title, $1.id) }
    }

    // MARK: - CalendarEventEndProviding

    /// One fetch serves every calendar group per plan window — per-rule
    /// filtering happens kit-side (`CalendarEventPlanner.fireDates`).
    /// `predicateForEvents` expands recurring events to occurrences, so each
    /// occurrence's end is a candidate (verified: "Retrieving events and
    /// reminders" documents the predicate matching occurrences in range).
    func eventEndCandidates(start: Date, end: Date) -> [CalendarEventCandidate] {
        guard !isTestEnvironment, authorizationStatus == .fullAccess else { return [] }
        let store = ensureStore()
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate).compactMap { event in
            guard let endDate = event.endDate else { return nil }
            return CalendarEventCandidate(
                end: endDate, isAllDay: event.isAllDay,
                calendarID: event.calendar?.calendarIdentifier, title: event.title)
        }
    }

    // MARK: - Change observation

    private func subscribe() {
        guard changeObservation == nil else { return }
        // object: nil — the notification may be posted for any store
        // instance in the process (e.g. after reset()); ours is filtered by
        // the debounced replan being idempotent anyway.
        changeObservation = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: nil, queue: .main
        ) { [weak self] _ in
            // Main queue delivery; hop is a formality for the actor checker.
            Task { @MainActor in self?.storeChanged() }
        }
        calendarLog.info("calendar change observation started")
    }

    private func unsubscribe() {
        guard let changeObservation else { return }
        NotificationCenter.default.removeObserver(changeObservation)
        self.changeObservation = nil
        debounceTask?.cancel()
        debounceTask = nil
        calendarLog.info("calendar change observation stopped")
    }

    /// `.EKEventStoreChanged` → debounced (2s) replan: the note carries no
    /// specifics ("Updating with notifications" — treat all data as stale)
    /// and bursts during sync, so coalesce before recomputing the schedule.
    private func storeChanged() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            calendarLog.info("calendar store changed — replanning")
            self?.replan()
        }
    }

    // MARK: - Groups

    private func hasEnabledCalendarGroup() -> Bool {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<PromptGroup>()
        guard let groups = try? context.fetch(descriptor) else { return false }
        return groups.contains { group in
            guard group.isEnabled else { return false }
            if case .calendarEventEnd = group.schedule { return true }
            return false
        }
    }

    private func ensureStore() -> EKEventStore {
        if let store { return store }
        let store = EKEventStore()
        self.store = store
        return store
    }
}
