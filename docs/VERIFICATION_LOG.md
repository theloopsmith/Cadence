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


## Bounded cloud audio processing (Oct 30)

Resampling, window scans and WAV encoding now run on a serial worker rather than in the microphone callback. A maximum of eight buffers and six seconds of queued PCM prevents unbounded accumulation. Overflow discards the incomplete utterance; generation checks suppress stale replies after echo, dropped audio or stop. Invalid PCM conversion no longer traps. The existing local recognizer continues independently. No runtime model provider changed.

**Evidence.** All 356 Swift tests pass, including nine CloudEar tests; the actual iPhone architecture app target builds with DAT. No app or audio was launched. Physical recording continuity and latency still need device acceptance; the callback retains PCM copying and a short admission lock.


## Durable login attempt limits (Oct 30)

SQLite now persists the account login budget across worker processes and server restarts. Attempts reserve a slot atomically before hashing; successful verification only clears the current reservation revision, preventing an older success from erasing newer failures. A crash consumes its reservation until expiry. Scrypt runs outside database write transactions. A startup schema addition preserves existing records; expired reservations are cleaned on admission. No running server or account was modified during verification.

**Evidence.** All 199 backend tests pass. New coverage verifies lock persistence through schema initialization and a fresh Python process, a shared five-attempt budget under parallel requests, successful recovery/expiry and a delayed successful verification racing with newer failures. These are account-level limits for workers sharing the database; distributed edge/IP throttling is not implemented by this change.


## Bluetooth configuration and microphone recovery (Oct 30)

A normal Bluetooth profile/sample-rate change could stop the cue engine and latch all audio input off. The companion's retry button did not clear that latch unless returning from Hey Meta. Output engine changes now coalesce for 350 ms and retry up to three times; explicit pauses, interruptions and actual output disconnections override pending recovery. Switching between profiles of the same named output is distinguished from removing that output. The health poll waits during configuration recovery. Redundant session-category writes are avoided.

Talk to Cadence now explicitly retries audio before acquiring its microphone. Input setup waits for Bluetooth negotiation after configuring the session, and a stopped input engine is recreated after a configuration change. Scheduled restarts are fenced by the listening session and skipped if input already recovered. The listener startup health grace is four seconds. This repairs the software recovery path; it does not establish that permissions or physical Bluetooth routing are correct on the user's installed app.

**Evidence.** The full 358-test Swift suite passed and the actual iPhone architecture app target built. Added regression coverage exercises transient restart failure followed by recovery and verifies that an actual disconnection overrides queued recovery. No app or audio was launched. The updated app still needs installation and verification on the connected phone and glasses.


## Hands-free companion controls (Oct 30)

The companion status bar no longer contains Talk to Cadence or Use Hey Meta buttons. A one-time Hands-free voice companion switch in Settings requests OS permissions. Voice starts on subsequent launches. “Let me use Meta” releases the microphone and keeps the setup preference. Returning from Siri or backgrounding resumes voice automatically when the app becomes active; “Siri, open Cadence” uses the system's app-opening command, not a Cadence wake word. “Stop listening” explicitly disables the preference; transient microphone errors preserve it for a later foreground retry. Permission dialogs and unlocking remain OS-controlled and may require touch. Cadence cannot hear its own return phrase while its microphone is released. Siri activation, app-name resolution and physical Bluetooth recovery still need an installed-device check.

**Evidence.** All 360 Swift tests pass and the physical-iPhone architecture target builds. Tests cover preserving setup through a Meta handoff and distinguishing it from an explicit voice-off command. No app or audio was launched during verification.

## Walking-first brief and calibration recovery (Oct 30)

The architecture/design contract is in ARCHITECTURE_AND_DESIGN_SPEC.md. Walking cueing remains the first delivery gate under the updated brief. Calibration read failures now remain visible during reference fallback, failed deletes report an error, and a failed recording save retains the original clip in memory for retry or explicit discard. New recording is blocked while a failed clip is pending. Calibration selection requires complete labels from one source; phone and glasses recordings cannot be silently combined. Counts and reference provenance are shown explicitly.

**Evidence.** All 363 Swift tests pass, including new storage-failure recovery, unreadable-store provenance and mixed-source rejection tests. The actual iPhone architecture target builds. No app or audio was launched. Physical worn-device calibration, active-sensor calibration matching, latency and cue/recovery acceptance remain open. Synthetic trap tests do not establish real-world sensitivity, specificity or medical efficacy. Contrast compliance has not been certified; the architecture/design contract records that limit.

## Active-sensor calibration binding (Oct 30)

MotionFeed now selects calibration through a source-start hook before opening a new motion stream. WalkingModel supplies the source kind from GlassesSessionManager's actual selected source, including phone fallback. FoGCalibrationController remembers that target on subsequent recalibrations and selects only that sensor's complete labeled set; missing or invalid matching recordings use disclosed synthetic reference motion. Other sensors' recordings do not fill missing labels.

The capture recorder now tags clips with the active stream's source rather than its default iPhone label. A changed or stopped stream invalidates an incomplete recording, preventing mixed-source or restarted motion from becoming one labeled clip. UI retry/discard controls are offered only when an unsaved clip actually exists.

Verification includes sensor-specific selection, recording provenance and interruption rejection, and an app-model mock-glasses connection/disconnection journey. Physical worn-device calibration, cue latency and recovery acceptance remain open; this work does not validate detection efficacy.

**Evidence.** All 366 Swift tests pass and the actual iPhone architecture target builds. No app or audio was launched. The integration fixture supplies real mock IMU samples; a mock without samples correctly falls back to phone motion rather than claiming an available glasses stream.


## Startup voice state and archived-event notice (Oct 30)

A missing voice preference previously decoded as false, leaving first-time setup silently off. It now defaults to automatic startup after OS microphone/speech permission, while explicitly saved false remains false across launches. A startup flag prevents overlapping authorization requests and the companion bar distinguishes starting, permission problems and a saved off choice. Archived records with unknown owners remain quarantined; their explanation is now in account Settings rather than a recurring Today warning. No records were deleted or reassigned.

**Evidence.** All 368 Swift tests pass and the actual iPhone architecture target builds. New tests verify default-on versus persisted explicit-off settings and meaningful startup state. No app/audio was launched; the installed phone still needs this build. If the phone already saved voice off, re-enable Hands-free voice companion once in Cadence Settings.

## Reachable Settings and scrollable voice status (Oct 30)

Settings is now a permanent fourth tab. The voice notice was removed from the inset above the entire TabView and sheet navigation; on Today, Diary and Help it now scrolls with content. Settings puts voice status and the hands-free switch first in its form and omits the repeated enable-voice explanation there. Its Done toolbar control is shown only when presented as a sheet; spoken done/cancel returns the Settings tab to Today. This removes reliance on a gear icon behind an expanding notice without restoring the removed everyday voice-control buttons.

The app display name now matches “Cadence” in the spoken Siri opening guidance (previously “Cadence Companion”). The bundle identifier and stored profile are unchanged. Speech permission copy now describes both companion and safety use. Siri app lookup and the installed-phone layout still require physical acceptance; no app/audio was launched here.

**Evidence.** The 368-test Swift suite passed during the layout update, and the iPhone architecture target compiled. This verifies source integration, not a visual layout check on the user's phone.

## Automatic voice upgrade (Oct 30)

Per the owner's request, first launch of the automatic-startup setup now enables voice for existing profiles too, overriding the older saved-off value once. A profile-scoped migration marker prevents repeated overrides, so a subsequent deliberate off choice is still honored. Microphone and speech permission remain required. All 19 DeveloperToolsTests pass, including an upgrade seeded with the legacy false preference followed by an explicit off choice and reload.

## Settings scrolling work reduction (Oct 30)

Settings no longer observes the app-wide publisher that forwards live motion, recorder and walking health updates. It observes settings, authentication and fall state directly, and subscribes only to reset-error and voice-action events it needs. Root presentation uses an equality boundary for unchanged Settings inputs; local state and directly observed changes continue to update normally. Glasses updates are confined to a small section.

Installed speech voices are loaded on appearance/foreground return instead of scanning AVFoundation during every form evaluation. The quarantined-record count is fetched on a utility task outside rendering and displayed from state, rather than synchronously querying SQLite twice per redraw. Spoken done remains subscribed directly to action IDs rather than depending on app-wide view invalidation.

**Evidence.** The 368-test Swift suite passed during the refactor and the iPhone architecture target built. No app/audio was launched and no physical-device frame-rate or Instruments measurement was taken. These changes remove identified render-path work; smooth scrolling on the installed phone still needs acceptance.

## Simplified Settings and developer tools (Oct 30)

Removed Today's upper-right Settings gear and the Developer tab. Settings remains in the permanent bottom bar. Under Settings → Advanced, Show developer tools reveals focused navigation pages for connection/status, walking replays, motion calibration, safety tests, medication tests, camera checks, hardware, diary fixtures and the outbox. Ordinary debug builds no longer enable tools automatically. The toggle persists per local profile; explicit testing launch flags supply the initial default only when no choice is saved.

Developer pages now use the Settings navigation stack rather than a nested stack. Opening the developer area no longer runs unrelated backend checks or fetches queue data; those run only on their relevant pages. Leaving a replay or capture page stops that active test, and a temporary simple-mode override is cleared. The duplicate raw-token/server connection form was removed; server/account setup remains in the main Settings form. Regression coverage checks toggle persistence, profile isolation and a saved choice overriding the launch default.

**Evidence.** All 368 Swift tests pass, including the updated developer preference test and screen-copy lint; the actual iPhone architecture target builds. No app or audio was launched. Visual acceptance on the installed phone remains pending.

## Reduced main Settings sections (Oct 30)

Removed the People to call editor from Settings without changing saved contacts or call behavior. Account and local history and Photo source now appear only when Settings → Advanced → Show developer tools is enabled. Main Settings contains voice preferences, the developer toggle and About. Hiding developer tools stops Bonjour discovery and clears the password field. This is a presentation change; no saved profiles, records or connection settings were erased.

## Stalled companion startup state (Oct 30)

The generic “Voice is preparing or paused” fallback masked a stopped microphone while the automatic-voice preference remained enabled. The status now preserves the companion's actual failure/pause reason. Starting with an active pause explicitly reports that reason, and repeating an unchanged pause state no longer cancels and reopens the listening turn.

The ordinary transcript listener distinguishes requested listening from a successfully started audio input. The companion polls readiness with a bounded startup deadline rather than reporting Listening immediately or trusting the request flag. Invalid Bluetooth input formats and audio-engine start failures retry twice after settling, then publish an actionable input failure. Setup-time configuration notifications cannot reset those retries indefinitely; only an input that already started can trigger route recovery. Session IDs fence queued work after stop, and media-service generations guard engine cleanup.

No app or audio was launched. Physical microphone/permissions behavior still needs the installed-phone check; the code changes do not establish which device condition caused the user's failure.

**Evidence.** All 371 Swift tests pass and the actual iPhone architecture target builds. New tests verify startup input-failure reporting, preserved retry preference and paused-start recovery; app-model status retains the actual pause reason. Automated checks do not verify acoustic input on physical glasses.

## Multiple medications and clear setup navigation (Oct 30)

Medication setup now edits a draft list with Add medication, exact time selection, removal and visible Save/Cancel controls. Saved schedules and reminder times change only on Save. Photo capture/removal is staged with the draft; if a photo cannot be persisted after the schedules save, the editor stays open and reports that partial result. Today provides an explicit medication selector and Manage medications action, also available in Settings. Help is now Get help and contains calling actions rather than medication or app setup.

The profile stores an array of schedules while retaining the selected schedule interface for existing code. Old single-medication settings migrate without dropping the existing schedule. Duplicate names and invalid times are refused; medication names identify records, so renaming leaves earlier diary entries under the earlier name. Dose history and Undo are scoped to the selected medication. Spoken dose confirmation names that medication, and changing schedules invalidates a pending confirmation. Logging a dose withdraws reminders via an explicit success callback rather than mistaking a switched history list for a new dose. Reminder identifiers include the medication, so identical times do not collide. Selecting a different medication does not rebuild the same reminder plan; startup/plan changes replay suppression from today's records.

Reference photos are stored separately by medication name digest. An older unscoped photo is migrated only when its one-medication owner can be inferred; the original is archived locally and cannot later reappear as a different medication's image. No server payload or caregiver dispatch behavior changed.

**Evidence.** All 375 Swift tests pass and the actual iPhone architecture target builds. New coverage verifies old settings migration, multiple-medication reload/selection, duplicate-name rejection, per-medication dose and photo isolation and independent reminders at the same time. No app or audio was launched; physical UI and reminder-delivery acceptance remain pending.

## Cadence iPhone icon (Oct 30)

Added an opaque 1024-pixel Cadence C-mark app icon to Assets.xcassets and selected AppIcon in Debug and Release build settings. The generated master and generation prompt are retained under docs/branding. Artwork was generated during development with the built-in image tool and bundled as a static asset; no runtime model provider was added.

**Evidence.** The iPhone target builds successfully. The built product contains Assets.car, an AppIcon60x60 PNG, and CFBundlePrimaryIcon metadata naming AppIcon. The artwork was visually inspected after resizing. No app was launched or installed during this check; the home-screen change appears after installing the updated build.
