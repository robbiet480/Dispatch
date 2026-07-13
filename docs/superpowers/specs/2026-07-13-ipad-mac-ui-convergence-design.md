# iPad / Mac large-screen UI convergence — design

- **Date:** 2026-07-13
- **Branch:** `ipad-mac-ui-convergence` (spec + implementation, one branch)
- **Status:** approved design; implementation to follow in three sprints, same session
- **Related:** plan 27 (iPad split), plan 36 (Mac shell), plan 47 (Mac Manage menu / catalog)

## 1. Problem

The large-screen experience diverged. Mac has a top pane picker
(Dashboard / Insights / Questions / Groups / Catalog) driven by a shared
`MacNavigation` model, but iPad still only splits a reports sidebar against
`HomeView`. Every management pane on Mac is a bespoke duplicate of its iOS
sibling (`MacDashboardView`, `MacInsightsView`, `MacQuestionsView`,
`MacPromptGroupsView`, `MacCatalogView`, `MacSettingsView` — ~1,556 LOC of
parallel UI). The Mac shell also carries four concrete UX defects the owner
called out:

1. The reports sidebar stays visible on every pane, including panes where a
   list of *reports* is irrelevant.
2. Only Dashboard/Insights follow the app's theme color; the management panes
   render in default system chrome.
3. The current pane name shows twice (segmented picker label **and** the
   pane's own `navigationTitle`).
4. The catalog "Submit" action uses the share icon (`square.and.arrow.up`),
   which reads as "export," not "contribute."

There is no side-by-side catalog detail on either large platform, and no
preview of what a catalog question will feel like once added.

## 2. Goals / non-goals

**Goals**

- One shared implementation of each pane's content that improves iPad and Mac
  simultaneously; delete the Mac duplicates.
- iPad adopts the same top pane picker + split shell Mac has.
- A shared, adaptive question catalog: **list + detail pane + non-interactive
  input preview**; side-by-side on iPad/Mac, push on iPhone.
- Resolve all four Mac defects as a by-product of the unified shell.
- Full richness, every question type, no "defer to v2" gaps (owner mandate).

**Non-goals**

- iPhone does **not** gain a top tab bar; it keeps native compact navigation
  (Home + Settings push). Its pane *content* is the same shared views, reached
  through Settings.
- No change to the sync layer, the survey/capture flow, CloudKit, or the
  question model. This is a presentation-layer convergence.
- No redesign of the visual identity beyond applying the existing theme
  treatment (white text + translucent rows on `Color.themeBackground`).

## 3. Current state (grounded)

- **iOS root** — `App/Sources/RootNavigationView.swift`: idiom gate. iPhone →
  `HomeView()`. iPad → `PadRootView` = `NavigationSplitView` [ `ReportsListView`
  sidebar | `NavigationStack` detail hosting `HomeView(isEmbedded:)` ]. The
  gate is idiom (not size class) on purpose — swapping split↔stack on a
  size-class change discards navigation state.
- **Mac root** — `Mac/Sources/MacRootView.swift`: `NavigationSplitView`
  [ `MacReportsListView` sidebar | `detailContent` ]. `detailContent` switches
  on `navigation.pane` (`MacDetailPane` enum: dashboard/insights/questions/
  groups/catalog) when no report is selected, else the report detail. The pane
  picker is a `.principal` segmented `Picker` (`detail-pane-picker`). Shared
  state: `MacNavigation` (`@Observable`: `pane`, `selectedReportID`, `show()`),
  also driven by the Manage menu ⌘1–5 (`DispatchMacApp.swift`).
- **Catalog** — iOS `CatalogView` (List of `NavigationLink` → `CatalogDetailView`;
  already themed; **no input preview**), presented from
  `QuestionSettingsView` (Settings → Questions → Catalog, three levels deep).
  Mac `MacCatalogView` (flat list, inline Add/Flag per row, in-content search
  field to dodge the dual-`.searchable` toolbar crash, Submit =
  `square.and.arrow.up`, own `navigationTitle`). Both ride the shared
  `CatalogStore` / `CatalogProvider` / `CatalogQuestion`.
- **`CatalogQuestion`** already carries every field the preview needs:
  `type`, `choices`, `inputStyle` (raw), `inputMin/Max/Step`, `placeholder`,
  `defaultAnswer`, `tags`, `credit`, `approvedAt`.
- **Question model** — `QuestionType`: tokens, multipleChoice, yesNo, location,
  people, number, note, time (8). `NumberInputStyle`: textField, slider,
  stepper, dial, tapCounter, scale (6). iOS survey input controls live in
  `App/Sources/Survey/` (`QuestionPageView`, `NumberInputViews`, `TimeInputView`,
  `CaptureChecklistView`).

## 4. Design overview — the unified model

Every large-screen pane reduces to the same shape:

> **a list (sidebar) + a selection → a detail (content)**

| Pane | Sidebar list | Detail |
|---|---|---|
| Dashboard | Reports | Dashboard stats / selected report |
| Insights | *(none — collapsed)* | Insight cards, full width |
| Questions | Your questions | Question editor |
| Groups | Prompt groups | Group schedule / triggers / questions |
| Catalog | Catalog entries | Entry detail + input preview |

This is expressed as **one** `NavigationSplitView` whose **sidebar content
swaps by pane** and whose **detail is driven by the pane's selection**. That
single decision resolves the Mac defects:

- **Defect 1 (reports sidebar everywhere)** → the sidebar shows the *pane's*
  list, not reports, off Dashboard; Insights collapses the column
  (`.detailOnly`). The reports list appears only on Dashboard.
- **Defect 2 (theming)** → every pane's list and detail use the shared theme
  treatment (`Color.themeBackground(theme)` + `.scrollContentBackground(.hidden)`
  + `.listRowBackground(Color.white.opacity(0.12))` + white text), the same
  treatment Dashboard's sidebar already uses. Native list styling is retained;
  it is only tinted.
- **Defect 3 (double title)** → the pane picker is the sole pane title; per-pane
  `navigationTitle` calls are removed on the large-screen hosts.
- **Defect 4 (submit icon)** → Submit becomes `plus` everywhere.

The `NavigationSplitView` collapses to a stack automatically at compact widths
(iPad Slide Over), so no separate compact code path is needed on iPad. iPhone
does not use this shell at all.

Each pane is therefore built from **two reusable pieces** — a `*ListView` and a
`*DetailView` — that compose three ways:

- **Shell (iPad/Mac):** list = sidebar, detail column = detail.
- **Push (iPhone):** list in a `NavigationStack`, rows push the detail.
- **Standalone:** unchanged where already correct.

## 5. Sub-design A — shared adaptive catalog

New/updated shared files (compiled into both `DispatchApp` and `DispatchMac`;
`CatalogStore`/`CatalogProvider`/`CatalogQuestion` are already dual-target):

- **`CatalogListView(store:selection:)`** — the entry list + search field +
  load-more + Submit (`plus`). One `@Binding var selection: CatalogQuestion.ID?`.
  Themed. Hosts:
  - iPhone: wrapped in `NavigationStack`; rows are `NavigationLink`s that push
    `CatalogDetailView` (selection binding unused / nil).
  - iPad/Mac: it *is* the shell sidebar; row tap sets `selection`.
  - Search is the in-content field pattern from `MacCatalogView` (avoids the
    dual-`.searchable` toolbar crash) on **all** platforms, so one code path.
- **`CatalogDetailView(entry:store:)`** — promoted to shared and upgraded. The
  existing iOS view is the base (already themed, has Add + Flag). Adds:
  - Header: prompt; `type · credit · approvedAt` metadata line; tag chips.
  - **"What you'll get"** config summary derived from the entry (choices for
    multipleChoice; resolved range/step/style for number; placeholder for note;
    a "captures …" line for location/people/time/tokens).
  - **`QuestionInputPreview(entry:)`** (sub-design B).
  - Actions: **Add to my questions** (primary) + **Flag** (secondary). Inline
    per-row Add/Flag on Mac is removed — actions live in the detail.
  - Empty-selection state on iPad/Mac ("Select a question"). The list
    auto-selects the first entry on load at regular width so the detail is
    never blank; compact/iPhone start unselected (push model).
- **`CatalogSubmitView`** — promoted to shared, replacing the near-identical
  `CatalogSubmitView` (iOS) and `MacCatalogSubmitView`. Presented as a sheet
  from the list's `plus`. **The submit logic is preserved verbatim** — the two
  files' `submit()` bodies and `init` signatures are already identical (same
  fields, validation, duplicate pre-check, daily quota, `store.submit(...)`
  write). Only the chrome changes: the form picks up the themed styling; Mac's
  native Cancel/Send bar + ⎋/⏎ shortcuts + min-window frame stay behind
  platform conditionals. Test identifiers consolidate onto the `catalog-submit-*`
  set (the `mac-catalog-submit-*` variants retire).
- **Deleted:** `MacCatalogView`, `MacCatalogSubmitView`.

## 6. Sub-design B — `QuestionInputPreview`

A shared, purpose-built, **non-interactive** renderer. It is *not* the live
survey control (which depends on `SurveyViewModel`); it mirrors each control's
appearance with static primitives, wrapped in
`.disabled(true).allowsHitTesting(false)` and captioned "Non-interactive
preview." It takes the resolved type + style + config from a `CatalogQuestion`
(and is reusable for a `Question`). Every type is covered:

| Type / style | Preview render |
|---|---|
| number · textField | Disabled field showing `placeholder` or `defaultAnswer` or "0" |
| number · slider | Disabled `Slider` at mid value; min/max end labels |
| number · stepper | `− value +` row, disabled |
| number · dial | Static circular gauge at mid value |
| number · tapCounter | Large count with a disabled "+1" target |
| number · scale | `NumberInputStyle.scalePoints(min:max:)` dots; middle filled |
| multipleChoice | Choice rows/chips; checkboxes if `allowsMultipleSelection`, else radio; one shown selected |
| yesNo | Yes / No pair; one highlighted |
| tokens | Wrap of sample token chips + disabled "add a word" field |
| people | Person chip (avatar + name) + disabled "add person" |
| location | Map-pin row "Current location" over a static mini-map placeholder |
| note | Multi-line area showing `placeholder`, disabled |
| time | "3:30 PM" pill / static wheel |

Number config resolves through the existing
`NumberInputStyle.resolvedConfig(for:min:max:step:)` so the preview matches what
the survey will actually show. Unknown/missing `inputStyle` → `.textField`.

## 7. Sub-design C — the shared large-screen shell

A single `LargeScreenShell` view used by **both** iPad and Mac:

```
NavigationSplitView(columnVisibility) {
    sidebar(for: pane)          // reports | questions | groups | catalog | none
} detail: {
    detail(for: pane, selection)
}
.toolbar {
    principal: pane picker (segmented)
    #if iOS (iPad): trailing: Settings gear button
}
```

- **Navigation state** — generalize `MacNavigation` into a shared
  `PaneNavigation` (`@Observable`: `pane`, and a per-pane selection). Mac keeps
  the Manage menu ⌘1–5 wired to it; iPad drives it from the picker. `pane`
  changes clear stale selections (existing Mac behavior).
- **Sidebar collapse** — Insights forces `.detailOnly`; other panes show their
  list. `columnVisibility` is owned by the shell.
- **iPad host** — `PadRootView` is replaced by `LargeScreenShell`. Dashboard
  pane preserves plan 27's report-detail push semantics (selecting a report
  row → report detail with a system back button). The idiom gate in
  `RootNavigationView` stays (iPhone → `HomeView`, iPad → shell).
- **Mac host** — `MacRootView` becomes a thin wrapper over `LargeScreenShell`
  (retaining the export alert + menu-bar integration). `MacDetailPane` is
  replaced by the shared pane enum.
- **Pane content** — the shell renders the **shared** pane views:
  `HomeView`/Dashboard content, `InsightsView`, the Questions list+editor, the
  Groups list+detail, and the catalog (sub-design A). The Mac duplicates are
  deleted once the shared views compile on macOS.
- **Cross-platform compile** — shared pane views currently in `App/Sources/`
  gain `#if os(iOS)` / `#if os(macOS)` guards around iOS-only API
  (`navigationBarTitleDisplayMode`, `UIDevice`, haptics, `.toolbar` placements
  that differ) and move to dual-target membership in `project.yml`. Parts that
  make no sense on Mac (e.g. the survey-start affordance on the Dashboard) are
  conditioned out, not forked (owner decision: "condition out parts that don't
  make sense on Mac").

## 8. Sub-design D — Settings restructure

- **iPad/Mac:** Questions, Groups, and Catalog leave Settings (they are now
  panes). Settings slims to true configuration: Data, Sensors, Notifications,
  Appearance, App Lock, Webhooks, About.
  - Mac keeps the native **Settings scene** (`⌘,`, separate window) — no
    Settings tab/pane. `MacSettingsView` stays but drops the promoted rows.
  - iPad reaches Settings via a **trailing gear** in the shell toolbar,
    presented as a sheet (as iPhone does). Not a selectable pane.
- **iPhone:** Settings keeps the management entries (no tab bar to promote them
  to), but they are **lifted into a top-level "Manage" section** of the Settings
  root — Questions, Prompt Groups, Catalog as three peer rows — instead of the
  current deep nesting (Catalog is presently 3 levels under Settings →
  Questions → Catalog). Same shared views; flatter path mirroring the tab
  grouping. *(Owner may veto; falls back to current nesting.)*

## 9. Sub-design E — the four Mac fixes, folded in

Each defect is resolved structurally by §4, not patched:

1. Reports sidebar off Dashboard → sidebar swaps per pane (§4, §7).
2. Theming → shared themed treatment on all panes (§4).
3. Double title → pane picker is the only title; drop per-pane
   `navigationTitle` on the shell hosts (§4).
4. Submit icon → `plus` in the shared `CatalogListView` (§5).

## 10. Sprint decomposition (all this session, one branch)

Sequenced to land in reviewable chunks; each builds + tests green before the
next.

- **Sprint 1 — shared adaptive catalog (§5, §6, fix 4).** Build
  `CatalogListView`, upgrade+share `CatalogDetailView`, build
  `QuestionInputPreview`, share `CatalogSubmitView`, delete `MacCatalogView`/
  `MacCatalogSubmitView`. **iPhone reaches its final form here** —
  `CatalogListView` in a `NavigationStack` pushing `CatalogDetailView`. On Mac,
  the catalog pane swaps to the shared pieces immediately (plus icon, shared
  submit, preview) but stays **single-column with push-within-pane** until the
  shell lands; true side-by-side is a shell capability and arrives in Sprint 3.
  No throwaway container is introduced — the same two pieces are recomposed as
  sidebar+detail by the shell. Lowest-risk, self-contained, absorbs the
  plus-icon fix.
- **Sprint 2 — cross-platform pane views (§7 pane content, fixes 2).** Make
  `HomeView`/Dashboard, `InsightsView`, Questions list+editor, Groups
  list+detail compile on macOS behind `#if os`; switch the Mac panes to the
  shared views; delete `MacDashboardView`, `MacInsightsView`, `MacQuestionsView`,
  `MacPromptGroupsView`. Absorbs theming (iOS views already themed).
- **Sprint 3 — shared shell + iPad adoption (§7, §8, fixes 1 & 3).** Extract
  `LargeScreenShell` + shared `PaneNavigation`; replace `PadRootView` and the
  body of `MacRootView` with it; add the iPad pane picker + trailing Settings
  gear; restructure Settings (§8). Absorbs hide-sidebar-off-Dashboard and
  drop-duplicate-title.

## 11. Testing

- **Unit/logic:** `QuestionInputPreview` type→render mapping is exhaustively
  covered (a case per `QuestionType` and per `NumberInputStyle`), asserting the
  resolved config and that no live binding is required.
- **iOS UI (`AppUITests`):** iPad — pane picker switches panes; Catalog shows
  list+detail side-by-side; selecting an entry shows the preview; Add + Flag
  from the detail; Settings gear opens Settings. iPhone — Catalog pushes from
  the flattened Manage section; detail shows the preview; Add works.
- **Mac UI (`MacUITests`):** existing `MacScreenshotTests` pane identifiers
  (`mac-catalog-list`, `mac-questions-list`, `mac-groups-list`, `insight-card`,
  `report-count`) are preserved or remapped so the screenshot suite still
  drives ⌘1–5. Add a catalog list+detail assertion. Keep the in-content search
  (no `.searchable`) to avoid the dual-toolbar crash regression (build 30).
- **Schema/CI:** unaffected (no model changes); the `cloudkit-schema` guard
  stays green.

## 12. Risks

- **Dual-`.searchable` crash (build 30):** the shell has two live columns; a
  toolbar `.searchable` in both crashes AppKit. Mitigation: keep the in-content
  search field everywhere; never add `.searchable` to a shell column.
- **`#if os` sprawl:** conditioning iOS views for macOS can scatter guards.
  Mitigation: isolate platform differences behind small helpers
  (e.g. a `platformNavTitle`/`platformToolbar` view extension) rather than
  inline `#if` at every call site.
- **iPad navigation-state loss:** keep the idiom gate; never swap the shell
  root on a size-class change (plan 27's lesson).
- **Screenshot suite breakage:** the Mac screenshot identifiers are load-bearing
  for `scripts/mac-shots.sh`. Verify each pane still exposes its `*-list`
  identifier after the swap.

## 13. Resolved decisions

- Pane content: fully unified with iOS richness; condition out Mac-irrelevant
  parts (not fork). — owner
- Settings: not a content tab; native `⌘,` on Mac, trailing gear on iPad;
  slims only on iPad/Mac; iPhone keeps entries, flattened into a Manage
  section. — owner (Manage flattening pending final veto)
- Input preview: non-interactive, purpose-built (not the live survey control),
  every type covered. — owner ("full kitchen sink," no v2 gaps)
- Adaptive layout: one `NavigationSplitView` with pane-swapped sidebar; auto
  collapses on compact; iPhone uses push, not the shell. — this design
