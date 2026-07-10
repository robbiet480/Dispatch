Build 18

NEW: PEOPLE
- Dispatch now knows who's who. People you log get a registry (Settings > People) with rename, merge, and delete. Optionally connect Contacts (off by default) for name suggestions and photos — everything stays on your device.

NEW: WEBHOOKS
- Send each report to your own HTTP endpoint as it's filed (Settings > Data > Webhooks). HMAC-signed, optional AES-256-GCM encryption with a shared secret, 3 retries with a notification if delivery fails, plus a Send All for backfilling — individual events or one bulk payload.

ALSO
- Person-aware visualizations, filters, and insights: renaming or merging a person updates history everywhere.
- Question catalog is now live in production — browse and submit from Settings.

WHAT TO TEST
1. Settings > People: rename someone, merge two spellings of the same person, watch charts update.
2. Enable the Contacts toggle (Settings > Sensors) and answer a "who are you with?" question — contact suggestions should blend into autocomplete.
3. Point a webhook at webhook.site (or your own server), file a report, check the payload. Try the encryption secret.
4. Browse the question catalog — it's real data now; submit something.
