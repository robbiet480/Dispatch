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
5. **Deploy Development → Production** (§3c).

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

   Optional keys: `"keyPath"` (default `~/.dispatch-mod/eckey.pem`),
   `"container"` (default `iCloud.io.robbie.Dispatch`), `"environment"`
   (default `development`). Environment variables `DISPATCH_MOD_KEY_ID`,
   `DISPATCH_MOD_KEY_PATH`, `DISPATCH_MOD_CONTAINER`, `DISPATCH_MOD_ENV`
   override the file.

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
| `SubmittedQuestion` | `prompt` String, `typeRaw` Int64, `choicesJSON` String, `creditName` String (optional), `submittedAt` Date/Time |
| `CatalogQuestion` | `prompt` String, `typeRaw` Int64, `choicesJSON` String, `credit` String (optional), `approvedAt` Date/Time, `tags` String List (optional) |
| `QuestionFlag` | `catalogRecordName` String, `reason` String, `flaggedAt` Date/Time |

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
`CloudKit error AUTHENTICATION_FAILED`.

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
