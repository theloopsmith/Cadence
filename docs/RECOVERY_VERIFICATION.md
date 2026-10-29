# Recovery and verification handoff — October 29, 2026

## Implemented

### Backend recovery

`fall_jobs` commits together with fall ingestion, before external delivery. It records the original retry deadline, next due time, current lease/token, state, and attempt number. Check-in candidates have a server-owned timeout, so a missing phone outcome can be escalated after restart. The lifespan recovery sweep continues to discover due jobs without another phone request.

`fall_attempts` records each attempt and recipient snapshot before the provider call. Expired in-flight attempts become `delivery_unknown`; a replacement worker receives a new attempt and lease. A stale worker cannot move a newer job or replace its provider IDs. Provider-result loss after an already signed acknowledgment does not erase that acknowledgment.

External delivery is **at least once**, not exactly once. A provider may have accepted a request whose response was lost; retrying that unknown outcome can produce a duplicate notification. The ledger preserves that ambiguity and bounds further alert attempts by the original deadline and retry ceiling. No provider-level idempotency guarantee is assumed.

Cancellation commits the resolved state and durable All-Clear work before returning success. If cancellation races an outbound request, the result remains canceled and the eventual contact is eligible for All-Clear. Failed All-Clear notifications remain queued across restart. Caregiver acknowledgment resolves the job without generating an erroneous All-Clear.

Signed callbacks must correlate to a committed attempt and call identity. Unknown/mismatched attempts are refused. Simulated acknowledgments are labeled and cannot satisfy the real acknowledgment flag. The authenticated `GET /api/v1/events/fall/{event_uuid}/delivery` endpoint separates provider acceptance, attempt status, and real caregiver acknowledgment.

### Account-bound phone queue

Every new row is bound to an account key and backend destination. The account key hashes JWT subject and wearer ID; claims are used for local routing only, while the backend still verifies authentication. Opaque credentials are conservatively isolated by their hash. Tokens are not stored in SQLite.

A drain snapshots the original destination, token, owner, and transport. It stops sending further rows after sign-out or identity/destination changes. Renewed JWTs for the same subject and wearer can drain that account's existing rows. An old failed request cannot expire a new sign-in. Queue withdrawals and acknowledgments are owner-scoped, and a stale payload response cannot acknowledge a newer replacement.

Legacy rows without provable ownership remain quarantined; signing in never adopts them automatically. Events created while signed out retain the last known destination/account binding. The UI identifies quarantined rows rather than sending them under the next sign-in.

### Local storage failures

Queue saves return a checked result. Database-open/write failures, locking, and invalid JSON are surfaced. SOS and Today display a persistence warning; the offline task flow no longer claims that an unsuccessful save is safely on disk. Manual calling remains available.

Persistable events that fail a disk write are retained in memory with their original account/destination, then retried when storage recovers. **Memory is not durable storage:** killing the app while the disk remains unavailable can still lose those buffered events. The app explicitly warns the wearer to keep it open and use manual calling; it does not promise a physically impossible disk guarantee.

### Contradictory speech and mock kit

The same `DualRecognizerCheckIn` reducer drives live listeners and the mock kit. Affirmatives remain provisional until the check-in closes. Distress from either source is latched, including trailing distress and contradictory results in either arrival order. Both sources must affirm when cloud text is available; cloud absence permits a local affirmative, while cloud-only affirmation cannot cancel. Stale recognition callbacks from an earlier listening session are ignored.

The debug app supports `-cadence-mock-kit`. It visibly labels simulated sensor input, disconnects live credentials/transport for the mock run, and replays motion through the actual companion pipeline. This is Cadence's mock kit, not a claim that Meta's physical hardware or microphones were tested.

## Verified evidence

- **122 Python tests pass**, including a subprocess forcibly exiting during dispatch, post-restart recovery, missing check-in outcome, concurrent workers, failed dispatch recovery, cancellation in flight, retryable All-Clear failure, expired deadlines, stale worker fencing, signed HTTP callback correlation, early acknowledgment, and provider-response loss after acknowledgment.
- **237 Swift package tests pass** with explicit test-only silent audio, including account/destination switches, token renewal, sign-out/relaunch, stale unauthorized responses, legacy queue migration/quarantine, invalid JSON, an actually locked database, an unavailable disk path, buffered recovery under a different sign-in, contradictory recognizers, and an end-to-end mock glasses → fall → contradictory speech → cancel → queue relaunch flow.
- The real iOS Simulator app target **builds successfully**, including the DAT host integration. An isolated iPhone Simulator was created, and the mock-kit app was installed and launched.
- [Mock-kit launch screenshot](verification/mock-kit-launch.png) shows the simulated-input label. The location permission overlay remained visible, and subsequent UI automation timed out. This establishes build/launch evidence, not complete interactive UI or physical-device verification.
- `git diff --check` is clean. Existing dependency deprecation and Swift 6 warnings are not represented as new regressions.

## Live caregiver drill

The user supplied a consenting test recipient ending **2704** and explicitly approved up to five minutes of callback-only public exposure after automatic approval review rejected the broader tunnel proposal.

`../scripts/verify_caregiver.py` defaults to preflight and does not send without `--send`. The approved mode creates an isolated temporary database, binds a callback-only server before opening a temporary tunnel, and verifies a random public readiness nonce before sending. It exposes just two signed Twilio POST routes and the random readiness GET; no dashboard, sign-in, reports, health endpoint, or API schema is exposed. A separate supervisor bounds tunnel lifetime even if the verifier exits. Production settings files and records remain untouched.

The message/call explicitly say this is a scheduled test with no emergency. Automatic redial is disabled. Provider acceptance alone is not success: the verification requires a non-simulated, signed, correlated DTMF acknowledgment. The evidence file contains masked contact information and result/SID metadata, not credentials.

- [Initial preflight](verification/caregiver-preflight.json): the configured callback was localhost; no call was placed.
- [Live drill](verification/caregiver-live.json): public readiness passed; the provider attempt returned no SMS/call IDs and no caregiver acknowledgment. Result: **not verified**. The callback-only tunnel and isolated server shut down.
- [Read-only provider preflight](verification/caregiver-provider-preflight.json): active Trial account; configured sender did not match an owned SMS/voice-ready number; test recipient was not verified for Trial use. Result: **provider setup required**. No additional message or call was attempted. These checks identify setup gaps; no specific provider error code was observed.
- Recovery review found and fixed a concurrent-worker race: stale snapshots could reset an accepted incident and dispatch again. Initial dispatch now rejects any existing attempt; scheduled retries compare the expected attempt and due time inside the claim transaction. Tests also cover stale retry snapshots and repeated phone requests after a failed initial attempt.

Cloudflare's [Quick Tunnels documentation](https://developers.cloudflare.com/tunnel/get-started/quick-tunnels/) describes temporary HTTPS routing; that mechanism is used only for the explicitly approved isolated test surface.

## Remaining limits

- Real glasses IMU accuracy, physical microphone/speaker routing, acoustic output, locked-screen/background operation, and actual reconnection behavior remain unverified. Mock results do not establish those properties.
- A disk that cannot write cannot guarantee persistence across app/process termination; the implemented fallback is explicit warning, RAM buffering, recovery attempts, and manual calling.
- Provider request ambiguity can cause duplicate notifications under at-least-once recovery; the system records uncertainty rather than claiming exactly-once delivery.
- Automated contacts remain single-wearer server configuration. Multi-wearer server contact provisioning, broader diary/data-quality work, and the other Phase 3 review items remain outside this change.
