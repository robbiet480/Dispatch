# Dispatch Plan 20: Community Question Catalog (CloudKit public DB)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** a shared question repository — anyone can submit a question, anyone can browse approved ones and add them to their Dispatch — built entirely on the existing CloudKit container's **public database**. Moderation via a local `dispatch-mod` tool (CLI + localhost web dashboard) using a CloudKit server-to-server key.

## Design decisions (decide + log)

- **Two record types = the moderation boundary.** `SubmittedQuestion` (any authenticated user creates; NOT world-readable once permissions are locked in Console) and `CatalogQuestion` (world-readable; creatable by NO client role — only the server-to-server key). Approval = the mod tool copying a submission into the catalog. Clients cannot self-approve by construction, not by policy.
- **Record shapes:** SubmittedQuestion {prompt, typeRaw, choicesJSON, creditName?, submittedAt}; CatalogQuestion {prompt, typeRaw, choicesJSON, credit?, approvedAt, tags?}; QuestionFlag {catalogRecordName, reason, flaggedAt}. Anonymous by default; optional credit name. No user identifiers stored beyond CloudKit's own creator metadata.
- **Kit-side `CatalogValidation`** shared by app + mod tool: prompt length bounds, type whitelist (the 7 QuestionTypes), choices sanity for multi-choice, profanity/URL rejection is NOT attempted client-side (that's what moderation is for) — validation is structural only. Pure + tested.
- **App UI:** Settings/Questions → "Question Catalog": browse approved (CKQuery, sorted by approvedAt desc, paginated), search, one-tap "Add to my questions" (creates a local Question with a FRESH UUID — catalog identity never collides with sync identity), "Submit a question" form (writes SubmittedQuestion; confirmation explains moderation), flag button per catalog entry. All CloudKit calls off-main, degrade gracefully (no account → browse works, submit explains it needs iCloud). Test-gated: UI tests get a stubbed catalog provider, never real CloudKit.
- **Moderation = `dispatch-mod`**, a Swift executable target in the package: CloudKit Web Services requests signed with the server-to-server key (ECDSA over the documented signature format — verify the format against Apple's CloudKit Web Services docs, don't recall it). Subcommands: `list` (pending + flags), `approve <id>` (creates CatalogQuestion, deletes/marks the submission), `reject <id>`, `serve` (localhost dashboard: static HTML/JS served by the tool, calling its own signing endpoints — the key never leaves the machine). Key path/config via env or ~/.dispatch-mod, NEVER in the repo. Note in the doc: the dashboard HTML is deliberately portable to a Cloudflare Worker later (documented follow-up, not built now).
- **No entitlement changes** — public DB rides the existing CloudKit entitlement. TestFlight caveat unchanged: record types + permissions + indexes must be deployed Dev → Production in Console before TestFlight users see the catalog.

## User actions (account holder only — surface, don't attempt)

1. CloudKit Console: create a **server-to-server key** (Settings → Tokens/Keys); store per README-mod instructions.
2. Console permissions after first dev write creates the record types: `CatalogQuestion` — World: read, Authenticated: none, Creator: n/a (creation only via server key). `SubmittedQuestion` — World: NO read, Authenticated: create, Creator: read/write own. `QuestionFlag` — Authenticated: create, World: no read.
3. Console indexes: CatalogQuestion.approvedAt (sortable), prompt (searchable/queryable) as the implementation requires (the mod tool/report will list exactly which).
4. Deploy schema Dev → Production.

## Global Constraints

- No delegation; suites green before every commit (counts from the previous plan's final report); commit + push per task; `git pull --rebase` before starting/pushing (pushing to main is standing instruction). No new entitlements. No local schema changes (catalog questions become ordinary local Questions on add). Do NOT bump the build number.

---

### Task 1: Kit — catalog types + validation

**Files:** new `Sources/DispatchKit/Catalog/CatalogQuestion.swift` (value types + CKRecord-field mapping as plain dictionaries so the kit stays CloudKit-import-free if possible — decide and document), `CatalogValidation.swift` + tests.
Verify: `swift test`. Commit `feat(kit): question catalog types + validation` → push.

### Task 2: App — catalog browse/submit/flag UI

**Files:** new `App/Sources/Catalog/` (CatalogStore: public-DB queries via CKContainer; views: browse list, search, detail w/ Add + Flag, submit form); Settings/Questions entry point.
Contract: per design; stubbed provider under test args; +1 UI test (catalog opens, renders stubbed entries, Add creates a local question).
Verify: build, kit suite, UI suite. Commit `feat: community question catalog` → push.

### Task 3: dispatch-mod tool + wrap

**Files:** `Package.swift` (executable target, macOS platform gate so iOS builds unaffected), new `Sources/dispatch-mod/` (signing, subcommands, embedded dashboard HTML), `docs/moderation.md` (key setup, Console permission/index/deploy checklist from "User actions" above).
Contract: signature format doc-verified with a real request against the Development environment (list on an empty DB is a safe smoke); `serve` dashboard lists/approves/rejects against Development; clear errors when the key/config is absent. CI unaffected (executable builds on macOS only — confirm `swift build`/`swift test` still green on CI's macOS image).
Verify: build, kit suite, UI suite, `swift run dispatch-mod --help`. Commit `feat: dispatch-mod moderation tool + dashboard` → push. Whole-branch review follows (controller-driven).
