# Design: Number input styles

**Status:** approved in discussion 2026-07-09 (Robbie). Split from the combined input-styles+contacts spec; the companion is `2026-07-09-person-identity-design.md`.

## Goal

Number questions gain user-selectable input styles beyond the text field: slider, stepper, dial, tap counter, rating scale.

## Model (additive, CloudKit-safe, no schemaVersion bump)

`Question` gains optional fields:
- `inputStyleRaw: String?` — nil = textField (today's behavior); values: `slider`, `stepper`, `dial`, `tapCounter`, `scale`. Exposed as `enum NumberInputStyle`. Unknown raw → textField (forward compat).
- `inputMin: Double?`, `inputMax: Double?`, `inputStep: Double?` — meaning per style (below). Nil defaults per style.

v2 export includes the fields when set, omits when nil; import tolerates absence; round-trip + nil-omission tests (established pattern).

## Styles

| Style | Config | Defaults | Notes |
|---|---|---|---|
| textField | — | — | current behavior, remains default |
| slider | min/max/step | 0–10, step 1 | value label above; integer display when step is whole |
| stepper | step, optional min/max | step 1, min 0, no max | large +/− buttons + value; long-press repeats |
| dial | min/max/step | 0–10, step 1 | custom rotary drag control; the whimsy option |
| tapCounter | optional max | min 0, no max | huge increment button, counts taps; long-press decrements; shows running count |
| scale | min/max (integer count of points, e.g. 1–5) | 1–5 | row of tappable dots with selected-state fill |

All styles write the same `numericResponse` string through the existing answer path — storage, exports, visualization, default-answer logic, and sync are untouched. Empty/untouched still means skipped (or the question's default answer, per Plan 11 semantics); tapCounter at 0 with no interaction = skipped, after interaction = "0" is a real answer (interaction tracked in view state).

## Editor

Number questions get an "INPUT STYLE" picker (same pattern as the visualization picker) + contextual config fields for the chosen style (numeric-validated like default answer: finite Doubles, min < max, step > 0; invalid → not persisted). Identifiers `input-style`, `input-min`, `input-max`, `input-step`.

## Survey rendering + accessibility

`QuestionPageView`'s number case switches on the style. Custom controls (dial, tapCounter, scale) are `.accessibilityAdjustable` with value announcements; system-derived ones (slider, stepper) inherit. All respect Dynamic Type (config values in labels scale). No keyboard for non-text styles → the flush-registry path is a no-op for them (values commit on interaction).

## Error handling

Invalid editor config → not persisted (field-level validation). Unknown inputStyleRaw → textField.

## Constraints inherited from the project

No new entitlements; suites green per commit; additive schema only; test-gating; accessibility per the Plan 17 bar.
