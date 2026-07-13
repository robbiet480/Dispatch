# CloudKit schema

Dispatch syncs its SwiftData store across devices with
`NSPersistentCloudKitContainer` (private database, container
`iCloud.io.robbie.Dispatch`). Every `@Model` listed in
`DispatchStore.allModels` is mirrored to a CloudKit record type named
`CD_<ClassName>`, with one `CD_<property>` field per stored property.

## The trap this guards against

CloudKit **only auto-creates a record type or field the first time a record
that populates it is exported — and only in the Development environment.**
Production **never** auto-creates schema. So if a synced `@Model` gains a field
(or a whole new model ships) and that `CD_` field is not deployed to Production,
every export from a Production/TestFlight build fails with
`CKError.partialFailure` (code 2). The failure is silent in the UI: data simply
never reaches other devices (a second device — e.g. the Mac — stays empty).

This actually happened: `CD_PromptGroup` and ~17 optional fields across
`CD_Question` / `CD_Report` / `CD_Response` were never deployed, because no
Development export had ever populated them, so the Production schema silently
lagged the models.

## The invariant

`CloudKit/schema.ckdb` (committed) is the source of truth for the complete
schema, and it must:

1. **cover every field of every model in `allModels`** — enforced in CI by
   `scripts/cloudkit_schema.py check` (hermetic; the `cloudkit-schema` job), and
2. **be deployed to Production** before any build that relies on it ships —
   a manual step (Apple only allows Production schema changes via *Deploy Schema
   Changes*), verifiable with `verify-production`.

The `CD_` type mapping is derived mechanically and was validated field-for-field
against SwiftData's own auto-generated output (53 fields, 0 mismatches):

| Swift type | CloudKit |
| --- | --- |
| `String` / `String?` | `STRING QUERYABLE SEARCHABLE SORTABLE` |
| `Int` / `Int?`, `Bool` / `Bool?` | `INT64 QUERYABLE SORTABLE` |
| `Double` / `Double?` | `DOUBLE QUERYABLE SORTABLE` |
| `Date` / `Date?` | `TIMESTAMP QUERYABLE SORTABLE` |
| `[T]`, Codable value types | `BYTES QUERYABLE SORTABLE` |
| to-one relationship (`Report?`) | `STRING QUERYABLE SEARCHABLE SORTABLE` (the related record id) |
| to-many relationship (`[Response]?`) | no field — stored on the to-one inverse |

Every record type also carries `CD_entityName STRING …` and the `___` system
fields (`___recordID`, `___createTime`, …).

## When you change a synced `@Model`

Adding/removing a stored property on any model in `allModels`, or adding a new
model to `allModels`:

1. **Regenerate the committed schema** and commit it:
   ```sh
   python3 scripts/cloudkit_schema.py generate
   git add CloudKit/schema.ckdb
   ```
   (CI's `cloudkit-schema` check fails until `CloudKit/schema.ckdb` covers the
   models, so you can't forget this part.)

2. **Deploy the schema to CloudKit.** Import to Development, then promote to
   Production (import is Development-only; Production changes go through *Deploy
   Schema Changes*):
   ```sh
   xcrun cktool import-schema \
     --team-id UTQFCBPQRF --container-id iCloud.io.robbie.Dispatch \
     --environment development --validate --file CloudKit/schema.ckdb
   ```
   Then in [CloudKit Console](https://icloud.developer.apple.com/dashboard) →
   **Schema → Deploy Schema Changes**, review the (purely additive) diff and
   deploy Development → Production.

   > Production schema changes are **additive-only** — CloudKit cannot drop a
   > field or record type, so a deploy can never lose data. A whole record type
   > rendering as a `-`/`+` block in the Console diff is cosmetic (column
   > realignment); the field *set* is what matters.

3. **Verify Production is current** (needs a CloudKit management token —
   `xcrun cktool save-token`):
   ```sh
   python3 scripts/cloudkit_schema.py verify-production \
     --team-id UTQFCBPQRF --container-id iCloud.io.robbie.Dispatch
   ```

## Release checklist

Before cutting a TestFlight/App Store build, if this build is the first to carry
a model change: run `verify-production` (step 3 above) and confirm it reports
*"up to date"*. If it doesn't, deploy the schema first — otherwise the build
ships with broken sync.

## Notes

- The public-database catalog types (`CatalogQuestion`, `QuestionFlag`,
  `SubmittedQuestion`, `Users`) and the `moderator` role are **not** derived
  from `@Model`s; `generate` preserves them verbatim and `check` ignores them.
- `cktool reset-schema` resets **Development to match Production** and deletes
  Development data — it is the *opposite* of promoting, so never use it to
  "sync" the environments.
