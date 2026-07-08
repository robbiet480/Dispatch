# Dispatch Plan 3: Home, Themes, Reports UI, Question Settings, Onboarding

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The app looks and navigates like Reporter: theme-colored home with hexagon + REPORT + AWAKE/ASLEEP (filing wake/sleep reports), 4-page onboarding, reports list with swipeable stats header + day grouping + detail + delete, settings (questions with reorder/toggle/add/edit, custom tokens, sensors, theme picker), all logic unit-tested in DispatchKit.

**Architecture:** DispatchKit gains Theme/ThemeStore, AwakeStore, ReportsOverview (day grouping in each report's own timezone + stats), and QuestionAdmin (reorder/create/update helpers) — all `swift test`-covered. The app target gains the themed Home, Onboarding, ReportsListView/ReportDetailView, SettingsView tree. Wake/sleep reports reuse SurveyFlowView with `kind: .wake/.sleep`.

**Tech Stack:** SwiftUI, SwiftData, Swift Testing, existing DispatchKit capture layer.

**Spec:** `docs/superpowers/specs/2026-07-07-reporter-clone-design.md` (§3 screens)

## Global Constraints

- Five themes with these exact colors (name: background hex): tomato `#FA5B3D`, teal `#20BEC6`, gray `#9B9B9B`, pink `#F268F1`, chartreuse `#CBD82B`. Theme selection persists (UserDefaults) and colors the whole app.
- Day grouping and the DAYS/AVG-PER-DAY stats use each report's OWN `timeZoneIdentifier`, not the device zone.
- AWAKE→ASLEEP presents a `.sleep`-kind survey; ASLEEP→AWAKE presents `.wake`-kind. Awake state persists. Cancelling the survey still flips the state (the toggle is authoritative; the report is optional), and this behavior is documented in code.
- Question reorder writes contiguous sortOrder values 0..n-1 (single pass, no duplicates).
- Accessibility identifiers added here are contract for UI tests: `home-hexagon`, `awake-toggle`, `reports-list-button`, `settings-button`, `reports-list`, `report-row`, `question-settings-list`, `add-question-button`, `onboarding-done`.
- Existing 41 DispatchKit tests + XCUITest stay green. Commit after each green cycle; push to origin main after every commit.
- Visual styling may be adjusted minimally where SwiftUI fights the letter of the code; structure, identifiers, copy, and logic are the contract.
- Never commit `/IMG_*.PNG` or `/reporter-export.json`.

---

### Task 1: DispatchKit — Theme, ThemeStore, AwakeStore

**Files:**
- Create: `Sources/DispatchKit/UIState/Theme.swift`
- Create: `Sources/DispatchKit/UIState/AwakeStore.swift`
- Test: `Tests/DispatchKitTests/UIStateTests.swift`

**Interfaces:**
- Produces:
  - `enum Theme: String, Codable, CaseIterable, Sendable { case tomato, teal, gray, pink, chartreuse }` with `var backgroundHex: String` (exact hexes above) and `var displayName: String` (capitalized rawValue).
  - `final class ThemeStore: @unchecked Sendable` — `init(defaults: UserDefaults = .standard)`, `var theme: Theme { get set }` persisted under key `"interface.theme"`, default `.tomato`.
  - `final class AwakeStore: @unchecked Sendable` — `init(defaults: UserDefaults = .standard)`, `var isAwake: Bool { get set }` persisted under `"awake.isAwake"`, default `true`; `func toggle() -> ReportKind` — flips state and returns the survey kind to file (`.sleep` when going to sleep, `.wake` when waking).

- [ ] **Step 1: Failing tests**

`Tests/DispatchKitTests/UIStateTests.swift`:

```swift
import Foundation
import Testing
@testable import DispatchKit

private func freshSuite() -> UserDefaults {
    UserDefaults(suiteName: "ui-test-\(UUID().uuidString)")!
}

@Test func themeDefaultsToTomatoAndPersists() {
    let defaults = freshSuite()
    let store = ThemeStore(defaults: defaults)
    #expect(store.theme == .tomato)
    store.theme = .teal
    #expect(ThemeStore(defaults: defaults).theme == .teal)
}

@Test func themeColorsAreExact() {
    #expect(Theme.tomato.backgroundHex == "#FA5B3D")
    #expect(Theme.teal.backgroundHex == "#20BEC6")
    #expect(Theme.gray.backgroundHex == "#9B9B9B")
    #expect(Theme.pink.backgroundHex == "#F268F1")
    #expect(Theme.chartreuse.backgroundHex == "#CBD82B")
    #expect(Theme.allCases.count == 5)
}

@Test func awakeToggleFilesCorrectKinds() {
    let store = AwakeStore(defaults: freshSuite())
    #expect(store.isAwake)
    #expect(store.toggle() == .sleep) // going to sleep files a sleep report
    #expect(!store.isAwake)
    #expect(store.toggle() == .wake)  // waking files a wake report
    #expect(store.isAwake)
}

@Test func awakeStatePersists() {
    let defaults = freshSuite()
    _ = AwakeStore(defaults: defaults).toggle()
    #expect(!AwakeStore(defaults: defaults).isAwake)
}
```

- [ ] **Step 2: Run to verify failure** — `swift test --filter UIStateTests` → FAIL (`cannot find 'ThemeStore'`)

- [ ] **Step 3: Implement**

`Sources/DispatchKit/UIState/Theme.swift`:

```swift
import Foundation

public enum Theme: String, Codable, CaseIterable, Sendable {
    case tomato, teal, gray, pink, chartreuse

    public var backgroundHex: String {
        switch self {
        case .tomato: "#FA5B3D"
        case .teal: "#20BEC6"
        case .gray: "#9B9B9B"
        case .pink: "#F268F1"
        case .chartreuse: "#CBD82B"
        }
    }

    public var displayName: String { rawValue.capitalized }
}

public final class ThemeStore: @unchecked Sendable {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public var theme: Theme {
        get { defaults.string(forKey: "interface.theme").flatMap(Theme.init(rawValue:)) ?? .tomato }
        set { defaults.set(newValue.rawValue, forKey: "interface.theme") }
    }
}
```

`Sources/DispatchKit/UIState/AwakeStore.swift`:

```swift
import Foundation

/// The manual AWAKE/ASLEEP toggle. Flipping it returns the kind of report
/// to offer (sleep report when going to sleep, wake report when waking).
/// The state change is authoritative even if the user cancels that survey.
public final class AwakeStore: @unchecked Sendable {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public var isAwake: Bool {
        get { defaults.object(forKey: "awake.isAwake") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "awake.isAwake") }
    }

    @discardableResult
    public func toggle() -> ReportKind {
        let kind: ReportKind = isAwake ? .sleep : .wake
        isAwake.toggle()
        return kind
    }
}
```

- [ ] **Step 4: Run to verify pass, full suite** — `swift test` → PASS
- [ ] **Step 5: Commit + push** — `git add -A && git commit -m "feat: theme and awake state stores" && git push origin main`

---

### Task 2: DispatchKit — ReportsOverview (day grouping + stats) and QuestionAdmin

**Files:**
- Create: `Sources/DispatchKit/UIState/ReportsOverview.swift`
- Create: `Sources/DispatchKit/UIState/QuestionAdmin.swift`
- Test: `Tests/DispatchKitTests/ReportsOverviewTests.swift`
- Test: `Tests/DispatchKitTests/QuestionAdminTests.swift`

**Interfaces:**
- Consumes: models, VocabularyBuilder outputs.
- Produces:
  - `struct DaySection: Identifiable { let id: String; let weekday: String; let dateLabel: String; let reports: [Report] }`
  - `enum ReportsOverview`:
    - `static func sections(from reports: [Report]) -> [DaySection]` — newest day first, reports within a day newest first; day computed in the report's own timezone; `weekday` like "THURSDAY", `dateLabel` like "DEC 13, 2018" (en_US_POSIX).
    - `static func stats(from reports: [Report]) -> (reports: Int, days: Int, avgPerDay: Double)` — days = distinct local days spanned by min..max report dates? NO: days = count of distinct days that have ≥1 report (matches the original's "36 DAYS" for 94 reports); avgPerDay = reports/days (0 when empty).
    - `static func vocabularyStats(tokens: Int, locations: [Report]) -> (tokens: Int, locations: Int, people: Int)` — NOT this; instead: `static func secondaryStats(reports: [Report], tokenCount: Int, personCount: Int) -> (tokens: Int, locations: Int, people: Int)` where locations = distinct `locationResponse.foursquareVenueId ?? text` values across responses.
  - `enum QuestionAdmin`:
    - `static func normalizeOrder(_ questions: [Question])` — rewrites sortOrder 0..n-1 following the array order given.
    - `static func move(_ questions: inout [Question], fromOffsets: IndexSet, toOffset: Int)` — array move + normalize.
    - `static func makeQuestion(prompt: String, type: QuestionType, choices: [String], placeholder: String?, kinds: [ReportKind], after questions: [Question]) -> Question` — sortOrder = max+1.

- [ ] **Step 1: Failing tests**

`Tests/DispatchKitTests/ReportsOverviewTests.swift`:

```swift
import Foundation
import Testing
@testable import DispatchKit

private func report(_ iso: String, tz: String) -> Report {
    let r = Report()
    let f = ISO8601DateFormatter()
    r.date = f.date(from: iso)!
    r.timeZoneIdentifier = tz
    return r
}

@Test func groupsByReportLocalDay() {
    // 23:30 New York on Dec 12 == 04:30 UTC Dec 13. Grouped by NY day.
    let late = report("2018-12-13T04:30:00Z", tz: "America/New_York")
    let noon = report("2018-12-12T17:00:00Z", tz: "America/New_York")
    let sections = ReportsOverview.sections(from: [late, noon])
    #expect(sections.count == 1)
    #expect(sections[0].weekday == "WEDNESDAY")
    #expect(sections[0].dateLabel == "DEC 12, 2018")
    #expect(sections[0].reports.first?.date == late.date) // newest first within day
}

@Test func sectionsNewestDayFirst() {
    let old = report("2017-11-16T18:00:00Z", tz: "America/Los_Angeles")
    let new = report("2018-12-13T18:00:00Z", tz: "America/Los_Angeles")
    let sections = ReportsOverview.sections(from: [old, new])
    #expect(sections.count == 2)
    #expect(sections[0].dateLabel == "DEC 13, 2018")
    #expect(sections[1].dateLabel == "NOV 16, 2017")
}

@Test func statsCountDistinctDaysWithReports() {
    let a = report("2018-12-12T17:00:00Z", tz: "UTC")
    let b = report("2018-12-12T18:00:00Z", tz: "UTC")
    let c = report("2018-12-14T18:00:00Z", tz: "UTC")
    let stats = ReportsOverview.stats(from: [a, b, c])
    #expect(stats.reports == 3)
    #expect(stats.days == 2)          // the empty Dec 13 doesn't count
    #expect(stats.avgPerDay == 1.5)
    let empty = ReportsOverview.stats(from: [])
    #expect(empty.reports == 0 && empty.days == 0 && empty.avgPerDay == 0)
}

@Test func secondaryStatsCountDistinctPlaces() {
    let r1 = report("2018-12-12T17:00:00Z", tz: "UTC")
    let resp1 = Response(); var loc1 = LocationAnswer(); loc1.text = "The Plaza"; loc1.foursquareVenueId = "v1"
    resp1.locationResponse = loc1; resp1.report = r1
    let r2 = report("2018-12-13T17:00:00Z", tz: "UTC")
    let resp2 = Response(); var loc2 = LocationAnswer(); loc2.text = "The Plaza again"; loc2.foursquareVenueId = "v1"
    resp2.locationResponse = loc2; resp2.report = r2
    r1.responses = [resp1]; r2.responses = [resp2]
    let stats = ReportsOverview.secondaryStats(reports: [r1, r2], tokenCount: 41, personCount: 18)
    #expect(stats.tokens == 41)
    #expect(stats.locations == 1) // same venue id
    #expect(stats.people == 18)
}
```

`Tests/DispatchKitTests/QuestionAdminTests.swift`:

```swift
import Foundation
import Testing
@testable import DispatchKit

private func q(_ id: String, sort: Int) -> Question {
    let question = Question()
    question.uniqueIdentifier = id
    question.sortOrder = sort
    return question
}

@Test func moveNormalizesContiguously() {
    var questions = [q("a", sort: 0), q("b", sort: 1), q("c", sort: 2)]
    QuestionAdmin.move(&questions, fromOffsets: IndexSet(integer: 2), toOffset: 0)
    #expect(questions.map(\.uniqueIdentifier) == ["c", "a", "b"])
    #expect(questions.map(\.sortOrder) == [0, 1, 2])
}

@Test func makeQuestionAppendsAfterMax() {
    let existing = [q("a", sort: 0), q("b", sort: 7)]
    let made = QuestionAdmin.makeQuestion(prompt: "New?", type: .yesNo, choices: [],
                                          placeholder: nil, kinds: [.regular], after: existing)
    #expect(made.sortOrder == 8)
    #expect(made.prompt == "New?")
    #expect(made.type == .yesNo)
    #expect(made.reportKinds == [.regular])
}
```

- [ ] **Step 2: RED** — `swift test --filter "ReportsOverviewTests|QuestionAdminTests"` → FAIL
- [ ] **Step 3: Implement**

`Sources/DispatchKit/UIState/ReportsOverview.swift`:

```swift
import Foundation

public struct DaySection: Identifiable, Sendable {
    public let id: String
    public let weekday: String
    public let dateLabel: String
    public let reports: [Report]
}

public enum ReportsOverview {
    private static func localDayKey(_ report: Report) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: report.timeZoneIdentifier) ?? .gmt
        let comps = calendar.dateComponents([.year, .month, .day], from: report.date)
        return String(format: "%04d-%02d-%02d", comps.year!, comps.month!, comps.day!)
    }

    private static func labels(_ report: Report) -> (weekday: String, date: String) {
        let tz = TimeZone(identifier: report.timeZoneIdentifier) ?? .gmt
        let weekdayFormatter = DateFormatter()
        weekdayFormatter.locale = Locale(identifier: "en_US_POSIX")
        weekdayFormatter.timeZone = tz
        weekdayFormatter.dateFormat = "EEEE"
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = tz
        dateFormatter.dateFormat = "MMM d, yyyy"
        return (weekdayFormatter.string(from: report.date).uppercased(),
                dateFormatter.string(from: report.date).uppercased())
    }

    public static func sections(from reports: [Report]) -> [DaySection] {
        let grouped = Dictionary(grouping: reports, by: localDayKey)
        return grouped
            .sorted { $0.key > $1.key }
            .map { key, dayReports in
                let sorted = dayReports.sorted { $0.date > $1.date }
                let label = labels(sorted[0])
                return DaySection(id: key, weekday: label.weekday,
                                  dateLabel: label.date, reports: sorted)
            }
    }

    public static func stats(from reports: [Report]) -> (reports: Int, days: Int, avgPerDay: Double) {
        guard !reports.isEmpty else { return (0, 0, 0) }
        let days = Set(reports.map(localDayKey)).count
        return (reports.count, days, Double(reports.count) / Double(days))
    }

    public static func secondaryStats(reports: [Report], tokenCount: Int, personCount: Int)
        -> (tokens: Int, locations: Int, people: Int) {
        var places = Set<String>()
        for report in reports {
            for response in report.responses {
                if let location = response.locationResponse {
                    if let venue = location.foursquareVenueId {
                        places.insert("venue:\(venue)")
                    } else if let text = location.text, !text.isEmpty {
                        places.insert("text:\(text)")
                    }
                }
            }
        }
        return (tokenCount, places.count, personCount)
    }
}
```

`Sources/DispatchKit/UIState/QuestionAdmin.swift`:

```swift
import Foundation

public enum QuestionAdmin {
    /// Rewrites sortOrder to 0..n-1 following the given array order.
    public static func normalizeOrder(_ questions: [Question]) {
        for (index, question) in questions.enumerated() {
            question.sortOrder = index
        }
    }

    public static func move(_ questions: inout [Question], fromOffsets: IndexSet, toOffset: Int) {
        questions.move(fromOffsets: fromOffsets, toOffset: toOffset)
        normalizeOrder(questions)
    }

    public static func makeQuestion(prompt: String, type: QuestionType, choices: [String],
                                    placeholder: String?, kinds: [ReportKind],
                                    after questions: [Question]) -> Question {
        let question = Question()
        question.prompt = prompt
        question.type = type
        question.choices = choices
        question.placeholderString = placeholder
        question.reportKinds = kinds
        question.sortOrder = (questions.map(\.sortOrder).max() ?? -1) + 1
        return question
    }
}
```

- [ ] **Step 4: GREEN + full suite** — `swift test` → PASS
- [ ] **Step 5: Commit + push** — `git commit -m "feat: reports overview stats and question admin" && git push origin main`

---

### Task 3: App — themes everywhere, Home screen, onboarding

**Files:**
- Create: `App/Sources/ThemeColor.swift`
- Create: `App/Sources/HomeView.swift`
- Create: `App/Sources/OnboardingView.swift`
- Modify: `App/Sources/ContentView.swift` (becomes a thin router: onboarding → HomeView)
- Modify: `App/Sources/Survey/SurveyFlowView.swift` (background uses theme color instead of the hardcoded tomato)

**Interfaces:**
- Consumes: Theme/ThemeStore/AwakeStore (Task 1), SurveyFlowView(kind:trigger:).
- Produces: `ThemeColor.color(_ theme: Theme) -> Color` (hex parser); HomeView with identifiers `home-hexagon`, `awake-toggle`, `reports-list-button`, `settings-button`, `report-button`, `report-count` preserved; OnboardingView with `onboarding-done`, shown when `UserDefaults` `"onboarding.completed"` is false.

**Requirements (structure is contract; fine styling is not):**
- `ThemeColor`: parse `#RRGGBB` → SwiftUI Color; expose `Color.themeBackground(_:)` helper.
- HomeView: full-bleed theme background; centered hexagon (SF Symbol `hexagon.fill` at ~96pt, white 35% opacity, overlaid text "Edit your questions" when `reports.isEmpty` that navigates to question settings — identifier `home-hexagon`); top bar: left `reports-list-button` (list icon → ReportsListView placeholder navigation destination until Task 4 replaces it — use a `Text("Reports")` destination now), right `settings-button` (gear → SettingsView from Task 5 — use `Text("Settings")` placeholder now); bottom bar: left `REPORT` button (existing behavior, presents SurveyFlowView `.regular`); right `AWAKE`/`ASLEEP` labeled toggle (identifier `awake-toggle`) that calls `AwakeStore.toggle()` and presents SurveyFlowView with the returned kind (trigger `.manual`); report count label retains `report-count`.
- Onboarding: 4 pages in a paged TabView, each a solid color (teal, pink, chartreuse, gray) with a headline + body copy matching the original's intent in YOUR OWN words (titles exactly: "Snapshot your life.", "Control your data.", "Embrace your sensors.", "Make it yours." — these short phrases are used verbatim; body copy paraphrased, 2–3 sentences each, mentioning randomly timed surveys / local-only data / sensor permissions / editable questions); DONE on the last page (identifier `onboarding-done`) sets `"onboarding.completed"` and dismisses. A simple triangle-motif decoration drawn with `Canvas` or SF Symbols is welcome but optional.
- SurveyFlowView background: `.background(Color.themeBackground(ThemeStore().theme).opacity(0.9))` replacing the hardcoded color (exact styling latitude allowed).

**Verification:**
- `xcodegen generate && xcodebuild … build` → BUILD SUCCEEDED
- `swift test` → 45+ green (unchanged kit)
- `xcodebuild … test` (XCUITest) → TEST SUCCEEDED. The existing UI test must still pass; if onboarding now blocks it, add `"--skip-onboarding"` launch-argument handling (sets the flag) in DispatchApp/ContentView and pass it in the existing UI test — document this in the report.

- [ ] Steps: implement → build → run both test suites → commit `feat: themes, home screen, onboarding` → push

---

### Task 4: App — reports list, stats header, detail, delete

**Files:**
- Create: `App/Sources/Reports/ReportsListView.swift`
- Create: `App/Sources/Reports/ReportDetailView.swift`
- Modify: `App/Sources/HomeView.swift` (wire real destination)

**Interfaces:**
- Consumes: ReportsOverview (Task 2), vocabulary entities, theme color.
- Produces: ReportsListView (identifier `reports-list`) and rows (`report-row`).

**Requirements:**
- Stats header: horizontally paged (TabView `.page`) two pages — page 1: `N REPORTS | N DAYS | N.N AVG/DAY`; page 2: `N TOKENS | N LOCATIONS | N PEOPLE` (token/person counts = TokenEntity/PersonEntity fetch counts; locations via `ReportsOverview.secondaryStats`). Large number over small caps label, three columns, separators — like the original.
- Below: `List` of `DaySection`s — section header `WEEKDAY … DEC 13, 2018` (weekday left, date right); rows: time `HH:mm` in the report's own timezone + place line (`placemark.locality, administrativeArea` when present, else kind/trigger description); wake/sleep rows get a moon/sun SF Symbol. Row identifier `report-row`. Swipe-to-delete deletes the Report (cascade removes responses) and saves.
- ReportDetailView: sensor summary rows (place, weather condition + tempF, altitude in feet, audio display dB + label, steps/flights from health, battery %, focus, connection) — only rows with data; then each response: prompt caps header + rendered answer (tokens joined " · ", options joined ", ", note text, numeric, location text); footer: kind, trigger, timezone identifier, exact timestamp.
- All screens themed (theme background, white-ish text like Home).

**Verification:** build + both suites green (existing UI test unaffected). Commit `feat: reports list and detail` → push.

---

### Task 5: App — settings tree: questions, tokens, sensors, interface

**Files:**
- Create: `App/Sources/Settings/SettingsView.swift`
- Create: `App/Sources/Settings/QuestionSettingsView.swift`
- Create: `App/Sources/Settings/QuestionEditorView.swift`
- Create: `App/Sources/Settings/CustomTokensView.swift`
- Create: `App/Sources/Settings/SensorSettingsView.swift`
- Modify: `App/Sources/HomeView.swift` (wire real SettingsView)

**Interfaces:**
- Consumes: QuestionAdmin, SensorSettings, ThemeStore, vocabulary entities.
- Produces: the settings tree; identifiers `question-settings-list`, `add-question-button`.

**Requirements:**
- SettingsView sections mirroring the original: SCHEDULE (Notifications row — placeholder `Text("Coming in Plan 4")` destination), SURVEY (Questions, Sensors), DATA (Export row placeholder "Coming soon", iCloud row placeholder), INTERFACE (5 theme swatch capsules in an HStack; tapping selects + persists via ThemeStore; selected shows a checkmark), ABOUT (app name, version from bundle, link-free credit line to the original Reporter app as inspiration).
- QuestionSettingsView: list (identifier `question-settings-list`) of all questions sorted by sortOrder — each row: prompt caps + subtitle `"<Type> – N responses"` (response count = fetch count of Response matching questionIdentifier OR prompt) + trailing enable Toggle writing `isEnabled`; `EditButton`-driven reorder calling `QuestionAdmin.move` + save; swipe-to-delete deletes the Question (responses stay; they join by prompt/identifier); `ADD A QUESTION…` row (identifier `add-question-button`) → QuestionEditorView.
- QuestionEditorView (add + edit): prompt TextField, type Picker (7 types; type locked when editing an existing question with responses), choices editor (list of TextFields + add/remove) shown only for multipleChoice, placeholder TextField, report-kinds multi-select (regular/wake/sleep toggles, at least one required), Save → insert via `QuestionAdmin.makeQuestion` or update in place + `try? context.save()`.
- CustomTokensView: "N TOKENS" header; list of TokenEntity sorted by text — text + "Used N times in M questions"; swipe-to-delete removes the TokenEntity (vocab only, not responses).
- SensorSettingsView: SENSORS section — a Toggle per SensorKind with display names matching the original (Location/Weather/Elevation/Photos/Audio + the health ones + Battery/Connection/Focus), bound to `SensorSettings`; UNITS section — temperature (F/C) and length (feet/meters) pickers bound to SensorSettings.
- Everything themed.

**Verification:** build + both suites. Commit `feat: settings tree with question management` → push.

---

### Task 6: UI test additions + Plan 3 wrap

**Files:**
- Modify: `AppUITests/SurveyFlowUITests.swift` (or new file `AppUITests/NavigationUITests.swift`)

**Requirements:**
- New UI test `testNavigationAndAwakeToggle`: launch with `--mock-sensors --skip-onboarding`; open reports list (assert `reports-list` exists), back; open settings, open questions (assert `question-settings-list` exists), back out; tap `awake-toggle` → survey appears (`survey-cancel` exists) → cancel; assert the toggle label changed (AWAKE→ASLEEP or the accessibility label/value reflects state).
- Keep the original flow test green.

**Verification:** `xcodebuild … test` → TEST SUCCEEDED (both tests), `swift test` green. Commit `test: navigation and awake-toggle UI coverage` → push.

---

## Notes for the controller

- Tasks 3–5 are UI-heavy with declared latitude; reviewers should gate on structure/identifiers/logic, not pixel styling.
- After Task 6, run the whole-branch review, then proceed to Plan 4.
