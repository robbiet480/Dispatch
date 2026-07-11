import DispatchKit
import Foundation
import Intents
import Observation
import os
import SwiftData
import UserNotifications

private let notificationLog = Logger(subsystem: "io.robbie.Dispatch", category: "notifications")

// NotificationIdentifiers (category/action identifiers and pending-request
// prefixes) moved to DispatchKit — Sources/DispatchKit/Prompting/
// NotificationIdentifiers.swift — alongside the kit-tested
// `promptSource(forIdentifier:)` parser used by the settings hero.

/// Owns UNUserNotificationCenter: permission, request building/re-planning,
/// delegate routing for quick answers/snooze/tap-through, and the
/// pending-survey handoff to the app's SurveyPresenter.
///
/// Quick-answer notification actions file a MINIMAL report directly —
/// `trigger: .notification`, the single answered question, and NO sensor
/// capture. Location/health/photo/weather capture requires async work
/// (permissions, background tasks) that is out of budget for a
/// notification-action handler, which iOS expects to complete quickly.
/// Users who want a full sensor-backed report should tap the notification
/// body instead, which opens the app into a normal survey.
@MainActor
@Observable
final class NotificationScheduler: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    private let container: ModelContainer
    private let prefs: NotificationPrefs
    private let isTestEnvironment: Bool
    /// Last "tails/parents" pair logged at info by the nag-tail budget line —
    /// replans re-run the same idempotent accounting constantly, so repeats
    /// log at debug instead (user-reported spam).
    private var lastLoggedNagTailSignature: String?
    /// Where the Focus filter state lives: the App Group suite in
    /// production (written by DispatchFocusFilter.perform()), the isolated
    /// per-launch test suite under `--ui-testing`/`--mock-sensors` — so real
    /// Focus state can never leak into tests, and a test can inject state
    /// deterministically via the FOCUS_FILTER_STATE launch hook.
    private let focusFilterDefaults: UserDefaults

    /// Guards against re-firing the permission request when the scene is
    /// recreated (e.g. backgrounding/foregrounding rebuilds ContentView,
    /// which would otherwise call `requestPermissionIfNeeded` again).
    private var hasRequestedThisLaunch = false

    /// Plan 39: set by DispatchApp to route a wake signal through
    /// AwakeAutoController when the liveness gate below clears a STALE
    /// sleep-marker filter — the gate can be the first place a missed
    /// deactivation delivery is noticed, and without this the state would
    /// strand asleep until HealthKit's lagged (hours-scale) correction.
    var staleSleepFilterCleared: (() -> Void)?

    /// EventKit seam (plan 31), wired by DispatchApp to CalendarEventObserver.
    /// The scheduler never touches EventKit directly: a nil source (tests,
    /// pre-wiring) simply plans no calendar prompts, so `replanNow` stays
    /// testable exactly as before. Weak — the app owns the observer.
    weak var calendarEventSource: (any CalendarEventEndProviding)?

    init(container: ModelContainer, prefs: NotificationPrefs, isTestEnvironment: Bool,
         focusFilterDefaults: UserDefaults) {
        self.container = container
        self.prefs = prefs
        self.isTestEnvironment = isTestEnvironment
        self.focusFilterDefaults = focusFilterDefaults
        super.init()
    }

    /// The active Dispatch Focus Filter's state, or nil when no filter is
    /// active. Read fresh on every access — the intent's perform() may have
    /// rewritten it from a background launch since the last read.
    ///
    /// Liveness gate: the persisted blob is only trusted while a Focus is
    /// actually on. If the app never received the deactivation perform()
    /// (e.g. it was terminated and the background launch failed), the blob
    /// would otherwise mute the schedule forever. Mirroring FocusProvider's
    /// gate: when Focus status is authorized AND the system says no Focus
    /// is active, the state is stale — clear it (flooring nag parents, see
    /// `focusFilterCleared`) and plan the full schedule. When Focus status
    /// is unauthorized or unavailable there is no signal to check against,
    /// so the blob is trusted as before. Test environments skip the
    /// INFocusStatusCenter check entirely so injected state (the
    /// FOCUS_FILTER_STATE launch hook) stays deterministic.
    var activeFocusFilter: FocusFilterState? {
        guard let state = FocusFilterState.read(from: focusFilterDefaults) else { return nil }
        if !isTestEnvironment,
           INFocusStatusCenter.default.authorizationStatus == .authorized,
           INFocusStatusCenter.default.focusStatus.isFocused == false {
            notificationLog.info("focus filter state (\(state.label, privacy: .public)) is stale — no Focus active; clearing and planning the full schedule")
            // Plan 39: capture the sleep marker BEFORE the clear — the wake
            // signal is derived from the outgoing state, matching the
            // intent path's previous-state read.
            let wasSleepMarker = state.indicatesSleep == true
            FocusFilterState.clear(in: focusFilterDefaults)
            focusFilterCleared()
            if wasSleepMarker {
                staleSleepFilterCleared?()
            }
            return nil
        }
        return state
    }

    /// Called on EVERY Focus-filter state-clear path (the intent's
    /// all-defaults deactivation delivery via DispatchApp's hook, and the
    /// liveness-gate clear above): floors past-parent nag computation by
    /// advancing `lastActedAt` to now when it's older.
    ///
    /// Why: prompts suppressed while the filter was active were never
    /// delivered, but their planned dates are recomputed deterministically
    /// from the day seed — without the floor, the deactivation replan would
    /// treat those phantom parents as delivered-but-unanswered prompts and
    /// resurrect nag chains for notifications the user never saw.
    /// `lastActedAt` is already cross-family by doctrine (one act quiets
    /// both global and group nags), so advancing it here is consistent.
    func focusFilterCleared(now: Date = Date()) {
        guard (prefs.lastActedAt ?? .distantPast) < now else { return }
        prefs.lastActedAt = now
        notificationLog.info("focus filter cleared — floored lastActedAt to now so suppressed prompts can't resurrect nag chains")
    }

    // MARK: - Setup

    /// Registers the DISPATCH_PROMPT category with quick-answer actions
    /// drawn from the first enabled regular-kind Yes/No question (falling
    /// back to generic Yes/No titles if none exists yet) plus "Snooze 15m".
    /// Safe to call repeatedly; UNUserNotificationCenter replaces the
    /// category definition each time.
    func registerCategory() {
        let context = ModelContext(container)
        registerCategory(question: Self.firstEnabledYesNoQuestion(in: context))
    }

    private func registerCategory(question: Question?) {
        let yesTitle = question?.choices.first ?? "Yes"
        let noTitle: String
        if let question, question.choices.count > 1 {
            noTitle = question.choices[1]
        } else {
            noTitle = "No"
        }

        let yesAction = UNNotificationAction(
            identifier: NotificationIdentifiers.answerYesAction,
            title: yesTitle,
            options: []
        )
        let noAction = UNNotificationAction(
            identifier: NotificationIdentifiers.answerNoAction,
            title: noTitle,
            options: []
        )
        let snoozeAction = UNNotificationAction(
            identifier: NotificationIdentifiers.snoozeAction,
            title: "Snooze 15m",
            options: []
        )

        let category = UNNotificationCategory(
            identifier: NotificationIdentifiers.category,
            actions: [yesAction, noAction, snoozeAction],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])
    }

    /// Requests `.alert .sound .badge` permission. Skipped under
    /// `--mock-sensors` / `--ui-testing` so UI tests never hit the system
    /// permission dialog (which blocks the test runner indefinitely).
    /// Guarded by `hasRequestedThisLaunch` so scene recreation (e.g.
    /// background/foreground rebuilding ContentView) doesn't refire the
    /// system prompt. On grant, triggers a replan so prompts scheduled
    /// before permission existed actually get queued.
    func requestPermissionIfNeeded(prefs: NotificationPrefs, awakeStore: AwakeStore) {
        guard !isTestEnvironment else { return }
        guard !hasRequestedThisLaunch else { return }
        hasRequestedThisLaunch = true
        center.requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, error in
            if let error {
                notificationLog.error("notification permission request failed: \(error, privacy: .public)")
            } else {
                notificationLog.info("notification permission granted: \(granted, privacy: .public)")
            }
            guard granted else { return }
            Task { @MainActor in
                await self?.replanNow(prefs: prefs, awakeStore: awakeStore)
            }
        }
    }

    // MARK: - Planning

    /// Re-plans pending DISPATCH_PROMPT requests: clears everything with the
    /// `prompt-` identifier prefix (snoozes are untouched while awake; while
    /// asleep, pending snoozes are also cleared so they can't fire during
    /// quiet hours), does nothing further while asleep, otherwise plans
    /// today's remaining window plus tomorrow's full window and schedules
    /// calendar-trigger requests for every future date.
    ///
    /// Sync wrapper around `replanNow` for call sites that can't await
    /// (scenePhase/onChange handlers, intents, etc). Fire-and-forget is safe
    /// here because `replanNow` sequences remove-before-add internally, so
    /// concurrent callers can't race a stale removal against a fresh add.
    func replan(prefs: NotificationPrefs, awakeStore: AwakeStore, now: Date = Date(), calendar: Calendar = .current) {
        Task { await replanNow(prefs: prefs, awakeStore: awakeStore, now: now, calendar: calendar) }
    }

    /// One-time stamp-format migration replan (plan 17): the en_US_POSIX pin
    /// on `isoMinuteFormatter` changes the content-addressed identifiers, so
    /// the first launch after upgrading must remove-and-reschedule everything
    /// or requests stamped by the old build are orphaned (the replan's
    /// removal is by prefix, which is locale-independent — it catches old
    /// stamps regardless of how their digits were rendered). Guarded by the
    /// kit's `ScheduleStampVersion` defaults marker: fires exactly once per
    /// install, and the marker is only advanced HERE, after the replan is
    /// scheduled. Runs at launch (DispatchApp.init) — foreground `.active`
    /// replans also run, but this guarantees the migration even if a future
    /// refactor changes when those fire.
    func runStampMigrationReplanIfNeeded(defaults: UserDefaults, prefs: NotificationPrefs,
                                         awakeStore: AwakeStore) {
        guard ScheduleStampVersion.needsMigrationReplan(in: defaults) else { return }
        notificationLog.info("stamp format v\(ScheduleStampVersion.current) migration — running one-time full replan")
        Task {
            // Marker advances only AFTER the replan completes: a launch that
            // dies mid-replan retries the migration next launch (replans are
            // idempotent, so a retry after a completed-but-unmarked replan
            // is harmless).
            await replanNow(prefs: prefs, awakeStore: awakeStore)
            ScheduleStampVersion.markMigrated(in: defaults)
            notificationLog.info("stamp format migration replan complete — marker advanced to v\(ScheduleStampVersion.current)")
        }
    }

    /// Async replan: reads pending requests, computes the identifiers to
    /// remove, removes them, and only THEN adds the freshly-planned
    /// requests. This ordering matters — `identifiers` are content-addressed
    /// (`prompt-<yyyyMMdd>-<HHmm>`) and can collide across replans of the
    /// same minute, so removing before adding avoids a race where the
    /// daemon processes an add before a stale remove and the new schedule
    /// gets deleted out from under it.
    func replanNow(prefs: NotificationPrefs, awakeStore: AwakeStore, now: Date = Date(), calendar: Calendar = .current) async {
        // Authorization gate (kit-tested: ReplanAuthorizationGate): while
        // permission is denied or notDetermined every `center.add` below
        // fails with "Source is not authorized" — seven-plus error lines per
        // pass, several passes at first launch (stamp-migration replan,
        // remote-change replans). Skip the whole pass with one debug line;
        // `requestPermissionIfNeeded`'s grant completion replans as soon as
        // permission arrives, so the schedule materializes then. Test
        // environments bypass the gate: UI tests never grant permission (the
        // dialog would block the runner) but still exercise the replan path.
        if !isTestEnvironment {
            let status = await center.notificationSettings().authorizationStatus
            guard ReplanAuthorizationGate.canSchedule(status) else {
                notificationLog.debug("replan skipped: notifications not authorized")
                return
            }
        }

        // Fetch the quick-answer question ONCE per replan and thread it
        // through category registration and every content build below —
        // avoids a full sorted Question fetch per scheduled request.
        let questionContext = ModelContext(container)
        let question = Self.firstEnabledYesNoQuestion(in: questionContext)

        // Re-register the category on every replan (not just at launch) so
        // question renames/reorders can't leave the quick-answer action
        // titles stale or mismatched with the notification body. This only
        // affects requests scheduled/updated after this point — already
        // DELIVERED notifications keep whatever content/actions they were
        // presented with, which is acceptable (the user already saw them).
        registerCategory(question: question)

        // gprompt- removals MUST share this batch with prompt-/nag- (plan 12):
        // a remove issued after the adds below could race the daemon and
        // delete the fresh schedule (this codebase shipped that bug once).
        let pending = await center.pendingNotificationRequests()
        var identifiersToRemove = pending
            .map(\.identifier)
            .filter {
                $0.hasPrefix(NotificationIdentifiers.promptPrefix)
                    || $0.hasPrefix(NotificationIdentifiers.groupPromptPrefix)
                    || $0.hasPrefix(NotificationIdentifiers.nagPrefix)
                    || $0.hasPrefix(NotificationIdentifiers.digestPrefix)
                    || $0.hasPrefix(NotificationIdentifiers.webhookFailedPrefix)
            }

        // Snoozes survive replans while awake — including replans while a
        // Focus filter is active. A snooze is an explicit user request
        // ("remind me in 15 minutes") that outranks the filter, so snoozed
        // prompts keep firing even for groups the filter mutes; only the
        // quiet-hours (asleep) path below removes them.
        if !awakeStore.isAwake {
            let snoozeIdentifiers = pending
                .map(\.identifier)
                .filter { $0.hasPrefix(NotificationIdentifiers.snoozePrefix) }
            identifiersToRemove.append(contentsOf: snoozeIdentifiers)
        }

        center.removePendingNotificationRequests(withIdentifiers: identifiersToRemove)

        // Digest reminders (plan 40) — scheduled ahead of the asleep guard: a
        // digest is a periodic summary, not an awake-window prompt. Removals
        // joined the digest- prefix batch above, so disabled/deleted schedules
        // simply never re-add. Weekly and monthly(day ≤ 28) repeat natively;
        // monthly 29–31 and quarterly are one-shot at the kit-computed next
        // fire, re-armed by every replan (foreground replans run on every app
        // open, so the request refreshes long before it fires).
        var digestRequestCount = 0
        for schedule in prefs.digestSchedules where schedule.isEnabled {
            let trigger: UNNotificationTrigger
            if let matching = schedule.repeatingTriggerComponents {
                trigger = UNCalendarNotificationTrigger(dateMatching: matching, repeats: true)
            } else if let fireDate = schedule.nextFireDate(after: now, calendar: calendar) {
                let components = calendar.dateComponents(
                    [.year, .month, .day, .hour, .minute], from: fireDate)
                trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            } else {
                continue
            }
            let content = UNMutableNotificationContent()
            content.title = Self.digestTitle(for: schedule.cadence.period)
            content.body = Self.digestBody(for: schedule.cadence.period)
            content.sound = .default
            content.userInfo = [NotificationIdentifiers.digestPeriodKey:
                                    schedule.cadence.period.rawValue]
            let request = UNNotificationRequest(
                identifier: "\(NotificationIdentifiers.digestPrefix)\(schedule.id.uuidString)",
                content: content, trigger: trigger)
            do {
                try await center.add(request)
                digestRequestCount += 1
            } catch {
                notificationLog.error("failed to schedule digest \(schedule.id, privacy: .public): \(error, privacy: .public)")
            }
        }

        guard awakeStore.isAwake else {
            // Asleep ⇒ no prompts scheduled: clear the widget's "next prompt"
            // and let it re-render.
            if !isTestEnvironment {
                WidgetRefresher.replanCompleted(nextPromptDate: nil)
            }
            return
        }

        // Focus filter pre-filter (plan 15): while a Dispatch Focus Filter
        // is active, only the allowed groups (and, unless paused, the global
        // schedule) enter the plan. Muted families contribute NOTHING
        // downstream — no prompts, no nag parents, no budget charge — and
        // their pending requests fall out in the single removal batch above.
        // Deactivation (Focus off/switched) clears the state and triggers a
        // replan, restoring the full schedule; past-parent nag resurrection
        // still works because planned dates are recomputed deterministically
        // from the day seed.
        let focusFilter = activeFocusFilter
        if let focusFilter {
            let groupsSummary = focusFilter.allowedGroupIDs.map { "\($0.count) groups allowed" } ?? "all groups allowed"
            notificationLog.info("focus filter active (\(focusFilter.label, privacy: .public)): \(groupsSummary, privacy: .public), global \(focusFilter.allowsGlobal ? "on" : "paused", privacy: .public)")
        }

        let (groups, planGlobal) = FocusFilterState.filterPlan(
            groups: Self.timerScheduledGroups(in: questionContext), state: focusFilter
        )
        let allPlannedDates = planGlobal
            ? plannedDates(prefs: prefs, now: now, calendar: calendar)
            : []
        let dates = allPlannedDates.filter { $0 > now }

        // Timer-scheduled groups (plan 12): planned per awake window with a
        // group-varied seed; event/disabled schedules plan nothing.
        let windows = planWindows(now: now, calendar: calendar)
        let timerPlans: [(group: PromptGroup, all: [Date], future: [Date])] = groups.map { group in
            let all = windows.flatMap { window in
                GroupPlanner.plan(group: group, awakeStart: window.start, awakeEnd: window.end,
                                  seed: window.seed, calendar: calendar)
            }.sorted()
            return (group, all, all.filter { $0 > now })
        }

        // Calendar-event groups (plan 31): SCHEDULED AHEAD — EventKit never
        // wakes the app (no background delivery, no relaunch; see
        // CalendarEventObserver's type doc), so matching events' END dates
        // become ordinary content-addressed gprompt requests within the same
        // plan windows. ONE candidate fetch per window is shared across
        // groups (per-rule matching is kit-pure); `all` is computed with
        // now = .distantPast so past ends feed past-parent nag resurrection
        // exactly like the timer plans' full-window dates.
        let (calendarGroups, _) = FocusFilterState.filterPlan(
            groups: Self.calendarScheduledGroups(in: questionContext), state: focusFilter)
        var calendarPlans: [(group: PromptGroup, all: [Date], future: [Date])] = []
        if let source = calendarEventSource, !calendarGroups.isEmpty {
            let windowCandidates = windows.map {
                source.eventEndCandidates(start: $0.start, end: $0.end)
            }
            calendarPlans = calendarGroups.map { group in
                guard case .calendarEventEnd(let rule) = group.schedule else {
                    return (group, [], [])
                }
                let all = zip(windows, windowCandidates).flatMap { window, candidates in
                    CalendarEventPlanner.fireDates(
                        candidates: candidates, rule: rule, now: .distantPast,
                        windowStart: window.start, windowEnd: window.end)
                }.sorted()
                return (group, all, all.filter { $0 > now })
            }
        }

        // Both event-planned families join the SAME budget allocation below,
        // interleaved in sortOrder so the allocator's in-order clamping
        // stays honest (a busy calendar day is data-driven load — exactly
        // what the allocator exists for).
        let groupPlans = (timerPlans + calendarPlans).sorted {
            ($0.group.sortOrder, $0.group.uniqueIdentifier)
                < ($1.group.sortOrder, $1.group.uniqueIdentifier)
        }

        // Past parents (delivered-but-unanswered prompts, both families)
        // whose nag chains scheduleNagChains will resurrect below: their
        // still-future tail fires consume real slots, so the allocator must
        // charge them before sizing nagsPerPrompt or the total adds can
        // silently exceed iOS's 64-pending cap.
        let lastActedAt = prefs.lastActedAt ?? .distantPast
        let pastNagParents = prefs.nagEnabled
            ? (allPlannedDates + groupPlans.flatMap(\.all)).filter { $0 > lastActedAt && $0 <= now }
            : []

        // One allocator owns the 64-pending arithmetic: global first, groups
        // in order, nags last. Cap 60 keeps the plan-10 headroom for snoozes.
        let allocation = NotificationBudget.allocate(
            globalCount: dates.count,
            groupCounts: groupPlans.map { ($0.group.uniqueIdentifier, $0.future.count) },
            nagRequest: prefs.nagEnabled
                ? NotificationBudget.NagRequest(delayMinutes: prefs.nagDelayMinutes,
                                                intervalMinutes: prefs.nagIntervalMinutes,
                                                maxCount: prefs.nagMaxCount)
                : nil,
            pastNagParents: pastNagParents,
            now: now,
            // Digests occupy the 64-request system cap too (there can now be
            // several), so drop the prompt allocation by however many digest
            // requests we just scheduled — digests never crowd out prompts.
            cap: 60 - digestRequestCount)
        if allocation.pastNagTails > 0 {
            // Replans run often (foreground, settings, every sync pass) and
            // this accounting is idempotent — only log at info when the
            // numbers actually change; repeats drop to debug (user-reported
            // log spam while prompts sat unanswered).
            let signature = "\(allocation.pastNagTails)/\(pastNagParents.count)"
            if signature != lastLoggedNagTailSignature {
                lastLoggedNagTailSignature = signature
                notificationLog.info("budget charged \(allocation.pastNagTails, privacy: .public) resurrected nag tail fires for \(pastNagParents.count, privacy: .public) past prompts against the cap")
            } else {
                notificationLog.debug("nag tail budget unchanged (\(signature, privacy: .public))")
            }
        } else {
            lastLoggedNagTailSignature = nil
        }
        if allocation.global < dates.count {
            notificationLog.info("budget clamped global prompts to \(allocation.global, privacy: .public) of \(dates.count, privacy: .public)")
        }
        for plan in groupPlans where allocation.count(forGroup: plan.group.uniqueIdentifier) < plan.future.count {
            notificationLog.info("budget clamped group \(plan.group.uniqueIdentifier, privacy: .public) to \(allocation.count(forGroup: plan.group.uniqueIdentifier), privacy: .public) of \(plan.future.count, privacy: .public)")
        }

        let stampFormatter = Self.isoMinuteFormatter()
        for date in dates.prefix(allocation.global) {
            let identifier = "\(NotificationIdentifiers.promptPrefix)\(stampFormatter.string(from: date))"
            let content = Self.makeContent(question: question)
            let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
            do {
                try await center.add(request)
            } catch {
                notificationLog.error("failed to schedule prompt \(identifier, privacy: .public): \(error, privacy: .public)")
            }
        }

        for plan in groupPlans {
            let granted = allocation.count(forGroup: plan.group.uniqueIdentifier)
            let body = Self.groupBody(for: plan.group, in: questionContext)
            let extraUserInfo = Self.eventMarkerUserInfo(for: plan.group)
            for date in plan.future.prefix(granted) {
                let stamp = Self.groupStamp(groupID: plan.group.uniqueIdentifier, date: date)
                let identifier = "\(NotificationIdentifiers.groupPromptPrefix)\(stamp)"
                let content = Self.makeGroupContent(groupID: plan.group.uniqueIdentifier, body: body,
                                                    extraUserInfo: extraUserInfo)
                let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
                let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
                let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
                do {
                    try await center.add(request)
                } catch {
                    notificationLog.error("failed to schedule group prompt \(identifier, privacy: .public): \(error, privacy: .public)")
                }
            }
        }

        // Publish the earliest planned prompt (global or group) for the
        // widget's "next prompt" line, then poke timelines. Nags below are
        // follow-ups to prompts, never the next prompt itself.
        if !isTestEnvironment {
            let nextGlobal = dates.prefix(allocation.global).first
            let nextGroup = groupPlans.compactMap { plan in
                plan.future.prefix(allocation.count(forGroup: plan.group.uniqueIdentifier)).first
            }.min()
            WidgetRefresher.replanCompleted(
                nextPromptDate: [nextGlobal, nextGroup].compactMap(\.self).min()
            )
        }

        guard prefs.nagEnabled, allocation.nagsPerPrompt >= 0 else { return }
        if allocation.nagsPerPrompt < prefs.nagMaxCount {
            notificationLog.info(
                "nag count clamped to \(allocation.nagsPerPrompt, privacy: .public) (budget) from \(prefs.nagMaxCount, privacy: .public)"
            )
        }
        guard allocation.nagsPerPrompt > 0 else { return }
        // Nag chains are computed from the budget-GRANTED prompts plus past
        // parents: the granted prefix of future dates (matching the prompt
        // adds above — the allocator charged nags for granted prompts only,
        // so planning from ungranted dates would exceed the cap) plus
        // already-fired prompts, so a replan (e.g. foregrounding the app)
        // doesn't kill the in-flight chain of a delivered-but-unanswered
        // prompt (they share the `nag-` removal batch above). Chains whose
        // parent the user already acted on (quick answer, snooze, tap,
        // in-app save — tracked via `lastActedAt`) stay dead. Group prompts
        // get the identical semantics with the group stamp embedded.
        let pastGlobalParents = allPlannedDates.filter { $0 > lastActedAt && $0 <= now }
        let nagParents = pastGlobalParents + dates.prefix(allocation.global)
        await scheduleNagChains(
            for: nagParents, nagsPerPrompt: allocation.nagsPerPrompt,
            stamp: { stampFormatter.string(from: $0) },
            makeContent: { Self.makeContent(question: question) },
            prefs: prefs, now: now, calendar: calendar)
        for plan in groupPlans {
            let body = Self.groupBody(for: plan.group, in: questionContext)
            let groupID = plan.group.uniqueIdentifier
            let pastGroupParents = plan.all.filter { $0 > lastActedAt && $0 <= now }
            let groupNagParents = pastGroupParents
                + plan.future.prefix(allocation.count(forGroup: groupID))
            await scheduleNagChains(
                for: groupNagParents, nagsPerPrompt: allocation.nagsPerPrompt,
                stamp: { Self.groupStamp(groupID: groupID, date: $0) },
                makeContent: { Self.makeGroupContent(groupID: groupID, body: body) },
                prefs: prefs, now: now, calendar: calendar)
        }
    }

    /// Schedules the pre-planned nag chains: `nag-<stamp>-<n>` children at
    /// `prompt + delay + (n-1)*interval`, where `<stamp>` is
    /// `yyyyMMdd-HHmm` for global prompts and `<groupID>-<yyyyMMdd-HHmm>`
    /// for group prompts. Parents may be in the past
    /// (delivered-but-unanswered prompts being resurrected on replan),
    /// so fires at or before `now` are skipped — only the still-future tail
    /// of a partially-elapsed chain is re-added, and past parents whose
    /// fires have all elapsed add no requests at all. The chain length comes
    /// from the shared NotificationBudget allocation (clamp already applied),
    /// so NagPlanner runs unbudgeted here.
    private func scheduleNagChains(
        for promptDates: [Date], nagsPerPrompt: Int,
        stamp: (Date) -> String,
        makeContent: () -> UNMutableNotificationContent,
        prefs: NotificationPrefs, now: Date, calendar: Calendar
    ) async {
        let chains = NagPlanner.plan(
            promptDates: promptDates,
            delayMinutes: prefs.nagDelayMinutes,
            intervalMinutes: prefs.nagIntervalMinutes,
            maxCount: nagsPerPrompt,
            budget: Int.max
        )

        for chain in chains {
            let stamp = stamp(chain.parent)
            for (index, fireDate) in chain.fires.enumerated() where fireDate > now {
                let identifier = "\(NotificationIdentifiers.nagPrefix)\(stamp)-\(index + 1)"
                let content = makeContent()
                content.title = "Still waiting on your report"
                content.interruptionLevel = .timeSensitive
                let components = calendar.dateComponents(
                    [.year, .month, .day, .hour, .minute, .second], from: fireDate
                )
                let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
                let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
                do {
                    try await center.add(request)
                } catch {
                    notificationLog.error("failed to schedule nag \(identifier, privacy: .public): \(error, privacy: .public)")
                }
            }
        }
    }

    // MARK: - Nag cancellation

    /// A report was just filed in-app: past-due nag chains are moot, so
    /// remove pending nags whose parent prompt fired at or before `now`.
    /// Chains for FUTURE prompts stay — they're nagging about prompts that
    /// haven't happened yet. The `lastActedAt` marker is persisted BEFORE
    /// any removal so a concurrent replan can't resurrect the chains being
    /// removed here.
    func reportFiled(now: Date = Date()) {
        // Cross-family by design: ANY filed report satisfies ALL past-due prompts (global and group).
        prefs.lastActedAt = now
        center.getPendingNotificationRequests { requests in
            let stale = requests
                .map(\.identifier)
                .filter { identifier in
                    guard let stamp = Self.nagParentStamp(fromNagIdentifier: identifier),
                          let parentDate = Self.parentDate(fromStamp: stamp) else {
                        return false
                    }
                    return parentDate <= now
                }
            guard !stale.isEmpty else { return }
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: stale)
        }
    }

    /// Drains the widget quick-answer pending-action marker (see
    /// `WidgetQuickAnswerMarker`): the widget intent files its report from
    /// the widget-extension process, where the app's `.standard` defaults
    /// (`lastActedAt`) and the app's notification identity (nag-chain
    /// removal) are unreachable — so it leaves a marker in the App Group
    /// defaults and this method applies both side effects at the app's next
    /// launch/foreground, exactly as an in-app save would via `reportFiled`.
    /// Called before the foreground replan so the replan reads the updated
    /// `lastActedAt`.
    func drainWidgetQuickAnswerActions(from defaults: UserDefaults?, now: Date = Date()) {
        guard let defaults,
              let actedAt = WidgetQuickAnswerMarker.takePendingActedAt(in: defaults) else { return }
        // Clamp future-dated markers (clock skew) to now; never regress an
        // already-newer lastActedAt.
        let effective = min(actedAt, now)
        notificationLog.info("draining widget quick-answer marker (actedAt \(effective, privacy: .public))")
        guard (prefs.lastActedAt ?? .distantPast) < effective else { return }
        reportFiled(now: effective)
    }

    /// Synced-report nag reconciliation (plan 19): reports mirrored in from
    /// another device (the watch quick answer in particular) must quiet an
    /// in-flight nag chain here — the remote device can reach neither this
    /// device's `lastActedAt` defaults nor its pending requests. Guards live
    /// in the kit (`SyncedReportReconciler`, kit-tested): floor from the
    /// report's OWN timestamp, forward-only, historical/backfill arrivals
    /// ignored via a window derived from the nag chain's own maximum
    /// lifetime under the current prefs — not a magic constant.
    /// Called by the remote-change callback BEFORE the replan so the replan
    /// reads the updated `lastActedAt` (same ordering contract as the
    /// widget-marker drain above).
    func syncedReportsArrived(reportDates: [Date], now: Date = Date()) {
        let window = TimeInterval(
            (prefs.nagDelayMinutes + prefs.nagMaxCount * prefs.nagIntervalMinutes) * 60
        )
        guard let floor = SyncedReportReconciler.newFloor(
            reportDates: reportDates,
            currentFloor: prefs.lastActedAt,
            now: now,
            window: window
        ) else { return }
        notificationLog.info("synced report arrival floors lastActedAt to \(floor, privacy: .public) — cancelling past-due nags")
        reportFiled(now: floor)
    }

    /// Removes the sibling nag chain for the prompt stamped `stamp`.
    /// Identifiers are enumerable (`nag-<stamp>-1...10`, nagMaxCount's upper
    /// clamp), so we remove the full range blindly — removing an identifier
    /// with no pending request is a documented no-op.
    private func removeNagChain(forStamp stamp: String) {
        let identifiers = (1...10).map { "\(NotificationIdentifiers.nagPrefix)\(stamp)-\($0)" }
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    /// Parent stamp (`yyyyMMdd-HHmm`, or `<groupID>-<yyyyMMdd-HHmm>` for
    /// group prompts) from a prompt, group-prompt, or nag identifier;
    /// nil for snoozes and anything else.
    // The stamp/date parsing helpers below are `nonisolated`: they're pure
    // string/date arithmetic with no scheduler state, and they run inside
    // UNUserNotificationCenter completion handlers (nonisolated contexts) —
    // reportFiled's pending-request filter in particular. Swift 6 flags the
    // isolated-static-from-nonisolated calls otherwise (build-4 review note).

    private nonisolated static func parentStamp(fromRequestIdentifier identifier: String) -> String? {
        if identifier.hasPrefix(NotificationIdentifiers.promptPrefix) {
            return String(identifier.dropFirst(NotificationIdentifiers.promptPrefix.count))
        }
        if identifier.hasPrefix(NotificationIdentifiers.groupPromptPrefix) {
            return String(identifier.dropFirst(NotificationIdentifiers.groupPromptPrefix.count))
        }
        return nagParentStamp(fromNagIdentifier: identifier)
    }

    /// The fire date encoded in a parent stamp. Global stamps are
    /// `yyyyMMdd-HHmm`; group stamps prepend `<groupID>-` (the group ID is a
    /// UUID and itself contains dashes), so the date is always the last two
    /// dash-separated segments.
    private nonisolated static func parentDate(fromStamp stamp: String) -> Date? {
        let segments = stamp.split(separator: "-")
        guard segments.count >= 2 else { return nil }
        return isoMinuteFormatter().date(from: segments.suffix(2).joined(separator: "-"))
    }

    /// `<groupID>-<yyyyMMdd-HHmm>` — the stamp used by gprompt identifiers
    /// and their nag chains.
    private nonisolated static func groupStamp(groupID: String, date: Date) -> String {
        "\(groupID)-\(isoMinuteFormatter().string(from: date))"
    }

    /// Parent stamp from `nag-<yyyyMMdd-HHmm>-<n>`; nil for non-nag identifiers.
    private nonisolated static func nagParentStamp(fromNagIdentifier identifier: String) -> String? {
        guard identifier.hasPrefix(NotificationIdentifiers.nagPrefix) else { return nil }
        let suffix = String(identifier.dropFirst(NotificationIdentifiers.nagPrefix.count))
        // suffix = "<yyyyMMdd>-<HHmm>-<n>" — the stamp is everything before the last dash.
        guard let lastDash = suffix.lastIndex(of: "-"), lastDash != suffix.startIndex else { return nil }
        return String(suffix[..<lastDash])
    }

    /// One awake window per planned day (today + tomorrow), with its day
    /// seed. Shared by the global schedule and every timer-scheduled group.
    struct PlanWindow {
        let start: Date
        let end: Date
        let seed: UInt64
    }

    private func planWindows(now: Date, calendar: Calendar) -> [PlanWindow] {
        let todayStart = calendar.startOfDay(for: now)
        guard let tomorrowStart = calendar.date(byAdding: .day, value: 1, to: todayStart),
              let dayAfterStart = calendar.date(byAdding: .day, value: 2, to: todayStart) else {
            return []
        }

        var awakeStartComponents = DateComponents()
        awakeStartComponents.hour = 8
        awakeStartComponents.minute = 0

        return [
            PlanWindow(start: calendar.date(byAdding: awakeStartComponents, to: todayStart) ?? todayStart,
                       end: tomorrowStart,
                       seed: Self.daySeed(for: todayStart, calendar: calendar)),
            PlanWindow(start: calendar.date(byAdding: awakeStartComponents, to: tomorrowStart) ?? tomorrowStart,
                       end: dayAfterStart,
                       seed: Self.daySeed(for: tomorrowStart, calendar: calendar)),
        ]
    }

    private func plannedDates(prefs: NotificationPrefs, now: Date, calendar: Calendar) -> [Date] {
        planWindows(now: now, calendar: calendar)
            .flatMap { window in
                PromptPlanner.plan(prefs: prefs, awakeStart: window.start, awakeEnd: window.end,
                                   seed: window.seed, calendar: calendar)
            }
            .sorted()
    }

    // MARK: - Prompt groups (plan 12)

    /// Enabled groups with a timer schedule, in creation (sortOrder) order —
    /// the budget allocator processes them in this order.
    private static func timerScheduledGroups(in context: ModelContext) -> [PromptGroup] {
        let descriptor = FetchDescriptor<PromptGroup>(
            sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.uniqueIdentifier)])
        guard let groups = try? context.fetch(descriptor) else { return [] }
        return groups.filter { group in
            guard group.isEnabled else { return false }
            switch group.schedule {
            case .everyNHours, .timesPerDay, .dailyAt: return true
            case .workoutEnd, .visitArrival, .calendarEventEnd, .disabled: return false
            }
        }
    }

    /// Enabled groups with a calendar event-end schedule (plan 31), in
    /// sortOrder — merged with the timer plans before budget allocation.
    /// Unknown match-kind raws resolve `.disabled` and drop out here.
    private static func calendarScheduledGroups(in context: ModelContext) -> [PromptGroup] {
        let descriptor = FetchDescriptor<PromptGroup>(
            sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.uniqueIdentifier)])
        guard let groups = try? context.fetch(descriptor) else { return [] }
        return groups.filter { group in
            guard group.isEnabled else { return false }
            if case .calendarEventEnd = group.schedule { return true }
            return false
        }
    }

    /// userInfo marker for event-scheduled group prompts: calendar groups'
    /// requests carry `calendarEventEndKey` so the tap-through report gets
    /// the `.calendarEventEnd` trigger (the visitArrivalKey pattern; visit
    /// and workout prompts are posted by their observers, not planned here).
    private static func eventMarkerUserInfo(for group: PromptGroup) -> [String: String] {
        if case .calendarEventEnd = group.schedule {
            return [NotificationIdentifiers.calendarEventEndKey: "1"]
        }
        return [:]
    }

    /// Notification body for a group prompt: the group's name, else its
    /// first (non-dangling) question's prompt, else the generic body.
    static func groupBody(for group: PromptGroup, in context: ModelContext) -> String {
        let name = group.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
        for questionID in group.questionIDs {
            var descriptor = FetchDescriptor<Question>(
                predicate: #Predicate { $0.uniqueIdentifier == questionID })
            descriptor.fetchLimit = 1
            if let prompt = (try? context.fetch(descriptor))?.first?.prompt, !prompt.isEmpty {
                return prompt
            }
        }
        return "What are you up to right now?"
    }

    /// Group prompts use a PLAIN category (no quick-answer/snooze actions):
    /// the group may not contain the global Yes/No question, so the actions
    /// would file answers against a question outside the group. userInfo
    /// carries the group ID for the tap-through survey scoping.
    /// Period-aware digest notification copy (plan 40). Static, stats-free —
    /// the screen computes fresh stats on open (plan-14 doctrine).
    static func digestTitle(for period: DigestPeriod) -> String {
        switch period {
        case .week: return "Your weekly digest is ready"
        case .month: return "Your monthly digest is ready"
        case .quarter: return "Your quarterly digest is ready"
        }
    }

    static func digestBody(for period: DigestPeriod) -> String {
        switch period {
        case .week: return "See how your week stacked up — reports, people, places, and more."
        case .month: return "A month of reports, people, and places — see how it added up."
        case .quarter: return "Three months of reports — see the bigger picture."
        }
    }

    static func makeGroupContent(
        groupID: String, body: String, extraUserInfo: [String: String] = [:]
    ) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "Time to report"
        content.body = body
        content.sound = .default
        var userInfo: [AnyHashable: Any] = [NotificationIdentifiers.promptGroupIDKey: groupID]
        for (key, value) in extraUserInfo { userInfo[key] = value }
        content.userInfo = userInfo
        return content
    }

    /// Immediate (nil-trigger ⇒ deliver now) group prompt for the EVENT
    /// observers (workout end, visit arrival). The identifier is
    /// content-addressed from the event date — `gprompt-<groupID>-<stamp>`,
    /// the same shape the replan/nag stamp parsers already handle — so
    /// duplicate deliveries of the same event collide instead of
    /// double-bannering.
    static func makeImmediateGroupPromptRequest(
        group: PromptGroup, in context: ModelContext, eventDate: Date,
        extraUserInfo: [String: String] = [:]
    ) -> UNNotificationRequest {
        let content = makeGroupContent(
            groupID: group.uniqueIdentifier, body: groupBody(for: group, in: context),
            extraUserInfo: extraUserInfo)
        let stamp = groupStamp(groupID: group.uniqueIdentifier, date: eventDate)
        let identifier = "\(NotificationIdentifiers.groupPromptPrefix)\(stamp)"
        return UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
    }

    // MARK: - Next alert readout

    /// Reads the soonest pending DISPATCH_PROMPT (or snooze) trigger date,
    /// for the settings UI's "next alert" caption. Delegates to
    /// `nextPrompt` so both readouts share the same "prompts only" filter
    /// (nags, the weekly digest, and webhook-failure notices are excluded —
    /// they are not upcoming prompts).
    func nextPromptDate(completion: @escaping @Sendable (Date?) -> Void) {
        nextPrompt { next in completion(next?.date) }
    }

    /// The soonest pending PROMPT (global, group, or snooze) and where it
    /// came from, for the settings "NEXT NOTIFICATION" hero. Nag reminders
    /// are deliberately excluded: a nag is a follow-up about an
    /// already-delivered prompt, not the next prompt.
    func nextPrompt(completion: @escaping @Sendable ((date: Date, source: NextPromptSource)?) -> Void) {
        // Snapshot prefs on the main actor; the center callback is nonisolated.
        let scheduledTimes = prefs.scheduledTimes
        center.getPendingNotificationRequests { requests in
            let candidates = requests.compactMap { request -> (date: Date, source: NextPromptSource)? in
                let nextDate: Date? = switch request.trigger {
                case let calendar as UNCalendarNotificationTrigger:
                    calendar.nextTriggerDate()
                case let interval as UNTimeIntervalNotificationTrigger:
                    interval.nextTriggerDate()
                default:
                    nil
                }
                guard let nextDate,
                      let source = NotificationIdentifiers.promptSource(
                        forIdentifier: request.identifier,
                        fireDate: nextDate,
                        scheduledTimes: scheduledTimes)
                else { return nil }
                return (nextDate, source)
            }
            completion(candidates.min { $0.date < $1.date })
        }
    }

    /// Display name for a prompt group, for the hero caption's
    /// "FROM GROUP <NAME>" line; nil when the group is unnamed or gone.
    func promptGroupName(forID groupID: String) -> String? {
        let context = ModelContext(container)
        var descriptor = FetchDescriptor<PromptGroup>(
            predicate: #Predicate { $0.uniqueIdentifier == groupID })
        descriptor.fetchLimit = 1
        let name = (try? context.fetch(descriptor))?.first?.name
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (name?.isEmpty ?? true) ? nil : name
    }

    /// Current notification authorization, for the hero's empty state
    /// ("Notifications are off" vs "No prompts scheduled").
    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    // MARK: - Delegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping @Sendable () -> Void
    ) {
        let actionIdentifier = response.actionIdentifier
        let requestIdentifier = response.notification.request.identifier
        // Probe (plan 19 Task 5, mandatory — uncited platform behavior):
        // pairs with the watch delegate's identical line; capturing both
        // devices' logs answers which process receives `didReceive` for
        // actions tapped on a notification FORWARDED to the watch. Kept
        // permanently — one line per response, documents the routing
        // contract the watch's action handling depends on.
        notificationLog.info("didReceive in process \(ProcessInfo.processInfo.processName, privacy: .public) action \(actionIdentifier, privacy: .public) request \(requestIdentifier, privacy: .public)")
        let promptGroupID = response.notification.request.content
            .userInfo[NotificationIdentifiers.promptGroupIDKey] as? String
        let triggeringWorkoutID = response.notification.request.content
            .userInfo[NotificationIdentifiers.triggeringWorkoutIDKey] as? String
        let firedByVisitArrival = response.notification.request.content
            .userInfo[NotificationIdentifiers.visitArrivalKey] != nil
        let firedByCalendarEventEnd = response.notification.request.content
            .userInfo[NotificationIdentifiers.calendarEventEndKey] != nil
        // Missing/unknown period → .week — also covers stale pre-plan-40
        // `digest-weekly` requests (no period payload).
        let digestPeriod = DigestPeriod(rawValue: response.notification.request.content
            .userInfo[NotificationIdentifiers.digestPeriodKey] as? String ?? "") ?? .week
        Task { @MainActor in
            // Digest taps deep-link to the digest screen — no survey, no
            // lastActedAt marker (the digest is not a prompt).
            if requestIdentifier.hasPrefix(NotificationIdentifiers.digestPrefix) {
                pendingDigestPeriod = digestPeriod
                completionHandler()
                return
            }
            // ANY action on a prompt or one of its nags counts as "acting on
            // it" — persist the `lastActedAt` marker FIRST (so a replan
            // triggered by the action, e.g. the default tap foregrounding
            // the app, can't resurrect the chain), then cancel the sibling
            // nag chain before handling the action. Snooze notifications
            // carry uuid identifiers (no stamp): no-op.
            if let stamp = Self.parentStamp(fromRequestIdentifier: requestIdentifier) {
                // Cross-family by design: acting on ANY prompt satisfies ALL past-due prompts (global and group).
                prefs.lastActedAt = Date()
                removeNagChain(forStamp: stamp)
            }
            switch actionIdentifier {
            case NotificationIdentifiers.snoozeAction:
                scheduleSnooze()
            case NotificationIdentifiers.answerYesAction:
                fileQuickAnswer(isYes: true)
            case NotificationIdentifiers.answerNoAction:
                fileQuickAnswer(isYes: false)
            default:
                // Default tap (including UNNotificationDefaultActionIdentifier)
                // opens the app into a new regular survey — scoped to the
                // prompt's group when the notification carries one, and
                // recorded as workout-/visit-triggered when an event fired it.
                let trigger: ReportTrigger = if triggeringWorkoutID != nil {
                    .workoutEnd
                } else if firedByVisitArrival {
                    .visitArrival
                } else if firedByCalendarEventEnd {
                    .calendarEventEnd
                } else {
                    .notification
                }
                pendingSurveyRequest = SurveyRequest(
                    kind: .regular,
                    trigger: trigger,
                    promptGroupID: promptGroupID,
                    triggeringWorkoutID: triggeringWorkoutID)
            }
            completionHandler()
        }
    }

    /// Set by the delegate on notification tap; ContentView/HomeView observe
    /// this via the environment and present SurveyFlowView, then clear it.
    var pendingSurveyRequest: SurveyRequest?

    /// Set by the delegate when a `digest-` notification is tapped, carrying
    /// the tapped schedule's period; ContentView observes this and presents
    /// the digest sheet scoped to that period. nil ⇒ no pending digest.
    var pendingDigestPeriod: DigestPeriod?

    private func scheduleSnooze() {
        let identifier = "\(NotificationIdentifiers.snoozePrefix)\(UUID().uuidString)"
        let context = ModelContext(container)
        let content = Self.makeContent(question: Self.firstEnabledYesNoQuestion(in: context))
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 15 * 60, repeats: false)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        center.add(request) { error in
            if let error {
                notificationLog.error("failed to schedule snooze: \(error, privacy: .public)")
            }
        }
    }

    /// Webhook enqueue+drain hook (plan 24), set by DispatchApp — the
    /// notification quick-answer save path runs in the app process, so it
    /// delivers immediately like any in-app save.
    var reportFiledWebhookHook: ((String) -> Void)?

    private func fileQuickAnswer(isYes: Bool) {
        let context = ModelContext(container)
        guard let question = Self.firstEnabledYesNoQuestion(in: context) else { return }
        do {
            let report = try QuickAnswerFiler.file(
                question: question,
                choiceIndex: isYes ? 0 : 1,
                trigger: .notification,
                in: context
            )
            reportFiledWebhookHook?(report.uniqueIdentifier)
            if !isTestEnvironment {
                WidgetRefresher.reload()
            }
        } catch {
            notificationLog.error("failed to save quick answer report: \(error, privacy: .public)")
        }
    }

    // MARK: - Helpers

    /// Builds notification content. When a quick-answer Yes/No question
    /// exists, the body states that question's prompt so the "Yes"/"No"
    /// actions on the notification are unambiguous about what they answer.
    /// Falls back to the generic body when there's no quick-answer question
    /// (and therefore no quick-answer actions to disambiguate).
    private static func makeContent(question: Question?) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "Time to report"
        if let question {
            content.body = question.prompt
        } else {
            content.body = "What are you up to right now?"
        }
        content.sound = .default
        content.categoryIdentifier = NotificationIdentifiers.category
        return content
    }

    /// Delegates to the kit's shared quick-answer path so the notification
    /// actions, the widget buttons, and this scheduler's content builder all
    /// target the SAME question.
    private static func firstEnabledYesNoQuestion(in context: ModelContext) -> Question? {
        QuickAnswerFiler.firstEnabledYesNoQuestion(in: context)
    }

    /// Day's `yyyyMMdd` digits as a UInt64 — stable within a calendar day,
    /// varies day to day, so the schedule doesn't repeat but doesn't churn
    /// on every re-plan either.
    static func daySeed(for date: Date, calendar: Calendar) -> UInt64 {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let year = components.year ?? 2000
        let month = components.month ?? 1
        let day = components.day ?? 1
        let value = year * 10_000 + month * 100 + day
        return UInt64(max(0, value))
    }

    /// Content-addressed identifier suffix (`yyyyMMdd-HHmm`) so pending
    /// prompt requests for the same planned minute collide (by design) on
    /// re-plan instead of accumulating index-based duplicates.
    /// `DateFormatter` isn't Sendable, so — same tradeoff as the kit's
    /// V2DateFormat — a fresh instance per use rather than a shared static
    /// (which would pin the nonisolated parsing helpers to the main actor).
    /// Construction count is a handful per replan, not a hot loop.
    ///
    /// Locale is pinned to `en_US_POSIX` (build-13 review minor): without
    /// the pin, an unset locale renders the digits per device locale (e.g.
    /// Eastern Arabic numerals), so stamps for the same minute vary with
    /// locale and stop matching what the parsing helpers produce. TRADEOFF:
    /// the pin re-stamps every identifier, so requests scheduled by a
    /// pre-pin build would be orphaned — `ScheduleStampVersion` (kit,
    /// tested) makes DispatchApp run one full replan on first launch after
    /// upgrade, which removes old requests by prefix (locale-independent)
    /// and re-adds them with pinned stamps.
    private nonisolated static func isoMinuteFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmm"
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        return formatter
    }
}
