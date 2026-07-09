# Dispatch Plan 21: Number input styles

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** number questions gain user-selectable input styles — slider, stepper, dial, tap counter, rating scale — per the approved spec `docs/superpowers/specs/2026-07-09-number-input-styles-design.md` (read it first; it is the contract).

**Architecture:** additive optional Question fields (`inputStyleRaw`, `inputMin/Max/Step`) + an editor picker + a style switch in the survey's number case. Every style writes the same `numericResponse` string through the existing answer path — storage, export, viz, sync untouched.

**Tech Stack:** SwiftUI custom controls (dial = drag-angle gesture; tapCounter = button with long-press decrement; scale = tappable dot row), system Slider/Stepper dressed to theme.

## Global Constraints

- No new entitlements (profiles pinned). Additive optional schema only; nils omitted from v2 export (tested); unknown `inputStyleRaw` → textField. No schemaVersion bump.
- Suites green before every commit (counts from the previous plan's final report); scoped commit + push per task; `git pull --rebase` before starting/pushing (pushing to main is the repo owner's standing instruction). Do NOT bump the build number.
- TDD: kit tests written first per task; UI behavior covered by the suite where the harness allows.
- Accessibility bar (Plan 17): custom controls are `.accessibilityAdjustable` with value announcements; Dynamic Type survives XXL.

---

### Task 1: Kit — NumberInputStyle fields + schema

**Files:**
- Modify: `Sources/DispatchKit/Models/Question.swift` (fields + enum), `Sources/DispatchKit/V2/V2Models.swift`, `V2Exporter.swift`, `Sources/DispatchKit/Import/V2Importer.swift`
- Test: `Tests/DispatchKitTests/V2ExportTests.swift`, `RoundTripTests.swift`, new `NumberInputStyleTests.swift`

**Interfaces (produced — Task 2 relies on these exact names):**
- `enum NumberInputStyle: String { case textField, slider, stepper, dial, tapCounter, scale }`
- `Question.inputStyle: NumberInputStyle` (get: raw ?? .textField, unknown → .textField; set: writes raw, `.textField` writes nil)
- `Question.inputStyleRaw: String?`, `inputMin: Double?`, `inputMax: Double?`, `inputStep: Double?` (all optional, CloudKit-safe)
- `NumberInputStyle.defaults` per spec table (e.g. slider → (min: 0, max: 10, step: 1)) as a static helper `resolvedConfig(for:min:max:step:) -> (min: Double, max: Double, step: Double)` clamping invalid combos to defaults.

**Contract:** spec §Model + §Styles table verbatim. Tests first: raw round-trip incl. unknown-raw fallback; resolvedConfig defaults + invalid-combo clamps (min ≥ max, step ≤ 0 → style defaults); v2 export includes fields when set / omits when nil (extend the existing nil-omission test); v2 import tolerance; old-fixture unchanged.

Verify: `swift test` (all green). Commit `feat(kit): number input style fields + schema` → push.

### Task 2: App — editor picker + survey controls + accessibility

**Files:**
- Modify: `App/Sources/Settings/QuestionEditorView.swift` (INPUT STYLE picker + config fields), `App/Sources/Survey/QuestionPageView.swift` (number case switches on style)
- Create: `App/Sources/Survey/NumberInputViews.swift` (DialInput, TapCounterInput, ScaleInput, themed Slider/Stepper wrappers — one file, focused views)
- Test: extend `AppUITests/NavigationUITests.swift` (or the survey UI test file): editor sets style; survey renders it and the answer saves.

**Interfaces (consumed):** Task 1's `Question.inputStyle` / `resolvedConfig`. Each input view: `init(value: Binding<String>, config: (min: Double, max: Double, step: Double))` — value is the same numericResponse string binding the text field uses today (empty string = untouched/skipped; views write the formatted number on interaction; tapCounter writes "0" only after first interaction per spec).

**Contract:** spec §Editor (identifiers `input-style`, `input-min`, `input-max`, `input-step`; validation = finite, min < max, step > 0, invalid → not persisted — reuse the default-answer validation pattern) + §Survey rendering + §Accessibility verbatim. Flush-registry: non-text styles register nothing (values commit on interaction). UI test: create a number question, set style to slider via editor, run a survey (--mock-sensors), move the slider, DONE, assert the saved report detail shows the numeric answer.

Verify: build, kit suite, UI suite (+1). Commit `feat: number input styles — slider, stepper, dial, tap counter, scale` → push. Whole-branch review follows (controller-driven).
