# Question Catalog Moderation (`dispatch-mod`)

The community question catalog (plan 20) lives in the **public database** of
the existing CloudKit container (`iCloud.io.robbie.Dispatch` — no new
entitlements). Moderation runs entirely on your Mac through `dispatch-mod`,
a Swift executable in this package, authenticated with a CloudKit
**server-to-server key**.

**The moderation boundary:** clients can create `SubmittedQuestion` and
`QuestionFlag` records only. `CatalogQuestion` records are created exclusively
by the server-to-server key — approval is `dispatch-mod` copying a submission
into the catalog. The app contains no code path that writes `CatalogQuestion`;
with the Console permissions below, clients *cannot* self-approve by
construction.

## Automated setup (`dispatch-mod setup`)

The Console odyssey below (§2–§3 plus the moderator role) is now automated
where CloudKit tooling allows. The manual sections are preserved as the
reference truth and as the fallback when `cktool` is unavailable.

```sh
swift run dispatch-mod setup                     # bootstrap Development (schema import + probes)
swift run dispatch-mod setup --env production    # verify Production (issue #8) — schema deploys via Console, see below
swift run dispatch-mod setup --export            # snapshot live schema → schema.ckdb
```

`setup` drives `xcrun cktool` (ships with Xcode 13+) to import the
repo-canonical schema `Sources/dispatch-mod/schema.ckdb` — record types,
field indexes, the `moderator` security role and every grant in §3a —
then verifies with the same list queries the moderation commands use, and
finally prints the steps that remain manual. It never runs
`cktool reset-schema` (which wipes Development data) and never deletes
records — but note that `cktool import-schema` **replaces** the
environment's whole schema with the file's contents, so record types
missing from `schema.ckdb` are scheduled for deletion (observed on the
live container 2026-07-09; CloudKit refuses when they are active in
Production). On a container with pre-existing types, run
`setup --export` first, merge, then import. Run setup from a source
checkout: the schema path is resolved relative to the source file
(`#filePath`).

**Schema import is Development-only.** Production rejects `cktool`
`import-schema`/`validate-schema` with *"endpoint not applicable in the
environment 'production'"* (verified empirically 2026-07-09). Promotion to
Production is Console-only: **Deploy Schema Changes → Production** (§3c).
`setup --env production` therefore skips the import, prints that Console
instruction, and still runs the verification probes and checklist.

On a **fresh environment**, expect the `SubmittedQuestion`/`QuestionFlag`
probes to fail until the moderator role→user assignment is done in Console —
the server key is role-bound, not a superuser. `setup` labels those failures
as expected; `--strict` makes any probe failure exit nonzero (unexpected
failures always do).

**What the schema language can and cannot express** (verified against
Apple's `sample-cloudkit-tooling` examples and real `cktool export-schema`
output, 2026-07-09):

| Concern | In `.ckdb`? | How |
|---|---|---|
| Record types + fields | ✅ | `RECORD TYPE X ( field STRING, … )` |
| Indexes (§3b) | ✅ | `QUERYABLE` / `SORTABLE` / `SEARCHABLE` after the field type |
| The `createdUserRecordName` trap | ✅ | `"___createdBy" REFERENCE QUERYABLE` — third name for the same field: Console UI says `createdUserRecordName`, server errors say `createdBy`, the schema language says `___createdBy` |
| Permission matrix (§3a) | ✅ | `GRANT READ TO "_world"`, `GRANT CREATE TO "_icloud"`, `GRANT READ, WRITE TO "_creator"` |
| Custom security roles | ✅ | `CREATE ROLE moderator;` + `GRANT CREATE, WRITE TO moderator` |
| Role → **user** assignment | ❌ | Console only, once per environment (see the moderator section below) — `setup` prints the exact instruction with the key's `whoami` identity embedded |
| Schema promotion to **Production** | ❌ | Console only — **Deploy Schema Changes → Production** (§3c). `cktool import-schema`/`validate-schema` are rejected in Production ("endpoint not applicable in the environment 'production'") |
| Server-to-server / management keys | ❌ | Console only (§1 and below). Registrations are **per environment**: register the same public key under Production and you get a *different* key ID — `"keyIDProduction"` in config.json (falls back to `"keyID"`) |

`Tests/DispatchKitTests/ModSchemaTests.swift` pins `schema.ckdb` to the
documented matrix/indexes so an export can't silently drop them.

> **Provenance:** `schema.ckdb` was authored from this document's
> battle-tested truth (grammar validated against Apple's published examples).
> `xcrun cktool validate-schema` accepts it against the live Development
> environment ("✅ Schema is valid.", 2026-07-09). It has not yet been
> round-tripped through a live `cktool export-schema`; run
> `swift run dispatch-mod setup --export` against Development once, diff, and
> commit — that makes the file export-canonical.

### Management token (one time, for `setup` only)

`cktool` schema operations need a CloudKit **management token** (distinct
from the §1 server-to-server key, which signs data-plane requests):

1. [CloudKit Console](https://icloud.developer.apple.com/dashboard/account/tokens)
   → Tokens & Keys → **Management Tokens** → ＋.
2. `xcrun cktool save-token --type management` (stores in the login
   keychain; `--method file` writes `~/.config/cktool` instead, or export
   `CLOUDKIT_MANAGEMENT_TOKEN`).

`setup` detects a missing token (via `cktool get-teams`), skips the import,
and prints these instructions rather than failing.

`setup` reads the same `~/.dispatch-mod/config.json` as the other
subcommands; the additional optional key `"teamID"` (env:
`DISPATCH_MOD_TEAM_ID`) is the Apple Developer team that owns the container
and defaults to the personal team.

### What `setup` still tells you to do by hand

- Mint the management token (above) if absent.
- Assign the `moderator` role to the server key's user record — per
  environment, in Console (the grammar has no role→user statement; role
  *definitions* deploy with the schema, *assignments* never do).
- Verify the permission matrix from a second Apple ID (§3a).
- For Production: deploy the schema in Console (**Deploy Schema Changes →
  Production**, §3c — cktool cannot), register the same s2s public key under
  Production and record the new key ID as `"keyIDProduction"` (§1 — key
  registrations are per-environment), then run `setup --env production`
  (probes + checklist only), then repeat the role assignment there
  (`whoami --env production` — the identity may differ).

## Bootstrap sequencing (chicken-and-egg order)

Record types only exist once a first record of that type is written, so the
setup below has a required order:

1. **Submit a question from a dev build** → creates `SubmittedQuestion`.
   (The browse screen may show an error until `CatalogQuestion` exists —
   harmless; the app now treats a missing record type as an empty catalog.)
2. **Create the server-to-server key** (§1) → the first
   `dispatch-mod approve` creates `CatalogQuestion` (or create the type
   manually in Console).
3. **`QuestionFlag`:** flag the first catalog entry from the app (or create
   the type manually) — it can't be created before a catalog entry exists.
4. **Then** apply the permission matrix + indexes (§3a/§3b).
5. **Deploy Development → Production** (§3c) — Console only; `cktool` cannot
   import or validate schema against Production.

## 1. Create the server-to-server key (one time)

1. Generate the key pair locally (the private key never leaves your Mac and
   is never committed — `~/.dispatch-mod/` is outside the repo):

   ```sh
   mkdir -p ~/.dispatch-mod && chmod 700 ~/.dispatch-mod
   openssl ecparam -name prime256v1 -genkey -noout -out ~/.dispatch-mod/eckey.pem
   chmod 600 ~/.dispatch-mod/eckey.pem
   openssl ec -in ~/.dispatch-mod/eckey.pem -pubout   # copy this public key
   ```

2. [CloudKit Console](https://icloud.developer.apple.com/) →
   container `iCloud.io.robbie.Dispatch` → **Settings → Tokens & Keys →
   Server-to-Server Keys → Add**. Paste the PUBLIC key, name it
   (e.g. `dispatch-mod`), and copy the generated **Key ID**.

3. Configure the tool:

   ```sh
   cat > ~/.dispatch-mod/config.json <<'EOF'
   {"keyID": "<KEY ID FROM CONSOLE>"}
   EOF
   ```

   Optional keys: `"keyIDProduction"` (see below), `"keyPath"` (default
   `~/.dispatch-mod/eckey.pem`), `"container"` (default
   `iCloud.io.robbie.Dispatch`), `"environment"` (default `development`).
   Environment variables `DISPATCH_MOD_KEY_ID`, `DISPATCH_MOD_KEY_PATH`,
   `DISPATCH_MOD_CONTAINER`, `DISPATCH_MOD_ENV` override the file.

### Key registrations are per-environment (verified live, 2026-07-09)

Server-to-server public keys are registered **per environment**, and each
registration gets its **own key ID**. The Development key ID returns
`AUTHENTICATION_FAILED` against Production until the *same public key* is
registered under Production (Console → **Production** → Server-to-Server
Keys → paste the output of
`openssl ec -in ~/.dispatch-mod/eckey.pem -pubout`), which yields a
different key ID that then authenticates immediately. Put that ID in
`config.json` as `"keyIDProduction"` (it falls back to `"keyID"` when
absent); `DISPATCH_MOD_KEY_ID` remains the quick one-off override for any
environment. The private key stays the same single PEM.

This joins the other production-vs-development traps: schema promotion is
Console-only (§3c) and the moderator role→user assignment is per-environment
and Console-only (bottom section).

## 2. Create the record types (first dev write)

Record types appear in the Development schema the first time a record of that
type is written. Easiest path:

- `SubmittedQuestion` + `QuestionFlag`: run a Development build of the app
  (Xcode builds talk to Development), submit a test question from
  Settings → Questions → Question Catalog → Submit, and flag any entry.
- `CatalogQuestion`: approve that submission with the mod tool —
  `swift run dispatch-mod list` then `swift run dispatch-mod approve <id>`.

(Alternatively create the types manually in Console → Schema with the exact
field names below.)

Field shapes (all created automatically by the writes above):

| Record type | Fields |
|---|---|
| `SubmittedQuestion` | `prompt` String, `typeRaw` Int64, `choicesJSON` String, `creditName` String (optional), `submittedAt` Date/Time, + input config below |
| `CatalogQuestion` | `prompt` String, `typeRaw` Int64, `choicesJSON` String, `credit` String (optional), `approvedAt` Date/Time, `tags` String List (optional), + input config below |
| `QuestionFlag` | `catalogRecordName` String, `reason` String, `flaggedAt` Date/Time |

**Input configuration fields (plan 41):** both `SubmittedQuestion` and
`CatalogQuestion` additionally carry `inputStyle` String, `defaultAnswer`
String, `placeholder` String, `inputMin` Double, `inputMax` Double, and
`inputStep` Double — all optional, all omitted when unset, none indexed
(the catalog sorts on `approvedAt` and filters client-side). They let an
approved question arrive fully configured when a user adds it to their
questions (the plan-21 number input styles). Forward-lenient by omission:
pre-plan-41 app builds only extract keys they know, so records carrying the
new fields render on old builds exactly as before (bare style), and records
without them decode with the fields nil.

**Schema deploy for these columns:** additive columns auto-create in
**Development** on the first write that carries them (a configured submission
from a dev build, or `dispatch-mod import` of a configured seed). But
**Production needs an OWNER Console deploy — Deploy Schema Changes →
Production (§3c)**; `cktool import-schema`/`validate-schema` are rejected in
Production. Writes that OMIT the new fields keep working before the deploy
(they are nil-omitted); only a write that SETS one of the new fields before
the Production deploy would fail. So the deploy gates real use of the
feature in Production, not the merge.

## 3. Console checklist (user actions — required before TestFlight)

### 3a. Record-type permission matrix

Console → Schema → Record Types → *(type)* → **Security**:

| Record type | World | Authenticated | Creator |
|---|---|---|---|
| `CatalogQuestion` | **Read** | *(none — no create/write)* | n/a (only the server key creates these) |
| `SubmittedQuestion` | **No read** | **Create** | Read + Write (own records) |
| `QuestionFlag` | **No read** | **Create** | Read (own records) |

The server-to-server key bypasses these role permissions — that is what makes
approval server-only. Double-check `CatalogQuestion` has NO create permission
for World or Authenticated.

**Verify the matrix, don't just set it:** from a device signed into a
**second Apple ID** (not the container owner — owner accounts can have
elevated access), run a Development build and confirm that querying
`SubmittedQuestion` records fails / returns nothing. If another account can
read the submission queue, the World/Authenticated read permission above was
not applied correctly.

### 3b. Indexes

Console → Schema → Indexes (Development):

| Record type | Field | Index |
|---|---|---|
| `CatalogQuestion` | `recordName` | Queryable *(required for the app's browse query)* |
| `CatalogQuestion` | `approvedAt` | Sortable *(browse sorts newest-approved first)* |
| `SubmittedQuestion` | `recordName` | Queryable *(mod tool queries)* |
| `SubmittedQuestion` | `submittedAt` | Sortable *(mod tool list order)* |
| `QuestionFlag` | `recordName` | Queryable *(mod tool queries)* |
| `QuestionFlag` | `flaggedAt` | Sortable *(mod tool list order)* |
| `SubmittedQuestion` | `createdUserRecordName` | Queryable *(see below)* |
| `QuestionFlag` | `createdUserRecordName` | Queryable *(see below)* |

**Why (and the naming trap):** once §3a's Creator-scoped read permissions are
applied, CloudKit injects an implicit creator filter into queries against those
record types, and that filter requires the creator metadata field to be
Queryable — queries fail with `BAD_REQUEST: Field 'createdBy' is not marked
queryable` otherwise. The server error says **`createdBy`** (legacy API name)
but the Console's Add Index field dropdown lists the SAME field as
**`createdUserRecordName`** — pick that one (found empirically during the first
live bootstrap, 2026-07-09). `CatalogQuestion` keeps World read, so it does
not need this.

Search in the app is client-side over loaded entries, so **no** SEARCHABLE
index on `prompt` is needed.

### 3c. Deploy to Production

Console → Schema → **Deploy Schema Changes → Development → Production**.
This step is Console-only: Production rejects `cktool`
`import-schema`/`validate-schema` ("endpoint not applicable in the
environment 'production'"), so `dispatch-mod setup --env production` prints
this instruction instead of importing.
TestFlight builds talk to Production: until this deploy (types + permissions
+ indexes), TestFlight users see an empty/erroring catalog. Approving into
Production afterwards: `swift run dispatch-mod list --env production`, etc.

## 4. Using the tool

```sh
swift run dispatch-mod list                    # pending submissions + open flags
swift run dispatch-mod approve <recordName> --tags mood,daily
swift run dispatch-mod reject <recordName>
swift run dispatch-mod serve                   # http://127.0.0.1:8787 dashboard
swift run dispatch-mod serve --port 9000 --env production
```

**Accepted question types.** `CatalogValidation` resolves the submission's
`typeRaw` through `QuestionType(rawValue:)`, so every shipped type is
structurally valid — including **time questions (`typeRaw` 7, plan 28)**, which
are accepted in community submissions. Time questions carry **no choices** (a
submitted choice list rejects with `choicesNotAllowed`, same as every
non-multiple-choice type). No moderator action is needed for the new type. Note
the forward-compatibility trade-off: app builds **older than plan 28** render a
catalog time entry as "Unknown type" and cannot install it (the client guards
unknown raws by design — forward-lenient, no data loss). New builds install it
normally.

`approve` validates the submission structurally (same `CatalogValidation` the
app uses), creates the `CatalogQuestion` with a fresh record name, then
deletes the submission. `reject` just deletes. If the post-approve submission
delete fails, the tool prints the leftover submission's record name — reject
it manually; do **not** re-approve it (that would duplicate the catalog
entry). The dashboard is a localhost web page served by the tool itself;
every CloudKit call is signed locally and the key never leaves the machine.

Dashboard hardening (beyond binding to 127.0.0.1 only):

- **Session token (CSRF guard):** each `serve` run generates a random token,
  embeds it in the served page, and rejects any `/api/*` POST that doesn't
  present it in `X-Dispatch-Mod-Token`. A hostile web page in your browser
  cannot forge moderation actions — it never learns the token.
- **Host-header check (DNS-rebinding guard):** requests whose `Host` header
  isn't exactly `127.0.0.1:<port>` are rejected, so a rebound hostname that
  resolves to localhost still can't reach the endpoints.
- **Output escaping:** all record fields (including record names, which are
  untrusted public-database input) are HTML-escaped or bound via
  `addEventListener` — never interpolated into inline handlers.

Smoke test after key setup (safe on an empty database):
`swift run dispatch-mod list` — an empty listing (`Pending submissions (0)`)
proves the signature is accepted; an authentication failure returns
`CloudKit error AUTHENTICATION_FAILED`. Against Production, that error
almost always means the public key isn't registered under Production yet
(or `keyIDProduction` is missing) — key registrations are per-environment,
see §1.

## 5. Signature format (verified against Apple docs, 2026-07-09)

Per the CloudKit Web Services Reference ("Composing Web Service Requests"):
headers `X-Apple-CloudKit-Request-KeyID` / `-ISO8601Date` / `-SignatureV1`;
message to sign is `[ISO8601 date]:[base64(SHA-256(body))]:[subpath]` (subpath
without host or API token, e.g.
`/database/1/iCloud.io.robbie.Dispatch/development/public/records/query`);
signature is ECDSA (prime256v1) over SHA-256, DER-encoded, base64. Signed
requests expire after 10 minutes. Implementation:
`Sources/DispatchKit/Catalog/CKWebServicesSigner.swift`, unit-tested with
fixed vectors in `Tests/DispatchKitTests/CKWebServicesSignerTests.swift`.

## 6. Follow-up (documented, not built)

The dashboard HTML/JS is framework-free and speaks only to four JSON
endpoints (`/api/pending`, `/api/flags`, `/api/approve`, `/api/reject` +
`/api/resolve-flag`), so it can later be ported to a Cloudflare Worker:
reimplement the endpoints with WebCrypto ECDSA P-256 signing (key in a Worker
secret) and serve the same page as a static asset, behind Cloudflare Access.

> **Query lag:** CloudKit query indexes are eventually consistent — `list` can
> briefly show already-processed submissions (or miss brand-new ones) for a few
> minutes after mutations. `approve` is safe against this: it verifies the
> submission with a strongly-consistent fetch before creating anything, so
> acting on a stale entry fails cleanly rather than duplicating.

## The moderator security role (REQUIRED — discovered the hard way, 2026-07-09)

Server-to-server keys are **not superusers**: they execute as a regular user
identity and are bound by the security-role matrix. With `CatalogQuestion`
locked to no-create for all default roles (correct!), the key itself is locked
out too — `approve` fails with `ACCESS_DENIED: CREATE operation not permitted`.

Fix, once per environment:

1. `swift run dispatch-mod whoami` — prints the key's user record name (a
   `_hex` string). Note: this identity may DIFFER per environment — run it
   with `--env production` after deploying and repeat these steps there.
2. Console → Schema → Security Roles → ＋ → role `moderator` with grants:
   `CatalogQuestion` Create+Write · `SubmittedQuestion` Read+Write ·
   `QuestionFlag` Read+Write. (Reads of others' submissions worked without
   the role in our testing, but grant them anyway — observed behavior, not
   documented contract.)
3. Assign the `moderator` role to the key's user record.
4. Role DEFINITIONS deploy with the schema; the user ASSIGNMENT is
   environment-specific — re-assign in Production after deploying.

Verify: `swift run dispatch-mod approve` of a test submission succeeds AND
`swift run dispatch-mod catalog` / `lookup <id>` shows the created entry.
(The tool verifies per-record results since 76f24e4 — an unverified success
once deleted a submission after a silently failed create.)
