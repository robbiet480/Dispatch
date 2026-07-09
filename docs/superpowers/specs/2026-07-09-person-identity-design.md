# Design: Person identity + Contacts integration

**Status:** approved in discussion 2026-07-09 (Robbie). Split from the combined input-styles+contacts spec; companion: `2026-07-09-number-input-styles-design.md`. Supersedes the earlier "contacts as suggestion source only" design after Robbie opted into full person identity.

## Goal

People in Dispatch become stable identities — surviving renames, unifying duplicate contact cards, syncing across devices — with the user's Contacts as an optional, per-device-linked suggestion source (names + photos in the typeahead).

## Research constraint that shapes everything (2026-07-09)

`CNContact.identifier` is device-local by Apple's documented contract ("only uniquely identifies the contact on the current device"); the same iCloud contact carries different identifiers on different devices (format even differs: `UUID:ABPerson` on macOS vs bare UUID on iOS — reproduced in Robbie's own data); identifiers churn on link/unlink, account re-add, restore; the server-side CardDAV UID is not publicly exposed. **Therefore contact identifiers never enter synced data.** Identity is app-level; contact linkage is a per-device cache.

## Architecture: promote PersonEntity into the registry

`PersonEntity` (the existing, already-synced people-vocabulary model) becomes the person registry. **Report storage does not change**: people answers remain name-text tokens (Reporter-format, v1/v2-compatible, sync-stable). Identity is a resolution layer — text → person — applied by suggestions, visualization, insights, and the management UI.

### Model changes (additive, CloudKit-safe)

`PersonEntity` gains:
- `uniqueIdentifier: String` (defaulted UUID — the synced person identity)
- `alternateNames: [String]` (defaulted `[]` — previous display names and aliases)

`text` remains the current display name. Resolution: a name matches a person if it equals `text` or any `alternateNames` entry (case/diacritic-insensitive). v2 export: PersonEntity vocabulary is derived data today (rebuilt from responses) — the registry fields make it authoritative-ish, so v2 export gains an optional `people` array (uniqueIdentifier, displayName, alternateNames); import tolerates absence (falls back to rebuild-derived entries). `VocabularyBuilder.rebuild` must PRESERVE registry fields (match existing entities by text/alternateNames instead of delete-all-recreate — this is the one genuinely delicate change; tested thoroughly).

### Rename healing

Renaming a person (management UI) moves the old `text` into `alternateNames` and sets the new display name. Historical reports keep their original text (honest history) but resolve to the same person everywhere: frequency viz, insights, suggestions, filters. New answers insert the current display name.

### Merge

Merging person B into person A: A absorbs B's `text` + `alternateNames` into its alternates, sums usage counts, B is deleted. `SyncDedupe` learns the same merge semantics for duplicate PersonEntities arriving via sync (union alternate names; deterministic survivor as today).

### Per-device contact link (never synced)

A local cache (app-group defaults or a small local-only store): person `uniqueIdentifier` → this device's `CNContact.identifier`, plus normalized match keys (email/phone) captured at link time for re-resolution when the identifier churns. Established automatically when the user picks a contact suggestion, or explicitly via "Link to Contact" (system contact picker). Resolution order at photo/detail time: cached identifier → keys-to-fetch verify → re-match by email/phone → unlink silently on total failure. Contact photos are fetched live from the linked contact for display only — never stored, never synced.

## Contacts in the typeahead

- "Suggest from Contacts" toggle, default OFF (Settings, with a one-time inline offer under a people question). Enabling makes one standard `CNContactStore.requestAccess(for:)` call — `NSContactsUsageDescription` purpose string, NO entitlement. iOS full-vs-limited access is transparent (single code path over whatever the store returns).
- Pipeline: history/registry suggestions first (usage-ranked, now person-resolved so alternate names don't produce duplicate chips), then contact matches (given/family/nickname prefix, unified contacts, `thumbnailImageData`, off-main, cached per appearance), deduped against registry persons AND by identical display text (duplicate cards → one chip, prefer the one with a photo), cap 8.
- Chips: person/contact chips show the photo when a linked/matched contact provides one.
- Picking a contact suggestion: inserts the display name, creates the PersonEntity if new, records the per-device link.
- Empty query: history top-used only. Denied/revoked/errors: silently history-only; settings hint when on-but-denied.
- **Known limitation (accepted):** two different people with an identical full display name collapse into one person. Splitting them requires per-answer person references (a storage format change) — out of scope; the human fix is distinct names. The "details popover while typing" idea is deferred to any future per-answer-reference design where picks could differ in outcome.

## Management UI

Settings → **People**: list (photo, display name, alternate names caption, report count), rename (heals), merge (multi-select → merge), link/unlink contact, delete (removes registry entry only — reports untouched; vocabulary rebuild may resurrect a plain entry, documented). Identifiers `people-list`, `person-rename`, `person-merge`, `person-link`.

## Consumers updated to resolve through the registry

Frequency visualization (people questions), Insights (person-keyed signals), ReportFilter person criterion, TokenSuggester people path. Each resolves text → person and aggregates by person, displaying the current display name.

## Testing

- Kit: resolution (text→person incl. alternates, case/diacritics), rename healing, merge (incl. SyncDedupe union), VocabularyBuilder preservation (the delicate one — fixtures with pre-existing registry data), v2 people round-trip + absence tolerance.
- App: contact provider stubbed under test args; UI tests: People screen renders, rename flow, blended suggestions with stub contacts.

## Error handling

Contact resolution failures degrade to text-only display (no photo), logged. Link cache misses self-heal by key-matching or silently unlink. No continuations in the contacts path. Registry corruption impossible-by-construction: answers never depend on the registry (text is always the ground truth).

## Constraints inherited from the project

No new entitlements (purpose string only); suites green per commit; additive schema only; test-gating; accessibility per the Plan 17 bar; SyncDedupe determinism preserved.
