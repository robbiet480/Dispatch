# Dispatch Plan 27: iPad layout

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Dispatch runs properly on iPad — device family 2 enabled with full orientation support, a real two-column reports experience via `NavigationSplitView`, adaptive grids for the Home visualizations and Insights on regular width, the survey presented as a centered sheet instead of full-bleed, readable-width constraints on forms/settings, and cheap keyboard shortcuts. Tracks GitHub issue #21 — reference it in commits/PRs.

**Scope discipline (hard constraints):** adaptivity of EXISTING screens only — no new features, no macOS/Catalyst, no watch changes. Screenshot/App-Store-asset work is explicitly OUT of scope (a later plan). iPad needs no new capabilities/entitlements — `project.yml` device-family/orientation keys only, no provisioning-profile churn.

## Design decisions (decide + log)

- **Topology gate = idiom, layout gate = size class.** The navigation *structure* (split vs stack) is chosen once per launch by `UIDevice.current.userInterfaceIdiom == .pad` — swapping a `NavigationSplitView` for a `NavigationStack` mid-scene on a size-class change would discard navigation state. *Layout* decisions (grid vs pager, column counts, readable width) key off `@Environment(\.horizontalSizeClass)` so iPad multitasking (Split View/Slide Over at compact width) degrades to the iPhone layouts automatically.
- **NavigationSplitView must be the root, so on iPad the reports list becomes the sidebar.** A `NavigationSplitView` pushed inside a `NavigationStack` collapses to stacked behavior (documented SwiftUI behavior), so the two-column reports win cannot be a push destination. On iPad the root is `NavigationSplitView`: sidebar = `ReportsListView` (selection-based), detail = the Home dashboard when nothing is selected, `ReportDetailView` when a report is selected. The detail column carries its own `NavigationStack` so all existing Settings/Insights/Questions pushes work unchanged inside it. iPhone topology is untouched.
- **ReportsListView grows a selection mode, not a fork.** One view, two behaviors: an optional `Binding<String?>` selection (report `uniqueIdentifier`). Binding present (iPad sidebar) → `List(selection:)` rows; absent (iPhone) → the existing `NavigationLink(destination:)` push. No duplicated list/stats code.
- **Home dashboard stays the iPad landing surface.** REPORT/AWAKE bottom bar, filter pill, and viz pages render in the detail column exactly as on iPhone; on regular width the paged `TabView` is replaced by a two-column card grid (all visible questions at once — an iPad-sized screen shouldn't hide N-1 visualizations behind swipes). The pager remains the compact-width fallback.
- **Survey = form sheet on iPad, fullScreenCover on iPhone.** `.sheet` on iPad renders as a centered card, which is exactly the "centered sheet/column" ask — no custom sizing. The existing lock/digest presentation-serialization getters are shared by both branches (single source of truth; only the presentation modifier differs by idiom). Survey page content additionally gets a readable-width column so wide iPad sheets/landscape don't stretch inputs edge-to-edge.
- **Readable width is one shared modifier.** `readableColumn(maxWidth: 640)` (frame(maxWidth:) centered) applied to the settings tree, editors, onboarding, digest, catalog, people, and survey pages. Mechanical, no per-screen redesign.
- **Accessibility identifiers are a UI-suite contract — none may change.** `reports-list-button`, `reports-list`, `report-row`, `settings-button`, `report-button`, etc. keep their identifiers in both topologies. On iPad, `reports-list-button` becomes the sidebar-visibility toggle (same identifier, same "shows the reports list" meaning). UI tests that assume push/back topology get minimal idiom-tolerant branches (helper: `isPad` via `UIDevice`), and the full suite must pass on BOTH an iPhone and an iPad simulator.
- **Orientations:** iPhone stays portrait-only (`INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone`); iPad supports all four (`INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad`) — required for App Store submission without `UIRequiresFullScreen`, and it keeps multitasking available. Widgets + UI-test bundle also move to `TARGETED_DEVICE_FAMILY: "1,2"` (widgets must be installable on iPad; the test bundle must run there).
- **Keyboard shortcuts (cheap only):** ⌘N = new report (Home REPORT button), ⌘F = focus reports search (`searchFocused` binding + hidden button). Nothing else — no menu-builder work.

## Global Constraints

- Suites green before every commit: `swift test` + `xcodebuild build-for-testing` for an iPhone AND an iPad simulator destination per task; the full UI suite runs on an iPad simulator in the wrap task (and stays green on iPhone). No kit schema changes anywhere in this plan; kit code should be untouched (all-SwiftUI app-side work) — if a task needs kit logic, it lands TDD-first.
- Branch workflow (NOT direct-to-main this time): worktree branch `plan-27-ipad-layout`, scoped commit per task, rebase on main before the PR (`main` is moving — the watch PR also touches `project.yml`). PR at the end titled `feat: iPad layout (plan 27)`.
- Do NOT bump the build number. No entitlement/profile changes. Every claimed platform behavior in comments cites docs where non-obvious (four-strikes rule).

---

### Task 1: project.yml — iPad device family + orientations

- [x] **Files:** `project.yml` (DispatchApp, DispatchWidgets, DispatchUITests: `TARGETED_DEVICE_FAMILY: "1,2"`; replace the bare `INFOPLIST_KEY_UISupportedInterfaceOrientations` with `_iPhone` (portrait) and `_iPad` (all four) variants on the app target).

**Contract:** `xcodegen generate` succeeds; `xcodebuild build-for-testing` succeeds for both an iPhone and an iPad simulator destination; the built app's Info.plist carries `UIDeviceFamily [1,2]`, portrait-only `UISupportedInterfaceOrientations~iphone`, all-four `~ipad` (verify in the built product, plan-16 style — INFOPLIST_KEY variants have burned us before). App launches on an iPad simulator (stretched iPhone layout is expected at this point).

Verify: kit suite + both build-for-testing destinations. Commit `feat: enable iPad device family + orientations (plan 27)`.

### Task 2: iPad root — NavigationSplitView with reports sidebar

- [x] **Files:** Create `App/Sources/RootNavigationView.swift` (idiom switch: pad → `NavigationSplitView` sidebar/detail per the design decision; phone → `HomeView()` unchanged). Modify `App/Sources/ContentView.swift` (mount `RootNavigationView` instead of `HomeView`), `App/Sources/HomeView.swift` (extract the dashboard content so the iPad detail column can embed it without a nested `NavigationStack`; iPhone keeps its own stack; on iPad the topBar reports button toggles sidebar visibility — same accessibility identifier), `App/Sources/Reports/ReportsListView.swift` (optional selection binding → `List(selection:)` mode; row identifiers preserved; swipe-delete keeps working in both modes and clears a dangling selection).

**Contract:** iPhone behavior byte-identical (UI suite proves it). iPad: sidebar lists reports with the stats header; selecting a row shows `ReportDetailView` in the detail column; no selection shows the Home dashboard; Settings/Insights/Questions push inside the detail column; deleting the selected report clears the detail pane rather than showing a dangling model. UI tests touched only where topology assumptions break, with idiom-tolerant helpers — identifiers unchanged.

Verify: kit suite + both build-for-testing destinations + iPhone UI suite spot-run of `NavigationUITests`. Commit `feat: iPad split-view navigation — reports sidebar + detail column`.

### Task 3: adaptive Home visualization grid + Insights columns

- [x] **Files:** `App/Sources/HomeView.swift` (regular width: `LazyVGrid` two-column card grid of `QuestionVisualizationView`s in a `ScrollView`, fixed card height, filter pill + report count unchanged; compact: existing pager untouched), `App/Sources/Insights/InsightsView.swift` (regular width: adaptive-minimum grid for insight cards).

**Contract:** grid appears only at `horizontalSizeClass == .regular`; the memoized `visualizationTaskID`/`insightsTaskID` rebuild pattern is reused untouched (the grid consumes the same `visualizations` dictionary); page-selection fallback logic stays for the pager path. No kit changes.

Verify: kit suite + both build-for-testing destinations. Commit `feat: adaptive grids for Home visualizations + Insights on iPad`.

### Task 4: survey as centered sheet + readable-width forms

- [x] **Files:** `App/Sources/ContentView.swift` (idiom-gated presentation: `.sheet` on pad / `.fullScreenCover` on phone, sharing the existing lock/digest-serialized binding; `interactiveDismissDisabled` on the sheet so CANCEL + discard-confirmation stays the only exit, matching fullScreenCover semantics), `App/Sources/Survey/SurveyFlowView.swift` (readable-width column on question pages), new `App/Sources/ReadableColumn.swift` (shared modifier), applied across `App/Sources/Settings/*.swift`, `App/Sources/OnboardingView.swift`, `App/Sources/Digest/*View*.swift`, `App/Sources/Catalog/CatalogView.swift` + `CatalogSubmitView.swift`, `App/Sources/People/PeopleListView.swift` + `PersonDetailView.swift`, `App/Sources/Reports/ReportDetailView.swift`, `App/Sources/Insights/InsightsView.swift` (explainer/empty state).

**Contract:** on iPhone (compact) every screen renders pixel-identical (the modifier's maxWidth exceeds compact widths — pure no-op); on iPad no form/list stretches past ~640pt centered. Survey presents as a centered card on iPad, full-bleed on iPhone; the survey-vs-digest presentation serialization comments/behavior carry over verbatim.

Verify: kit suite + both build-for-testing destinations. Commit `feat: iPad survey sheet + readable-width forms`.

### Task 5: keyboard shortcuts

- [ ] **Files:** `App/Sources/HomeView.swift` (⌘N on the REPORT action), `App/Sources/Reports/ReportsListView.swift` (⌘F focuses search via `searchFocused` + hidden shortcut button).

**Contract:** shortcuts work from a hardware keyboard on iPad; zero behavior change without one; no shortcut fires while the survey cover/sheet is up (the presenting view is off-screen — verify, don't assume; guard if SwiftUI keeps it active).

Verify: kit suite + both build-for-testing destinations. Commit `feat: keyboard shortcuts — new report, search`.

### Task 6: iPad UI-suite pass + wrap

- [ ] **Files:** `AppUITests/*.swift` (only what the iPad run surfaces — idiom-tolerant fixes, identifiers untouched).

**Contract:** the FULL existing UI suite passes on an iPad simulator (`iPad Pro 11-inch (M4)`) — run synchronously, tee'd to a log — and stays green on iPhone (`iPhone 16 Pro`). Fix what the run surfaces; no test deleted or weakened (assertions may branch by idiom, never vanish). Wrap: completion notes in this doc, rebase on main (expect `project.yml` conflicts from the watch PR — resolve additively), open the PR referencing #21.

Verify: `swift test`; full UI suite green on iPad + iPhone. Commit `test: iPad UI-suite pass (plan 27)`.
