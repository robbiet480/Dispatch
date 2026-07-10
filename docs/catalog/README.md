# Catalog seed files

Curated question sets that `dispatch-mod import` bulk-loads into the public
CloudKit catalog. The moderation boundary is unchanged: seed files are data,
and `dispatch-mod` (server-to-server key) remains the only writer of
`CatalogQuestion` records.

## Format

```json
{
  "source": "where the set came from (documentation only, ignored by the tool)",
  "defaultCredit": "credit applied to entries without their own",
  "questions": [
    {
      "prompt": "Did you exercise today?",
      "type": "yesNo",
      "choices": ["only for multipleChoice"],
      "credit": "optional per-entry override",
      "tags": ["wake", "day", "sleep"]
    }
  ]
}
```

`type` is the `QuestionType` case name: `tokens`, `multipleChoice`, `yesNo`,
`location`, `people`, `number`, `note`. Entries are validated with the same
`CatalogValidation` rules as user submissions (prompt ≤ 200 chars, 2–20
choices of ≤ 60 chars on multiple-choice only, credit ≤ 50 chars) plus a
duplicate-prompt check across the file; every problem is reported at once.

## Usage

```bash
# Validate + preview (no network, no key needed)
swift run dispatch-mod import --dry-run docs/catalog/reporter-tumblr-seed.json

# Load into Development, then Production once verified in a dev build
swift run dispatch-mod import docs/catalog/reporter-tumblr-seed.json
swift run dispatch-mod import --env production docs/catalog/reporter-tumblr-seed.json
```

Import order is preserved in the app (the catalog sorts `approvedAt`
descending; timestamps are staggered so the file's first entry shows newest).
Prompts already in the catalog are skipped case-insensitively, so re-running
after a partial failure or with an extended seed file is safe.

## reporter-tumblr-seed.json

100 questions scraped 2026-07-09 from the community question blog for the
original Reporter app (reporter-app-survey-questions.tumblr.com, Feb 2014 –
Nov 2016, all 12 pages — the remaining posts were tooling/meta, not
questions). Question types and wake/day/sleep tags come from each post's own
Tumblr tags. Curation choices:

- Prompts and choices normalized to title case ("w/" expanded to "With",
  grammar and trailing `?` fixed); wording otherwise faithful to the post.
- "Are you happy?" was tagged multi-choice but listed no options → `yesNo`.
- "Barriers to self-actualization" and "What did you fall asleep to?" were
  tagged both tokens and multi-choice → multiple-choice, keeping the posted
  option lists.
- One exact duplicate ("What would you have done differently today?",
  posted as both tokens and note) → kept once, as `note`.
- Credit is "Reporter community (Tumblr)" except the three George Gritsouk
  questions and the blog editor's "Where would you rather be?".
