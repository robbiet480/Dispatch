# Report webhooks (plan 24)

When a report is completed, Dispatch POSTs its JSON to your configured URL
(Settings → Data → Advanced → Webhook). Configuration is device-local and
never syncs (a URL+secret is a credential; syncing would also double-deliver
from two devices).

## Delivery model

- **Queue-and-drain.** Every save path (in-app survey, notification
  quick-answer, widget quick-answer, backfill) enqueues the report; the app
  process drains immediately after in-app saves, on foreground, and after
  the widget quick-answer drain. There is deliberately no background
  URLSession in v1 — a report filed from the widget delivers the next time
  the app comes to the foreground.
- **Success** = any HTTP 2xx status.
- **Retries:** 15-second timeout per attempt; a failed report is retried at
  subsequent drain opportunities, capped at **3 attempts**. On the 3rd
  failure a local notification tells you delivery failed and the report
  drops from the queue (the settings status row shows the failure).
- **URLs:** HTTPS anywhere. Plain HTTP is allowed only for local-network
  hosts — `localhost`, `*.local`, and RFC1918 addresses (the Home Assistant
  case). Anything else is rejected at entry.

## Events

| Event | When | Body |
| --- | --- | --- |
| `report.created` | a report is saved (and Send All, individual mode) | `{"event": "report.created", "schemaVersion": 2, "report": <v2 report>}` |
| `report.bulk` | Send All Reports…, single-payload mode (one POST, 60s timeout, no retry queue — a failure offers one retry via alert) | `{"event": "report.bulk", "schemaVersion": 2, "reports": [<v2 report>…]}` (oldest first) |
| `test` | the Send Test button | `{"event": "test"}` |

The `report` object is encoded exactly as the v2 JSON export encodes it
(same DTO, same encoder — byte-consistent), so a consumer parses one format
for exports and webhooks alike. `Content-Type: application/json`.

## Signature (optional)

Set a secret and every request carries:

```
X-Dispatch-Signature: sha256=<hex HMAC-SHA256 of the request body>
```

The MAC covers the body **as sent** — with payload encryption on, that is
the encrypted envelope (encrypt-then-MAC). Verify in Python:

```python
import hmac, hashlib

def verify(body: bytes, secret: str, header: str) -> bool:
    expected = "sha256=" + hmac.new(secret.encode(), body, hashlib.sha256).hexdigest()
    return hmac.compare_digest(expected, header)
```

## Payload encryption (optional)

With "Encrypt Payload" on (requires a secret), the JSON payload is encrypted
with AES-256-GCM. The key is derived from the secret with HKDF-SHA256
(salt `io.robbie.Dispatch.webhook`, info `payload-encryption`, 32 bytes),
and the body becomes:

```json
{"algorithm": "aes-256-gcm", "data": "<base64>", "encrypted": true}
```

where `data` is base64 of `nonce (12 bytes) ‖ ciphertext ‖ tag (16 bytes)`
(CryptoKit's `AES.GCM.SealedBox.combined`). Applies to all events,
including `test` and `report.bulk`.

Receiver recipe (Python, `pip install cryptography`):

```python
import base64, json
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

def decrypt(body: bytes, secret: str) -> dict:
    envelope = json.loads(body)
    assert envelope["encrypted"] and envelope["algorithm"] == "aes-256-gcm"
    key = HKDF(algorithm=hashes.SHA256(), length=32,
               salt=b"io.robbie.Dispatch.webhook",
               info=b"payload-encryption").derive(secret.encode())
    combined = base64.b64decode(envelope["data"])
    nonce, ciphertext = combined[:12], combined[12:]  # tag is the last 16 bytes of ciphertext
    return json.loads(AESGCM(key).decrypt(nonce, ciphertext, None))
```

Both the HKDF derivation and the AES-GCM output are pinned in
`Tests/DispatchKitTests/WebhookTests.swift` against reference vectors
generated with this exact Python code.

## Privacy

The full report — including location and health readings — is sent to the
configured URL. That server is yours to secure. The settings screen states
this plainly.

## Transport security notes

- The app declares the **scoped** `NSAllowsLocalNetworking` ATS key (plain
  plist key, not an entitlement) so plain-HTTP LAN deliveries work;
  `NSAllowsArbitraryLoads` is deliberately NOT set — the kit-side URL rule
  rejects non-local `http://` URLs before they are ever attempted.
- First LAN delivery triggers iOS's local-network permission prompt
  (`NSLocalNetworkUsageDescription`).
- Export compliance: the feature uses only OS-provided, standard-algorithm
  cryptography (CryptoKit HMAC/HKDF/AES-GCM). Per Apple's
  [Complying with Encryption Export Regulations](https://developer.apple.com/documentation/security/complying-with-encryption-export-regulations),
  encryption built into the operating system is exempt from the export
  documentation upload requirement, so `ITSAppUsesNonExemptEncryption: NO`
  remains valid (see docs/app-store/review-readiness.md §2.8).
