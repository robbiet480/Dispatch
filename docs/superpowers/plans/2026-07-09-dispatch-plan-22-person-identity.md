# Dispatch Plan 22: Person identity + Contacts integration

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** stable person identities — rename-healing, duplicate-merging, cross-device-syncing — with Contacts as an optional per-device-linked suggestion source (names + photos), per the approved spec `docs/superpowers/specs/2026-07-09-person-identity-design.md` (read it first; it is the contract, including the research constraint that contact identifiers NEVER enter synced data).

**Architecture:** PersonEntity (already synced) is promoted to the registry via additive fields (`uniqueIdentifier`, `alternateNames`). Report answers remain name text — identity is a resolution layer used by suggestions, viz, insights, filters, and a People management screen. Contact links live in a per-device cache keyed by person UUID with email/phone re-matching.

**Tech Stack:** SwiftData additive fields, Contacts framework (CNContactStore, unified contacts, thumbnails), SwiftUI management screen.

## Global Constraints

- No new entitlements (`NSContactsUsageDescription` purpose string only). Additive optional schema; v2 `people` array optional both ways; no schemaVersion bump. Contact identifiers/photos never stored in synced models — per-device cache only.
- Suites green before every commit; scoped commit + push per task; `git pull --rebase` before starting/pushing (pushing to main is standing instruction). Do NOT bump the build number.
- TDD kit-first per task. Contacts test-gated: `--mock-sensors`/`--ui-testing` → stub provider, no permission dialogs.
- The delicate change is `VocabularyBuilder.rebuild` preservation — it currently delete-all-recreates; Task 1 makes it preserve registry fields. Heaviest test coverage lives there.

---

### Task 1: Kit — registry fields, resolution, rebuild preservation, schema, dedupe merge

**Files:**
- Modify: `Sources/DispatchKit/Models/PersonEntity.swift` (wherever PersonEntity is declared — locate), `Sources/DispatchKit/Import/VocabularyBuilder.swift`, `Sources/DispatchKit/Sync/SyncDedupe.swift`, `Sources/DispatchKit/V2/*` (people array)
- Create: `Sources/DispatchKit/People/PersonResolver.swift`
- Test: new `Tests/DispatchKitTests/PersonRegistryTests.swift`, extend `SyncDedupeTests.swift`, `RoundTripTests.swift`

**Interfaces (produced — later tasks rely on these exact names):**
- `PersonEntity.uniqueIdentifier: String` (defaulted UUID), `PersonEntity.alternateNames: [String]` (defaulted [])
- `PersonResolver.person(matching text: String, in: [PersonEntity]) -> PersonEntity?` (case/diacritic-insensitive across text + alternateNames)
- `PersonResolver.rename(_ person: PersonEntity, to newName: String)` (old text → alternateNames, deduped)
- `PersonResolver.merge(_ absorbed: PersonEntity, into survivor: PersonEntity, context: ModelContext) throws` (union names, sum usageCounts, delete absorbed)

**Contract:** spec §Model changes, §Rename healing, §Merge verbatim. VocabularyBuilder.rebuild: match existing entities by text OR alternateNames and update counts in place; create only genuinely new; delete only entities matching nothing AND having no alternateNames (registry entries with aliases survive even at zero current usage — spec's delete semantics). Tests: resolution (case/diacritics/alternates), rename (incl. rename-to-existing-alias no-dup), merge, rebuild preservation (fixtures: pre-existing registry entities with aliases survive rebuild with counts updated; plain rebuild behavior for token entities unchanged), SyncDedupe person-merge unions alternateNames deterministically, v2 people round-trip + absence tolerance + nil-omission.

Verify: `swift test`. Commit `feat(kit): person registry — identity, resolution, healing, merge` → push.

### Task 2: App — contacts provider + typeahead blending + per-device link cache

**Files:**
- Create: `App/Sources/People/ContactSuggestionProvider.swift` (protocol + CNContactStore impl + test stub), `App/Sources/People/ContactLinkCache.swift`
- Modify: `App/Sources/Survey/QuestionPageView.swift` (people-path suggestions), `App/Sources/Settings/SensorSettingsView.swift` (toggle), `project.yml` (NSContactsUsageDescription)
- Test: extend UI suite (stub-blended suggestions render); kit test only if merge logic lands kit-side (prefer kit: `PersonSuggestionMerger.blend(history:contacts:cap:)` in `Sources/DispatchKit/People/` + tests)

**Interfaces:**
- Consumes: Task 1's PersonResolver.
- Produces: `ContactSuggestionProvider.matches(prefix: String) async -> [ContactMatch]` where `ContactMatch { displayName: String, thumbnail: Data?, matchKeys: [String] /* normalized emails+phones */ }`; `ContactLinkCache.link(personID: String, contactIdentifier: String, matchKeys: [String])`, `.contactIdentifier(for personID: String) -> String?`, `.unlink(personID:)` — app-group defaults-backed, never synced.
- `PersonSuggestionMerger.blend(history: [String], contacts: [ContactMatch], cap: Int = 8) -> [PersonSuggestion]` (history first; contacts deduped case-insensitively vs history AND by identical display text preferring thumbnailed; `PersonSuggestion { text: String, thumbnail: Data?, isContact: Bool }`).

**Contract:** spec §Contacts in the typeahead verbatim (toggle default OFF + one-time inline offer; single requestAccess call; limited/full transparent; empty query = history only; denied → history-only + settings hint; picking a contact inserts displayName, creates PersonEntity if new via PersonResolver, records link). Chips render thumbnails per spec. All store access off-main, cached per field appearance, no continuations.

Verify: build, kit suite, UI suite (+ stub test). Commit `feat: contacts suggestions with per-device person links` → push.

### Task 3: People management screen

**Files:**
- Create: `App/Sources/People/PeopleListView.swift`, `PersonDetailView.swift`
- Modify: `App/Sources/Settings/SettingsView.swift` (entry row)
- Test: extend UI suite (People screen renders persons from seeded store; rename flow updates list)

**Interfaces (consumed):** PersonResolver.rename/merge; ContactLinkCache; ContactSuggestionProvider (link-to-contact uses the zero-permission `CNContactPickerViewController` regardless of the suggestions toggle).

**Contract:** spec §Management UI verbatim (identifiers `people-list`, `person-rename`, `person-merge`, `person-link`; delete removes registry entry only with the documented resurrection caveat shown in a confirmation footnote). Photos via linked contact, live-fetched. Rename/merge trigger vocabulary-consumer refresh (the remote-change pipeline's rebuild path or a direct call — match existing patterns).

Verify: build, kit suite, UI suite (+1). Commit `feat: people management — rename, merge, contact links` → push.

### Task 4: Consumers resolve through the registry + wrap

**Files:**
- Modify: `Sources/DispatchKit/Visualization/VisualizationData.swift` (people frequency person-keyed), `Sources/DispatchKit/Visualization/ReportFilter.swift` (person criterion resolves alternates), `Sources/DispatchKit/Insights/InsightsEngine.swift` (person signals resolve — NOTE: lands only if Plan 18 shipped first; otherwise record the integration point in the report), `Sources/DispatchKit/Search/TokenSuggester.swift` people path (alternate names don't produce duplicate chips)
- Test: extend the respective kit test files (renamed person unifies frequency counts; filter matches via alternate name; suggester dedupes aliases)

**Interfaces (consumed):** PersonResolver.person(matching:in:).

**Contract:** spec §Consumers verbatim — aggregate by person, display current display name. Wrap: full suites; completion note in this doc; README People section (what identity does, what's device-local, the same-name limitation).

Verify: build, kit suite, UI suite. Commit `feat: person-resolved visualization, filters, suggestions` → push. Whole-branch review follows (controller-driven).
