# Design: Number input styles + Contacts suggestions

**Status:** approved in discussion 2026-07-09 (Robbie); spec for the Plan 21 implementation plan.

## Goal

1. Number questions gain user-selectable input styles beyond the text field: slider, stepper, dial, tap counter, rating scale.
2. People questions optionally blend the user's Contacts into the existing typeahead suggestions.

## Part 1 — Number input styles

### Model (additive, CloudKit-safe, no schemaVersion bump)

`Question` gains optional fields:
- `inputStyleRaw: String?` — nil = textField (today's behavior); values: `slider`, `stepper`, `dial`, `tapCounter`, `scale`. Exposed as `enum NumberInputStyle`. Unknown raw → textField (forward compat).
- `inputMin: Double?`, `inputMax: Double?`, `inputStep: Double?` — meaning per style (below). Nil defaults per style.

v2 export includes the fields when set, omits when nil; import tolerates absence; round-trip + nil-omission tests (established pattern).

### Styles

| Style | Config | Defaults | Notes |
|---|---|---|---|
| textField | — | — | current behavior, remains default |
| slider | min/max/step | 0–10, step 1 | value label above; integer display when step is whole |
| stepper | step, optional min/max | step 1, min 0, no max | large +/− buttons + value; long-press repeats |
| dial | min/max/step | 0–10, step 1 | custom rotary drag control; the whimsy option |
| tapCounter | optional max | min 0, no max | huge increment button, counts taps; long-press decrements; shows running count |
| scale | min/max (integer count of points, e.g. 1–5) | 1–5 | row of tappable dots with selected-state fill |

All styles write the same `numericResponse` string through the existing answer path — storage, exports, visualization, default-answer logic, and sync are untouched. Empty/untouched still means skipped (or the question's default answer, per Plan 11 semantics); tapCounter at 0 with no interaction = skipped, after interaction = "0" is a real answer (interaction tracked in view state).

### Editor

Number questions get an "INPUT STYLE" picker (same pattern as the visualization picker) + contextual config fields for the chosen style (numeric-validated like default answer: finite Doubles, min < max, step > 0; invalid → not persisted). Identifiers `input-style`, `input-min`, `input-max`, `input-step`.

### Survey rendering + accessibility

`QuestionPageView`'s number case switches on the style. Custom controls (dial, tapCounter, scale) are `.accessibilityAdjustable` with value announcements; system-derived ones (slider, stepper) inherit. All respect Dynamic Type (config values in labels scale). No keyboard for non-text styles → the flush-registry path is a no-op for them (values commit on interaction).

## Part 2 — Contacts suggestions for people questions

### Decision: contacts are a suggestion source ONLY — no contact data is stored

Research finding (2026-07-09, cited in the plan): `CNContact.identifier` is device-local by Apple's documented contract ("only uniquely identifies the contact on the current device"); the same iCloud contact carries different identifiers on different devices, and identifiers churn on link/unlink, account re-add, and restore. The server-side CardDAV UID is not publicly exposed. Since Dispatch reports sync across devices, storing identifiers would silently mismatch off-device.

Therefore: picking a contact suggestion inserts the contact's display name as the token text — byte-identical in storage to typing it. Same-person consistency comes from picking (same contact → same string every time). **Non-goal, documented for the future:** a person-identity feature (synced app-level person UUID + per-device contact caches matched by phone/email) — the standard workaround if rename-healing or contact photos are ever wanted. Not built now.

### Behavior

- "Suggest from Contacts" toggle, default OFF (Settings → Sensors area with the other data-source toggles) + a one-time inline offer footer the first time a people question's suggestions render.
- Enabling makes one standard `CNContactStore.requestAccess(for: .contacts)` call. `NSContactsUsageDescription` purpose string ("Dispatch suggests names from your contacts when you answer people questions. Contacts are never stored or uploaded."). Purpose string only — NO new entitlement (profiles pinned).
- iOS limited-access is transparent: the user may grant full or a subset in the system dialog; our single code path queries whatever the store returns. No ContactAccessButton, no state machine.
- Suggestion pipeline: existing history suggestions first (usage-ranked TokenSuggester, unchanged), then contact matches (given/family/nickname prefix match on the typed text, unified contacts, fetched off-main, cached per field appearance), deduped case-insensitively against history entries, total cap unchanged (8).
- Empty query: history top-used only (contacts appear only while typing — avoids surfacing an arbitrary contact list unprompted).
- Denied/revoked/no-access: silently history-only; the settings toggle shows an "allow in Settings" hint when on-but-denied.
- Contact fetch failures degrade silently to history-only (logged).

### Testing

- Kit: suggestion merge/dedupe/ordering is pure — extend TokenSuggester (or a wrapper) with contact-candidate blending + tests.
- App: contacts access is test-gated (`--mock-sensors` → stub contact provider); one UI test asserts blended suggestions render from the stub.

## Error handling summary

Invalid editor config → not persisted (field-level validation). Unknown inputStyleRaw → textField. Contacts errors → history-only suggestions, logged, never user-facing. No new crash surfaces: no continuations in the contacts path (async/await store enumeration off-main).

## Constraints inherited from the project

No new entitlements; suites green per commit; additive schema only; test-gating; accessibility per the Plan 17 bar.
