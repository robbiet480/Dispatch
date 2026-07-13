# iPad / Mac UI Convergence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Converge the iPad and Mac large-screen UI onto one shared implementation — a shared adaptive question catalog, shared pane content (deleting the Mac duplicates), and a shared top-pane-picker split shell both platforms adopt — resolving the four Mac shell defects as a by-product.

**Architecture:** Every large-screen pane is *one list (sidebar) + a selection → a detail*, expressed as a single `NavigationSplitView` whose sidebar swaps by pane. SwiftUI-free logic (input-preview resolution, pane navigation) lives in `DispatchKit/UIState` and is unit-tested with `swift test`; thin SwiftUI views compile into both `DispatchApp` (iOS) and `DispatchMac`. iPhone keeps native compact push navigation and reuses the same views.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, XcodeGen (`project.yml` → `Dispatch.xcodeproj`), SwiftPM (`DispatchKit` library + `DispatchKitTests`), XCTest/XCUITest (`DispatchUITests`, `DispatchMacUITests`, `DispatchAppTests`).

## Global Constraints

Every task's requirements implicitly include these.

- **Branch:** `ipad-mac-ui-convergence` — spec + implementation on this one branch. Do not open a separate spec PR.
- **Presentation only:** no changes to the sync layer, the survey/capture (report-filing) flow, CloudKit, or the SwiftData model. The catalog submit *logic* (`store.submit(...)`, fields, validation, quota, duplicate pre-check) is preserved verbatim.
- **DispatchKit is Foundation/SwiftData-only** — never `import SwiftUI` there. Preview/navigation *logic* goes in `Sources/DispatchKit/UIState/`; SwiftUI *views* go in `App/Sources/` with dual-target membership.
- **Themed treatment (verbatim):** `Color.themeBackground(theme)` background + `.scrollContentBackground(.hidden)` + `.listRowBackground(Color.white.opacity(0.12))` + white text (`.foregroundStyle(.white)` / `.white.opacity(0.7)` for secondary).
- **Never add `.searchable` to a shell/split column** — two live columns crash AppKit (`NSInternalInconsistencyException`, build 30 regression). Use the in-content search `TextField` pattern from the old `MacCatalogView` everywhere.
- **iPad navigation:** keep the idiom gate in `RootNavigationView` (iPhone → `HomeView`, iPad → shell). Never swap the root view on a size-class change (plan 27's lesson).
- **Preserve Mac screenshot identifiers** used by `scripts/mac-shots.sh` / `MacScreenshotTests`: `report-count`, `report-row`, `detail-back-button`, `insight-card`, `mac-questions-list`, `mac-groups-list`, `mac-catalog-list`. When a pane's view is replaced, its `*-list` identifier must survive.
- **After adding/removing files or editing `project.yml`:** run `xcodegen generate` before building the Xcode project.
- **Commit message footer (every commit):**
  ```
  Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
  ```

## Build & Test Commands (reference)

- DispatchKit unit tests: `swift test --filter <TestClass>`
- Regenerate project: `xcodegen generate`
- iOS build: `xcodebuild -project Dispatch.xcodeproj -scheme DispatchApp -destination 'generic/platform=iOS Simulator' build`
- Mac build: `xcodebuild -project Dispatch.xcodeproj -scheme DispatchMac -destination 'platform=macOS' build`
- Mac UI test: `xcodebuild test -project Dispatch.xcodeproj -scheme DispatchMac -destination 'platform=macOS' -only-testing:DispatchMacUITests/<Class>/<method>`
- iOS UI test (simulator): `xcodebuild test -project Dispatch.xcodeproj -scheme DispatchApp -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:DispatchUITests/<Class>/<method>`

## File Structure

**New (Sprint 1):**
- `Sources/DispatchKit/UIState/QuestionInputPreview.swift` — SwiftUI-free resolver: `(QuestionType, NumberInputStyle, config…) → QuestionPreviewControl`. Overloads for `Question` and `CatalogQuestion`.
- `Tests/DispatchKitTests/QuestionInputPreviewTests.swift` — exhaustive per-type / per-style coverage.
- `App/Sources/Catalog/QuestionInputPreviewView.swift` — SwiftUI renderer of `QuestionPreviewControl`, non-interactive. Dual-target.
- `App/Sources/Catalog/CatalogListView.swift` — shared themed list (selection-based, in-content search, `plus` submit). Dual-target.

**New (Sprint 3):**
- `Sources/DispatchKit/UIState/PaneNavigation.swift` — SwiftUI-free `AppPane` enum + `PaneNavigation` `@Observable` (pane + per-pane selection + `show`/clear logic).
- `Tests/DispatchKitTests/PaneNavigationTests.swift` — selection-clearing behavior.
- `App/Sources/Shell/LargeScreenShell.swift` — the shared `NavigationSplitView` shell (sidebar-swap + pane picker + iPad Settings gear). Dual-target.

**Modified:**
- `App/Sources/Catalog/CatalogView.swift` — becomes the shared push host (Sprint 1); iPhone-permanent.
- `App/Sources/Catalog/CatalogDetailView` (in `CatalogView.swift`) — upgraded + dual-target (Sprint 1).
- `App/Sources/Catalog/CatalogSubmitView.swift` — dual-target + platform-conditioned chrome (Sprint 1).
- `App/Sources/Insights/InsightsView.swift`, `App/Sources/HomeView.swift`, `App/Sources/Settings/QuestionSettingsView.swift`, `App/Sources/Settings/PromptGroupsView.swift` — dual-target + `#if os` guards (Sprint 2).
- `Mac/Sources/MacRootView.swift`, `App/Sources/RootNavigationView.swift` — rewritten over `LargeScreenShell` (Sprint 3).
- `App/Sources/Settings/SettingsView.swift`, `Mac/Sources/MacSettingsView.swift` — Settings restructure (Sprint 3).
- `project.yml` — dual-target membership for each newly shared file.

**Deleted:**
- `Mac/Sources/MacCatalogView.swift`, `Mac/Sources/MacCatalogSubmitView.swift` (Sprint 1).
- `Mac/Sources/MacDashboardView.swift`, `Mac/Sources/MacInsightsView.swift`, `Mac/Sources/MacQuestionsView.swift`, `Mac/Sources/MacPromptGroupsView.swift` (Sprint 2).

---

# Sprint 1 — Shared adaptive catalog

Delivers: `QuestionInputPreview` (logic + view), `CatalogListView`, upgraded shared `CatalogDetailView`, shared `CatalogSubmitView`, `plus` submit icon; iPhone reaches final form; Mac catalog pane uses the shared pieces (single-column push-within-pane until Sprint 3). Ends buildable on both platforms with green catalog UI tests.

### Task 1.1: `QuestionInputPreview` resolver (logic)

**Files:**
- Create: `Sources/DispatchKit/UIState/QuestionInputPreview.swift`
- Test: `Tests/DispatchKitTests/QuestionInputPreviewTests.swift`

**Interfaces:**
- Consumes: `QuestionType` (V1Models), `NumberInputStyle` (Models/Question.swift) incl. `resolvedConfig(for:min:max:step:)` and `scalePoints(min:max:)`, `CatalogQuestion`, `Question`.
- Produces:
  - `enum QuestionPreviewControl: Equatable, Sendable` with cases `number(NumberPreview)`, `choices(options:[String], multiSelect:Bool, selected:Int?)`, `yesNo(selected:Bool?)`, `tokens(samples:[String])`, `people(sample:String)`, `location`, `note(placeholder:String?)`, `time(sample:String)`.
  - nested `enum NumberPreview: Equatable, Sendable` with cases `textField(placeholder:String?, value:String?)`, `slider(min:Double, max:Double, value:Double)`, `stepper(value:Double)`, `dial(min:Double, max:Double, value:Double)`, `tapCounter(value:Int)`, `scale(points:[Int], selected:Int)`.
  - `enum QuestionInputPreview` with statics `control(forType:inputStyle:choices:allowsMultipleSelection:inputMin:inputMax:inputStep:placeholder:defaultAnswer:) -> QuestionPreviewControl`, `control(for: CatalogQuestion) -> QuestionPreviewControl`, `control(for: Question) -> QuestionPreviewControl`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import DispatchKit

final class QuestionInputPreviewTests: XCTestCase {
    // Bounded number styles resolve to a mid value from the resolved config.
    func testSliderUsesMidpointOfResolvedRange() {
        let control = QuestionInputPreview.control(
            forType: .number, inputStyle: .slider, choices: [], allowsMultipleSelection: false,
            inputMin: 0, inputMax: 10, inputStep: 1, placeholder: nil, defaultAnswer: nil)
        XCTAssertEqual(control, .number(.slider(min: 0, max: 10, value: 5)))
    }

    func testScaleFillsMiddlePoint() {
        let control = QuestionInputPreview.control(
            forType: .number, inputStyle: .scale, choices: [], allowsMultipleSelection: false,
            inputMin: 1, inputMax: 5, inputStep: 1, placeholder: nil, defaultAnswer: nil)
        XCTAssertEqual(control, .number(.scale(points: [1, 2, 3, 4, 5], selected: 3)))
    }

    func testTextFieldPrefersPlaceholderThenDefault() {
        let control = QuestionInputPreview.control(
            forType: .number, inputStyle: .textField, choices: [], allowsMultipleSelection: false,
            inputMin: nil, inputMax: nil, inputStep: nil, placeholder: "kg", defaultAnswer: "0")
        XCTAssertEqual(control, .number(.textField(placeholder: "kg", value: "0")))
    }

    func testUnknownInputStyleFallsBackToTextField() {
        // An entry whose stored inputStyle raw is nil/unknown → textField.
        let entry = CatalogQuestion(
            recordName: "r", prompt: "How many?", typeRaw: QuestionType.number.rawValue,
            choices: [], approvedAt: Date(timeIntervalSince1970: 0), inputStyle: nil)
        XCTAssertEqual(QuestionInputPreview.control(for: entry), .number(.textField(placeholder: nil, value: nil)))
    }

    func testMultipleChoiceMarksFirstSelectedAndKeepsMultiSelectFlag() {
        let control = QuestionInputPreview.control(
            forType: .multipleChoice, inputStyle: .textField, choices: ["A", "B", "C"],
            allowsMultipleSelection: true, inputMin: nil, inputMax: nil, inputStep: nil,
            placeholder: nil, defaultAnswer: nil)
        XCTAssertEqual(control, .choices(options: ["A", "B", "C"], multiSelect: true, selected: 0))
    }

    func testYesNoNoteTokensPeopleLocationTime() {
        func c(_ t: QuestionType) -> QuestionPreviewControl {
            QuestionInputPreview.control(forType: t, inputStyle: .textField, choices: [],
                allowsMultipleSelection: false, inputMin: nil, inputMax: nil, inputStep: nil,
                placeholder: "Notes…", defaultAnswer: nil)
        }
        XCTAssertEqual(c(.yesNo), .yesNo(selected: nil))
        XCTAssertEqual(c(.note), .note(placeholder: "Notes…"))
        XCTAssertEqual(c(.location), .location)
        if case .tokens(let s) = c(.tokens) { XCTAssertFalse(s.isEmpty) } else { XCTFail("tokens") }
        if case .people(let s) = c(.people) { XCTAssertFalse(s.isEmpty) } else { XCTFail("people") }
        if case .time(let s) = c(.time) { XCTAssertFalse(s.isEmpty) } else { XCTFail("time") }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter QuestionInputPreviewTests`
Expected: FAIL — `cannot find 'QuestionInputPreview' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// Non-interactive rendering of a question's input control, resolved off the
/// data model with no SwiftUI dependency so it is unit-testable and shareable.
/// The SwiftUI renderer (`QuestionInputPreviewView`) switches on this.
public enum QuestionPreviewControl: Equatable, Sendable {
    case number(NumberPreview)
    case choices(options: [String], multiSelect: Bool, selected: Int?)
    case yesNo(selected: Bool?)
    case tokens(samples: [String])
    case people(sample: String)
    case location
    case note(placeholder: String?)
    case time(sample: String)

    public enum NumberPreview: Equatable, Sendable {
        case textField(placeholder: String?, value: String?)
        case slider(min: Double, max: Double, value: Double)
        case stepper(value: Double)
        case dial(min: Double, max: Double, value: Double)
        case tapCounter(value: Int)
        case scale(points: [Int], selected: Int)
    }
}

public enum QuestionInputPreview {
    /// A representative value inside [min, max]: the midpoint, rounded to the
    /// nearest step, clamped in-range. Used for slider/dial previews.
    private static func midValue(min: Double, max: Double, step: Double) -> Double {
        let mid = (min + max) / 2
        guard step > 0 else { return mid }
        let snapped = (mid / step).rounded() * step
        return Swift.min(Swift.max(snapped, min), max)
    }

    /// A representative count for unbounded styles (stepper/tapCounter):
    /// clamp a friendly sample of 3 into [min, max] when those are finite.
    private static func sampleCount(min: Double, max: Double) -> Double {
        let sample = 3.0
        let lo = min.isFinite ? min : sample
        let hi = max.isFinite ? max : sample
        return Swift.min(Swift.max(sample, lo), Swift.max(lo, hi))
    }

    public static func control(
        forType type: QuestionType,
        inputStyle: NumberInputStyle,
        choices: [String],
        allowsMultipleSelection: Bool,
        inputMin: Double?, inputMax: Double?, inputStep: Double?,
        placeholder: String?,
        defaultAnswer: String?
    ) -> QuestionPreviewControl {
        switch type {
        case .number:
            let cfg = NumberInputStyle.resolvedConfig(for: inputStyle, min: inputMin, max: inputMax, step: inputStep)
            switch inputStyle {
            case .textField:
                return .number(.textField(
                    placeholder: placeholder?.isEmpty == false ? placeholder : nil,
                    value: defaultAnswer?.isEmpty == false ? defaultAnswer : nil))
            case .slider:
                return .number(.slider(min: cfg.min, max: cfg.max, value: midValue(min: cfg.min, max: cfg.max, step: cfg.step)))
            case .dial:
                return .number(.dial(min: cfg.min, max: cfg.max, value: midValue(min: cfg.min, max: cfg.max, step: cfg.step)))
            case .stepper:
                return .number(.stepper(value: sampleCount(min: cfg.min, max: cfg.max)))
            case .tapCounter:
                return .number(.tapCounter(value: Int(sampleCount(min: cfg.min, max: cfg.max))))
            case .scale:
                let points = NumberInputStyle.scalePoints(min: cfg.min, max: cfg.max)
                let selected = points.isEmpty ? 0 : points[points.count / 2]
                return .number(.scale(points: points, selected: selected))
            }
        case .multipleChoice:
            return .choices(options: choices, multiSelect: allowsMultipleSelection, selected: choices.isEmpty ? nil : 0)
        case .yesNo:
            return .yesNo(selected: nil)
        case .tokens:
            return .tokens(samples: ["work", "home", "focus"])
        case .people:
            return .people(sample: "Alex")
        case .location:
            return .location
        case .note:
            return .note(placeholder: placeholder?.isEmpty == false ? placeholder : nil)
        case .time:
            return .time(sample: "3:30 PM")
        }
    }

    public static func control(for entry: CatalogQuestion) -> QuestionPreviewControl {
        let style = entry.inputStyle.flatMap(NumberInputStyle.init(rawValue:)) ?? .textField
        return control(
            forType: entry.type ?? .note, inputStyle: style, choices: entry.choices,
            allowsMultipleSelection: entry.type == .multipleChoice,
            inputMin: entry.inputMin, inputMax: entry.inputMax, inputStep: entry.inputStep,
            placeholder: entry.placeholder, defaultAnswer: entry.defaultAnswer)
    }

    public static func control(for question: Question) -> QuestionPreviewControl {
        control(
            forType: question.type, inputStyle: question.inputStyle, choices: question.choices,
            allowsMultipleSelection: question.allowsMultipleSelection,
            inputMin: question.inputMin, inputMax: question.inputMax, inputStep: question.inputStep,
            placeholder: question.placeholderString, defaultAnswer: question.defaultAnswerString)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter QuestionInputPreviewTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/DispatchKit/UIState/QuestionInputPreview.swift Tests/DispatchKitTests/QuestionInputPreviewTests.swift
git commit -m "feat(kit): question input-preview resolver

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### Task 1.2: `QuestionInputPreviewView` (SwiftUI renderer)

**Files:**
- Create: `App/Sources/Catalog/QuestionInputPreviewView.swift`
- Modify: `project.yml` (add file to DispatchApp **and** DispatchMac membership)

**Interfaces:**
- Consumes: `QuestionPreviewControl` (Task 1.1).
- Produces: `struct QuestionInputPreviewView: View { init(control: QuestionPreviewControl) }` — non-interactive; caller wraps in a themed card.

- [ ] **Step 1: Add the file to both targets in `project.yml`**

The `DispatchApp` target already globs `App/Sources` (a new file under it is picked up automatically). The `DispatchMac` target lists shared iOS files explicitly. Find the block that adds shared `App/Sources/Visualizations/QuestionVisualizationView.swift` to `DispatchMac` and add, adjacent to it:

```yaml
      - path: App/Sources/Catalog/QuestionInputPreviewView.swift
```

Verify with: `grep -n "QuestionInputPreviewView\|QuestionVisualizationView" project.yml`

- [ ] **Step 2: Write the view**

```swift
import DispatchKit
import SwiftUI

/// Non-interactive preview of a question's input control. Mirrors the survey
/// controls' appearance with static primitives — it never binds to a live
/// answer — so it renders identically on iOS and macOS inside the catalog
/// detail. Whole subtree is inert.
struct QuestionInputPreviewView: View {
    let control: QuestionPreviewControl

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            content
            Text("Non-interactive preview")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .disabled(true)
        .allowsHitTesting(false)
        .accessibilityIdentifier("question-input-preview")
    }

    @ViewBuilder private var content: some View {
        switch control {
        case .number(let n): number(n)
        case .choices(let options, let multi, let selected): choices(options, multi, selected)
        case .yesNo(let selected): yesNo(selected)
        case .tokens(let samples): chips(samples)
        case .people(let sample): chips([sample], systemImage: "person.crop.circle")
        case .location: row(systemImage: "mappin.and.ellipse", text: "Current location")
        case .note(let placeholder): noteField(placeholder)
        case .time(let sample): pill(sample, systemImage: "clock")
        }
    }

    @ViewBuilder private func number(_ n: QuestionPreviewControl.NumberPreview) -> some View {
        switch n {
        case .textField(let placeholder, let value):
            fieldBox(value ?? placeholder ?? "0")
        case .slider(let lo, let hi, let value):
            VStack(spacing: 4) {
                Slider(value: .constant(value), in: lo...hi)
                    .tint(.white)
                HStack {
                    Text(trimmed(lo)); Spacer(); Text(trimmed(hi))
                }.font(.caption2).foregroundStyle(.white.opacity(0.6))
            }
        case .dial(let lo, let hi, let value):
            dial(fraction: hi > lo ? (value - lo) / (hi - lo) : 0, label: trimmed(value))
        case .stepper(let value):
            HStack(spacing: 12) {
                stepButton("minus"); Text(trimmed(value)).font(.title3.monospacedDigit()).foregroundStyle(.white)
                stepButton("plus")
            }
        case .tapCounter(let value):
            VStack(spacing: 6) {
                Text("\(value)").font(.system(size: 34, weight: .semibold).monospacedDigit()).foregroundStyle(.white)
                pill("+1", systemImage: "plus")
            }
        case .scale(let points, let selected):
            HStack(spacing: 8) {
                ForEach(points, id: \.self) { p in
                    Text("\(p)")
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                        .background(p == selected ? Color.white.opacity(0.9) : Color.white.opacity(0.08),
                                    in: RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(p == selected ? Color.black.opacity(0.8) : .white)
                        .font(.subheadline)
                }
            }
        }
    }

    private func choices(_ options: [String], _ multi: Bool, _ selected: Int?) -> some View {
        VStack(spacing: 8) {
            ForEach(Array(options.enumerated()), id: \.offset) { idx, option in
                HStack {
                    Image(systemName: multi
                          ? (idx == selected ? "checkmark.square.fill" : "square")
                          : (idx == selected ? "largecircle.fill.circle" : "circle"))
                    Text(option); Spacer()
                }
                .foregroundStyle(.white)
                .padding(10)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func yesNo(_ selected: Bool?) -> some View {
        HStack(spacing: 10) {
            ForEach([true, false], id: \.self) { value in
                Text(value ? "Yes" : "No")
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                    .background(selected == value ? Color.white.opacity(0.9) : Color.white.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: 8))
                    .foregroundStyle(selected == value ? Color.black.opacity(0.8) : .white)
            }
        }
    }

    private func chips(_ items: [String], systemImage: String? = nil) -> some View {
        HStack(spacing: 8) {
            ForEach(items, id: \.self) { item in
                Label {
                    Text(item)
                } icon: {
                    if let systemImage { Image(systemName: systemImage) }
                }
                .labelStyle(.titleAndIcon)
                .font(.subheadline).foregroundStyle(.white)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Color.white.opacity(0.12), in: Capsule())
            }
            Text("＋").foregroundStyle(.white.opacity(0.5))
        }
    }

    private func noteField(_ placeholder: String?) -> some View {
        Text(placeholder ?? "Write a note…")
            .foregroundStyle(.white.opacity(0.5))
            .frame(maxWidth: .infinity, minHeight: 66, alignment: .topLeading)
            .padding(10)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func fieldBox(_ text: String) -> some View {
        Text(text).foregroundStyle(.white.opacity(0.85))
            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func row(systemImage: String, text: String) -> some View {
        Label(text, systemImage: systemImage).foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func pill(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage).font(.subheadline).foregroundStyle(.white)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Color.white.opacity(0.12), in: Capsule())
    }

    private func stepButton(_ systemImage: String) -> some View {
        Image(systemName: systemImage).foregroundStyle(.white)
            .frame(width: 34, height: 34)
            .background(Color.white.opacity(0.12), in: Circle())
    }

    private func dial(fraction: Double, label: String) -> some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.15), lineWidth: 8)
            Circle().trim(from: 0, to: max(0, min(1, fraction)))
                .stroke(Color.white.opacity(0.9), style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(label).foregroundStyle(.white).font(.headline)
        }
        .frame(width: 92, height: 92)
    }

    private func trimmed(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}
```

- [ ] **Step 3: Regenerate and build both platforms**

Run:
```bash
xcodegen generate
xcodebuild -project Dispatch.xcodeproj -scheme DispatchMac -destination 'platform=macOS' build
xcodebuild -project Dispatch.xcodeproj -scheme DispatchApp -destination 'generic/platform=iOS Simulator' build
```
Expected: both `BUILD SUCCEEDED` (the view compiles on both targets).

- [ ] **Step 4: Commit**

```bash
git add App/Sources/Catalog/QuestionInputPreviewView.swift project.yml
git commit -m "feat(ui): non-interactive question input preview view

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### Task 1.3: Upgrade + share `CatalogDetailView`

**Files:**
- Modify: `App/Sources/Catalog/CatalogView.swift` (the `CatalogDetailView` struct, lines 135–270)
- Create: `AppUITests/CatalogUITests.swift`

> **Sequencing note (controller correction):** `CatalogView.swift`'s DispatchMac membership is deferred to Task 1.4, where `CatalogView` is rewritten cross-platform. Adding it to DispatchMac here would break the Mac build (this file still has iOS-only modifiers). This task therefore only makes `CatalogDetailView` *Mac-ready* (guarding its iOS-only nav modifiers) and builds/tests iOS.

**Interfaces:**
- Consumes: `QuestionInputPreviewView` (1.2), `QuestionInputPreview.control(for:)` (1.1), existing `CatalogStore.addToMyQuestions`, `store.flag`, `store.accountStatus`.
- Produces: `CatalogDetailView(entry: CatalogQuestion, store: CatalogStore)` unchanged signature; now renders metadata header, tag chips, "What you'll get" config summary, the input preview, then Add + Flag. Its iOS-only nav modifiers are guarded so the file compiles on macOS when 1.4 adds it to DispatchMac.

- [ ] **Step 1: Add a UI test asserting the preview appears (iOS, failing)**

In `AppUITests/CatalogUITests.swift` (create if absent — mirror an existing UITest's launch setup with `--ui-testing --demo-data`), add:

```swift
func testCatalogDetailShowsInputPreview() {
    let app = XCUIApplication()
    app.launchArguments = ["--ui-testing", "--demo-data", "--mock-sensors"]
    app.launch()
    // Navigate: Settings → Questions → Catalog → first entry.
    // (Use the app's existing settings-open identifier; see other AppUITests.)
    openCatalog(app)
    app.descendants(matching: .any).matching(identifier: "question-catalog-list")
        .firstMatch.cells.firstMatch.tap()
    XCTAssertTrue(app.descendants(matching: .any)
        .matching(identifier: "question-input-preview").firstMatch.waitForExistence(timeout: 5))
}
```

Run: `xcodebuild test -project Dispatch.xcodeproj -scheme DispatchApp -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:DispatchUITests/CatalogUITests/testCatalogDetailShowsInputPreview`
Expected: FAIL (no `question-input-preview` yet).

- [ ] **Step 2: Replace the `CatalogDetailView` body's first `Section` with the upgraded header + preview**

Keep the existing Add (`catalog-add-button`) and Flag (`catalog-flag-button`) sections and all handler methods. Replace the metadata `Section { … }` (prompt/type/choices/credit rows) with:

```swift
Section {
    Text(entry.prompt)
        .font(.title3).fontWeight(.semibold)
        .foregroundStyle(.white)
        .listRowBackground(Color.white.opacity(0.12))

    Text(metadataLine)
        .font(.caption)
        .foregroundStyle(.white.opacity(0.7))
        .listRowBackground(Color.white.opacity(0.12))

    if !entry.tags.isEmpty {
        tagChips
            .listRowBackground(Color.white.opacity(0.12))
    }

    if let summary = configSummary {
        Text(summary)
            .font(.footnote)
            .foregroundStyle(.white.opacity(0.8))
            .listRowBackground(Color.white.opacity(0.12))
    }
}

Section {
    QuestionInputPreviewView(control: QuestionInputPreview.control(for: entry))
        .padding(.vertical, 4)
        .listRowBackground(Color.white.opacity(0.12))
} header: {
    Text("PREVIEW")
        .font(.caption).fontWeight(.semibold)
        .foregroundStyle(.white.opacity(0.8))
}
```

Add these computed helpers to `CatalogDetailView`:

```swift
private var metadataLine: String {
    var parts = [entry.type?.displayName ?? "Unknown type"]
    if let credit = entry.credit, !credit.isEmpty { parts.append("by \(credit)") }
    parts.append(entry.approvedAt.formatted(.dateTime.month().year()))
    return parts.joined(separator: " · ")
}

@ViewBuilder private var tagChips: some View {
    HStack(spacing: 6) {
        ForEach(entry.tags, id: \.self) { tag in
            Text(tag).font(.caption2)
                .padding(.horizontal, 9).padding(.vertical, 3)
                .background(Color.white.opacity(0.15), in: Capsule())
                .foregroundStyle(.white)
        }
    }
}

/// One-line "what you'll get" summary; nil when the preview already says it all.
private var configSummary: String? {
    switch entry.type {
    case .multipleChoice:
        return entry.choices.isEmpty ? nil : "\(entry.choices.count) options"
    case .number:
        let style = entry.inputStyle.flatMap(NumberInputStyle.init(rawValue:)) ?? .textField
        let cfg = NumberInputStyle.resolvedConfig(for: style, min: entry.inputMin, max: entry.inputMax, step: entry.inputStep)
        if style == .textField { return "Number entry" }
        return "\(style.displayName) · \(trimmed(cfg.min))–\(trimmed(cfg.max)) step \(trimmed(cfg.step))"
    case .note:
        return entry.placeholder.map { "Free text · \u{201C}\($0)\u{201D}" }
    default:
        return nil
    }
}

private func trimmed(_ v: Double) -> String {
    v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
}
```

Delete the now-unused `choices` `ForEach` rows and the standalone "Type"/"Submitted by" rows (folded into `metadataLine`).

- [ ] **Step 3: Make `CatalogDetailView` Mac-ready — guard its iOS-only nav modifiers**

`CatalogDetailView` currently ends with `.navigationTitle("Catalog Question")` + `.navigationBarTitleDisplayMode(.inline)` + `.toolbarColorScheme(.dark, for: .navigationBar)`. The last two are iOS-only and would fail the Mac build when 1.4 adds this file to DispatchMac. Guard them:

```swift
.navigationTitle("Catalog Question")
#if os(iOS)
.navigationBarTitleDisplayMode(.inline)
.toolbarColorScheme(.dark, for: .navigationBar)
#endif
```

(Do NOT add `CatalogView.swift` to `project.yml`/DispatchMac in this task — that happens in 1.4. This task builds and tests iOS only.)

- [ ] **Step 4: Regenerate (to pick up the new test file), build iOS, run the test**

Run:
```bash
xcodegen generate
xcodebuild -project Dispatch.xcodeproj -scheme DispatchApp -destination 'generic/platform=iOS Simulator' build
xcodebuild test -project Dispatch.xcodeproj -scheme DispatchApp -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:DispatchUITests/CatalogUITests/testCatalogDetailShowsInputPreview
```
Expected: build succeeds; test PASSES. (`xcodegen generate` is needed because `CatalogUITests.swift` is a new file the DispatchUITests target globs.)

- [ ] **Step 5: Commit**

```bash
git add App/Sources/Catalog/CatalogView.swift AppUITests/CatalogUITests.swift
git commit -m "feat(catalog): rich shared detail with input preview

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### Task 1.4: `CatalogListView` (shared themed list)

**Files:**
- Create: `App/Sources/Catalog/CatalogListView.swift`
- Modify: `project.yml` — add **both** `App/Sources/Catalog/CatalogListView.swift` **and** `App/Sources/Catalog/CatalogView.swift` to DispatchMac membership (the latter deferred from Task 1.3). `CatalogView.swift` also contains the now-Mac-ready `CatalogDetailView` (guarded in 1.3), and its own `CatalogView` is rewritten cross-platform in Step 2, so both compile on macOS after this task.
- Modify: `App/Sources/Catalog/CatalogView.swift` (`CatalogView` becomes the push host over `CatalogListView`)

**Interfaces:**
- Consumes: `CatalogStore` (`filteredEntries`, `searchText`, `phase`, `hasMore`, `isLoadingMore`, `loadFirstPage`, `loadNextPage`), `CatalogDetailView` (1.3).
- Produces: `struct CatalogListView: View { init(store: CatalogStore, selection: Binding<CatalogQuestion.ID?>, onSubmit: @escaping () -> Void) }` — themed `List(selection:)` with in-content search + `plus` submit; identifier `question-catalog-list` on the list, `mac-catalog-list` also applied so the Mac screenshot suite keeps working, `catalog-submit-button` on the plus.

- [ ] **Step 1: Write `CatalogListView`**

```swift
import DispatchKit
import SwiftUI

/// Shared, themed catalog list. Selection-based so the same view is a
/// push-list (iPhone, wrapped in a NavigationStack with a navigationDestination)
/// and a shell sidebar (iPad/Mac). Search is an in-content field — never a
/// toolbar `.searchable`, which crashes when two split columns are live.
struct CatalogListView: View {
    let store: CatalogStore
    @Binding var selection: CatalogQuestion.ID?
    var onSubmit: () -> Void

    @Environment(ThemeStore.self) private var themeStore
    private var theme: Theme { themeStore.theme }

    var body: some View {
        @Bindable var store = store
        ZStack {
            Color.themeBackground(theme).ignoresSafeArea()
            VStack(spacing: 0) {
                searchField(store: store)
                content(store: store)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: onSubmit) {
                    Label("Submit a Question", systemImage: "plus")
                }
                .tint(.white)
                .accessibilityIdentifier("catalog-submit-button")
            }
        }
        .task { if store.phase == .idle { await store.loadFirstPage() } }
    }

    private func searchField(store: CatalogStore) -> some View {
        @Bindable var store = store
        return HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.6))
            TextField("Search questions", text: $store.searchText)
                .textFieldStyle(.plain).foregroundStyle(.white)
                .accessibilityIdentifier("catalog-search")
            if !store.searchText.isEmpty {
                Button { store.searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.6))
                }
                .buttonStyle(.borderless).accessibilityLabel("Clear search")
            }
        }
        .padding(8)
        .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .padding([.horizontal, .top])
    }

    @ViewBuilder private func content(store: CatalogStore) -> some View {
        switch store.phase {
        case .idle, .loading:
            Spacer(); ProgressView().tint(.white).accessibilityIdentifier("catalog-loading"); Spacer()
        case .failed(let message):
            Spacer()
            VStack(spacing: 12) {
                Text(message).font(.subheadline).foregroundStyle(.white.opacity(0.8)).multilineTextAlignment(.center)
                Button("Try Again") { Task { await store.loadFirstPage() } }.foregroundStyle(.white).fontWeight(.semibold)
            }.padding().accessibilityIdentifier("catalog-error")
            Spacer()
        case .loaded:
            if store.filteredEntries.isEmpty {
                Spacer()
                Text(store.searchText.isEmpty
                     ? "No questions in the catalog yet. Be the first to submit one!"
                     : "No questions match your search.")
                    .font(.subheadline).foregroundStyle(.white.opacity(0.8))
                    .multilineTextAlignment(.center).padding()
                    .accessibilityIdentifier("catalog-empty")
                Spacer()
            } else {
                list(store: store)
            }
        }
    }

    private func list(store: CatalogStore) -> some View {
        List(selection: $selection) {
            ForEach(store.filteredEntries) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.prompt).font(.subheadline).fontWeight(.semibold)
                        .foregroundStyle(.white).lineLimit(2)
                    Text(subtitle(entry)).font(.caption).foregroundStyle(.white.opacity(0.7))
                }
                .tag(entry.id)
                .listRowBackground(Color.white.opacity(0.12))
            }
            if store.hasMore, store.searchText.isEmpty {
                Button { Task { await store.loadNextPage() } } label: {
                    if store.isLoadingMore { ProgressView().tint(.white) }
                    else { Text("LOAD MORE…").font(.subheadline).fontWeight(.semibold).foregroundStyle(.white) }
                }
                .listRowBackground(Color.white.opacity(0.12))
                .accessibilityIdentifier("catalog-load-more")
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .accessibilityIdentifier("question-catalog-list")
        .accessibilityIdentifier("mac-catalog-list")
    }

    private func subtitle(_ entry: CatalogQuestion) -> String {
        var parts = [entry.type?.displayName ?? "Unknown type"]
        if let credit = entry.credit, !credit.isEmpty { parts.append("by \(credit)") }
        return parts.joined(separator: " · ")
    }
}
```

> Note: SwiftUI allows only one `accessibilityIdentifier` per view — the second call wins. To carry BOTH identifiers, apply one on the `List` and the other on an enclosing container. Concretely, wrap the `List` in a `Group { … }.accessibilityIdentifier("question-catalog-list")` and keep `.accessibilityIdentifier("mac-catalog-list")` on the `List` (Mac screenshot suite queries `mac-catalog-list`; iOS test queries `question-catalog-list`). Adjust if a UITest fails to find its id.

- [ ] **Step 2: Rewrite `CatalogView` as the push host**

Replace the whole `CatalogView` struct (lines 9–131) with:

```swift
/// iPhone / compact host for the catalog: the shared `CatalogListView` in a
/// NavigationStack that pushes `CatalogDetailView`. Also used as the interim
/// Mac catalog pane until the shared shell lands (Sprint 3).
struct CatalogView: View {
    @State private var store = CatalogStore()
    @State private var selection: CatalogQuestion.ID?
    @State private var showingSubmit = false

    var body: some View {
        NavigationStack {
            CatalogListView(store: store, selection: $selection) { showingSubmit = true }
                .navigationTitle("Question Catalog")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                .toolbarColorScheme(.dark, for: .navigationBar)
                #endif
                .navigationDestination(item: detailBinding) { entry in
                    CatalogDetailView(entry: entry, store: store)
                }
        }
        .sheet(isPresented: $showingSubmit) { CatalogSubmitView(store: store) }
    }

    /// Maps the id selection to the entry so `navigationDestination(item:)`
    /// pushes the detail and a pop clears the selection.
    private var detailBinding: Binding<CatalogQuestion?> {
        Binding(
            get: { store.filteredEntries.first { $0.id == selection } },
            set: { selection = $0?.id })
    }
}
```

- [ ] **Step 3: Regenerate, build both platforms**

Run:
```bash
xcodegen generate
xcodebuild -project Dispatch.xcodeproj -scheme DispatchApp -destination 'generic/platform=iOS Simulator' build
xcodebuild -project Dispatch.xcodeproj -scheme DispatchMac -destination 'platform=macOS' build
```
Expected: both `BUILD SUCCEEDED`.

- [ ] **Step 4: Re-run the catalog UI test from 1.3**

Run: `xcodebuild test -project Dispatch.xcodeproj -scheme DispatchApp -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:DispatchUITests/CatalogUITests/testCatalogDetailShowsInputPreview`
Expected: PASS (list id + push detail still resolve).

- [ ] **Step 5: Commit**

```bash
git add App/Sources/Catalog/CatalogListView.swift App/Sources/Catalog/CatalogView.swift project.yml
git commit -m "feat(catalog): shared themed CatalogListView + push host

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### Task 1.5: Share `CatalogSubmitView`; delete Mac catalog duplicates

**Files:**
- Modify: `App/Sources/Catalog/CatalogSubmitView.swift` (platform-condition the chrome; keep logic)
- Modify: `project.yml` (add `CatalogSubmitView.swift` to DispatchMac; remove the two Mac files' membership)
- Modify: `Mac/Sources/MacRootView.swift` (`.catalog` case → `CatalogView()`)
- Delete: `Mac/Sources/MacCatalogView.swift`, `Mac/Sources/MacCatalogSubmitView.swift`
- Modify: `MacUITests/MacScreenshotTests.swift` (identifiers unchanged — verify only)

**Interfaces:**
- Consumes: `CatalogSubmitView(store:…)` existing init (unchanged).
- Produces: one shared `CatalogSubmitView`; `MacCatalogSubmitView` retired.

- [ ] **Step 1: Platform-condition `CatalogSubmitView` chrome so it compiles on macOS**

`CatalogSubmitView` uses `navigationBarTitleDisplayMode`, `.toolbarColorScheme(.dark, for: .navigationBar)`, and `.topBarLeading`/`.topBarTrailing` placements — all iOS-only. Guard them. Change the toolbar/title modifiers on the `NavigationStack` body to:

```swift
.navigationTitle("Submit a Question")
#if os(iOS)
.navigationBarTitleDisplayMode(.inline)
.toolbarColorScheme(.dark, for: .navigationBar)
#endif
.toolbar {
    ToolbarItem(placement: .cancellationAction) {
        Button(submitted ? "Done" : "Cancel") { dismiss() }.tint(.white)
    }
    if !submitted {
        ToolbarItem(placement: .confirmationAction) {
            Button("Send") { submit() }
                .tint(.white).fontWeight(.semibold)
                .disabled(isSubmitting || store.submissionsRemaining == 0)
                .accessibilityIdentifier("catalog-submit-send")
        }
    }
}
```

(`.cancellationAction`/`.confirmationAction` resolve to the leading/trailing nav bar on iOS and the window's Cancel/Send affordance on macOS — one code path, native on both.) Leave `submit()`, `form`, `confirmation`, and all `@State` untouched.

- [ ] **Step 2: Update `project.yml` membership**

- Add to DispatchMac (adjacent to the other Catalog entries):
  ```yaml
      - path: App/Sources/Catalog/CatalogSubmitView.swift
  ```
- The `DispatchMac` target globs `Mac/Sources` — deleting the two files (next step) removes them from the target automatically; no explicit membership line to remove unless one exists (check: `grep -n "MacCatalogView\|MacCatalogSubmitView" project.yml`).

- [ ] **Step 3: Point the Mac catalog pane at the shared host and delete the duplicates**

In `Mac/Sources/MacRootView.swift`, change:
```swift
case .catalog: MacCatalogView()
```
to:
```swift
case .catalog: CatalogView()
```

Then:
```bash
git rm Mac/Sources/MacCatalogView.swift Mac/Sources/MacCatalogSubmitView.swift
```

- [ ] **Step 4: Regenerate, build Mac, run the Mac catalog screenshot test**

Run:
```bash
xcodegen generate
xcodebuild -project Dispatch.xcodeproj -scheme DispatchMac -destination 'platform=macOS' build
env TEST_RUNNER_SCREENSHOT_MODE=1 xcodebuild test -project Dispatch.xcodeproj -scheme DispatchMac -destination 'platform=macOS' -only-testing:DispatchMacUITests/MacScreenshotTests/testCaptureMacScreenshots
```
Expected: build succeeds; screenshot test passes (shot 07 finds `mac-catalog-list` via the shared `CatalogListView`; ⌘5 still opens the catalog pane).

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "refactor(mac): use shared catalog; delete Mac catalog duplicates

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### Task 1.6: Sprint 1 verification gate

- [ ] **Step 1: Full DispatchKit test run**

Run: `swift test`
Expected: all pass (incl. `QuestionInputPreviewTests`).

- [ ] **Step 2: Both app builds**

Run:
```bash
xcodebuild -project Dispatch.xcodeproj -scheme DispatchApp -destination 'generic/platform=iOS Simulator' build
xcodebuild -project Dispatch.xcodeproj -scheme DispatchMac -destination 'platform=macOS' build
```
Expected: both `BUILD SUCCEEDED`.

- [ ] **Step 3: Manual smoke (document result in the commit body if run)** — iPhone: Settings → Questions → Catalog → tap an entry → preview + Add + Flag; the `+` opens submit. Mac: ⌘5 → catalog list → tap an entry → detail pushes with preview; `+` opens submit.

---

# Sprint 2 — Cross-platform pane views

Delivers: `InsightsView`, the Questions list+editor, the Groups list+detail, and the Dashboard content compile on macOS and are used by the Mac panes; the Mac duplicates are deleted. Theming comes for free (iOS views are already themed). Ends with the existing Mac shell rendering shared views, both platforms building, Mac screenshot suite green.

> **Porting pattern (applies to every task in this sprint).** Each Mac duplicate is replaced by its iOS sibling made cross-platform. For each shared view: (a) add its file(s) to `DispatchMac` membership in `project.yml`; (b) wrap iOS-only API in `#if os(iOS)` — the usual offenders are `navigationBarTitleDisplayMode`, `.toolbarColorScheme(_, for: .navigationBar)`, `.topBarLeading`/`.topBarTrailing` (use `.cancellationAction`/`.confirmationAction`/`.primaryAction` instead), `UIDevice`, `.sensoryFeedback`, `UIApplication`, `keyboardType`; (c) condition out report-filing affordances that don't exist on Mac; (d) swap the `MacRootView` pane case to the shared view; (e) `git rm` the duplicate; (f) build both platforms + run the relevant Mac screenshot shot. Introduce a small helper to avoid `#if` sprawl (Task 2.1 Step 1).

### Task 2.1: Cross-platform view helpers

**Files:**
- Create: `App/Sources/Shell/PlatformModifiers.swift` (dual-target)
- Modify: `project.yml`

**Interfaces:**
- Produces: `extension View { func inlineNavTitleOnPhone() -> some View; func darkNavBarOnPhone() -> some View }` — no-ops on macOS, applying `navigationBarTitleDisplayMode(.inline)` / `toolbarColorScheme(.dark, for: .navigationBar)` on iOS.

- [ ] **Step 1: Write the helper**

```swift
import SwiftUI

extension View {
    /// Inline navigation title on iPhone/iPad; no-op on macOS (no nav bar).
    @ViewBuilder func inlineNavTitleOnPhone() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    /// Dark nav-bar chrome so white text reads on the themed background; iOS only.
    @ViewBuilder func darkNavBarOnPhone() -> some View {
        #if os(iOS)
        self.toolbarColorScheme(.dark, for: .navigationBar)
        #else
        self
        #endif
    }
}
```

- [ ] **Step 2: Add to both targets, build**

Add `App/Sources/Shell/PlatformModifiers.swift` to DispatchMac membership in `project.yml`; then:
```bash
xcodegen generate
xcodebuild -project Dispatch.xcodeproj -scheme DispatchMac -destination 'platform=macOS' build
```
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Commit**

```bash
git add App/Sources/Shell/PlatformModifiers.swift project.yml
git commit -m "chore(ui): cross-platform nav-chrome helpers

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### Task 2.2: Share `InsightsView` (exemplar — simplest pane)

**Files:**
- Modify: `App/Sources/Insights/InsightsView.swift`, `App/Sources/Insights/QuestionCorrelationView.swift` (dual-target + `#if os`)
- Modify: `project.yml`
- Modify: `Mac/Sources/MacRootView.swift` (`.insights` case → `InsightsView()`)
- Delete: `Mac/Sources/MacInsightsView.swift`

**Interfaces:**
- Consumes: existing `InsightsView()` init.
- Produces: `InsightsView` compiling on macOS; Mac `.insights` pane renders it. Must expose the `insight-card` identifier the Mac screenshot test (shot 03) queries — verify `InsightsView` cards carry `.accessibilityIdentifier("insight-card")`; if only `MacInsightsView` did, add it to `InsightsView`'s card.

- [ ] **Step 1: Read both files, apply the porting pattern**

Read `App/Sources/Insights/InsightsView.swift`, `App/Sources/Insights/QuestionCorrelationView.swift`, and `Mac/Sources/MacInsightsView.swift`. Guard iOS-only API in the iOS views per the pattern; ensure each insight card has `.accessibilityIdentifier("insight-card")` (port it over from `MacInsightsView` if the iOS view lacks it). Add both iOS files to DispatchMac membership.

- [ ] **Step 2: Swap the pane case and delete the duplicate**

In `MacRootView.swift`: `case .insights: MacInsightsView()` → `case .insights: InsightsView()`. Then `git rm Mac/Sources/MacInsightsView.swift`.

- [ ] **Step 3: Regenerate, build, run shot 03**

```bash
xcodegen generate
xcodebuild -project Dispatch.xcodeproj -scheme DispatchMac -destination 'platform=macOS' build
env TEST_RUNNER_SCREENSHOT_MODE=1 xcodebuild test -project Dispatch.xcodeproj -scheme DispatchMac -destination 'platform=macOS' -only-testing:DispatchMacUITests/MacScreenshotTests/testCaptureMacScreenshots
```
Expected: build succeeds; shot 03 finds `insight-card`.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "refactor: share InsightsView across iOS/macOS; drop Mac duplicate

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### Task 2.3: Share the Questions list + editor

**Files:**
- Modify: `App/Sources/Settings/QuestionSettingsView.swift`, `App/Sources/Settings/QuestionEditorView.swift`, `App/Sources/Settings/ChoiceOptionsEditorView.swift` (dual-target + `#if os`)
- Modify: `project.yml`
- Modify: `Mac/Sources/MacRootView.swift` (`.questions` case → shared Questions view)
- Delete: `Mac/Sources/MacQuestionsView.swift`, `Mac/Sources/MacQuestionEditorView.swift`, `Mac/Sources/MacQuestionImportSheet.swift` (if their functionality is fully covered by the shared iOS views; otherwise keep import sheet and condition it in)

**Interfaces:**
- Consumes: `QuestionSettingsView()` (iOS Questions list; identifier for the Mac shot: add `.accessibilityIdentifier("mac-questions-list")` to its List so shot 05 keeps working), `QuestionEditorView(question:)`.
- Produces: Mac `.questions` pane renders the shared list+editor.

- [ ] **Step 1: Read the iOS + Mac question views; reconcile**

Read `QuestionSettingsView.swift`, `QuestionEditorView.swift`, `Mac/Sources/MacQuestionsView.swift`, `Mac/Sources/MacQuestionEditorView.swift`, `Mac/Sources/MacQuestionImportSheet.swift`. Decide per-file whether the iOS view fully covers the Mac one (list, add, edit, reorder, import). Apply the porting pattern to the iOS files. Add `.accessibilityIdentifier("mac-questions-list")` to the shared list. Keep `MacQuestionImportSheet` if it provides a Mac file-picker import the iOS view lacks; wire it behind a toolbar button in the shared list via `#if os(macOS)`.

- [ ] **Step 2: Swap the pane case; delete covered duplicates**

`case .questions: MacQuestionsView()` → the shared Questions list view. `git rm` the duplicates whose behavior is fully shared.

- [ ] **Step 3: Regenerate, build, run shot 05**

```bash
xcodegen generate
xcodebuild -project Dispatch.xcodeproj -scheme DispatchMac -destination 'platform=macOS' build
env TEST_RUNNER_SCREENSHOT_MODE=1 xcodebuild test -project Dispatch.xcodeproj -scheme DispatchMac -destination 'platform=macOS' -only-testing:DispatchMacUITests/MacScreenshotTests/testCaptureMacScreenshots
```
Expected: build succeeds; shot 05 finds `mac-questions-list`.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "refactor: share Questions list+editor across iOS/macOS

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### Task 2.4: Share the Prompt Groups list + detail

**Files:**
- Modify: `App/Sources/Settings/PromptGroupsView.swift` (1,029 lines — dual-target + `#if os`; the big port)
- Modify: `project.yml`
- Modify: `Mac/Sources/MacRootView.swift` (`.groups` case → `PromptGroupsView()`)
- Delete: `Mac/Sources/MacPromptGroupsView.swift`

**Interfaces:**
- Consumes: `PromptGroupsView()`.
- Produces: Mac `.groups` pane renders the shared groups view. Add `.accessibilityIdentifier("mac-groups-list")` to its list so shot 06 keeps working.

- [ ] **Step 1: Port `PromptGroupsView` to compile on macOS**

Read `App/Sources/Settings/PromptGroupsView.swift` and `Mac/Sources/MacPromptGroupsView.swift`. This is the largest port; work file-region by region. Guard every iOS-only API per the pattern (place-trigger location UI, `CLLocationManager` one-shot fix is available on macOS — keep it; `keyboardType`, nav-bar modifiers → guard/helper). Where the Mac version had a Mac-specific affordance the iOS one lacks (e.g. the current-location fix flow), fold it into the shared view behind `#if os(macOS)`. Add `.accessibilityIdentifier("mac-groups-list")` to the groups list.

- [ ] **Step 2: Swap the pane case, delete the duplicate**

`case .groups: MacPromptGroupsView()` → `case .groups: PromptGroupsView()`. `git rm Mac/Sources/MacPromptGroupsView.swift`.

- [ ] **Step 3: Regenerate, build, run shot 06**

```bash
xcodegen generate
xcodebuild -project Dispatch.xcodeproj -scheme DispatchMac -destination 'platform=macOS' build
env TEST_RUNNER_SCREENSHOT_MODE=1 xcodebuild test -project Dispatch.xcodeproj -scheme DispatchMac -destination 'platform=macOS' -only-testing:DispatchMacUITests/MacScreenshotTests/testCaptureMacScreenshots
```
Expected: build succeeds; shot 06 finds `mac-groups-list`.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "refactor: share Prompt Groups across iOS/macOS; drop Mac duplicate

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### Task 2.5: Share the Dashboard content

**Files:**
- Modify: `App/Sources/HomeView.swift` (dual-target + `#if os`; condition out the REPORT/AWAKE strip on macOS)
- Modify: `project.yml`
- Modify: `Mac/Sources/MacRootView.swift` (`.dashboard` case → `HomeView(isEmbedded: true)`)
- Delete: `Mac/Sources/MacDashboardView.swift` (only if `HomeView` fully covers the Mac dashboard; otherwise extract the shared visualization grid into a `DashboardContentView` used by both — decide in Step 1)

**Interfaces:**
- Consumes: `HomeView(isEmbedded:toggleSidebar:)`.
- Produces: Mac `.dashboard` pane renders the shared dashboard content. Must keep the `report-count` identifier (shot 01) — verify it lives in the shared dashboard content, not only in `MacDashboardView`.

- [ ] **Step 1: Read `HomeView` + `MacDashboardView`; choose share-vs-extract**

Read `App/Sources/HomeView.swift` (esp. lines 111 `isEmbedded`, 284 `toggleSidebar`, 350–420 the REPORT/AWAKE bottom strip) and `Mac/Sources/MacDashboardView.swift`. If the dashboard *visualization grid* is cleanly separable, extract it into a shared `DashboardContentView` (dual-target) that both `HomeView` (with the REPORT strip below it on iOS) and the Mac `.dashboard` pane render. Otherwise make `HomeView` compile on macOS with the REPORT/AWAKE strip under `#if os(iOS)`. Ensure `report-count` is on the shared content.

- [ ] **Step 2: Swap the pane case, delete/retire the Mac dashboard**

`case .dashboard: MacDashboardView(searchQuery: searchQuery)` → the shared dashboard content (passing `searchQuery`). `git rm Mac/Sources/MacDashboardView.swift` if fully covered, else keep only the Mac-specific wrapper.

- [ ] **Step 3: Regenerate, build, run shot 01**

```bash
xcodegen generate
xcodebuild -project Dispatch.xcodeproj -scheme DispatchMac -destination 'platform=macOS' build
env TEST_RUNNER_SCREENSHOT_MODE=1 xcodebuild test -project Dispatch.xcodeproj -scheme DispatchMac -destination 'platform=macOS' -only-testing:DispatchMacUITests/MacScreenshotTests/testCaptureMacScreenshots
```
Expected: build succeeds; shot 01 finds `report-count`.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "refactor: share dashboard content across iOS/macOS

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### Task 2.6: Sprint 2 verification gate

- [ ] **Step 1: Both builds + full Mac screenshot suite + iOS build**

```bash
swift test
xcodegen generate
xcodebuild -project Dispatch.xcodeproj -scheme DispatchApp -destination 'generic/platform=iOS Simulator' build
env TEST_RUNNER_SCREENSHOT_MODE=1 xcodebuild test -project Dispatch.xcodeproj -scheme DispatchMac -destination 'platform=macOS' -only-testing:DispatchMacUITests/MacScreenshotTests
```
Expected: `swift test` passes; both builds succeed; all 7 Mac shots capture. Confirm no `Mac{Dashboard,Insights,Questions,PromptGroups,Catalog}View.swift` remain: `ls Mac/Sources/Mac*View.swift`.

---

# Sprint 3 — Shared shell + iPad adoption

Delivers: `PaneNavigation` (shared logic), `LargeScreenShell` adopted by both iPad and Mac, the iPad pane picker + trailing Settings gear, the Settings restructure (slim on iPad/Mac; iPhone Manage section), and the two remaining Mac fixes (hide reports sidebar off Dashboard, drop the duplicate pane title). Ends with iPad and Mac on one shell; full suite green.

### Task 3.1: `PaneNavigation` (shared logic)

**Files:**
- Create: `Sources/DispatchKit/UIState/PaneNavigation.swift`
- Test: `Tests/DispatchKitTests/PaneNavigationTests.swift`
- (Sprint 3 later steps delete `MacNavigation`/`MacDetailPane` from `MacRootView.swift`.)

**Interfaces:**
- Produces:
  - `enum AppPane: String, CaseIterable, Identifiable, Sendable { case dashboard, insights, questions, groups, catalog; var id: String; var label: String; var isManagement: Bool; var showsReportsSidebar: Bool /* dashboard only */ }`
  - `@MainActor @Observable final class PaneNavigation { var pane: AppPane; var selectedReportID: String?; var selectedQuestionID: String?; var selectedGroupID: String?; var selectedCatalogID: String?; func show(_ pane: AppPane) }` — `show` sets `pane` and clears report selection; changing to a pane whose `showsReportsSidebar == false` clears `selectedReportID`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import DispatchKit

@MainActor
final class PaneNavigationTests: XCTestCase {
    func testShowManagementPaneClearsReportSelection() {
        let nav = PaneNavigation()
        nav.selectedReportID = "r1"
        nav.show(.questions)
        XCTAssertEqual(nav.pane, .questions)
        XCTAssertNil(nav.selectedReportID)
    }

    func testOnlyDashboardShowsReportsSidebar() {
        XCTAssertTrue(AppPane.dashboard.showsReportsSidebar)
        for pane in AppPane.allCases where pane != .dashboard {
            XCTAssertFalse(pane.showsReportsSidebar)
        }
    }

    func testManagementFlag() {
        XCTAssertFalse(AppPane.dashboard.isManagement)
        XCTAssertFalse(AppPane.insights.isManagement)
        XCTAssertTrue(AppPane.questions.isManagement)
        XCTAssertTrue(AppPane.groups.isManagement)
        XCTAssertTrue(AppPane.catalog.isManagement)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter PaneNavigationTests`
Expected: FAIL — `cannot find 'PaneNavigation' in scope`.

- [ ] **Step 3: Implement**

```swift
import Foundation

public enum AppPane: String, CaseIterable, Identifiable, Sendable {
    case dashboard, insights, questions, groups, catalog

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .dashboard: "Dashboard"
        case .insights: "Insights"
        case .questions: "Questions"
        case .groups: "Groups"
        case .catalog: "Catalog"
        }
    }

    /// Setup surfaces vs. review surfaces (dashboard/insights).
    public var isManagement: Bool {
        switch self {
        case .dashboard, .insights: false
        case .questions, .groups, .catalog: true
        }
    }

    /// The reports list is only meaningful on the dashboard; every other pane
    /// shows its own list (or none), so the reports sidebar hides off it.
    public var showsReportsSidebar: Bool { self == .dashboard }
}

/// Shared large-screen navigation state (generalizes the Mac-only
/// `MacNavigation`). Owns the active pane and a per-pane selection so both the
/// iPad picker and the Mac Manage menu drive one source of truth.
@MainActor
@Observable
public final class PaneNavigation {
    public var pane: AppPane = .dashboard
    public var selectedReportID: String?
    public var selectedQuestionID: String?
    public var selectedGroupID: String?
    public var selectedCatalogID: String?

    public init() {}

    /// Menu/picker action: show a pane, clearing the report selection when the
    /// destination pane doesn't show the reports sidebar.
    public func show(_ pane: AppPane) {
        if !pane.showsReportsSidebar { selectedReportID = nil }
        self.pane = pane
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter PaneNavigationTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/DispatchKit/UIState/PaneNavigation.swift Tests/DispatchKitTests/PaneNavigationTests.swift
git commit -m "feat(kit): shared pane navigation model

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### Task 3.2: `LargeScreenShell` (shared split shell)

**Files:**
- Create: `App/Sources/Shell/LargeScreenShell.swift` (dual-target)
- Modify: `project.yml`

**Interfaces:**
- Consumes: `PaneNavigation` (3.1) from the environment; the shared pane views (Sprint 2): dashboard content, `InsightsView`, Questions list, Groups list, `CatalogListView` + `CatalogDetailView`; `ReportsListView` (iOS) / `MacReportsListView` (macOS) for the Dashboard sidebar; `CatalogDetailView`.
- Produces: `struct LargeScreenShell: View` — one `NavigationSplitView` whose sidebar swaps by `pane` (reports on dashboard; questions/groups/catalog lists elsewhere; collapsed for insights) and whose detail is driven by the pane's selection; principal-toolbar pane `Picker` (`detail-pane-picker`) is the sole pane title; iPad-only trailing Settings gear (`open-settings-button`).

- [ ] **Step 1: Write the shell**

```swift
import DispatchKit
import SwiftData
import SwiftUI

/// Shared large-screen shell: one split, sidebar swaps by pane, the pane picker
/// is the only title. iPad and Mac both host it. Compact widths collapse the
/// split to a stack automatically (no separate code path).
struct LargeScreenShell: View {
    @Environment(PaneNavigation.self) private var nav
    @Environment(ThemeStore.self) private var themeStore
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var reportsSearch = ""
    @State private var showingSettings = false

    var body: some View {
        @Bindable var nav = nav
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar(nav: nav)
        } detail: {
            detail(nav: nav)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        Picker("View", selection: paneBinding(nav)) {
                            ForEach(AppPane.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("detail-pane-picker")
                    }
                    #if os(iOS)
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showingSettings = true } label: { Image(systemName: "gearshape") }
                            .accessibilityIdentifier("open-settings-button")
                    }
                    #endif
                }
        }
        .onChange(of: nav.pane) { syncColumnVisibility() }
        .onAppear { syncColumnVisibility() }
        #if os(iOS)
        .sheet(isPresented: $showingSettings) { NavigationStack { SettingsView() } }
        #endif
    }

    /// Pane changes route through `show(_:)` so selection-clearing stays in one place.
    private func paneBinding(_ nav: PaneNavigation) -> Binding<AppPane> {
        Binding(get: { nav.pane }, set: { nav.show($0) })
    }

    private func syncColumnVisibility() {
        columnVisibility = nav.pane == .insights ? .detailOnly : .automatic
    }

    @ViewBuilder private func sidebar(nav: PaneNavigation) -> some View {
        switch nav.pane {
        case .dashboard:
            reportsSidebar(nav: nav)
        case .insights:
            EmptyView()
        case .questions:
            QuestionsPaneList(selection: bind(\.selectedQuestionID, nav))   // Sprint 2 shared list
        case .groups:
            GroupsPaneList(selection: bind(\.selectedGroupID, nav))         // Sprint 2 shared list
        case .catalog:
            CatalogListView(store: catalogStore, selection: catalogSelectionBinding(nav)) {
                showingCatalogSubmit = true
            }
        }
    }

    @ViewBuilder private func detail(nav: PaneNavigation) -> some View {
        switch nav.pane {
        case .dashboard: dashboardDetail(nav: nav)
        case .insights: InsightsView()
        case .questions: QuestionsPaneDetail(selection: bind(\.selectedQuestionID, nav))
        case .groups: GroupsPaneDetail(selection: bind(\.selectedGroupID, nav))
        case .catalog: catalogDetail(nav: nav)
        }
    }

    // Helpers: `reportsSidebar`, `dashboardDetail`, `catalogStore`,
    // `catalogSelectionBinding`, `catalogDetail`, `showingCatalogSubmit`, and
    // the `bind(_:_:)` KeyPath→Binding helper. Implement using the platform's
    // reports list (ReportsListView on iOS, MacReportsListView on macOS behind
    // `#if os`) and the shared pane views from Sprint 2. See Step 2.
}
```

> The `QuestionsPaneList/Detail` and `GroupsPaneList/Detail` names refer to the shared list/detail views finalized in Sprint 2. If Sprint 2 kept those panes as single combined views (list+editor in one), host that single view in the detail column and use a plain list in the sidebar; wire selection through the `PaneNavigation` id. Resolve the exact view names against the Sprint 2 result before writing Step 2.

- [ ] **Step 2: Fill in the helpers and platform reports list**

Add the private helpers referenced above. Reports sidebar per platform:
```swift
@ViewBuilder private func reportsSidebar(nav: PaneNavigation) -> some View {
    #if os(macOS)
    MacReportsListView(selection: Binding(get: { nav.selectedReportID }, set: { nav.selectedReportID = $0 }),
                       searchQuery: $reportsSearch)
        .navigationSplitViewColumnWidth(min: 300, ideal: 360)
    #else
    ReportsListView(selection: Binding(get: { nav.selectedReportID }, set: { nav.selectedReportID = $0 }))
        .navigationSplitViewColumnWidth(min: 320, ideal: 380)
    #endif
}
```
Implement `catalogStore` as `@State private var catalogStore = CatalogStore()`, `catalogSelectionBinding` mapping `nav.selectedCatalogID`, `catalogDetail` resolving the selected entry (empty-state "Select a question" when nil; auto-select first on load at regular width), and `bind(_:_:)`:
```swift
private func bind(_ keyPath: ReferenceWritableKeyPath<PaneNavigation, String?>, _ nav: PaneNavigation) -> Binding<String?> {
    Binding(get: { nav[keyPath: keyPath] }, set: { nav[keyPath: keyPath] = $0 })
}
```

- [ ] **Step 3: Add to both targets, build**

Add `App/Sources/Shell/LargeScreenShell.swift` to DispatchMac membership; `xcodegen generate`; build both. Do not wire it into a root yet (Tasks 3.3/3.4). At this point it compiles but is unused.
Expected: `BUILD SUCCEEDED` on both. (If unused-view warnings block nothing, proceed.)

- [ ] **Step 4: Commit**

```bash
git add App/Sources/Shell/LargeScreenShell.swift project.yml
git commit -m "feat(shell): shared large-screen split shell (unwired)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### Task 3.3: Adopt the shell on Mac

**Files:**
- Modify: `Mac/Sources/MacRootView.swift` (host `LargeScreenShell`; delete `MacDetailPane`; replace `MacNavigation` with `PaneNavigation`)
- Modify: `Mac/Sources/DispatchMacApp.swift` (inject `PaneNavigation`; Manage menu ⌘1–5 → `nav.show(...)` with `AppPane`)

**Interfaces:**
- Consumes: `LargeScreenShell` (3.2), `PaneNavigation` (3.1).
- Produces: Mac renders `LargeScreenShell`; the reports sidebar shows only on Dashboard; the pane picker is the only title.

- [ ] **Step 1: Replace `MacRootView` body with the shell; retain the export alert**

Rewrite `MacRootView` to inject nothing new but host `LargeScreenShell` wrapped with the existing `.alert` for `exportController`. Delete the local `MacNavigation` class and `MacDetailPane` enum (now provided by DispatchKit as `PaneNavigation`/`AppPane`). Update `DispatchMacApp.swift` where it constructs `MacNavigation()` → `PaneNavigation()` and where the Manage menu calls `navigation.show(.dashboard/.insights/...)` (the `AppPane` cases match by name).

- [ ] **Step 2: Regenerate, build, run the full Mac screenshot suite**

```bash
xcodegen generate
xcodebuild -project Dispatch.xcodeproj -scheme DispatchMac -destination 'platform=macOS' build
env TEST_RUNNER_SCREENSHOT_MODE=1 xcodebuild test -project Dispatch.xcodeproj -scheme DispatchMac -destination 'platform=macOS' -only-testing:DispatchMacUITests/MacScreenshotTests
```
Expected: build succeeds; all 7 shots pass; the ⌘1–5 navigation (via `showPane`) still switches panes. Off-Dashboard shots (03/05/06/07) now show no reports sidebar.

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "refactor(mac): adopt shared LargeScreenShell; hide reports sidebar off Dashboard

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### Task 3.4: Adopt the shell on iPad

**Files:**
- Modify: `App/Sources/RootNavigationView.swift` (iPad branch → `LargeScreenShell`; delete `PadRootView`)
- Modify: `App/Sources/DispatchApp.swift` (inject a `PaneNavigation` into the environment for the iPad path)

**Interfaces:**
- Consumes: `LargeScreenShell` (3.2), `PaneNavigation` (3.1).
- Produces: iPad renders the same shell (pane picker + trailing Settings gear); iPhone unchanged (`HomeView`).

- [ ] **Step 1: Add a failing iPad UI test**

In `AppUITests` add `PadShellUITests.swift`:
```swift
func testIpadPanePickerSwitchesToCatalog() {
    let app = XCUIApplication()
    app.launchArguments = ["--ui-testing", "--demo-data", "--mock-sensors"]
    app.launch()
    // Regular-width (iPad) only: the pane picker exists.
    let picker = app.descendants(matching: .any).matching(identifier: "detail-pane-picker").firstMatch
    XCTAssertTrue(picker.waitForExistence(timeout: 5))
    app.buttons["Catalog"].firstMatch.tap()
    XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "question-catalog-list").firstMatch.waitForExistence(timeout: 5))
}
```
Run on an iPad simulator:
`xcodebuild test -project Dispatch.xcodeproj -scheme DispatchApp -destination 'platform=iOS Simulator,name=iPad (10th generation)' -only-testing:DispatchUITests/PadShellUITests/testIpadPanePickerSwitchesToCatalog`
Expected: FAIL (no picker; still `PadRootView`).

- [ ] **Step 2: Replace the iPad branch with the shell**

In `RootNavigationView.swift`:
```swift
var body: some View {
    if UIDevice.current.userInterfaceIdiom == .pad {
        LargeScreenShell()
    } else {
        HomeView()
    }
}
```
Delete `PadRootView`. Inject `PaneNavigation` where the iPad scene is built in `DispatchApp.swift` (e.g. `.environment(PaneNavigation())` on the root, guarded so iPhone doesn't pay for it, or unconditionally — it's cheap). Ensure `ReportsListView` and the shared pane views are reachable from the shell on iOS (they already compile there).

- [ ] **Step 3: Regenerate, build, run the iPad test + iPhone smoke test**

```bash
xcodegen generate
xcodebuild -project Dispatch.xcodeproj -scheme DispatchApp -destination 'generic/platform=iOS Simulator' build
xcodebuild test -project Dispatch.xcodeproj -scheme DispatchApp -destination 'platform=iOS Simulator,name=iPad (10th generation)' -only-testing:DispatchUITests/PadShellUITests/testIpadPanePickerSwitchesToCatalog
```
Expected: build succeeds; iPad test PASSES. Spot-check an existing iPhone UI test still passes (HomeView path unchanged).

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "feat(ipad): adopt shared pane-picker shell

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### Task 3.5: Settings restructure (slim iPad/Mac; iPhone Manage section)

**Files:**
- Modify: `App/Sources/Settings/SettingsView.swift` (add a "Manage" section on iPhone with Questions / Prompt Groups / Catalog as peers; these rows already exist scattered — consolidate)
- Modify: `Mac/Sources/MacSettingsView.swift` (drop the promoted rows — Questions/Groups/Catalog — leaving Data, Sensors, Notifications, Appearance, App Lock, Webhooks, About)

**Interfaces:**
- Consumes: existing destinations (`QuestionSettingsView`, `PromptGroupsView`, `CatalogView`, etc.).
- Produces: iPhone Settings root shows a Manage section (Questions, Prompt Groups, Catalog) one tap deep; iPad/Mac Settings show only configuration.

- [ ] **Step 1: iPhone — add the Manage section**

In `SettingsView.swift`, add a `manageSection` placed near the top of the `List` (after any header, before `scheduleSection`), and remove the now-duplicated `PromptGroupsView`/`QuestionSettingsView` links from `scheduleSection`/`surveySection` (leave Insights where it is):
```swift
private var manageSection: some View {
    Section("Manage") {
        NavigationLink(destination: QuestionSettingsView()) { settingsLabel("Questions") }
        NavigationLink(destination: PromptGroupsView()) { settingsLabel("Prompt Groups") }
        NavigationLink(destination: CatalogView()) { settingsLabel("Catalog") }
    }
}
```
Add `manageSection` to the `List` body. (Catalog previously lived under Questions → Catalog; keep that inner link too or remove it to avoid two paths — remove the inner one for a single canonical path.)

- [ ] **Step 2: Mac — slim `MacSettingsView`**

Remove any Questions/Groups/Catalog navigation from `MacSettingsView` (they're panes now). Keep Data, Sensors, Notifications, Appearance, App Lock, Webhooks, About. `⌘,` still opens this window.

- [ ] **Step 3: Build both; run iPhone settings UI smoke**

```bash
xcodegen generate
xcodebuild -project Dispatch.xcodeproj -scheme DispatchApp -destination 'generic/platform=iOS Simulator' build
xcodebuild -project Dispatch.xcodeproj -scheme DispatchMac -destination 'platform=macOS' build
```
Expected: both succeed. If an existing settings UI test referenced the old Questions/Groups path, update it to the Manage section.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "refactor(settings): slim on iPad/Mac; iPhone Manage section

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### Task 3.6: Sprint 3 verification gate + duplicate-title check

- [ ] **Step 1: Full suite**

```bash
swift test
xcodegen generate
xcodebuild -project Dispatch.xcodeproj -scheme DispatchApp -destination 'generic/platform=iOS Simulator' build
xcodebuild -project Dispatch.xcodeproj -scheme DispatchMac -destination 'platform=macOS' build
env TEST_RUNNER_SCREENSHOT_MODE=1 xcodebuild test -project Dispatch.xcodeproj -scheme DispatchMac -destination 'platform=macOS' -only-testing:DispatchMacUITests/MacScreenshotTests
xcodebuild test -project Dispatch.xcodeproj -scheme DispatchApp -destination 'platform=iOS Simulator,name=iPad (10th generation)' -only-testing:DispatchUITests/PadShellUITests
```
Expected: everything green.

- [ ] **Step 2: Verify no duplicate pane title**

Confirm no shared pane view sets its own `navigationTitle` while hosted in the shell (the picker is the title). Grep the shared pane views for `navigationTitle` and remove/guard any that render inside the shell detail:
`grep -rn "navigationTitle" App/Sources/Insights App/Sources/HomeView.swift App/Sources/Catalog` — the catalog push host (`CatalogView`) keeps its title (iPhone), but the shell hosts `CatalogListView` directly (no title). Confirm shot captures show a single pane name.

- [ ] **Step 3: Confirm the four Mac defects are resolved** — (1) off-Dashboard shots show no reports sidebar; (2) panes are themed to the app color; (3) single pane title; (4) catalog Submit is `plus`. Document in the commit body.

- [ ] **Step 4: Final commit (if any cleanup)**

```bash
git add -A
git commit -m "chore: convergence cleanup + verification

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-review notes (author)

- **Spec coverage:** §5 catalog → Tasks 1.3–1.5; §6 preview → 1.1–1.2; §7 shell → 3.1–3.4; §8 Settings → 3.5; §9 four fixes → fix 4 in 1.4, fixes 1&3 in 3.3/3.6, fix 2 across Sprint 2; §10 sprint order preserved; §11 testing → the `swift test` + UI-test steps and preserved identifiers.
- **Deferred detail (intentional):** Sprint 2's per-file `#if os` guards and Sprint 3's `LargeScreenShell` pane-view names depend on the exact shape of files not fully reproduced here (`PromptGroupsView` 1,029 lines, `HomeView` 470). Those tasks direct the implementer to read the specific file and apply the stated pattern, with exact membership/wiring/verification — appropriate for a mechanical port, not a placeholder for new logic.
- **Type consistency:** `QuestionPreviewControl`/`NumberPreview` cases match between 1.1 (producer) and 1.2 (consumer); `AppPane`/`PaneNavigation` members match between 3.1 (producer) and 3.2/3.3 (consumers); `CatalogListView(store:selection:onSubmit:)` matches between 1.4 (producer) and 3.2 (consumer).
