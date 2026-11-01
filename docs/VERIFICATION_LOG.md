# Verification log

One entry per workstream, oldest first. Each records what was built, the evidence observed at the time, and what that evidence does not establish. Test counts are snapshots; the latest workstream entries record newer checks than the original [readiness review](HACKATHON_READINESS_REVIEW_2026-10-29.md). Machine-readable traces live in [`verification/`](verification/).

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

### 2026-10-31 — Medication uncertainty and requests for caregiver assistance

- Uncertain medication statements and questions (including “Did I take my pill?”) route to saved medication review rather than dose-log confirmation. Review explicitly distinguishes saved records from proof of ingestion and offers the caregiver call command.
- A caregiver or emergency request during an existing confirmation replaces it with a fresh call confirmation. A later yes cannot execute the abandoned dose action.
- The separate voice dose assistant cancels on uncertainty in the complete transcript, including growing partial results, before processing affirmative suffixes.
- Added regression coverage for uncertain review, caregiver interruption, and uncertainty after dose readback. Full Swift suite: 385 tests passed. iPhone target build succeeded with signing disabled; git diff --check passed.
- No app launch, physical-glasses drill, or live caregiver call performed. Medication selection by spoken name and end-to-end caregiver delivery verification remain follow-up work.

### 2026-10-31 — Spoken medication selection and daily history refresh

- Voice medication requests now resolve against complete saved medication names. With multiple saved medications, generic review/log requests ask which medication; name-only replies retain the intended action. Named ingestion statements still require a fresh confirmation. Multiple matches are clarified; there is no fuzzy selection.
- Selection is abandoned on cancellation, pauses, flow changes, timeout, or another feature request. Caregiver/emergency requests can replace it. App callbacks select the medication before constructing the named readback; selection failures stop the action.
- Fixed stale dose history when a foreground session spans midnight: the minute refresh, foreground return, and spoken medication review read the current day's diary. Recovering from an unreadable diary clears the history error so review can resume without restarting.
- Added coverage for multiple-medication selection, ambiguous names, caregiver interruption, pause invalidation, named readbacks/actual per-medication app records, midnight rollover, and history read recovery. No physical glasses or caregiver service drill was performed.
- Follow-up: successful dose Undo now rebuilds reminders from the complete saved plan and remaining diary records. Added an app-level regression with two medications at the same time: Undo restores the second medication's repeating reminder while the first remains suppressed.
- Final validation for this batch: 392 Swift tests passed, iPhone target build succeeded with signing disabled, and git diff --check passed. Test logs: /private/tmp/cadence-medication-journey-tests.log and /private/tmp/cadence-medication-journey-build.log.

### 2026-10-31 — Preserve recurring medication reminders after logging

- Fixed the reminder recurrence defect: logging removed the entire repeating request and replaced it with a one-off for tomorrow, leaving no reminders after that unless the app reopened.
- Dose logging now removes the matching delivered notification while leaving the daily pending request intact. Added delivered-notification removal to the system notification adapter and test doubles. Sync replaces legacy one-offs at the next launch/plan sync.
- This supersedes the earlier same-day suppression behavior: a dose recorded early may still be followed by the scheduled reminder that day. Reminder wording asks the user to review the saved schedule and dose record, and seek caregiver/pharmacist help if unsure, rather than instructing another dose.
- Regression checks cover repeat preservation after repeated logging, medication isolation, early logging, recurrence across subsequent days without another sync, and Undo retaining both medications' daily requests. These are scheduler/adapter checks; actual locked-phone notification delivery remains unverified.
- Validation: 393 Swift tests passed; iPhone target build succeeded with signing disabled; git diff --check passed. Logs: /private/tmp/cadence-reminder-recurrence-tests.log and /private/tmp/cadence-reminder-recurrence-build.log.

### 2026-10-31 — Reminder scheduling failures and retry

- The system notification adapter now awaits add completion and propagates errors. Scheduler status reports failure if any request is rejected, instead of claiming every reminder was scheduled.
- Reconciliation enumerates pending IDs, clears only obsolete Cadence dose IDs, and replaces desired IDs individually. Valid pending reminders survive a rejected replacement; removed medication times do not linger. Other notification categories are preserved.
- Updates are serialized and revision-fenced so an older asynchronous add cannot overwrite the latest plan. Profile reset clears any late-finishing add before returning.
- Settings → Medications now displays permission/scheduling failures and a Retry reminders action. Notification state is observed in a small child view to preserve Settings performance.
- Added checks for rejected updates/retry, obsolete-time cleanup despite failure, reset during system add, and overlapping plan replacement. No notification permissions were changed on the user's iPhone and no live caregiver action was performed.
- Validation: 397 Swift tests passed; iPhone target build succeeded with signing disabled; git diff --check passed. Logs: /private/tmp/cadence-reminder-errors-tests.log and /private/tmp/cadence-reminder-errors-build.log. Actual iPhone notification delivery and rejection UI still require device acceptance testing.

### 2026-10-31 — Diagnose and fix failing GitHub CI

- Inspected run 41177956908 at commit 84e3f1785: backend passed; Simulator build failed with exit 70 because forced Xcode 16.2 reported no eligible destination / missing iOS 18.2 platform. Package failures were unordered JSON token fixture comparisons in DeviceProfileTests and QueueDurabilityTests, plus a fixed 80 ms confirmation timeout test.
- Workflow now uses the runner default Xcode and prints simulator SDK diagnostics. Exact runner image lists Xcode 16.4 as default. JWT fixtures serialize with sorted keys; timeout test waits for the observed timeout with a bounded three-second deadline.
- Current working tree passed 397 Swift tests with TZ=UTC using scripts/test_ios.sh. The existing CI Simulator build command passed locally on Xcode 27.1. Validation on GitHub's default Xcode requires a new hosted run.
- CI-only patch saved at /private/tmp/cadence-ci-only.patch and tested separately against the last committed source in /private/tmp/cadence-ci-only-efo16tzx, preserving unrelated local feature edits. Full downloaded failing logs stay in /private/tmp; credentials were used only for user-approved read-only log retrieval and were not printed or saved.

### 2026-10-31 — Motor exam implementation review and fixes

Reviewed the presented motor flow, companion routing, audio priority/completion, voice capture, walking recorder, handwriting requests, exam persistence/submission, and backend raw-metric contracts. Concrete fixes:

- Removed duplicate narration from manager transitions. The presented flow owns instructions, including when automatic hands-free listening is disabled. Native Apple speech retains the configured installed voice.
- Added awaited, cancelable utterance completion. The microphone is prepared and settled before the start cue; vowel samples begin after narration ends. Timed walking also waits for its cue. Interrupted/replaced speech cannot start a measurement.
- The same displayed handwriting sentence is spoken slowly in three phrases, with six-second pauses and unlimited time afterward. Repeat voice routing and a visible replay action repeat the script. Returning from a camera child does not replay the entire writing instruction; manually opening the camera does not inherit previous automatic capture.
- Voice measurement no longer starts at exam entry. Nonfinite samples are ignored; silence and brief sound are unavailable rather than successful measurements. At least 2.5 seconds of above-threshold samples are required within the five-second window. This is a capture-quality gate, not clinical validation or vowel recognition. Live sample durations use the buffer sample rate, and stale microphone callbacks are fenced by monitoring session.
- Interrupted/insufficient voice remains retryable. Missing motion input or sparse/interrupted walking provides retry/skip instead of silently saving a failed measurement. Timers use monotonic deadlines. Backgrounding and leaving cancel capture, narration, handwriting requests, and exam-start tasks. Explicit session/operation IDs fence late permission and measurement callbacks.
- Added step-transition guards and duplicate completion protection. Existing account/data-generation fences, skipped/unavailable statuses, local raw history, and offline queue behavior remain in effect.
- Backend handwriting extraction and motor score formulas were inspected but not changed. Handwriting perspective/character-size effects, voice amplitude thresholds across audio routes, and gait heuristics remain unvalidated on physical hardware. No diagnostic accuracy or clinical score validation is claimed.

Validation: 402 Swift tests passed (including capture validity, cancellation, script consistency, duplicate completion, and repeat routing); iPhone target build succeeded with signing disabled. Final camera UI cleanup is compile-checked below. Actual voice timing/route switching, handwriting capture, walking safety/usability, and notification/provider delivery still require device acceptance tests. Logs: /private/tmp/cadence-motor-review-tests.log and /private/tmp/cadence-motor-review-build.log.
- Final follow-up: invalid voice capture no longer publishes an intermediate handwriting transition; the step changes only after capture validation. Timers run in the common run-loop mode with monotonic deadlines, so scrolling does not extend a nominal recording. The final iPhone target build succeeded; git diff --check passed.

### 2026-10-31 — In-app personal questions without connector approval

- User reports having applied for Meta AI connector preview. No form was submitted or edited by the agent. Preview access and separate DAT Voice Invocation approval remain unverified; this change does not activate either integration.
- Added a read-only question route before command interpretation. It answers local medication history, next saved reminder, configured medication plan/times, latest saved motor check, caregiver acknowledgment status, feature capabilities, and motor-check purpose. A dose-history answer accepts today/yesterday follow-ups.
- Local record queries require no server, OAuth connector or model-generated patient facts. Existing optional cloud transcription/intent classification remains Meta-only; these factual answers are ordinary app code, with existing Apple OS speech output.
- Diary reads run off the main thread. Latest-dose search is bounded to 30 local calendar days; unsupported relative dates ask for clarification. Unreadable data is distinguished from no record. Answers are fenced against account/profile change, stop/pause, and flow replacement. Read questions invalidate pending action confirmations and never create a dose/call.
- Added parser, named medication isolation, factual record/ingestion distinction, simultaneous reminder times, pending-action replacement, late-answer suppression, offline app integration, and unreadable-history checks. Full suite: 409 Swift tests passed. Physical-device speech acceptance remains outstanding.
- Final validation: iPhone target build succeeded with signing disabled; all five focused question-flow tests passed after follow-up invalidation changes; git diff --check passed. Logs: /private/tmp/cadence-questions-tests.log, /private/tmp/cadence-questions-focused-tests.log, /private/tmp/cadence-questions-build.log.

### 2026-10-31 — Meta-assisted interpretation of personal questions

- Extended existing /api/v1/companion/interpret with allowlisted read-only question intents: latest/today/yesterday dose history, next saved dose time, medication plan, last motor check, caregiver status, capabilities and task explanation.
- Ambiguous natural wording uses the existing configured Meta model interpreter. iOS maps only known question enums to the existing local factual answer service. Generated answers, medication times and patient identifiers are neither forwarded nor consumed. Known phrases retain the local path when offline/online interpretation is disabled.
- Added backend cases proving invented model answer/patient_id fields are discarded, plus iOS checks for model-assisted routing, today scope, no action execution, and local answers without a model call. Existing cancellation/profile/flow fences are rechecked after local lookup.
- Live synthetic check from the normal backend environment: “Catch me up on my pill log from this morning” returned doseHistoryTodayQuestion, source meta_open_weights, model meta-models/muse-spark-open-1026. No patient records were sent for this check.
- Validation: 14 backend interpretation tests passed; all 411 Swift tests passed; iPhone target build succeeded with signing disabled; git diff --check passed. Logs: /private/tmp/cadence-meta-questions-backend.log, /private/tmp/cadence-meta-questions-swift.log, /private/tmp/cadence-meta-questions-build.log.
- Requires the updated backend and iPhone build, existing online interpretation opt-in and a configured Meta provider. No Meta connector approval is required. No physical-device deployment or caregiver action was performed.

### 2026-10-31 — Prepare isolated Google Cloud demo deployment

- User supplied target project ultra-concord-513321-q3 and authorized starting a Google Cloud demo deployment using trial credit.
- Prepared an explicit Compute Engine deployment script, source-only upload builder, private environment/account generator, Debian/Caddy/systemd installer, and operational runbook. Local source bundles exclude secrets, records, caches, Git metadata and symlinks.
- Added public_demo startup checks requiring a durable signing secret, disabled shared tokens, simulated delivery mode, and no Twilio credentials. Model credentials are copied only through an allowlist; no local patient database is included. Generated secrets/passwords persist privately across redeploys and are not logged.
- Downloaded Google Cloud CLI 591.0.0 from Google's official arm64 distribution and verified SHA-256 3b7bbaaf2dd0287fab5320359fb61c678cbd6e8d6d58b884470def1bf96589a1. CLI credentials/config are isolated under ignored .local/gcloud; no shell profile was changed.
- Validation: all 211 backend tests passed; deployment shell syntax and git diff --check passed. Linux installation, HTTPS issuance, actual cloud IAM/networking, live-provider connectivity and restart durability remain to be verified on the VM.
- Current state: no authenticated Cloud SDK account; user sign-in is open in a browser handoff, with CLI session 12607 awaiting the one-time verification code. No VM, address, firewall rule or other cloud resource has been created, and no credentials/data were uploaded.

### 2026-10-31 — Google Cloud demo deployed and verified

- Completed a fresh user-approved Google Cloud sign-in after the prior sandboxed attempt failed. Verified linked project billing; no billing upgrade was performed.
- Created `cadence-demo` VM, dedicated VPC, static Standard-tier IPv4 and two firewall rules in project `ultra-concord-513321-q3`, zone `us-central1-a`. Only TCP 80/443 are public; SSH is restricted to IAP. The VM has no Google service account. Initial API activation and VM/IAP propagation delays required retries; deployment now checks sign-in/billing before mutations and probes SSH readiness before uploading credentials.
- Live origin: https://35.209.6.236.sslip.io ; dashboard: https://35.209.6.236.sslip.io/dashboard . Valid public TLS was checked against the installed CA bundle (verification was never disabled). Caddy and Cadence are active; Uvicorn listens only on 127.0.0.1:8000.
- Private server environment is root:cadence 640 inside restricted /etc/cadence. Database is cadence:cadence 600 inside restricted persistent storage. Corrected bootstrap umask so future databases also start with owner-only permissions. Twilio credentials and local patient records were excluded from upload. Generated account passwords and signing secret remain in ignored local files; no credential values were displayed.
- Added scripts/verify_cloud_demo.py. Initial pass verified HTTPS/dashboard, anonymous 401, public development token 401, writer/reader logins, reviewer write 403, live Meta classification using meta-models/muse-spark-open-1026, and one labeled SYNTHETIC DEPLOYMENT CHECK dose in the hackathon-demo patient. After systemctl restart cadence, the original JWTs, same server identity and saved synthetic record all remained valid.
- Updated iPhone connection instructions to support both cloud HTTPS and Mac development servers. iPhone target build succeeded with signing disabled (/private/tmp/cadence-cloud-iphone-build.log). Focused cloud/auth tests: 30 passed. Shell syntax, verifier compilation and git diff --check passed.
- No iPhone app was installed/launched, no phone profile was changed or erased, and no real caregiver SMS/call was sent. Device/glasses acceptance, backup automation, budget alerts and final judge credential sharing remain separate operational work. Resources consume trial credit while retained; deletion protection and retained disk require deliberate cleanup after judging.

### 2026-10-31 — Wearer-led walkthrough redesign, deployed

- Replaced the technical walkthrough control panel with a scroll-driven wearer story inspired by the supplied Apple design reference. Added a portrait-to-first-person glasses transition, five feature chapters with synchronized captions/steps/app receipts, and a closing illustrated iPhone diary. Clearly identifies Cadence as an iPhone app paired with glasses.
- Created four original static photographic illustrations with built-in image_gen and delivered same-origin JPEGs (about 1.5 MB combined). Prompts, asset paths, runtime boundaries, and design decisions are recorded in docs/WALKTHROUGH_DESIGN.md. No new runtime model provider was introduced.
- Removed fabricated medication answers, nutrition/absorption guidance, auto-running metronome/caregiver countdowns, and claims that frontend timers prove delivery. Scrolling is an illustrative, read-only experience. Safety delivery/acknowledgment and app imagery are explicitly labeled as simulated/illustrative.
- Added an optional authenticated judge panel: in-memory token only, writer/demo-patient check, cleared password, sign-out cancellation/late-response fencing, explicit sequential synthetic writes, and real report readback. It never invokes caregiver dispatch. No provider key is delivered to the page.
- Live browser verification succeeded: signed in privately as demo-wearer, ran a real Muse Spark Open interpretation (doseHistoryTodayQuestion), saved a synthetic dose and walking event, and read both UUIDs back from the report. Signed out afterward; sequence returned to disabled. No caregiver message/call was sent. Browser console had no warnings/errors on the deployed page.
- Desktop 1280×720 and phone-width 390×844 / 375×667 inspected. No horizontal overflow; short screens use normal scrolling so captions stay reachable. Reduced-motion/print CSS included; sound defaults off. Local preview logs confirmed scrolling produced no POST requests; the deliberate invalid-login check returned 401 with the run button disabled.
- Added exact-allowlist image route and CSS delivery under the existing nonce CSP, and expanded the source bundle allowlist for photographic assets. All 217 backend tests passed; JS syntax and git diff --check passed.
- Deployed to https://35.209.6.236.sslip.io/walkthrough . Public TLS, anonymous/static-token rejection, reviewer write protection, and existing JWT/server identity/saved data across redeployment all passed. Existing credentials/database were preserved. No iPhone installation, real sensor exam, or physical glasses acceptance was performed.
- Visual evidence: docs/verification/walkthrough-desktop-2026-10-31.jpg and docs/verification/walkthrough-live-proof-2026-10-31.jpg . Test log: /private/tmp/cadence-walkthrough-tests.log . Deployment log: /private/tmp/cadence-walkthrough-deploy.log . No commit or push was performed.

### 2026-10-31 — Complete guided feature journeys and human impact story

- Reframed the walkthrough around illustrative characters Arun and Maya, ordinary plans, user control, a diary that reduces the need to reconstruct details, and a closing scene of tea together. No patient testimonial or clinical outcome claim was added. Other conditions are presented as a future direction.
- Added “Play Arun’s day” and independently playable feature journeys with pause, previous, next, stop, and replay. The motor journey has eleven explicit beats matching the app's guidance: readiness, five-second voice illustration, writing introduction, three dictated chunks with six-second pauses, glasses-photo capture, photo confirmation, ten-second walking illustration, and a sample summary. Medication shows plan/record lookup, confirmation, saving and later recall; surroundings shows capture/review/confirmation/description; safety separates queued contact, provider acceptance and simulated human acknowledgment.
- Playback remains entirely illustrative and does not access the microphone/camera/sensors, make backend requests, write an exam, or contact caregivers. OS narration is opt-in. Countdown/dictation pauses begin after narration completion. Hidden-page and manual-scroll events pause playback, and stale callbacks are fenced by a revision. The authenticated live-proof panel remains separate and unchanged.
- Added six virtual-time production-controller tests, now in CI: no background API/audio calls, voice timing after spoken Begin, full pauses after slow dictation, pause/stop cancellation, hidden-page pause, and full-day progression to the care view. All six passed; all 217 backend tests passed. JS syntax and git diff --check passed.
- Browser-inspected voice capture, handwriting chunk progression, confirmed photo, walking countdown and sample summary locally; verified motor steps 5/11 through 11/11 on the deployed page. Phone-width 390×844 inspected with fixed playback navigation and no horizontal overflow. No audio playback was enabled during validation. Local preview log contained no POST requests.
- Original closing illustration created with built-in image_gen and saved as backend/app/static/walkthrough/together.jpg, added to the exact image allowlist. Character reference, full prompt and runtime boundaries are recorded in docs/WALKTHROUGH_DESIGN.md. Fixed stylesheet indentation and mobile heading word separation during review.
- Deployed to https://35.209.6.236.sslip.io/walkthrough . Live browser console had no warnings/errors; closing image loaded. HTTPS, anonymous/static-token rejection, read-only reviewer enforcement and original JWT/server identity/saved records all passed after redeploy. Credentials and database were preserved; no physical-device app change or real caregiver delivery was performed.
- Evidence: docs/verification/walkthrough-guided-motor-2026-10-31.jpg and docs/verification/walkthrough-human-ending-2026-10-31.jpg . Logs: /private/tmp/cadence-guided-story-tests.log, /private/tmp/cadence-guided-story-playback-tests.log, /private/tmp/cadence-guided-story-deploy.log . No commit/push was performed.

### Walkthrough regression repairs — deployment verified

- Preserved the user's newly restyled page and scene artwork. Fixed the first Play Arun's day action to explicitly navigate to the visible medication scene. Individual guided-exam controls no longer request navigation. Removed the sticky showcase's centered flex layout and scroll anchoring that could move the viewport during updates.
- Live browser checks: the first action showed medication step 1/5 with scene top 84px below a 52px header; starting Watch the guided exam left scrollY exactly unchanged (2893.5 before and after). Narration is enabled by default but remains locked until a Play/Continue gesture; tests mute it before browser interactions. No speech is attempted on page load.
- Restored contrasting writing-chunk highlighting and optional OS word-boundary underlining, fenced against stale speech callbacks. Added separate voice, progressive writing, completed handwriting capture and walking visuals. Handwriting images visibly build the exact dictated sentence. Timer markup includes a literal space and CSS column gap: verified 5 seconds and a 14px gap.
- Removed guided-image zoom transforms, fitted previews with object-fit:contain, and added a full-photo dialog. The readable close-up contains the complete sentence and no text is covered. Opening the viewer pauses playback; closing it does not resume automatically. At phone width 390×844 the dialog fits without horizontal overflow, and the preview panel/caption have a 14px separation.
- Built-in image_gen created five project-bound assets from existing character/page references; generated sources were retained and JPEGs saved under backend/app/static/walkthrough. Asset paths and exact prompts are in docs/WALKTHROUGH_REPAIR_NOTES.md. No runtime model/provider was added.
- All 217 backend tests passed, with the asset-route tests rerun after the final image was added. All 11 silent virtual-time playback tests passed, including first-click navigation, no local scroll, default narration gating, progressive visuals, countdown spacing and full-photo open/close. JS syntax and git diff --check passed.
- Deployed to https://35.209.6.236.sslip.io/walkthrough . The live default sound state, writing image/highlight and full-photo dialog were checked in the browser; TLS, account/role restrictions and existing data/JWTs were checked after redeploy. No caregiver contact or iPhone app change occurred. Evidence: docs/verification/walkthrough-repaired-photo.jpg . Logs: /private/tmp/cadence-walkthrough-repair-tests.log, /private/tmp/cadence-walkthrough-repair-playback-tests.log, /private/tmp/cadence-walkthrough-repair-deploy.log . No commit or push performed.
- Friendly-domain follow-up: the preexisting acceptance baseline identified cadence-companion.duckdns.org as the configured primary domain. The initial deploy invocation had defaulted to the IP host. Updated deployment to remember the chosen hostname in ignored .local/gcp-demo/hostname, and Caddy installation to accept the friendly primary plus the IP-based sslip.io alias. Redeployed explicitly to the existing friendly domain; both hosts returned 200 over validated HTTPS for /health and the new photo asset. The original baseline then passed through the friendly domain: original JWTs, server identity, saved record, and role protections were all intact. The runbook now uses the explicit friendly hostname. No DNS record or credentials were changed.

### 2026-11-01 — Judge architecture and implementation guide

- Added an accessible Experience / How it works tab with a directly linkable `#how-it-works` view. Animated four-part architecture connects glasses, the iPhone, authenticated backend and care connection. Tab switches pause narration/playback; motion can be paused and reduced-motion preferences are respected.
- Model cards reflect source configuration: Muse Spark Open for bounded intent/label selection, SAM 3.1 for scene segmentation, Muse Voice Transcribe for transcription. Llama is documented as an alternate configuration. Installed Apple speech output and local DSP/OpenCV are explicitly distinguished from runtime external Meta model calls.
- Interactive, clearly synthetic spectra show the FoG higher-band/step-band ratio with the actual 3 Hz boundary and contextual gates. Synthetic component heights show the first/last-group handwriting change formula; the illustrative photo is not claimed as the source of those numbers. Additional cards explain voice RMS/dBFS, walking samples, medication confirmations and deterministic fall escalation.
- README now includes a reproducible code-drawn animated GIF architecture, static SVG alternative, model map, formulas, implementation links and live guide link. Generated by `scripts/generate_architecture_art.py`; no model was called to create these diagrams.
- Local checks: 218 backend tests, 24 JavaScript tests (dashboard renderer, guided playback and architecture math), 411 silent Swift tests, and an iOS Simulator build passed. Desktop and 390×844 phone layouts checked in-browser; no horizontal overflow, keyboard tab navigation and slider outputs verified. Browser console had no warnings/errors. These checks do not constitute hardware or caregiver delivery acceptance.
- GitHub CI for the existing remote revision b56a3a3 was green (run 41281097092). Publication and checks for this change are recorded separately when available.
- Deployed the guide to https://cadence-companion.duckdns.org/walkthrough#how-it-works . Live browser verified the selected tab, all model/math sections, and no console warnings/errors. Post-restart cloud checks passed: valid HTTPS, anonymous/shared-token rejection, read-only role enforcement, original JWTs, server identity and saved synthetic record preserved. No new patient record/model call/caregiver message was needed for this check.

### 2026-11-01 — Tour continuity, sound startup and simpler native navigation

- Removed viewport-center-based playback cancellation. A responsive scene or an automatic chapter transition can move the center away from the selected scene; that is not user intent to pause. Deliberate wheel/touch scrolling and page-navigation keys pause playback instead. Explicit Pause, hidden-page, architecture-tab and photo-review cancellation remain intact.
- Story-page load attempts a short OS/browser welcome when speech is available. Browser `not-allowed` errors leave an explicit Enable sound control; its first tap enables rather than mutes. Play/Continue also unlock narration. No autoplay policy is bypassed. Stale speech callbacks cannot reset a later narration's sound status.
- Native screens now share the web experience's graphite background, mint accents, larger rounded cards and readable text contrast. The root has Today, My routine and Settings tabs. Today leads with the companion, medication and plain-language tasks; device/walking controls expand on demand. Walking-support failures remain visible without expanding, the help action remains on Today, and Diary/Help sheets have explicit Done buttons. Existing confirmations, persistence, voice routing and emergency overlay remain in place.
- Checks passed: 218 backend tests, 28 JavaScript tests, 411 silent Swift tests, and compilation of the iOS app target with the Meta DAT SDK for Simulator. New regression tests cover blocked/allowed autoplay, first-tap unlock, deliberate scroll pause, and repeated layout/scroll frames through the full day.
- Browser playback locally completed every chapter and automatically reached the care view at 64px below the top (journey player hidden, no active controlled chapter). No API/model/caregiver requests were made by the story. The deployed server passed HTTPS, anonymous/shared-token rejection, reader-role enforcement and original JWT/server/saved-record survival checks. Native changes require installing the updated app; physical-iPhone visual/audio acceptance has not been performed by these checks.
- The full deployed tour also completed through surroundings and safety to the care view (care top 64px, no controlled chapter, journey player hidden). First audio activation changed Enable sound to Sound on; browser autoplay restrictions remain respected. No browser console warnings/errors were observed. Public completion screenshot: /private/tmp/cadence-live-complete-day.jpg.
- CI run 41286201704 exposed a timing assumption in the existing growing-partial-transcript test: after 60ms the main-actor debounce had not finished on the hosted runner. Replaced fixed startup/completion sleeps with bounded waits for listener readiness and the actual action; retained the final negative-transcript/cancel assertions and added an immediate no-action assertion. All 30 VoiceCompanionTests passed locally after the repair. This changes test synchronization, not production debounce duration.

### 2026-11-01 — Principal review: default-mode contracts and submission boundaries

- Confirmed and fixed the default-mode iOS handwriting decode break. `micrographiaDetected` is optional: a withheld field remains nil, rather than becoming a negative finding. Swift tests decode both measured and unreadable accessibility responses without research fields.
- Measured and unreadable handwriting results now use the same explicit observation-field projection. Corrected the sign in the spoken size comparison: negative change means smaller, positive means larger. Default handwriting processing does not calculate the experimental score/classification; its legacy database flag is a withheld compatibility placeholder. Research calculations require an explicit opt-in.
- Backend tests now default to research disabled, matching the submitted build. Seven legacy endpoint/score tests explicitly request the research fixture. Added real-image-input, default measured/unreadable, no-future-field leakage and actual unconfigured caregiver-client 503 tests. No real call is made by these tests.
- Public-demo startup rejects research mode and unreviewed model IDs. Deployment preparation explicitly pins research off. Public/production interactive docs and schema routes are disabled; development documentation remains available. Existing prepared deployment configuration passed the guard before redeployment.
- Fixed another live-journey gap: Muse label selection needs room for its reasoning/final output, as the companion intent path already does. The grounded selector now uses low reasoning and 512 output tokens, accepts only one complete allowed label (including quoted labels), and falls back on malformed/prose answers. Its three-second maximum is clamped by the shared eight-second request budget and enforced by an outer wall-clock timeout. A never-returning transport regression test verifies cancellation.
- Recorded a live, fixed-text, non-personal Muse intent request through the deployed app: Baseten, `meta-models/muse-spark-open-1026`, surroundings intent, 2135ms server-reported / 2396ms end-to-end. Sanitized trace: docs/verification/muse-intent-live-2026-11-01.json. This does not establish real-photo SAM grounding or audible physical-glasses delivery. No image, diary record or caregiver contact was created by this proof. Public /docs, /redoc and /openapi.json returned 404.
- Signed-out browser access showed the GitHub repository marked Public, Sign in/Sign up controls, and the README. Existing original Git history is preserved. The supplied guide's page 4 explicitly identifies the Oct 27–Nov 4 build period and requires clearly identified event-built contributions; foundation commits dated Oct 26 therefore remain an organizer-boundary question, not an eligibility conclusion.
- Latest local checks: 238 backend tests, 412 silent Swift tests and iOS Simulator compilation passed. Previous clean-clone CI for the tour/native UI passed all three jobs: https://github.com/theloopsmith/Cadence/actions/runs/41286437848 . New contract changes are checked on their published revision separately.
- Pending owner inputs/evidence: organizer scope/start-boundary reply; an approved non-sensitive real glasses photo (owner says not yet available); physical audio acceptance; video, contributor/representative declaration and asset rights confirmation. Caregiver delivery stays explicitly simulated. No message was posted to Discord by the agent; a copyable clarification was supplied to the owner.
