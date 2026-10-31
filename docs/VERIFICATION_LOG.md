# Verification log

One entry per workstream, oldest first. Each records what was built, the evidence observed at the time, and what that evidence does not establish. Test counts are the snapshot of that day; the current counts are in the [readiness review](HACKATHON_READINESS_REVIEW_2026-10-29.md). Machine-readable traces live in [`verification/`](verification/).

Three evidence grades are used throughout: **verified with mocks** (unit/integration tests, simulated transports), **verified live** (a real external service answered), and **verified on device** (a physical iPhone and glasses). Nothing here is clinical validation.

---

## Scope and positioning (Oct 29)

The submitted product is an accessibility and daily-living companion: rhythmic walking cues, a suspected-fall check-in with caregiver contact, user-requested bounded photo descriptions, reminders of an existing prescribed routine, and factual activity/meal-time logs. `ENABLE_RESEARCH_METRICS=false` is the default; the normal report, exam and handwriting APIs omit interpreted health states and scores. Meal logging records a time only. Scene descriptions name what can be identified in a photo and say the whole scene cannot be verified; empty segmentation never means "safe".

Legacy formulas and column names remain behind the disabled research flag to avoid a destructive migration. That is a product boundary, not organizer approval.

### Organizer clarification draft (not sent)

> We are building Cadence for Build for Your World: a voice-first accessibility companion with rhythmic walking cues, suspected-fall check-ins and caregiver contact, user-requested bounded photo descriptions, reminders of a user's existing prescribed routine, and factual activity/meal-time logs. The submitted mode does not provide diagnosis, medication-state interpretation, nutrient estimates, or advice about medication or nutrition. It reports uncertainty and distinguishes queued alerts from provider acceptance and caregiver acknowledgment. Would this scope fit the event's anti-project guidance? The repository retains legacy experimental formulas behind a disabled-by-default research setting; should those be excluded from the public submission entirely?
>
> Our first commits were after the October 26 kickoff, while the PDF also labels the building period October 27–November 4. Could you confirm the permitted start boundary? We will identify original contributions and preserve the actual history.

The project owner later clarified with organizers that **every runtime model call must use a Meta model; built-in system voice output is allowed.** Spoken replies use the OS voice; no third-party TTS is integrated.

---

## Emergency integrity and durable dispatch (Oct 29)

**Built.** Production cannot fabricate simulated Twilio success; a failed or unconfirmed dispatch returns 503 so the phone keeps the event. Unsigned webhooks fail closed in production. Fall mutations check wearer ownership. The phone checks fall response bodies, prioritizes fall rows, prevents overlapping drains and acknowledges only the exact payload revision sent. Spoken affirmatives stay provisional until the window ends; distress from either recognizer escalates immediately and is latched (`DualRecognizerCheckIn`).

`fall_jobs` commits with fall ingestion before any external call and holds deadline, lease and attempt number. `fall_attempts` records each attempt and recipient snapshot before the provider call; expired in-flight attempts become `delivery_unknown`. Delivery is **at least once**. Cancellation commits before returning; signed callbacks must correlate to a committed attempt. `GET /api/v1/events/fall/{uuid}/delivery` separates provider acceptance, attempt status and caregiver acknowledgment.

The phone outbox binds every row to an account key and destination; a drain snapshots both and stops after sign-out or identity change. Queue saves return a checked result; disk failures are shown on SOS and Today, and buffered events are retried when storage recovers (memory is not durable storage).

**Evidence (mocks).** 122 backend tests including a subprocess killed mid-dispatch, post-restart recovery, concurrent workers, stale-worker fencing and signed callback correlation. 237 Swift tests including an end-to-end mock glasses → fall → contradictory speech → cancel → relaunch flow. Mock-kit app launched in the simulator ([screenshot](verification/mock-kit-launch.png)).

**Live caregiver drill: not verified.** With the user's consenting test recipient and a five-minute callback-only tunnel, public readiness passed but the provider attempt returned no SMS/call IDs ([caregiver-live.json](verification/caregiver-live.json)). Read-only preflight found a Trial account with no owned SMS/voice-ready sender and an unverified recipient ([caregiver-provider-preflight.json](verification/caregiver-provider-preflight.json)). Provider setup is required before a real drill.

---

## Live Meta Model API (Oct 29)

**SAM 3.1** over `POST https://api.meta.ai/v1/responses`: a 640×480 synthetic frame with a red circle at (220,140)–(420,340) returned one box at (220,140)–(420,339), confidence 0.945, in 3.6 s cold ([trace](verification/sam-live-2026-10-29.json)). Five concepts in parallel completed in 2.2 s. **Muse Voice Transcribe**: synthesized "I'm okay, I just sat down" came back as "I'm okay. I just sat down.." in 2.0 s ([trace](verification/muse-transcribe-live-2026-10-29.json)). **Muse Spark Open** via Baseten: one synthetic conversation returned the expected `motor` intent in about 0.85 s.

Protocol checks against the live services, not a wearer or room photo. Real-photo scene results and a recorded Baseten label selection remain to be captured. Re-run: `scripts/sam_smoke.py [photo.jpg concept ...]`.

---

## Audio control and protection health (Oct 29)

**Built.** `PromptArbiter`: one active utterance, no backlog, priority preemption, completion IDs so cancelled speech cannot complete a replacement. Siren cancels speech; stopping a cue cancels its speech and PCM; "Step to the beat" has a 45 s cooldown. Interruption begin pauses playback and stops capture; provisional affirmatives are invalidated, latched distress is kept. Media-services reset rebuilds engine, player, synthesizer and keep-alive nodes. Motion health distinguishes off / waiting / fresh / stale with a two-second gap rule; healthy protection requires fresh samples, usable audio and active keep-alive, never the toggle alone. Today shows actual input and output port names.

**Evidence (mocks).** 253 Swift tests (16 new), 137 backend, app target builds. Control logic only; no sound was played. Physical items still open: one prompt and beat, Stop clearing both, a call interruption, Bluetooth disconnect/reconnect, mic denial, media reset, screen-lock continuity. A suspended process cannot monitor; the freshness check reports stale after resume, not during.

---

## Partial motor checks (Oct 29)

**Built.** Each check resets its full measurement state and session identity. Tasks carry `measured` / `skipped` / `unavailable`; the backend adds `legacy_unverified` for older records. Unmeasured values are null; a measured task must supply its values; nonfinite numbers are rejected. Partial checks cannot produce a composite; default mode computes no exam scores. Walking needs ≥3 s, ≥16 samples and a continuous stream. `motor_exam_validity_v1` is an atomic recorded migration that makes the old NOT NULL columns nullable without certifying historical defaults as observations. Deploy the backend before the app.

**Evidence (mocks).** 152 backend, 262 Swift, dashboard renderer check with nulls and real zeros.

---

## Dashboard stored-text security (Oct 29)

**Built.** All dynamic sections use DOM nodes and `textContent`; no HTML sink remains in `dashboard.js`. GPS links use a fixed HTTPS Maps origin with bounded, finite coordinates. `/dashboard` issues a fresh nonce per response with a CSP that allows only the nonce-authorized script, forbids inline handlers, eval, plugins, base-URL changes and framing; responses are no-store and nosniff.

**Evidence.** 154 backend tests; `node --test backend/tests/dashboard_exam_validity.test.cjs`; an isolated headless Chrome run against the real HTML, headers and script with hostile text in every field: text inert, authorized script and sign-in button work, injected inline/un-nonced scripts and handlers blocked, zero unexpected requests ([result](verification/dashboard-browser-security-2026-10-29.json)). Authentication still uses a bearer token in `sessionStorage`.

---

## Report accuracy (Oct 29)

**Built.** One consistent SQLite snapshot over the exact trailing 24 h half-open UTC interval, anchored on generation time. Counts and the 48 buckets include every row; detail arrays cap at 100 and say so. Empty buckets read "No observations"; a dose or scene log is a point observation, never a healthy period. Pending, canceled and suppressed candidates do not count as alerts. A real provider SID is acceptance, a correlated DTMF callback is acknowledgment, simulated SIDs are neither. The phone polls delivery evidence for its active incident; shared PDFs label queued alerts "Alerts requested".

**Evidence (mocks).** 161 backend, 267 Swift, five JavaScript checks, isolated Chrome check.

---

## Single-wearer local profile and address repair (Oct 29)

**Built.** One wearer and one server per installation, bound by an atomically written manifest under `Documents/CadenceDevice/<profile>/`. A different subject, patient or destination is refused before it reaches the API, outbox or caregiver configuration. Today, Diary and Help work before setup and while signed out. **Erase local profile** shows its scope, refuses during an active alert or in-flight request, writes a durable marker, then erases on the next launch and retries if interrupted. Legacy unassigned files are never adopted. An authenticated localhost→LAN repair migrates only that owner's queue rows with a journal; later moves must match the learned server ID.

**Evidence (mocks).** 279 Swift tests, later 289 with the launch and repair regressions. Local reset leaves server records unchanged; this is routing and provisioning, not a device lock.

---

## Server erase and offline sync (Oct 29)

**Built.** A per-patient **data generation** (the count of `patient_wipes` rows) coordinates erasure. A wipe deletes and appends the ledger row in one `BEGIN IMMEDIATE` transaction; every HTTP write checks the request generation under the same writer lock, so a write either commits before the wipe or is rejected with 409 `data_generation_changed`. Phone rows are stamped at creation; learning a newer generation atomically retires older pending rows into a terminal state that is **not counted as delivered**. Dose Undo appends an idempotent retraction (`/api/v1/medication/dose/retract`); dose and retraction are order-independent and replay-safe. Demo seeding preserves the ledger.

**Evidence (mocks).** 175 backend tests including erase between precheck and commit, a model result arriving after erase, lock ordering and racing Undo; 304 Swift; eight JavaScript checks. Upgrade all backend workers first. A server erase cannot unsend a provider request already handed off.

---

## iPhone server connection and glasses camera (Oct 29)

**Built.** `scripts/run_phone_backend.py` runs a LAN development server on port 8001 bound to `0.0.0.0` with a separate database, a random phone account written to `.local/phone-login.txt` (mode 0600), Twilio overridden empty, and a `_cadence._tcp` Bonjour advertisement that **Settings → Find my Mac server** discovers. `GET /api/v1/device/connection` returns a durable server ID and the patient binding. The DAT adapter waits for asynchronous device discovery before `createSession`, declares the Bluetooth peripheral transport, and shows device/link/compatibility diagnostics. A shared live glasses video screen serves medication references, surroundings and handwriting; capture needs an explicit **Use this photo**; optional glasses shutter presses feed the same flow. Phone camera is an explicit alternative, never an automatic fallback.

**Evidence (mocks).** 163 backend, 314 Swift; the physical-iPhone app target builds with DAT 1.0.1. The server answered on loopback, LAN IP and `.local` from the Mac. iPhone reachability, video rendering, shutter input and a real-photo Meta result are device checks still to run.

---

## Voice companion and Hey Meta handoff (Oct 29–30)

**Built.** An opt-in conversation controller with one microphone owner, transcript debouncing, echo rejection and cancellation tokens. Exact requests route locally; less exact wording goes to Muse Spark Open, which returns only an allowlisted intent and cannot write records, place calls or make emergency decisions. Sensitive actions need a separate clear confirmation that expires after 20 s. Voice can open motor, surroundings, medication reference, camera, diary, meal and settings flows; the motor screen accepts start/ready/skip/finish; photo screens accept capture/use/retake/retry. A fall check-in pauses the companion and reclaims audio. The launch session is `.playback`; microphone use is owned explicitly and released by the last owner. **Use Hey Meta instead** hands the route to native Meta AI; return needs an explicit tap. "I didn't quite get that" no longer cancels a step.

**Evidence (mocks + one live call).** 332 then 342 Swift tests, 183 backend, physical-iPhone build. The companion listens while foregrounded only. Native wake word, locked-screen conversation and barge-in are not implemented.

---

## Principal review pass (Oct 30)

Two independent file-by-file reviews (backend and iOS) plus CI and toolchain checks; fixes landed with failing tests first. Headline fixes: the server-owned fall check-in timeout could never dispatch after a wearer had ever reset their data and the failure stopped recovery for every wearer; the siren screen claimed "Trying to contact caregiver" on a signed-out phone; the siren now resumes by itself after a call interruption or media-services reset; the check-in prompt is spoken after the microphone session is configured; walking cues cannot start during a check-in and the echo guard covers PCM playback; production refuses to start without caregiver dispatch settings or with demo/static tokens on; a key misconfiguration no longer deletes a database; NaN, future and unparseable timestamps and out-of-range values are 422s; care partners can enter caregiver and emergency numbers; Today controls meet the 72 pt rule.

**Evidence.** 195 backend, 350 Swift, 8 renderer checks, isolated browser check; the app target builds for simulator and device and launches in the iOS 26.0.1 simulator with the mock kit. CI installs the lockfile, generates the dashboard fixture, installs Playwright and compiles the app target on an Xcode 16 runner. The open list is in the readiness review.
