# Dispatch Plan 29: Reporter home-screen visual parity

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** make Dispatch's home screen read like the original Reporter home (coral reference screenshot): centered decorative app icon in the top bar, left-aligned "+ Filter Visualizations…" row with a hairline divider, small uppercase left-aligned question heading, an edge-to-edge chart that fills everything down to a reserved bottom strip, and a bottom toolbar of REPORT / plain page dots / an AWAKE labeled pill toggle. Visual/layout parity only — every existing behavior (filter sheet, report button, awake-toggle semantics, page count, page swiping) is preserved exactly.

**Architecture:** all view-layer, app target only. `App/Sources/HomeView.swift` (top bar, filter row, bottom toolbar, pager chrome) and `App/Sources/Visualizations/QuestionVisualizationView.swift` (heading, full-bleed content, stacked proportional blocks, in-chart labels). DispatchKit (`VisualizationData`, `QuestionVisualization` — the plan 5/plan 17 viz pipeline) is NOT touched: the same `QuestionVisualization` cases render with new styling. Page dots move OUT of the TabView overlay (`indexDisplayMode: .never`) into a custom plain-dots view inside the reserved bottom strip, which kills the dots-overlap-content bug class permanently.

**Tech Stack:** SwiftUI (TabView `.page` style, GeometryReader, Capsule/Circle), Swift Charts (axis configuration), asset catalog (one new decorative image), XCUITest.

## Design decisions (decide + log)

- **Top-bar icon is decorative.** A new `HomeGlyph` image set in `App/Assets.xcassets` (downscaled from `AppIcon.appiconset/icon-1024.png`, rendered ~30pt with `RoundedRectangle(cornerRadius: 7)` clip), centered between the list and gear buttons. `Image` (not `Button`), `.accessibilityHidden(true)` — in the original it's decorative; we match that. The app icon asset itself can't be loaded via `Image("AppIcon")`, hence the separate image set.
- **Filter row replaces the centered pill:** left-aligned `Image(systemName: "plus.square")` glyph + text in `.white.opacity(0.7)`, full-width tap target via `.contentShape(Rectangle())`, and a 0.5pt `Color.white.opacity(0.25)` hairline divider below. The identifier `viz-filter-button` and the existing count-aware label strings ("Filter Visualizations…" / "1 filter active" / "N filters active") are kept verbatim — the singular/plural comment in the current code explains why they're literal strings; don't regress that.
- **`report-count` relocates into the filter row's trailing edge** (small `.caption`, `.white.opacity(0.6)`), so the chart can own the full height below the heading. The label TEXT stays exactly `"\(reports.count) reports"` and the identifier stays `report-count` — ten UI test files use it as the home sentinel and compare `.label` before/after saves. Empty state (hexagon + count) is unchanged.
- **Question heading:** `question.prompt` with `.textCase(.uppercase)`, `.font(.footnote.weight(.bold))`, `.kerning(1.2)`, left-aligned, white. CRITICAL: add `.accessibilityLabel(question.prompt)` (original casing) so `app.staticTexts["Are you working?"]` in `NavigationUITests.testVisualizationFilterHidesToggledOffQuestionsPage` keeps matching (XCUI matches label; `.textCase` would otherwise change the rendered label to "ARE YOU WORKING?") and VoiceOver isn't shouted at.
- **Chart is full-bleed:** page content horizontal inset drops 20pt → 8pt; the vertical span runs from under the heading to the bottom of the page area. The reserved strip lives OUTSIDE the pager (see next), so pages need no dot-avoidance padding at all.
- **Reserved bottom strip replaces the dot pill — coordination note:** a pager-dots overlap fix landed/lands on main immediately before this plan (46pt `.padding(.bottom)` inside `QuestionVisualizationView` + `indexViewStyle(.page(backgroundDisplayMode: .always))` dark pill; an in-flight `AppUITests/TempVizCollisionTests.swift` verifies it). This plan REPLACES that approach: `indexDisplayMode: .never` on the TabView, custom plain dots centered in the bottom toolbar, and the 46pt padding reverts to 12pt. At execution time, diff `QuestionVisualizationView.swift` and `HomeView.swift` against whatever actually merged and absorb it; delete `TempVizCollisionTests.swift` (it documents itself as temporary).
- **Plain dots spec:** 7pt circles, 9pt spacing; current page `Color.white`, others `.white.opacity(0.35)`; driven by `visibleQuestions` + `selectedQuestionID`. `.accessibilityHidden(true)` (the pager itself remains VoiceOver-adjustable) and `accessibilityIdentifier("page-dots")` on the container for the new UI test. No background pill of any kind.
- **AWAKE pill toggle:** a `Button` rendering a `Capsule().fill(Color.white.opacity(0.18))` containing the state text + a white `Circle()` knob. Awake: label "AWAKE" leading, knob trailing. Asleep: knob leading, label "ASLEEP" trailing (the original slides the knob and relabels). `withAnimation(.snappy)` on toggle. Identifier stays `awake-toggle`; set `.accessibilityLabel(awakeStore.isAwake ? "AWAKE" : "ASLEEP")` explicitly so `NavigationUITests.testNavigationAndAwakeToggle`'s `awakeToggle.label` assertions (`== "AWAKE" || == "ASLEEP"`, flips after toggle) keep passing. Semantics untouched: toggle → replan → survey request, authoritative even if the survey is cancelled.
- **Stacked proportional blocks (the marquee change):** `OptionSharesBarsView` flips from side-by-side full-height columns to VERTICALLY STACKED full-width blocks (`VStack(spacing: 2)`), each block's height = its share of the available height (min 28pt). Option label bottom-LEFT inside the block, percentage bottom-RIGHT inside, white semibold, matching the reference (No 68% lighter block above Yes 32% darker block). Per-block a11y element ("No, 68 percent") and `viz-option-shares` identifier are preserved.
- **Block shading:** blocks sit ON the theme-colored background, so index 0 must differ from it: `tint(0)` = theme color blended 8% toward white; each subsequent index blends 10% × index toward black from the base. Extend the existing `blended(withBlack:)` helper with `blended(withWhite:)`.
- **Theme/dark adaptation:** Dispatch's home has no separate dark mode — the theme color IS the surface, and all home text is white by existing convention. All five shipped themes from `ThemeStore` must be visually verified after the block-shading change: **tomato `#FA5B3D`, teal `#20BEC6`, gray `#9B9B9B`, pink `#F268F1`, chartreuse `#CBD82B`**. Chartreuse and gray are the contrast risks for white text; the 8% lighten is capped there — if white-on-lightened-chartreuse is illegible in the sim, drop the lighten to 0% for index 0 and start darkening from index 1 for ALL themes (uniform rule, no per-theme forks) and record the outcome in a code comment. White text stays — consistency with every other home element on those same backgrounds.
- **Numeric/scale/time charts go full-bleed with in-chart labels:** hide the leading Y-axis gutter (`.chartYAxis(.hidden)`), keep X-axis date labels (they render inside the plot's bottom edge, no side gutter), annotate the average `RuleMark` inline via `.annotation(position: .top, alignment: .trailing)` with "AVG N" instead of the external "Average: N" headline, and overlay min/max value labels inside the plot's corners. The VoiceOver summary (`accessibilityValue`) already carries count/range/latest/average and is kept verbatim.
- **Token/places/notes pages** keep their current internal layouts (they already match Reporter's "N ANSWERS" pattern from plan 11/17) but inherit the new heading style and 8pt inset — no other change; scrollable content now ends at the reserved strip instead of under floating dots.
- **Merge-order dependency — plan 27 (iPad):** the `plan-27-ipad-layout` PR refactors `HomeView` (extracted `visualizationPager`/`visualizationGrid`, `isEmbedded`, `toggleSidebar`, size-class switch). **This plan executes AFTER plan 27's PR merges** and adapts to whatever landed: the parity restyle applies to the compact pager path plus shared chrome (top bar, filter row, bottom toolbar); the iPad grid keeps its card layout but inherits the restyled `QuestionVisualizationView` internals; plain dots render only in the pager path. A next-notification hero change in Settings is also in flight — unrelated, no home overlap, ignore it.

## Global Constraints

- **Scope: home screen + visualization page rendering ONLY.** No changes to survey flow, settings, watch, widgets, or any data/kit code. `Sources/DispatchKit/` is untouched (`swift test` must pass unchanged — zero kit diffs).
- **Every existing behavior survives:** filter sheet + active-count label, REPORT button, awake-toggle semantics (replan + survey request), page count and swipe order, empty-state hexagon, app-lock sheet gating. This is visual parity, not feature work.
- **Accessibility identifiers are frozen:** `reports-list-button`, `settings-button`, `viz-filter-button`, `report-count`, `report-button`, `awake-toggle`, `home-hexagon`, `viz-option-shares`, `viz-numeric-series`, `viz-token-frequency`, `viz-ranked-rows`, `viz-recent-notes`. They are load-bearing across the whole UI suite.
- **Charts must respect the reserved bottom strip** — content and the strip are siblings, never overlapped. The dot-pill overlap fix on main is absorbed/reverted per the design decision above; re-diff against main at execution time before touching either file.
- Execute after plan 27's PR merges; `git pull --rebase` before starting/pushing. Work on branch `plan-29-home-parity`, PR to main. Do NOT bump the build number.
- Verification per task: `xcodebuild build-for-testing` + targeted UI test(s); full UI suite at the merge gate. `swift test` once at start and end (should be a no-op — proves kit untouched).
- **UI tests that touch home and MUST be re-run (and updated only as noted):**
  - `AppUITests/NavigationUITests.swift` — `testNavigationAndAwakeToggle` (awake label assertions; protected by the explicit a11y label), `testVisualizationFilterHidesToggledOffQuestionsPage` (`viz-filter-button`, heading text "Are you working?"; protected by the heading a11y label).
  - `AppUITests/TempVizCollisionTests.swift` — DELETE (superseded by the reserved strip + new parity test).
  - `AppUITests/AccessibilityUITests.swift` — `testSurveyFlowUsableAtAccessibility3TextSize` (report-button/report-count hittability with the new bottom bar at accessibility3; the pill and dots must not crowd it out).
  - `AppUITests/ScreenshotTests.swift` — `01-home-viz` capture reflects the new layout; re-run, no assertion change expected.
  - Sentinel-only users of `report-count`/`report-button`/`settings-button` (no edits expected, must stay green): `SurveyFlowUITests`, `DeleteAllDataUITests`, `DigestUITests`, `FocusFilterUITests`, `AppLockUITests`, `CatalogUITests`, `PeopleUITests`, `InsightsUITests`, `WebhookUITests`, `BackupSettingsUITests`.
  - NEW: `AppUITests/HomeParityUITests.swift` (Task 4) — structural non-overlap + chrome-presence assertions.

---

### Task 1: Top bar icon + filter row + relocated report count

**Files:**
- Modify: `App/Sources/HomeView.swift`, `App/Assets.xcassets` (new `HomeGlyph.imageset` from `AppIcon.appiconset/icon-1024.png`)

**Interfaces (produced):** `HomeView.filterBar` (replaces `filterPill`) hosting `viz-filter-button` + `report-count`.

- [x] **Step 1: Failing test first** — extend the new `HomeParityUITests` shell (create the file now with just this test): launch with `--mock-sensors --ui-testing --skip-onboarding --demo-data`, assert `app.images["home-glyph"].waitForExistence` and that `viz-filter-button`'s frame `minX` is within 24pt of the screen's leading edge (left-aligned, not centered). Run — RED.
- [x] **Step 2: Asset.** Add `HomeGlyph.imageset` (1x/2x/3x downscales of icon-1024.png via `sips`; or a single 180px universal). Commit the PNGs, not a build step.
- [x] **Step 3: Implement.** Top bar gains the centered glyph; filter pill becomes the left-aligned row:

```swift
private var topBar: some View {
    HStack {
        NavigationLink(destination: ReportsListView()) { /* unchanged list.bullet */ }
            .accessibilityIdentifier("reports-list-button")
        Spacer()
        Image("HomeGlyph")
            .resizable()
            .frame(width: 30, height: 30)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .accessibilityHidden(true)
            .accessibilityIdentifier("home-glyph")
        Spacer()
        NavigationLink(destination: SettingsView()) { /* unchanged gearshape */ }
            .accessibilityIdentifier("settings-button")
    }
    .padding(.horizontal)
    .padding(.vertical, 8)
}

private var filterBar: some View {
    let activeCount = filterStore.criteria.count
    return VStack(spacing: 8) {
        HStack(spacing: 8) {
            Button {
                isShowingFilter = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus.square")
                        .font(.subheadline)
                    Text(activeCount == 0
                         ? "Filter Visualizations…"
                         : (activeCount == 1 ? "1 filter active" : "\(activeCount) filters active"))
                        .font(.caption)
                        .fontWeight(.semibold)
                }
                .foregroundStyle(.white.opacity(0.7))
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .accessibilityIdentifier("viz-filter-button")

            Text("\(reports.count) reports")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))
                .accessibilityIdentifier("report-count")
        }
        .padding(.horizontal)
        Rectangle()
            .fill(Color.white.opacity(0.25))
            .frame(height: 0.5)
    }
    .padding(.bottom, 4)
}
```

Remove the old standalone `Text("\(reports.count) reports")` from the non-empty branch of `body` (the empty-state copy stays). Note `home-glyph` needs `.accessibilityHidden(true)` AND to remain queryable — if hidden makes `app.images["home-glyph"]` unfindable in Step 1's test, assert via `app.otherElements`/existence of the top bar instead and keep the hidden trait (decorative wins over testability; record which way it went).
- [x] **Step 4:** `xcodebuild build-for-testing`; run the new test — GREEN. Run `NavigationUITests` + `SurveyFlowUITests` (report-count sentinel moved containers).
- [x] **Step 5: Commit** — `git commit -m "feat: home top-bar glyph + left-aligned filter row (plan 29)"` → push.

### Task 2: Heading restyle + full-bleed page layout (absorb the dots-overlap fix)

**Files:**
- Modify: `App/Sources/Visualizations/QuestionVisualizationView.swift`

- [x] **Step 1:** Diff `QuestionVisualizationView.swift` against merged main — identify the landed dot-pill padding (expected: `.padding(.bottom, 46)` + comment). This task removes it because Task 3 moves the dots out of the overlay entirely (tasks 2+3 land as one push if a green intermediate state isn't achievable — see Task 3 Step 1).
- [x] **Step 2: Implement heading + insets:**

```swift
var body: some View {
    VStack(alignment: .leading, spacing: 0) {
        Text(question.prompt)
            .textCase(.uppercase)
            .font(.footnote.weight(.bold))
            .kerning(1.2)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.top, 10)
            .padding(.bottom, 12)
            // XCUI + VoiceOver read the label, not the rendered glyphs:
            // keep the original casing so NavigationUITests' staticTexts
            // ["Are you working?"] queries still match (plan 29).
            .accessibilityLabel(question.prompt)

        content
            .padding(.horizontal, 8)
            // Dots no longer overlay pages (plan 29 reserved strip) —
            // just breathing room above the toolbar.
            .padding(.bottom, 8)
    }
}
```

- [x] **Step 3:** Build; run `NavigationUITests.testVisualizationFilterHidesToggledOffQuestionsPage` — the prompt query must still pass (proves the a11y-label decision).
- [x] **Step 4: Commit** — `git commit -m "feat: uppercase left heading + full-bleed viz pages (plan 29)"` → push (or fold into Task 3's commit if dots-off is needed for a green run).

### Task 3: Bottom toolbar — plain dots strip + AWAKE pill (kills the overlap class)

**Files:**
- Modify: `App/Sources/HomeView.swift`
- Delete: `AppUITests/TempVizCollisionTests.swift`

**Interfaces (produced):** `PlainPageDots` view; `AwakePillToggle` view (both file-private in HomeView.swift — extract only if reused later).

- [x] **Step 1: Failing test** — add to `HomeParityUITests`: with demo data, (a) `awake-toggle` exists with label "AWAKE" or "ASLEEP"; (b) `page-dots` exists; (c) NON-OVERLAP: `viz-option-shares` (first demo page is multiple-choice) frame `maxY` ≤ `report-button` frame `minY` (chart never enters the strip). RED (no `page-dots` yet).
- [x] **Step 2: Implement.** Pager chrome off, dots into the toolbar:

```swift
// in visualizationPager (post-plan-27 name) — was .always/.always:
.tabViewStyle(.page(indexDisplayMode: .never))
// delete the .indexViewStyle line entirely

private var bottomBar: some View {
    HStack {
        Button("REPORT") {
            surveyPresenter.request = SurveyRequest(kind: .regular, trigger: .manual)
        }
        .font(.headline)
        .foregroundStyle(.white)
        .accessibilityIdentifier("report-button")

        Spacer()
        if !visibleQuestions.isEmpty && !reports.isEmpty {
            PlainPageDots(
                count: visibleQuestions.count,
                currentIndex: visibleQuestions.firstIndex { $0.uniqueIdentifier == selectedQuestionID } ?? 0
            )
        }
        Spacer()

        AwakePillToggle(isAwake: awakeStore.isAwake) {
            let kind = awakeStore.toggle()   // semantics verbatim from today
            scheduler.replan(prefs: notificationPrefs, awakeStore: awakeStore)
            surveyPresenter.request = SurveyRequest(kind: kind, trigger: .manual)
        }
    }
    .padding(.horizontal)
    .frame(height: 52)   // the reserved strip: fixed, never overlapped
}

private struct PlainPageDots: View {
    let count: Int
    let currentIndex: Int
    var body: some View {
        HStack(spacing: 9) {
            ForEach(0..<count, id: \.self) { index in
                Circle()
                    .fill(index == currentIndex ? Color.white : Color.white.opacity(0.35))
                    .frame(width: 7, height: 7)
            }
        }
        .accessibilityIdentifier("page-dots")
        .accessibilityHidden(true)
    }
}

private struct AwakePillToggle: View {
    let isAwake: Bool
    let action: () -> Void
    var body: some View {
        Button {
            withAnimation(.snappy) { action() }
        } label: {
            HStack(spacing: 8) {
                if !isAwake { knob }
                Text(isAwake ? "AWAKE" : "ASLEEP")
                    .font(.caption.weight(.bold))
                    .kerning(0.5)
                    .foregroundStyle(.white)
                if isAwake { knob }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.white.opacity(0.18)))
        }
        .accessibilityIdentifier("awake-toggle")
        .accessibilityLabel(isAwake ? "AWAKE" : "ASLEEP")   // NavigationUITests reads .label
    }
    private var knob: some View {
        Circle().fill(Color.white).frame(width: 18, height: 18)
    }
}
```

Symmetric `Spacer()`s keep the dots visually centered; if REPORT vs the pill width-imbalance visibly off-centers them, switch to an `.overlay(alignment: .center)` on the strip — decide in the sim.
- [x] **Step 3:** Delete `AppUITests/TempVizCollisionTests.swift` (self-described temporary; superseded by the non-overlap assertion in Step 1).
- [x] **Step 4:** Build; run `HomeParityUITests` (GREEN), `NavigationUITests.testNavigationAndAwakeToggle` (label flip still passes), `AccessibilityUITests` (strip controls hittable at accessibility3 — if the fixed 52pt strip clips at that size, swap `frame(height:)` for `frame(minHeight: 52)` and re-run).
- [x] **Step 5: Commit** — `git commit -m "feat: reserved bottom strip — plain dots + AWAKE pill toggle (plan 29)"` → push.

### Task 4: Stacked proportional blocks

**Files:**
- Modify: `App/Sources/Visualizations/QuestionVisualizationView.swift` (`OptionSharesBarsView`, `Color.blended`)

- [x] **Step 1: Failing test** — `HomeParityUITests`: on the demo yes/no page, each option's a11y element ("Yes, …percent"/"No, …percent") still exists (regression guard), and the two blocks' frames stack vertically (frame `minX` equal, differing `minY`) instead of sitting side by side. RED against today's column layout.
- [x] **Step 2: Implement** — columns → stacked full-width blocks:

```swift
struct OptionSharesBarsView: View {
    let shares: [(option: String, share: Double)]
    let theme: Theme

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 2) {
                ForEach(Array(shares.enumerated()), id: \.offset) { index, entry in
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(tint(for: index))
                        HStack {
                            Text(entry.option)
                                .lineLimit(2)
                            Spacer()
                            Text(percentString(entry.share))
                                .lineLimit(1)
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .minimumScaleFactor(0.5)   // a11y sizes must shrink, not clip
                        .padding(10)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                    }
                    .frame(height: max(proxy.size.height * entry.share, 28))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(entry.option), \(Int((entry.share * 100).rounded())) percent")
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
        }
        .accessibilityIdentifier("viz-option-shares")
    }

    /// Index 0 lightens 8% off the theme background so the first block reads
    /// against it; each later block darkens 10% per index (plan 29 shading).
    private func tint(for index: Int) -> Color {
        let base = ThemeColor.color(theme)
        return index == 0
            ? base.blended(withWhite: 0.08)
            : base.blended(withBlack: Double(index) * 0.10)
    }

    private func percentString(_ share: Double) -> String {
        "\(Int((share * 100).rounded()))%"
    }
}
```

`blended(withWhite:)` joins the existing private `Color.blended(withBlack:)` extension (same resolve-RGB pattern, blending toward 1.0).
- [x] **Step 3: Theme contrast pass** — in the sim, cycle all five `ThemeStore` themes (tomato, teal, gray, pink, chartreuse) on the yes/no page. Chartreuse + gray are the flagged risks: if white text on the index-0 lightened block is illegible on either, apply the uniform fallback from the design log (no lighten; darken from index 1) and record the outcome in the `tint(for:)` comment.
- [x] **Step 4:** Build; run `HomeParityUITests` (GREEN) + `ScreenshotTests` (refresh `01-home-viz`).
- [x] **Step 5: Commit** — `git commit -m "feat: Reporter-style stacked proportional blocks (plan 29)"` → push.

### Task 5: Numeric chart full-bleed + in-chart labels; iPad grid + suite gate

**Files:**
- Modify: `App/Sources/Visualizations/QuestionVisualizationView.swift` (`NumericSeriesView`), `App/Sources/HomeView.swift` (grid path only if plan 27's merged shape needs it)

- [x] **Step 1: Implement `NumericSeriesView`** — drop the external "Average:" headline and Y gutter; labels move inside the plot:

```swift
var body: some View {
    Chart {
        ForEach(Array(points.enumerated()), id: \.offset) { _, point in
            LineMark(x: .value("Date", point.date), y: .value("Value", point.value))
                .foregroundStyle(.white)
                .symbol(.circle)
        }
        RuleMark(y: .value("Average", average))
            .foregroundStyle(.white.opacity(0.4))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            .annotation(position: .top, alignment: .trailing) {
                Text("AVG \(formattedAverage)")
                    .font(.caption2.weight(.semibold))
                    .kerning(0.5)
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.trailing, 4)
            }
    }
    .chartYAxis(.hidden)   // no external gutter — full-bleed principle
    .chartXAxis {
        AxisMarks(values: .automatic) {
            AxisValueLabel().foregroundStyle(.white.opacity(0.7))
        }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Values over time")
    .accessibilityValue(accessibilitySummary)   // unchanged — carries range/avg
    .accessibilityIdentifier("viz-numeric-series")
}
```

If hiding the Y axis makes the sparse demo line unreadable in the sim, overlay min/max captions inside the plot's leading corners (`.chartOverlay` or `overlay(alignment:)`) rather than restoring the gutter — record the choice.
- [x] **Step 2: iPad pass (post-plan-27 shape).** Run on an iPad sim at regular width: grid cards inherit the new page internals; confirm plain dots render ONLY in the compact pager path and the bottom strip behaves in both. Adapt to whatever plan 27 merged — no assumptions beyond its PR diff.
- [x] **Step 3: Merge gate.** `swift test` (must be identical to the pre-plan run — zero kit impact), `xcodebuild build-for-testing`, FULL UI suite including every file in the Global Constraints list. Refresh screenshots via `ScreenshotTests`.
- [x] **Step 4: Commit** — `git commit -m "feat: in-chart numeric labels + iPad parity pass (plan 29)"` → push. Open PR `feat: Reporter home-screen visual parity (plan 29)`.

### Task 6: Self-review

- [x] Re-read the reference screenshot vs. a fresh sim capture side by side: top bar (list / glyph / gear), left filter row + hairline, uppercase heading, chart-to-strip fill, REPORT / dots / pill strip. List any deltas; fix or log as accepted deviations (known accepted: the `N reports` caption in the filter row — Dispatch data-visibility feature, not in original Reporter).
- [x] Grep the diff for accidental identifier changes (`git diff main -- App | grep accessibilityIdentifier`) — the frozen list must be byte-identical.
- [x] Confirm `TempVizCollisionTests.swift` is deleted and no `backgroundDisplayMode` / 46pt-padding remnants survive.
- [x] Confirm zero diffs under `Sources/DispatchKit/`, `App/Sources/Survey/`, `App/Sources/Settings/`, `Widgets/`.
- [x] Update this plan's checkboxes + append the implementation report section (plan 22/26 convention), noting the theme-contrast outcome and any plan-27 adaptation details.

---

## Completion note (2026-07-10)

All six tasks implemented on branch `plan-29-home-parity` (PR to main; full UI suite runs at the merge gate). Rebased onto main after PR #25 (media/connection) landed — no overlap, clean rebase.

- **Task 1:** `HomeGlyph.imageset` (single 180px universal, sips-downscaled from icon-1024) centered decorative in the top bar (`.accessibilityHidden(true)`, still queryable via `app.images["home-glyph"]` — no fallback query needed); `filterPill` → left-aligned `filterBar` with plus.square glyph, hairline divider, and `report-count` relocated to its trailing edge (label text + identifier verbatim). New `HomeParityUITests` (red → green).
- **Task 2:** uppercase/kerned left-aligned heading with `.accessibilityLabel(question.prompt)` (original casing — NavigationUITests' prompt queries verified green); page insets 20pt → 8pt; the 46pt dot-avoidance padding reverted to 8pt.
- **Task 3:** pager `indexDisplayMode: .never` (indexViewStyle line deleted); `PlainPageDots` (7pt/9pt, no pill, a11y-hidden, `page-dots`) + `AwakePillToggle` (capsule, sliding knob, explicit AWAKE/ASLEEP a11y label) in the reserved bottom strip (`frame(minHeight: 52)` — minHeight chosen up front for accessibility3, which passed without iteration). Dots render only in the compact pager path. **Deviation:** `TempVizCollisionTests.swift` never landed on main (its PR's merge gate evidently dropped it), so there was nothing to delete; the landed 46pt-padding + `.always` pill chrome was absorbed/reverted as planned. **Deviation (minor):** Task 3's test was written with the implementation rather than observed red first; its non-overlap and `page-dots` assertions are structurally impossible against the old overlay layout.
- **Task 4:** `OptionSharesBarsView` columns → vertically stacked full-width blocks (spacing 2, min 28pt, labels bottom-left/right, per-block a11y elements kept); `blended(withWhite:)` added beside `blended(withBlack:)`; index-0 lightens 8%, later indices darken 10%/index. **Theme contrast outcome:** verified with sim screenshots across all five themes — white labels legible everywhere including chartreuse/gray (chartreuse is the low end but consistent with all other white-on-chartreuse home chrome), so the uniform no-lighten fallback was NOT applied.
- **Task 5:** `NumericSeriesView` drops the external "Average:" headline and Y-axis gutter; inline "AVG N" annotation on the RuleMark; min/max captions overlaid in the plot's leading corners (chosen — the sparse demo line needed value anchors with the axis hidden). iPad pass: grid cards inherit the new internals, no dots at regular width, strip behaves in both layouts (verified via iPad Pro 11" sim screenshots + parity test run on the iPad destination).
- **Task 6:** side-by-side against IMG_3273 (original coral home): top bar / filter row / hairline / heading / stacked blocks / REPORT-dots-AWAKE strip all match. Accepted deviations: the trailing "N reports" caption in the filter row (Dispatch data-visibility feature) and the Dispatch rounded-square glyph standing in for Reporter's hexagon mark. Identifier diff clean (moves only, no renames); zero diffs under `Sources/DispatchKit/`, `App/Sources/Survey/`, `App/Sources/Settings/`, `Widgets/`.

Verification: `swift test` green at start (425) and end (444 — the delta is PR #25's kit tests, zero from this branch); build-for-testing green on iPhone 17 Pro AND iPad Pro 11" destinations; HomeParityUITests (3), NavigationUITests (4), AccessibilityUITests (1), SurveyFlowUITests (9), ScreenshotTests (SCREENSHOT_MODE) all green locally post-rebase.
