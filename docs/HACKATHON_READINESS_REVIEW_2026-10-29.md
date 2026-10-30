# Cadence: what to work on next — October 29, 2026

## Follow-up status — item 1 reviewed, item 3 implemented

The phone/glasses entry journey was the next product blocker and is now implemented: a running LAN development backend, authenticated localhost repair that preserves phone queues, consistent glasses-first photo actions, capture lifecycle/timeouts and nullable SAM confidence decoding. See [phone/glasses setup and remaining physical checks](PHONE_AND_GLASSES_JOURNEY_2026-10-29.md).

Items 8 and 9 are implemented: server wipe and offline pending uploads are coordinated via durable `patient_wipes` ledgers; events predating a wipe are cleanly dropped without resurrecting deleted data or hanging the outbox. Dose Undo appends an idempotent retraction (`/api/v1/medication/dose/retract`) referring to the original dose UUID; effective dose history derives from both events across reports, timeline buckets and dose clock, with full support for out-of-order network arrival. **167 backend tests and 292 Swift tests pass.**

Item 8's local-history portion is implemented using a single-wearer installation, durable account/server binding, profile-specific files/preferences and an explicit restart-based local erase/reprovisioning flow. Different account/server changes are rejected; legacy unassigned files are not silently adopted. **279 Swift tests and the actual app build pass.** See [local-profile verification](LOCAL_PROFILE_VERIFICATION_2026-10-29.md). Coordination between the dashboard's server wipe and offline pending uploads remains open; local reset explicitly leaves server data unchanged.

Item 6 is implemented: one consistent trailing UTC interval, complete aggregates with disclosed detail limits, unknown monitoring coverage, factual narratives and distinct queued/provider-accepted/caregiver-acknowledged states. The phone consumes incident-bound delivery evidence, and shared PDFs label requests accurately. See [report verification and limits](REPORT_TRUTH_VERIFICATION_2026-10-29.md) for its verification snapshot. The unchanged backend/dashboard checks remain 161 backend tests, five JavaScript checks and isolated headless Chrome. Physical-device and live caregiver proof remain unverified. Server-wipe/upload coordination is the next data-integrity priority while provider setup is pending.

Item 5 is implemented and browser-verified: dynamic dashboard text uses DOM text nodes, GPS links validate coordinates, and nonce-based CSP blocks injected scripts/handlers. See [dashboard security verification](DASHBOARD_SECURITY_VERIFICATION_2026-10-29.md) for its earlier verification snapshot.

Item 4 is implemented: nullable measurements and task validity propagate through phone, API, storage, dashboard and shared summaries; existing database upgrades preserve raw history without treating unknown defaults as observations. See [partial-check verification](EXAM_VALIDITY_VERIFICATION_2026-10-29.md) for that change's verification snapshot.

The user's SAM adapter now uses the documented Responses path and includes live synthetic-image and synthesized-speech evidence. The original endpoint mismatch below is superseded; real-photo scene and Baseten-selection evidence remain open. The parser currently uses box area and does not surface malformed-output diagnostics.

Item 3 now has speech preemption/cancellation/cooldown, audio interruption/reset recovery, explicit Stop/Retry controls, actual route display and sensor freshness health. See [audio/protection verification](AUDIO_PROTECTION_VERIFICATION_2026-10-29.md) for the implementation, 253 passing Swift tests, 137 passing backend tests, successful actual app build and remaining physical-device limits. Other findings below remain the backlog. Original review/test counts below are a snapshot from before these follow-ups.

## Recommendation

Make one authentic, useful Meta-powered accessibility journey work end to end, then make it effortless for judges to understand and reproduce. The strongest next investment is **repairing and proving the live SAM integration**, followed by audio reliability and a truthful demo. More emergency infrastructure, additional providers, and more clinical features currently offer less submission value.

The architecture is a reasonable foundation: Swift owns motion, immediate audio, check-ins and an offline outbox; FastAPI owns authenticated inference, persistent caregiver jobs, and reports. Keep that split and SQLite for this deadline. A database/platform rewrite, microservices, or adding an LLM to emergency decisions would distract from the gaps below. Winning cannot be predicted from source code; useful behavior and the submitted evidence are still decisive.

This review supersedes the **current priority order** in the [October 28 review](PROJECT_REVIEW_2026-10-28.md). That document remains historical evidence, and several of its critical findings have now been addressed.

## Scope and verification

Repository-wide review of the app/package structure, DAT adapter, edge detectors, audio and speech paths, emergency coordinator, account/session and persistence paths, medication/diary/report flows, backend routes/models/services/provider adapters, tests, scripts and planning documents. Findings below distinguish source inspection, automated checks, and external evidence. This is not a claim that every device path, external account, or provider response has been exercised.

- Current backend suite: **122 passed**, two dependency/API deprecation warnings.
- Swift package suite: **237 passed**, with the explicit XCTest-only silent audio flag.
- Actual iOS Simulator app target: **BUILD SUCCEEDED**, including DAT compilation. Latest build did not launch the app or play audio.
- Simulator mock-kit build/install/launch was previously verified; the screenshot has a permission overlay. It is not complete UI or physical-device validation.
- Real caregiver drill: **not verified**. Public callback readiness succeeded, but the dispatch returned no provider IDs or acknowledgment. Read-only checks found Trial sender/recipient setup gaps. See [verification evidence](RECOVERY_VERIFICATION.md).
- No physical glasses, acoustic routing, locked-screen continuity, or live Meta segmentation success has been established by these tests.

During the ongoing recovery work, a concurrent-worker test exposed duplicate initial dispatch from a stale snapshot. This review run fixed it by removing the stale state reset, preventing initial-dispatch reuse after an attempt exists, and fencing scheduled retries by expected attempt and due time. Two regression tests were added. Unknown provider outcomes remain explicitly at least once; this fix does not promise exactly-once delivery.

## Findings, ordered by submission value and severity

### 1. P0 — Live SAM contract differs from Meta's documented API

**Evidence:** `backend/app/clients/meta_models.py:74` calls the configured default `https://api.llama.com/v1/vision/segment`, sending `candidate_labels` and `image_base64`, then reads `data['masks']`. `backend/tests/test_sam_client.py` fabricates that same response and does not validate the official endpoint.

Meta's [SAM overview](https://dev.meta.ai/docs/sam/overview) documents the Responses endpoint on `api.meta.ai`, image/text input parts, one concept per request, and tokenized segmentation output. The [official protocol](https://github.com/meta-models/meta-sam/blob/main/protocol/sam3.md) specifies optional confidence; missing confidence is not zero. The pipeline currently rejects masks without a numeric confidence of at least 0.65.

**Consequence:** the normal configuration is incompatible with the documented service. Even changing only the URL would leave request construction, parsing, candidate orchestration, and confidence handling incorrect. I have not made a live request to prove a particular HTTP failure.

**Next work:** implement the documented contract and parser, deliberately select a small concept set, bound concurrency and total latency, and preserve uncertainty. Add fixtures from the official format plus a separately run live smoke check. Do not fan out all closed-vocabulary labels under the existing assumed 1.8-second stage budget without measuring it.

**Done when:** a real photo produces decoded masks/boxes, a bounded spoken result, exact model and input-source metadata, timings, and a sanitized trace. Empty, missing-confidence, malformed-output and provider-failure cases behave honestly. Record live Muse/Baseten execution separately; its deterministic day summary is not evidence of Muse reasoning.

### 2. P0 submission gate — Eligibility remains unresolved; hiding scores is incomplete scope separation

**Evidence:** guide page 5's anti-project examples include AI medical advice, nutrition coaching, and simple image analyzers. Default APIs now hide scores and meal nutrition, but `main.py:519–596` still computes and stores medication-state classifications and exam scores. `MedicationSchedule.isPredictedOffPeriod` still drives simplified UI timing. Scene questions remain centered on whether a person/intruder is present.

**Assessment:** this is an unresolved organizer-scope question, not a finding that all accessibility projects are prohibited. Renaming the app or adding disclaimers does not determine eligibility. Also, a basic photo-label demonstration alone may be too close to the guide's simple-image-analyzer example.

**Next work:** obtain organizer clarification using the existing draft in [PHASE_0_1.md](PHASE_0_1.md). Prepare a submission build with an explicit, tested accessibility scope and a concrete daily task. Avoid executing interpreted clinical/nutrition logic in that build unless cleared. Explain why voice access, constrained observations and useful follow-through solve a specific need beyond image labeling. Preserve real contribution history and clarify the guide's start-boundary ambiguity.

**Done when:** the scope decision is recorded, visible behaviors match it, disabled features cannot leak through the submitted path, and the pitch demonstrates a useful workflow. No organizer contact has been sent by this review.

### 3. P1 — Audio priority and protection health are still weaker than the UI promises

**Evidence:** `AudioCueEngine.speakPrompt` queues `AVSpeechSynthesizer` utterances. Stopping the metronome stops the PCM player, but does not cancel its queued speech. Siren activation does not preempt existing speech. A duplicate start guard now avoids requeuing within one active cue episode, but does not establish cross-episode cooldown or cancellation. The earphone repetition reported during the mock run demonstrates the practical cost.

`MotionFeed.start` sets running state from startup flags; it has no sample-age watchdog. `SilentAudioKeepAlive.start` ignores engine-start errors and can report active. There is a route-change observer, but no interruption/media-services-reset recovery observer was found. Bluetooth HFP/LE input is treated as glasses, including ordinary earphones.

**Next work:** give speech/cues explicit cancellation and preemption, a clear Stop action, episode prompt deduplication/cooldown, and visible output/input identity. Track last valid sample and audio startup/recovery errors; stale input must show degraded/unavailable protection. Handle interruptions and reconnects. Do not describe silent background audio as proof of uninterrupted protection.

**Done when:** stopping a demo clears pending speech, a second cue does not replay old prompts, emergency audio preempts lower priority speech, and input loss changes UI health. Unit checks can cover arbitration; routing, interruptions, screen lock and audible behavior need device evidence or must remain explicit limitations. Mock-kit launch now starts protection off.

### 4. P1 — Incomplete exams still send default or previous measurements

**Evidence:** `HomeMotorExamManager.startExam` resets measured flags without replacing numeric measurements. `completeExam:220–228` sends every numeric field regardless of flags. Local trends omit unmeasured fields, but the backend stores and narrates them as measurements. The backend schema has no corresponding task validity fields.

**Next work:** reset each exam's full state, send nullable values plus per-task measured/quality status, and make backend summaries honor validity. Stop incomplete checks from generating a full composite. Treat a skipped photo, denied microphone and interrupted walk as unavailable measurements.

**Done when:** completing a partial second exam cannot reuse the first exam's values, and phone, API, dashboard and PDF agree on what was actually measured. If checks are not in the selected journey, defer the feature from the demo rather than polishing its scoring.

### 5. P1 — Dashboard includes stored HTML injection paths

**Evidence:** `neurologist_dashboard.html:355–368,412–414` interpolates stored timestamp/transcript/question/response strings into `innerHTML`; `models.py` accepts arbitrary query/transcript strings. The page also holds its bearer token in `sessionStorage`. No CSP was found.

**Consequence:** attacker-controlled wearer text displayed in a care-team session can execute in that page's origin. Authentication and SQL parameters do not prevent HTML injection.

**Next work:** construct DOM nodes and set text with `textContent`, validate numeric link coordinates and add CSP as defense in depth. Cover stored markup in a real rendering test.

**Done when:** a stored question or cancellation transcript containing HTML displays as text and cannot execute. Fix before exposing the dashboard as the live submission.

### 6. P1 — Factual reports still misrepresent time, coverage and contact status

**Follow-up: implemented.** See [report verification](REPORT_TRUTH_VERIFICATION_2026-10-29.md). The evidence below describes the original finding; unknown physical monitoring and historical phone reconciliation remain explicit limits.

**Evidence:** `get_neurologist_report` fetches row-capped histories without a common time predicate; freeze/fall totals count those histories while doses use a separate last-day filter. `diary_engine.py` anchors on the newest event, so an inactive account can show an old period. `_within_last_day` accepts future timestamps. Timeline colors imply healthy/quiet periods even with no observation coverage. Default mode hides clinical labels but does not fix missing observations or mixed ranges.

`SummaryReport.swift:144` still labels `.helpSent` counts “Falls, help contacted”, while `CadenceAppModel` creates that entry when the alert is only locally queued. Local diary wording has improved, but the PDF reintroduces the overclaim. No phone consumer of the new backend delivery-status endpoint was found.

**Next work:** query an explicit UTC interval with complete aggregates; show interval, freshness, source and observation coverage. Use “no observations” where appropriate. Drive queued/provider-accepted/caregiver-acknowledged presentation from correlated state; rename the PDF count now.

**Done when:** an offline alert is never reported as contacted, a five-day-old record cannot become today's activity, future data is rejected, and high-volume days do not silently lose counts.

### 7. P1 — Caregiver delivery is not demonstrated and contacts are deployment-wide

**Evidence:** the actual isolated test returned no SIDs or acknowledgment. [Read-only preflight](verification/caregiver-provider-preflight.json) found an active Trial account, no matching owned SMS/voice-ready sender, and an unverified Trial recipient. `_primary_phone` and secondary routing use server settings for every patient; `AppSettings.caregiverPhone` configures the local call button, not automated server routing.

**Next work:** fix provider setup, repeat the already scoped consenting test when ready, and retain correlated signed DTMF acknowledgment evidence. Surface readiness to the demonstrator. For this deadline enforce/document one wearer per deployment and show the same masked recipient in setup; patient-specific verified contacts are required before shared multi-wearer use.

**Done when:** a real expected test contact receives the labeled notification, presses 1, and the signed callback resolves the exact attempt. Otherwise demonstrate a clearly labeled mock and do not claim successful real delivery. No additional calls were placed for this review.

### 8. P1 — Account-bound transport does not isolate the rest of the phone's data

**Follow-up: local-history isolation implemented; server-wipe coordination open.** The app now rejects switching wearer/server without a confirmed local reset and uses profile-specific storage/setup. See [verification and upgrade limits](LOCAL_PROFILE_VERIFICATION_2026-10-29.md). The evidence below describes the original finding. Local erasure is coordinated with that phone's queue; an independent dashboard server wipe still cannot invalidate offline queued data.

**Evidence:** the outbox now binds rows to account and destination. `DiaryStore.default`, `TaskMetricsHistory.default`, pill-photo storage, schedule and summary settings remain shared device locations. `AuthSession.signOut` changes credentials without switching these stores; `CadenceAppModel` retains them.

**Consequence:** signing in as B can still show A's diary, measurements, schedule and pill image even though B cannot drain A's queue. Queue ownership must not be advertised as whole-app account isolation.

**Next work:** either explicitly enforce a single-wearer device with a deliberate reset/provisioning flow, or scope all stores and subscriptions by account/destination. Coordinate deletion with pending events so deleted data is not later uploaded.

**Done when:** a two-account drill verifies both transmission isolation and visible local history, photos, reminders, summaries and erase behavior.

### 9. P1 — Dose Undo is only a local withdrawal

**Evidence:** `DoseLogModel.undo` removes a diary item and withdraws an unsynced queue row. It cannot undo a dose already accepted by the backend, nor reliably cancel an in-flight request. UI and backend history can disagree immediately.

**Next work:** append an idempotent retraction referring to the original event and derive effective dose history from both events. Handle out-of-order arrival. If deferred, do not promise that Undo corrects the shared record.

### 10. P2 — Latency budgets are not hard deadlines; image work is unbounded

**Evidence:** `RequestDeadlineContext` computes a timeout scalar, but no outer cancellation scope encloses the scene pipeline. HTTP transport phase timeouts do not enforce its documented total wall-clock claim. Clients are created for each request. Image fields have no comparable encoded-length limit to audio; handwriting decode/threshold/components run synchronously in an async route.

**Next work:** enforce a total request deadline, limit encoded bytes and decoded dimensions, move CPU work off the event loop, and bound concurrency. Reuse managed clients. Measure capture-to-spoken-result latency separately from server/model time and DSP execution time.

### 11. P2 — Retention and migrations remain incomplete

**Evidence:** the startup foreign-key deletion crash was mitigated by retaining parents with jobs. `purge_expired_telemetry_sync` never removes durable jobs/attempts/clears, never expires confirmed falls, and now preserves essentially every canceled fall that has a job. Maintenance runs at startup only. Backend schema changes still rely on CREATE IF NOT EXISTS rather than versioned migrations. Synced local queue rows are not pruned.

**Next work:** define lifecycle rules for completed jobs and audits, delete in dependency order after the stated retention, run bounded scheduled maintenance, and add versioned upgrade migrations. Test an existing database upgrade and a long-running server. This is lower priority than the live Meta journey for a small isolated hackathon demo.

### 12. P1 submission execution — No reproducible, rubric-focused acceptance gate

**Evidence:** no tracked CI workflow or backend dependency lock was found; requirements use lower bounds. The manual iOS app build is now proven, but package tests alone would not catch DAT compile failures. Historical diagrams/plan still describe work differently from runtime. Existing test fixtures validate several assumed provider contracts rather than recorded live ones.

**Next work:** add backend tests, silent-audio Swift tests and actual app-target compilation to CI; lock dependencies; supply a clean-clone setup and a sanitized sample session. Make one short current execution board with acceptance evidence. Document original event-period work, contributors, representative, third-party rights, public repository access and accessible video. Do not rewrite provenance.

## What is already worth keeping

Keep the deterministic edge/cloud boundary, FFT/reference comparison tests, labeled mock replay, shared distress-first recognition reducer, explicit persistence warnings, account-bound outbox, transactional dispatch jobs and attempt/lease correlation. Those support a credible technical-depth story. Explain one recovery failure in the demo instead of reciting the entire implementation.

Do not restart Phase 0/1 from scratch: production simulation restrictions, ownership checks, rearming, crash recovery, account-bound queueing and contradiction logic have implementation and automated evidence. Remaining integration claims need their own evidence. Avoid equating “tests passed” with clinical validity or a physical-device result.

## Execution order through submission

These are recommended targets, not organizer promises or estimates of guaranteed completion. The supplied guide weights Impact 30%, Meta Tooling 25%, Technical Depth/Execution 20%, Demo 25% (page 9). Its page-8 deadline is November 4 at 9 PM EST / **6 PM Pacific**; this review uses that snapshot and does not establish later organizer changes.

1. **October 29: clear the first gates.** Resolve scope with organizers; fix SAM's protocol and run one real segmentation plus actual Muse selection/transcription check. Save traces and a screen recording. Choose one main user journey and list exactly what is simulated.
2. **October 30: make that journey reliable.** Cancel/preempt queued audio; add sensor freshness and honest contact state. Fix dashboard text rendering if it is exposed. Either repair partial-exam semantics or remove that feature from the submitted journey.
3. **October 31: prove usefulness and failure behavior.** Run a small consented usability session around an everyday task. Measure completion, interaction count, latency, misunderstandings and user feedback; report sample size honestly. Record offline recovery and one uncertainty case. Finish caregiver setup if it remains in the promised scope.
4. **November 1: make it reproducible.** CI, dependencies, clean-clone setup, one-wearer provisioning and explicit demo reset. Verify physical device behavior if available; otherwise keep the phone/mock fallback visible and narrow claims.
5. **November 2: assemble the three-minute story.** User need → live Meta-grounded task → observed benefit → one technical/failure demonstration → limitations and original contribution. Spend most time showing behavior, not dashboards or provider logos.
6. **November 3: freeze and submit with buffer.** Confirm public signed-out repository access, accessible video, contributor/representative details, rights, original-work notes and any required live-product access. Leave November 4 for submission recovery rather than new features.

If time runs short: prioritize eligible scope, working Meta inference, one useful journey, understandable evidence and a complete submission. Defer clinical scoring, nutrition, SAM handwriting refinement, extra inference vendors, agentic bonus work, multi-tenant expansion and a platform rewrite. Named open-weight bonus fit requires the guide's specified model and actual use; it should not displace the core entry.

## Immediate next implementation ticket

**Repair and verify the SAM 3.1 adapter against the official Responses protocol.** Deliver the adapter/parser, recorded contract fixtures, genuine-image smoke-check command, explicit model/source/latency evidence and uncertainty behavior. This removes a concrete blocker while supporting both the Meta-use gate and the demo. Scope clarification can proceed alongside this work; no external message or submission is authorized by this review.

Sources: supplied [hackathon guide](Details%20%E2%80%93%20Meta%20Global%20AI%20Developer%20Hackathon%20%E2%80%93%20Cerebral%20Valley.pdf), pages 4–5 and 8–11; current repository; linked official Meta API/protocol documentation inspected October 29. Some guide table columns are clipped; no unseen wording is assumed. No numerical prediction of winning odds is warranted.
