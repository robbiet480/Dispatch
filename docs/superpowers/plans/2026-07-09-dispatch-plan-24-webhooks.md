# Dispatch Plan 24: Report webhooks

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** an advanced export feature — when a report is completed, POST its JSON to a user-configured URL.

**Architecture:** kit-side payload/signing/retry policy (pure, tested) + an app-side WebhookManager using the queue-and-drain pattern (reports enqueue at every save path incl. the widget-extension process via app-group storage; delivery drains from the app process). No new entitlements.

## Design decisions (decide + log)

- **Payload:** `{"event": "report.created", "schemaVersion": 2, "report": <v2 report object>}` — the report encoded exactly as V2Exporter renders it (single-report reuse of the existing DTO encoding, byte-consistent with exports so consumers parse one format). Content-Type `application/json`.
- **Signing (optional):** if the user sets a secret, header `X-Dispatch-Signature: sha256=<hex HMAC-SHA256 of the body>` (webhook-idiomatic; CryptoKit). No secret → no header.
- **Transport rules:** HTTPS always allowed. Plain HTTP allowed ONLY for local-network hosts (RFC1918/.local/localhost — the Home Assistant case) via `NSAllowsLocalNetworking` (scoped ATS key, NOT NSAllowsArbitraryLoads; plist-only, no entitlement). Non-local http URLs are rejected at entry with an inline explanation. Hitting the LAN triggers iOS's local-network prompt → `NSLocalNetworkUsageDescription` purpose string ("Dispatch delivers report webhooks to servers on your network when you configure one.").
- **Delivery + retry:** enqueue-and-drain. Every successful report save (in-app survey, notification quick-answer, widget quick-answer via its existing marker pattern, backfill, intents) enqueues the report's uniqueIdentifier in app-group defaults. The app drains: immediately after in-app saves, on foreground, and after the widget-marker drain. Per attempt: 15s timeout; failure → retained with attempt count, exponential-ish backoff by drain opportunity, dropped after 5 attempts (logged). Delivery status (last success/failure + time) shown in settings. Deliberately NO background URLSession in v1 (drain-on-foreground is honest and simple; noted as future work).
- **Privacy:** the settings screen states plainly that the full report — including location and health readings — is sent to the configured URL, and that this is the user's own server responsibility. Webhook config is device-local (NOT synced — a URL+secret is a credential; also avoids double-delivery from two devices).
- **Settings UI:** Data → Advanced → Webhook: enabled toggle, URL field, secret field (redacted display), "Send Test" button (posts a `{"event":"test"}` payload, shows result inline), last-delivery status row. Identifiers `webhook-toggle`, `webhook-url`, `webhook-secret`, `webhook-test`.

## Global Constraints

- No new entitlements (plist keys only). No schema changes. Suites green before every commit; scoped commit + push per task; `git pull --rebase` before starting/pushing (standing instruction). Test-gated: no real network from tests (URLProtocol stub or injected transport). Do NOT bump the build number.

---

### Task 1: Kit — payload, signing, queue policy

**Files:** Create `Sources/DispatchKit/Webhooks/WebhookPayload.swift`, `WebhookSigner.swift`, `WebhookQueuePolicy.swift` + `Tests/DispatchKitTests/WebhookTests.swift`.

**Interfaces (produced):**
- `WebhookPayload.body(for report: Report, event: String) throws -> Data` (v2-consistent encoding; deterministic key order via the exporter's encoder config)
- `WebhookSigner.signatureHeader(body: Data, secret: String) -> String` ("sha256=<hex>")
- `WebhookQueuePolicy`: `URLRule.validate(_ urlString: String) -> ValidationResult` (https anywhere; http only for localhost/.local/RFC1918; else .rejected(reason)); `nextAttemptAllowed(attempts: Int) -> Bool` (cap 5)

**Contract:** tests first — payload matches V2Exporter's report encoding byte-for-byte for a fixture report; HMAC vector verified against a known-good value computed with python3 hmac (session rule: verify crypto against a reference); URL rules (https ok, http+LAN ok, http+public rejected, garbage rejected); attempt cap.

Verify: `swift test`. Commit `feat(kit): webhook payload, signing, queue policy` → push.

### Task 2: App — WebhookManager, settings UI, save-path wiring

**Files:** Create `App/Sources/Webhooks/WebhookManager.swift`; modify `App/Sources/Settings/DataSettingsView.swift` (Advanced section), save-path hooks (grep the reportFiled/backup hook sites — SurveyFlowView, quick-answer filing, widget marker drain in DispatchApp, backfill), `App/Info.plist` (NSAllowsLocalNetworking scoped ATS) + `project.yml` (NSLocalNetworkUsageDescription).

**Interfaces (consumed):** Task 1's three types. **Produced:** `WebhookManager.enqueue(reportID: String)` (app-group defaults queue; callable pattern-wise from wherever saves happen — widget process enqueues only, never delivers), `WebhookManager.drain()` (app process; async; injected `URLSession`-like transport for tests).

**Contract:** per design decisions verbatim. Delivery status persisted + rendered. Send Test uses the same transport path. UI test: configure a webhook against the stub transport (test arg), file a report, assert status row shows delivered. Kit-test the manager's queue semantics if extractable; otherwise app-side test via stub.

Verify: build, kit suite, UI suite (+1), archive (entitlements unchanged — ATS/purpose-string are plist-only; prove with the usual codesign/plutil check). Commit `feat: report webhooks` → push. Whole-branch review follows (controller-driven).
