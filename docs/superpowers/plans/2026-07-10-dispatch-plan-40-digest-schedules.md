# Dispatch Plan 40: Configurable digest schedules

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal (issue #45):** the weekly digest reminder (plan 14) is hardcoded — one notification, Sunday 19:00 local, identifier `digest-weekly`, behind a single toggle. Make it user-configurable: custom day-of-week and time, MULTIPLE schedules (e.g. a mid-week digest alongside the Sunday one), and monthly/quarterly cadences. Each schedule is its own notification; tapping one opens the digest screen scoped to the right period (week / month / quarter). The digest screen itself stays reachable from Settings exactly as today.

**Architecture:** a pure kit model `DigestSchedule` in `Sources/DispatchKit/Digest/` — `{id, cadence (.weekly(weekday)/.monthly(dayOfMonth)/.quarterly(dayOfMonth)), hour, minute, isEnabled}` — with kit-tested next-fire-date math (DST-safe, month-length clamping) and a `DigestPeriod` (week/month/quarter) whose trailing-interval math generalizes `DigestStats.compute` from week-scoped to any period. Persistence follows `NotificationPrefs.scheduledTimes` to the letter (JSON `Data` in the defaults suite), with a one-time migration from `digestEnabled`. App-side: `NotificationScheduler.replanNow`'s digest block iterates enabled schedules (`digest-<uuid>` identifiers — the existing `digest-` removal-batch prefix and next-prompt-parser exclusion cover the new scheme with ZERO parser changes), the delegate's digest branch grows a period payload, and `NotificationSettingsView.digestSection` becomes a list editor modeled on the scheduled-times section (rows + swipe-to-delete + ADD sheet).

**Tech Stack:** Foundation (`Calendar.nextDate(after:matching:matchingPolicy:)`, `range(of:in:for:)`), Swift Testing (kit), UserNotifications (`UNCalendarNotificationTrigger`, repeating and one-shot), SwiftUI (List editor, wheel pickers, `presentationDetents`), XCUITest.

## Design decisions (decide + log)

- **Cadence semantics.** `.weekly(weekday: Int)` uses the `Calendar` convention (1 = Sunday … 7 = Saturday). `.monthly(dayOfMonth: Int)` fires the chosen day 1–31, **clamped to the actual month length** (31 → Feb 28/29, Apr 30 — the user's intent is "end of month", not "skip February"). `.quarterly(dayOfMonth: Int)` fires the chosen day (same clamping) **in each calendar-quarter START month — Jan/Apr/Jul/Oct** — so a quarterly digest early in the new quarter reviews the quarter that just ended via the trailing window below. Decided over user-chosen anchor months (config surface nobody asked for) and over quarter-END months (a Dec 31 digest reviews a quarter that isn't finished being lived; a Jan 5 one reviews Oct–Dec complete).
- **Period stats are TRAILING windows, not calendar-aligned periods.** `DigestPeriod.interval(ending:calendar:)` returns the 7 days / 1 calendar month / 3 calendar months ending at (and excluding) the start of the day after `ending` — the exact plan-14 weekly window rule, generalized by swapping `.day, -7` for `.month, -1/-3`. The prior window (for deltas/trends) is the same-length window immediately before. Rationale: preserves today's weekly contract byte-for-byte, never shows a half-empty "current period", and calendar-aligned review (THE March, THE 2026) is Wrapped's job (plan 33).
- **Shared period-stats surface — this plan does the interval generalization plan 33 deliberately skipped.** Plan 33 (`2026-07-10-dispatch-plan-33-wrapped.md`, PR #37, unmerged) chose compose-don't-refactor and computes its own yearly/monthly aggregation in `WrappedStats`, leaving `DigestStats` weekly. This plan generalizes `DigestStats.compute` to `compute(reports:questions:period:ending:calendar:)` with `weekStart/weekEnd/priorWeekReportCount` renamed to `periodStart/periodEnd/priorPeriodReportCount` and a stored `period: DigestPeriod` — one rename pass, all call sites and tests in the same commit (house single-pass renumbering rule). The weekly entry point `compute(reports:questions:weekEnding:calendar:)` survives as a thin `.week` wrapper so existing tests keep their shape. **Coordination note for plan 33's implementer:** whichever plan lands second rebases; `WrappedStats`' per-period report/token/people/place counting should call this interval-parameterized compute (or its extracted helpers) rather than duplicating the aggregation — the plan-33 doc's "compose, never re-invent" decision now has a real seam to compose against. Wrapped's registry-resolved people upgrade stays Wrapped-only.
- **`templateSummary` learns period nouns.** "this week" / "the week before" become `period`-driven ("this month", "the quarter before"); the zero-report weekly sentence stays byte-identical because `DigestUITests` pins `"You filed 0 reports this week"` (Settings always opens the weekly period — below). The week-only "fortnight" quip generalizes to "your first reports in two \(noun)s".
- **Persistence + migration.** `NotificationPrefs.digestSchedules: [DigestSchedule]` stored as JSON `Data` under key `digestSchedules` (the `scheduledTimes` pattern verbatim, including silent-failure decode/encode). One-time `migrateDigestSchedulesIfNeeded()`: key absent AND `digestEnabled == true` → seed `[weekly Sunday 19:00, enabled]` (today's exact constants: `weekday = 1`, `hour = 19`, minute 0); key absent and false → write `[]` (writing marks migrated). Called from `DispatchApp.init` before the first replan. The `digestEnabled` key stops being read (left in place — harmless; `DeleteAllData`'s preference-key doc list swaps it for `digestSchedules`).
- **Identifiers: `digest-<uuid>`, and the old scheme migrates itself.** `NotificationIdentifiers.digestPrefix` (`"digest-"`) already drives the replan removal batch AND the delegate's tap branch by prefix, so per-schedule identifiers `digest-<uuid.uuidString>` join both for free; stale `digest-weekly` requests from pre-plan-40 builds are removed by the same prefix batch on first replan — no bespoke cleanup. The `digestWeeklyIdentifier` constant is deleted (kit-internal; freeze test updated). **The next-prompt source parser needs NO change and MUST NOT gain one:** `promptSource(forIdentifier:)` classifies only `prompt-`/`gprompt-`/`snooze-` prefixes and returns nil for everything else — `digest-weekly` is excluded today by that fall-through, and `digest-<uuid>` inherits the exclusion. Pinned with a new test (the plan-33 `wrapped-annual` pin's sibling) so a future parser refactor can't start classifying digests as prompts.
- **Trigger strategy: repeating where iOS can express it, re-armed otherwise.** Weekly → `UNCalendarNotificationTrigger(dateMatching: {weekday, hour, minute}, repeats: true)` — exactly today's `digest-weekly` mechanics; fires even if the app is never opened. Monthly with `dayOfMonth ≤ 28` → repeating `{day, hour, minute}`. Monthly 29–31 (clamping is not expressible in matching components) and quarterly (no multi-month component set) → ONE non-repeating trigger at the kit-computed `nextFireDate`, re-armed by every replan (replans run on every app foreground/scene-active, so the request is refreshed long before it goes stale; a user who never opens the app misses at most the second occurrence — accepted, logged).
- **Budget honesty:** digest requests stay outside `NotificationBudget`'s allocation (plan-14 placement, ahead of the asleep guard — a digest is not an awake-window prompt) but they DO occupy the 64-request system cap, and there can now be several. The allocator call's cap drops from the fixed 60 to `60 - <digest requests just scheduled>`, and the editor caps schedules at 8 (`digest-add-schedule` disabled beyond) so digests can never crowd out prompts.
- **Tap routing carries the period.** Content `userInfo[NotificationIdentifiers.digestPeriodKey] = period.rawValue`; the delegate's digest branch parses it into `pendingDigestPeriod: DigestPeriod?` (replacing the Bool `pendingDigestOpen`; missing/unknown value → `.week`, which also covers stale pre-plan-40 `digest-weekly` requests). `ContentView`'s digest sheet keeps its lock/survey serialization semantics untouched and passes the period into the screen.
- **Digest screen renders non-weekly periods; entry point fixes the period.** `WeeklyDigestView` gains `period: DigestPeriod = .week` (file/type name kept — it's frozen in test/identifier space via `weekly-digest-view`/`weekly-digest-link`, and week remains the default): navigation title "Weekly/Monthly/Quarterly Digest", narrative header "THIS WEEK/MONTH/QUARTER", delta caption "vs last week/month/quarter", compute called with the view's period. No in-screen period switcher: Settings' link stays weekly (`DigestUITests` pin), notification taps open their own period, and on-demand month browsing belongs to Wrapped (plan 33) — logged to keep the screens from converging into two period pickers.
- **Editor UX = the scheduled-times pattern, one notch richer.** `digestSection` becomes: one row per schedule — single-line label "Weekly · Sunday · 7:00 PM" / "Monthly · Day 31 · 9:00 AM" / "Quarterly · Day 1 · 8:00 AM" with a per-row enable Toggle — swipe-to-delete, and an "ADD A DIGEST…" button opening a medium-detent sheet (cadence segmented picker → weekday picker OR day-of-month picker → wheel time picker; Cancel/Add toolbar — the `addTimeSheet` skeleton). Rows sort by cadence rank (weekly, monthly, quarterly) then day then time — stable, no reorder UI. Every mutation writes `prefs.digestSchedules` and triggers the standard replan. The old `digest-enabled` toggle identifier retires (grep-verified: no UI test uses it); new identifiers below.
- **Day-of-month picker offers 1–31 with a clamping footnote** ("Months shorter than your chosen day fire on their last day") rather than restricting to 28 — "the 31st" meaning "month-end" is the feature, and the kit math owns the truth.
- **Notification copy is period-aware, stats-free:** weekly keeps today's strings; monthly "Your monthly digest is ready" / "A month of reports, people, and places — see how it added up."; quarterly "Your quarterly digest is ready" / "Three months of reports — see the bigger picture." (content is static; the screen computes fresh stats on open, plan-14 doctrine).

## Global Constraints

- Kit changes test-first: failing test → `swift test` red → implement → `swift test` green, per task. App target verified with `xcodebuild build-for-testing`; UI suite at the merge gate.
- `DigestSchedule` math is deterministic: injected `Calendar` (tests pin `America/New_York` for DST cases), no `Date()` inside kit code, explicit tiebreaks. At least one DST-transition test is mandatory.
- Additive persistence only: new defaults key `digestSchedules`; `digestEnabled` is abandoned in place, never repurposed. No report/export schema change anywhere in this plan.
- Existing behavior survives: a migrated `digestEnabled == true` user gets the identical Sunday-19:00 weekly notification (now editable); `digestEnabled == false` users see an empty editor and no requests. Digest taps keep the lock/survey serialization contract.
- Frozen accessibility identifiers stay frozen (`weekly-digest-view`, `weekly-digest-link`, `digest-narrative`, `digest-regenerate`, `next-notification-time`, …). Retired: `digest-enabled` (no test coverage — verified). New: `digest-schedule-row-<uuid>`, `digest-schedule-toggle-<uuid>`, `digest-add-schedule`, `digest-cadence-picker`, `digest-day-picker`, `digest-time-picker`, `digest-add-confirm`.
- Test gating absolute: `--ui-testing`/`--mock-sensors` paths schedule through the same replan gates as today (test environments bypass the authorization gate but use isolated defaults) — the new UI test drives the editor and asserts via the store, never real notification delivery.
- Suites green before every commit; scoped commit + push per task; `git pull --rebase` before starting/pushing. Do NOT bump the build number.
- Track on GitHub Project 1: set issue #45 In Progress at dispatch, close with the build number when shipped.

---

### Task 1: Kit — DigestSchedule model + next-fire math

**Files:**
- Create: `Sources/DispatchKit/Digest/DigestSchedule.swift`
- Test: create `Tests/DispatchKitTests/DigestScheduleTests.swift`

**Interfaces (produced — later tasks rely on these exact names):**

```swift
public struct DigestSchedule: Codable, Equatable, Identifiable, Sendable {
    public enum Cadence: Codable, Equatable, Sendable {
        case weekly(weekday: Int)       // 1 = Sunday … 7 = Saturday (Calendar convention)
        case monthly(dayOfMonth: Int)   // 1…31, clamped to each month's length
        case quarterly(dayOfMonth: Int) // fires in Jan/Apr/Jul/Oct, same clamping
        public var period: DigestPeriod // .week / .month / .quarter
    }
    public var id: UUID
    public var cadence: Cadence
    public var hour: Int
    public var minute: Int
    public var isEnabled: Bool

    /// Components for a REPEATING UNCalendarNotificationTrigger, or nil when
    /// the cadence can't be expressed as one (monthly day 29–31 — clamping;
    /// quarterly — no multi-month match) and the caller must re-arm one-shot
    /// triggers from `nextFireDate` on each replan.
    public var repeatingTriggerComponents: DateComponents?

    /// Next wall-clock fire strictly after `now`. Weekly delegates to
    /// Calendar.nextDate (DST-correct); monthly/quarterly scan candidate
    /// months forward, clamping the day via range(of: .day, in: .month).
    public func nextFireDate(after now: Date, calendar: Calendar = .current) -> Date?
}

public enum DigestPeriod: String, Codable, Sendable, CaseIterable {
    case week, month, quarter
    /// Trailing window ending at (and excluding) the start of the day after
    /// `ending` — the plan-14 weekly rule generalized. `priorStart` begins
    /// the same-length window immediately before `start`.
    public func interval(ending: Date, calendar: Calendar = .current)
        -> (start: Date, end: Date, priorStart: Date)
}
```

- [ ] **Step 1: Write the failing tests.** `DigestScheduleTests.swift` (Swift Testing, pinned-zone calendars like `DigestStatsTests`' `utcCalendar` helper): (a) weekly next-fire — from a Wednesday, `.weekly(weekday: 1)` 19:00 lands the coming Sunday 19:00; from Sunday 19:00 exactly, the NEXT Sunday (strictly after); (b) monthly clamping — `.monthly(dayOfMonth: 31)` from Feb 1 2027 fires Feb 28 2027, then Mar 31; from Jan 31 19:01 (past today's fire) → Feb 28; (c) quarterly anchors — `.quarterly(dayOfMonth: 5)` from Feb → Apr 5, from Dec 20 → Jan 5 next year; `.quarterly(dayOfMonth: 31)` → Apr 30 (clamp inside a quarter month); (d) **DST (mandatory)** — calendar `America/New_York`: weekly Sunday 19:00 across the 2027-03-14 spring-forward keeps wall-clock 19:00 (offset changes, hour doesn't); a `.weekly` schedule at 02:30 with `now` = the night of the transition resolves per `.nextTime` policy (rolls to the next valid instant, never nil, never double-fires) — pin whatever the API does; (e) `repeatingTriggerComponents` — weekly gives `{weekday, hour, minute}`, monthly 15 gives `{day, hour, minute}`, monthly 31 and quarterly give nil; (f) Codable round-trip for all three cadences (`==` after decode; this is the persistence format — a failure here is a data-loss bug); (g) `DigestPeriod.interval` — `.week` reproduces the exact current `DigestStats` window arithmetic (7 days ending day-after-`ending`), `.month` from Mar 15 spans Feb 16…Mar 16 boundaries per `calendar.date(byAdding: .month, -1)`, `.quarter` spans 3 months, and `priorStart` chains another same-length step back.
- [ ] **Step 2: Run `swift test` — expect FAIL** (types don't exist).
- [ ] **Step 3: Implement.** Header doc mirrors `DigestStats`': pure, Foundation-only, and the logged decisions (Calendar weekday convention, clamping-not-skipping, Jan/Apr/Jul/Oct anchoring, trailing windows). Weekly via `calendar.nextDate(after:matching:matchingPolicy: .nextTime)`. Monthly/quarterly: iterate month starts from `now`'s month forward (14 months covers every case), clamp `dayOfMonth` with `calendar.range(of: .day, in: .month, for: monthStart)`, build the candidate via `calendar.date(from: DateComponents(year:month:day:hour:minute:))`, return the first candidate `> now`; quarterly filters months to `[1, 4, 7, 10]`. Synthesized Codable for the associated-value enum.
- [ ] **Step 4: Run `swift test` — expect PASS** (whole kit suite).
- [ ] **Step 5: Commit** — `git commit -m "feat(kit): DigestSchedule — weekly/monthly/quarterly cadence + next-fire math"` → push.

### Task 2: Kit — persistence, migration, identifier pins

**Files:**
- Modify: `Sources/DispatchKit/Prompting/NotificationPrefs.swift`, `Sources/DispatchKit/Prompting/NotificationIdentifiers.swift`, `Sources/DispatchKit/Support/DeleteAllData.swift` (doc list only)
- Test: extend `Tests/DispatchKitTests/NotificationIdentifiersTests.swift` (+ prefs cases wherever `NotificationPrefs` is currently tested — follow the suite-named ephemeral-`UserDefaults` pattern)

- [ ] **Step 1: Write the failing tests.** (a) `digestSchedules` round-trips through a fresh suite-named `UserDefaults` (encode → decode `==`); empty and multi-schedule arrays; (b) migration — `digestEnabled = true` + no `digestSchedules` key → `migrateDigestSchedulesIfNeeded()` seeds exactly `[weekly Sunday 19:00 enabled]`; `digestEnabled = false` → seeds `[]`; second call is a no-op (mutate the array, migrate again, mutation survives); (c) `promptSource(forIdentifier: "digest-\(UUID().uuidString)", …)` returns nil — the digests-are-not-prompts pin; keep the existing `digest-weekly` exclusion case passing by replacing the deleted constant with the literal string (old builds' requests still exist in the wild).
- [ ] **Step 2: Run `swift test` — expect FAIL.**
- [ ] **Step 3: Implement.**

```swift
// NotificationPrefs — the scheduledTimes storage pattern verbatim:
public var digestSchedules: [DigestSchedule] {
    get {
        guard let jsonData = defaults.data(forKey: "digestSchedules") else { return [] }
        return (try? JSONDecoder().decode([DigestSchedule].self, from: jsonData)) ?? []
    }
    set {
        if let jsonData = try? JSONEncoder().encode(newValue) {
            defaults.set(jsonData, forKey: "digestSchedules")
        }
    }
}

/// One-time plan-40 migration: `digestEnabled == true` becomes the exact
/// schedule plan 14 hardcoded (weekly, Sunday, 19:00); false becomes an
/// empty list. Writing the array (even empty) marks migration done — the
/// key's presence is the marker. `digestEnabled` is never read again.
public func migrateDigestSchedulesIfNeeded() {
    guard defaults.data(forKey: "digestSchedules") == nil else { return }
    digestSchedules = digestEnabled
        ? [DigestSchedule(id: UUID(), cadence: .weekly(weekday: 1),
                          hour: 19, minute: 0, isEnabled: true)]
        : []
}
```

`NotificationIdentifiers`: comment on `digestPrefix` updated (`/// Digest reminders (plan 14, reworked plan 40): one request per schedule, `digest-<uuid>`; removals join the prompt-/gprompt-/nag- batch. Excluded from promptSource by fall-through — pinned.`), `digestWeeklyIdentifier` deleted, new `public static let digestPeriodKey = "digestPeriod"`. `digestEnabled`'s doc comment gains a "superseded by digestSchedules (plan 40), key abandoned in place" line. `DeleteAllData` doc list: `digestEnabled` → `digestSchedules`.
- [ ] **Step 4: Run `swift test` — expect PASS.** Commit — `git commit -m "feat(kit): digest schedule persistence + digestEnabled migration"` → push.

### Task 3: Kit — DigestStats period generalization

**Files:**
- Modify: `Sources/DispatchKit/Digest/DigestStats.swift`
- Test: extend `Tests/DispatchKitTests/DigestStatsTests.swift`

- [ ] **Step 1: Write the failing tests.** (a) `compute(reports:questions:period: .month, ending:…)` counts a report 20 days before `ending` that the `.week` compute excludes; prior-month delta uses the month before that; (b) `.quarter` spans 3 months with the prior quarter as baseline; (c) `.week` via BOTH entry points (the kept `weekEnding:` wrapper and `period: .week`) produces `==` stats — the byte-identical weekly contract; (d) `templateSummary` period nouns — a `.month` stats' summary says "this month"/"the month before"; the zero-report `.week` sentence is STILL exactly `"You filed 0 reports this week"` (the `DigestUITests` pin); (e) rename fallout — `periodStart`/`periodEnd`/`priorPeriodReportCount`/`period` populated correctly for all three periods.
- [ ] **Step 2: Run `swift test` — expect FAIL.**
- [ ] **Step 3: Implement.** `compute(reports:questions:period:ending:calendar:)` derives windows from `DigestPeriod.interval(ending:calendar:)`; every existing aggregation (tokens/people/places/numeric/valence/health/streak/insights) is untouched — only the two window filters change source. Rename `weekStart → periodStart`, `weekEnd → periodEnd`, `priorWeekReportCount → priorPeriodReportCount`, add `period: DigestPeriod`; update the header doc (trailing-window rule, plan-40 pointer) and ALL call sites + tests in this one commit (single-pass rename rule). Keep `compute(reports:questions:weekEnding:calendar:)` delegating with `.week`. `templateSummary`: `let noun = period.noun` ("week"/"month"/"quarter") threaded through the delta clause, fortnight line ("your first reports in two \(noun)s"), and mood-trend sentences. Add the plan-33 seam comment on `compute`: *"Wrapped (plan 33) computes calendar-aligned periods — its implementer should reuse this interval-parameterized compute (or helpers extracted from it) instead of duplicating the aggregation; see the plan-40 shared-surface decision."*
- [ ] **Step 4: Run `swift test` — expect PASS.** Commit — `git commit -m "feat(kit): DigestStats period generalization — week/month/quarter trailing windows"` → push.

### Task 4: App — per-schedule notifications + period-aware routing and screen

**Files:**
- Modify: `App/Sources/Notifications/NotificationScheduler.swift`, `App/Sources/DispatchApp.swift` (migration call), `App/Sources/ContentView.swift`, `App/Sources/Digest/WeeklyDigestView.swift`

- [ ] **Step 1: Schedule.** Replace `replanNow`'s `prefs.digestEnabled` block (same placement — after the removal batch, ahead of the asleep guard, same comment discipline):

```swift
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
```

`NotificationBudget.allocate`'s `cap:` becomes `60 - digestRequestCount` (budget-honesty decision; add the one-line why comment). `DispatchApp.init` calls `prefs.migrateDigestSchedulesIfNeeded()` before the stamp-migration replan.
- [ ] **Step 2: Tap routing.** Delegate digest branch: `pendingDigestOpen = true` → `pendingDigestPeriod = DigestPeriod(rawValue: userInfo[digestPeriodKey] as? String ?? "") ?? .week` (comment: missing/unknown → `.week`, covers stale `digest-weekly` requests from pre-plan-40 builds; still no `lastActedAt` — a digest is not a prompt). `ContentView`: the digest sheet's getter/setter swaps the Bool for nil-checks on `pendingDigestPeriod` (serialization semantics byte-identical — only the flag's type changes), hosting `WeeklyDigestView(period: notificationScheduler.pendingDigestPeriod ?? .week)`.
- [ ] **Step 3: Period-aware screen.** `WeeklyDigestView` gains `let period: DigestPeriod` (default `.week` — the Settings `NavigationLink` and `weekly-digest-link` stay untouched): `.onAppear` compute switches to `DigestStats.compute(reports:questions:period:ending: Date())`; `.navigationTitle` → "Weekly/Monthly/Quarterly Digest"; narrative header "THIS \(period noun, uppercased)"; `deltaText` "vs last \(noun)". Nothing else changes — stats/narrative plumbing is period-agnostic after Task 3.
- [ ] **Step 4: Verify** — `swift test`, `xcodebuild build-for-testing`, run `DigestUITests` (the weekly template pin must stay green). Sim: seed a monthly day-31 schedule → pending request exists with the correct one-shot `nextTriggerDate()`; weekly schedule shows a repeating trigger; deliver a near-future test notification → tap opens the digest sheet titled for the right period; locked app defers it.
- [ ] **Step 5: Commit** — `git commit -m "feat: per-schedule digest notifications + period-aware digest screen"` → push.

### Task 5: App — digest schedule editor in notification settings

**Files:**
- Modify: `App/Sources/Settings/NotificationSettingsView.swift`
- Test: create `AppUITests/DigestScheduleUITests.swift`

- [ ] **Step 1: Failing UI test.** Launch `--mock-sensors --ui-testing --skip-onboarding`, navigate Settings → Notifications: (a) `digest-add-schedule` exists; (b) tap it, pick Monthly in `digest-cadence-picker`, confirm via `digest-add-confirm` → a row whose label contains "Monthly" appears; (c) toggle the row's `digest-schedule-toggle-<uuid>` off and back on (query by the row's position — the UUID is runtime-generated, so match `digest-schedule-toggle-` by BEGINSWITH predicate); (d) swipe-to-delete removes it. RED (no editor yet).
- [ ] **Step 2: Implement.** `@State private var digestSchedules: [DigestSchedule]` (seeded from prefs in `init`) replaces `digestEnabled`; section becomes:

```swift
private var digestSection: some View {
    Section {
        ForEach(sortedDigestSchedules) { schedule in
            Toggle(isOn: digestEnabledBinding(for: schedule)) {
                Text(scheduleLabel(schedule)) // "Weekly · Sunday · 7:00 PM"
                    .foregroundStyle(.white)
            }
            .accessibilityIdentifier("digest-schedule-toggle-\(schedule.id.uuidString)")
            .listRowBackground(Color.white.opacity(0.12))
        }
        .onDelete(perform: deleteDigestSchedules)

        Button {
            isAddingDigest = true
        } label: {
            Text("ADD A DIGEST…")
                .foregroundStyle(.white)
        }
        .disabled(digestSchedules.count >= 8) // budget-honesty cap (plan 40)
        .accessibilityIdentifier("digest-add-schedule")
        .listRowBackground(Color.white.opacity(0.12))
    } header: {
        sectionHeader("DIGESTS")
    } footer: {
        Text("Each digest is a notification that opens your digest for the period. Monthly and quarterly digests on short months fire on the month's last day. The weekly digest is always available from Settings.")
            .font(.caption)
            .foregroundStyle(.white.opacity(0.6))
            .listRowBackground(Color.clear)
    }
}
```

`scheduleLabel`: cadence word + day ("Sunday" via `calendar.weekdaySymbols`; "Day N" for monthly/quarterly) + localized time (`Date` from hour/minute through the existing time formatting conventions). Sort: cadence rank (weekly/monthly/quarterly) → day → hour/minute. Add-sheet mirrors `addTimeSheet` (NavigationStack, theme ZStack, medium detent, Cancel/Add): segmented `Picker` over cadences (`digest-cadence-picker`), then a weekday `Picker` OR a 1–31 `Picker` (`digest-day-picker`) with the clamping footnote, then the wheel `DatePicker` (`digest-time-picker`); Add (`digest-add-confirm`) appends an enabled `DigestSchedule(id: UUID(), …)`. Every mutation (`add`/`delete`/`toggle`) writes `prefs.digestSchedules = digestSchedules` and calls the existing `replan()`. Delete maps offsets through `sortedDigestSchedules` (the `deleteScheduledTimes` sorted-offsets pattern — same trap, same fix).
- [ ] **Step 3: Verify** — build-for-testing; `DigestScheduleUITests` GREEN; `DigestUITests` still green (Settings link untouched). Sim smoke at accessibility3: rows and the sheet remain hittable (the plan-29 discipline).
- [ ] **Step 4: Commit** — `git commit -m "feat: digest schedule editor — multiple schedules, cadence/day/time picker"` → push.

### Task 6: Wrap + self-review

- [ ] Full suites green (`swift test`, build-for-testing, UI suite at the merge gate); note the test-count delta from the previous plan's final report.
- [ ] Self-review the whole branch diff: (a) `DigestSchedule`/`DigestPeriod` have no `Date()`/`Locale.current` inside kit code; (b) `promptSource` body untouched — digests excluded by fall-through, pinned by test, never by new parser branches; (c) the `.week` path is byte-identical end to end (wrapper compute, template zero-report sentence, Settings entry, `weekly-digest-*` identifiers); (d) migration seeds today's exact constants and runs before the first replan; (e) removal-batch prefix discipline intact (no post-add removes); (f) budget cap arithmetic charges the digests actually added; (g) new identifiers all present; (h) plan-33 seam comment on `compute` in place.
- [ ] Completion note in this doc (what shipped, divergences, test counts). Whole-branch review follows (controller-driven). Close issue #45 via the implementation PR (`Closes #45`) when it merges; update Project 1 status.
