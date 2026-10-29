# Cadence project review — October 28, 2026

## Assessment

**Updated after reading the complete 12-page hackathon participant guide:** preserve the technical foundation, but put hackathon eligibility and a focused, demonstrable Meta-model workflow ahead of further feature expansion. The page-5 anti-project guidance creates a material eligibility risk for the current clinical and nutrition positioning. This is an assessment of the supplied guide, not an organizer ruling. The detailed requirement mapping and revised submission plan appear below.

The architectural foundation is appropriate for a small team: Swift owns time-sensitive sensing and audio, FastAPI owns persistence and orchestration, external models are behind adapters, and deterministic rules control the main decisions. Keep that structure. The next investment should be reliability and trustworthy data, ahead of additional pipelines or providers.

The implementation is materially ahead of the nine-day plan. However, persistent rows do not yet guarantee that a fall will reach a caregiver, and the report can present missing or stale observations as measured states. These are integration-contract problems that passing component tests do not settle.

This review covers the repository's Swift package and app integration, Python API, persistence, provider adapters, dashboard, tests, scripts, implementation plan, prior architecture review, diagram XML, and the supplied hackathon PDF. It is a software and hackathon-alignment review, not validation of detector accuracy or medical effectiveness. Existing application code was not changed. The original test results describe the initial review run; the PDF follow-up did not rerun them or revalidate later source changes.

## Verification and limits

- Backend: **97 tests passed**, with two deprecation warnings.
- Swift: package compilation succeeded using a scratch directory outside iCloud and SwiftPM's sandbox disabled inside the execution sandbox. XCTest passed the seven API-client tests, then aborted with an uncaught audio-related NSException in the fall detector test. A complete Swift pass is **not established** by this review. Swift 6 concurrency warnings also appeared in voice tests.
- Five additional isolated Python probes reproduced: production-mode simulated Twilio success; cross-patient mutation of a fall candidate; HTTP 200 despite total dispatch failure; an allegedly current report anchored five days in the past; and a retention purge failing with a foreign-key error.
- Probes used a temporary database and disabled external credentials. No real caregiver calls or provider requests were made.
- Real glasses, physical iPhone background operation, live cloud contracts, Twilio callbacks, and acoustic output were not validated. Swift package tests do not build the separate DAT adapter in the Xcode app target.

## Findings to fix first

### 1. P0 — Production can report a simulated caregiver dispatch as success

Evidence: `backend/app/clients/twilio_client.py:73–85`, `backend/app/security.py:98–99`, `backend/app/auth.py:190–198`.

When Twilio credentials or sender configuration are missing, the client returns `SM_SIM_*` and `CA_SIM_*` SIDs with `queued`, regardless of environment. The escalation manager accepts those SIDs as dispatch success. The webhook verifier also accepts unsigned requests when the auth token is empty, with no production-mode check. Production startup currently validates only the JWT secret.

**Reproduced:** with `cadence_env='production'` and empty Twilio credentials, dispatch returned `SM_SIM_review-s` and `queued`.

**Improve:** inject an explicit simulated transport for tests/demo. A production transport must never fabricate success. Fail startup or clearly disable remote escalation when required credentials, HTTPS callback URL, sender, or recipient configuration are absent. Production webhook verification must fail closed. Add production-mode contract tests.

### 2. P0 — A failed caregiver dispatch is acknowledged as delivered by the phone

Evidence: `backend/app/services/fall_escalation.py:150–165`, `backend/app/main.py:207–217`, `ios/CadenceCompanion/Sync/EventSyncManager.swift:56–73`.

When both Twilio channels fail, the backend resets the fall to `confirmed_waiting_dispatch` and returns a normal HTTP 200 body containing `twilio_dispatched: false`. The phone ignores that body and marks every 2xx response delivered. No retry loop was started for this failure, and startup recovery only resumes `escalated_twilio` rows with alert records. That can strand the event permanently.

**Reproduced:** the HTTP endpoint returned `200 / confirmed_waiting_dispatch / false` with both channels failing.

**Improve:** define exactly what an API acknowledgment transfers responsibility for. Prefer an atomic durable dispatch job plus HTTP 202, with the server owning retries thereafter. Until then, return a retryable failure and have the phone parse endpoint-specific results. Distinguish persisted, provider accepted, delivered, and caregiver acknowledged states.

### 3. P0 — Fall writes can cross patient boundaries

Evidence: `backend/app/services/fall_escalation.py:75–127`, `backend/app/db.py:38–40`.

The initial lookup includes `patient_id`, but the conflict update and later claim/read operate on globally unique `event_uuid` alone. A different authenticated patient who knows an event ID can update a pending candidate or interact with an existing dispatch. Authentication alone does not preserve tenant isolation here.

**Reproduced:** patient A inserted `candidate_check_in_pending`; patient B posted the same UUID as canceled; A's row became `canceled_false_alarm`.

**Improve:** enforce ownership in every mutation and read, reject foreign-owned IDs, and preferably use composite `(patient_id, event_uuid)` identity with matching foreign keys. For public signed webhooks, resolve the tenant through a stored provider attempt and validate the callback SID. Add adversarial two-patient tests, including cancellations and retries.

### 4. P0 — Restart recovery misses key fall states

Evidence: `backend/app/services/fall_escalation.py:119–149,167–205,464–488`, `ios/CadenceCompanion/DSP/FallDetector.swift:175–206`, `ios/CadenceCompanion/Emergency/FallAlertCoordinator.swift:195–239`.

The backend commits `escalated_twilio` before contacting Twilio, then writes the alert audit afterward. A crash in that gap leaves an escalated row without the audit row required by the recovery JOIN. A crash after provider acceptance but before recording the SID also leaves an ambiguous outcome. Pending check-in candidates have no durable timeout recovery if the phone dies or is killed before posting the outcome.

**Improve:** persist the fall transition, check-in deadline, dispatch job, and attempt identity transactionally. Recover all nonterminal states using durable deadlines and expiring worker leases. Reconcile ambiguous external results rather than assuming either delivery or failure. Add crash injection before and after every commit and provider call. A SQLite outbox is sufficient for the demo; a new broker is unnecessary at this stage.

### 5. P1 — Caregiver routing is global despite patient-scoped accounts

Evidence: `backend/app/services/fall_escalation.py:141,228–244,422–425`, `ios/CadenceCompanion/App/AppSettings.swift:168–176`.

Every patient's automated alert uses the same environment-configured caregiver numbers. The caregiver entered in the phone only sets the local dialer button; it does not configure backend dispatch. Configuring a caregiver in the UI therefore does not establish where automated alerts go.

**Improve:** either explicitly enforce a single-patient deployment, or create patient-scoped verified contacts, channel preferences, and contact snapshots on each dispatch attempt. Show remote escalation readiness separately from the local phone number. Test that two patients route to different contacts.

### 6. P1 — The offline queue is neither tenant-bound nor serialized across drains

Evidence: `ios/CadenceCompanion/Sync/EventSyncManager.swift:96–103,157–177,193–211,281–309`, `ios/CadenceCompanion/App/AuthSession.swift:50–70`.

Queue rows contain no account/patient identity and each send uses the current global bearer token. Signing out of A and into B can upload A's pending data under B. Multiple save-triggered drains and the periodic drain can read the same rows concurrently. Since candidate and final fall states replace the same local row, an in-flight candidate response can mark a newer replacement synced. Events are FIFO, so urgent falls also wait behind older telemetry and per-request timeouts.

**Improve:** bind rows to a stable account/tenant and destination, implement a single drain actor, and acknowledge only the exact payload revision that was sent. Use append-only event transitions or versioned rows. Prioritize fall outcomes/cancellations, surface persistence failures, and keep permanently rejected records in a visible dead-letter state rather than calling them delivered.

### 7. P1 — The app claims caregiver contact before any network acknowledgment

Evidence: `ios/CadenceCompanion/App/CadenceAppModel.swift:174–186`, `ios/CadenceCompanion/Emergency/FallAlertCoordinator.swift:277–286`, `ios/CadenceCompanion/Diary/DiaryStore.swift:36–37,110–113`.

`confirmed_waiting_dispatch` immediately records “Your caregiver was contacted” and the diary later says help was contacted. This happens even in airplane mode. The local `.dispatched` phase means a siren is sounding and an event was queued, not that anyone was contacted.

**Improve:** model queued, sent, provider accepted, and acknowledged separately. Record a factual “Alert saved; trying to contact caregiver” until there is evidence for a stronger statement. Feed server status back into both the SOS screen and diary.

### 8. P1 — Dual speech listeners cancel on the first affirmative result

Evidence: `ios/CadenceCompanion/Audio/SpeechCheckInListener.swift:125–129,242–259`, `ios/CadenceCompanion/Emergency/FallAlertCoordinator.swift:240–254`.

Either recognizer can immediately cancel the check-in. A local affirmative stops the cloud listener before a contradictory distress result can arrive; an interim affirmative can also arrive before the wearer finishes speaking. This does not implement the plan's distress-wins arbitration across both sources. `normalizeTranscript` also does not normalize “OK” into “okay”.

**Improve:** one coordinator should own source results, finality, and bounded arbitration. Any distress dominates; a single provisional affirmative cannot terminate listening. Explicitly define the unavailable-cloud case. Test contradictory results in both arrival orders and “I'm okay … but I can't get up”.

### 9. P1 — Missing exam measurements are still submitted as real numbers

Evidence: `ios/CadenceCompanion/DSP/HomeMotorExamManager.swift:12–31,175–195,217–229`.

The local UI correctly tracks `voiceMeasured`, `handwritingMeasured`, and `walkMeasured`, but the API payload ignores them and always sends numeric defaults or previous values. Starting an exam resets flags, not the measurements. A skipped or failed step can therefore contribute stale or invented data to the backend composite and report.

**Improve:** reset the full measurement object for a real new exam and put validity/completeness in the shared API schema. Send null for unmeasured values and do not calculate a full composite from incomplete tasks. Validate recording duration and usable signal, rather than treating nonzero stability as the proof a voice sample exists.

### 10. P1 — The “24-hour” report is stale, truncated, and assumes observations

Evidence: `backend/app/services/diary_engine.py:119–145,193–235`, `backend/app/main.py:596–678`.

The report anchors itself on the latest event, not now, and returns between 8 and 48 buckets. An inactive device can show a historical day as the current report. Each event table is capped by a different row limit before aggregation, so active periods lose data. Empty buckets use healthy-looking default measurements and become ON after a logged dose; `NO_DOSE` also conflates no log with no medication. Headline event counts cover retained rows while dose count uses the actual last day. Pending fall candidates count as falls. Within a bucket, newest-first exams are selected with `[-1]`, choosing the oldest exam.

**Reproduced:** a lone dose five days ago generated a report still ending five days ago, with 12.5% ON despite no motor observations.

**Improve:** expose explicit start/end/timezone and data freshness; use time-bounded SQL queries for all counts and buckets. Include an UNKNOWN/no-observation state and coverage denominator. Keep medication log status separate from motor state. Aggregate complete data, paginate detailed lists independently, and select the newest exam by parsed timestamp. Add historical mode explicitly for demos.

### 11. P1 — The clinician dashboard renders stored query text as HTML

Evidence: `backend/app/static/neurologist_dashboard.html:412–414`, `backend/app/main.py:354–384`.

`user_query` is persisted and later interpolated into `innerHTML` without escaping. An authenticated writer can store markup that executes when the associated clinician opens the report. The clinician's bearer token is available in that page's `sessionStorage`.

**Improve:** render untrusted strings through `textContent` or framework-escaped text nodes, including all other string fields used in HTML interpolation. Add a content security policy as defense in depth. Test with harmless markup sent through the real ingestion/report path. This is a confirmed source-to-sink code path; browser exploitation was not attempted.

### 12. P1 — Retention can prevent the backend from starting

Evidence: `backend/app/db.py:408–424`, `backend/app/main.py:67–72`.

The purge deletes canceled fall parents after 30 days while caregiver child rows remain for 365 days. With foreign keys enabled, a previously dispatched and then canceled fall triggers an integrity error. Purge runs before startup yields, so that routine condition can block service startup. There is also no daily purge scheduler, and confirmed fall parents are never deleted at the incident cutoff.

**Reproduced:** a 31-day-old canceled fall with an audit child caused `IntegrityError: FOREIGN KEY constraint failed`.

**Improve:** make parent/child retention one transactionally consistent policy. Retain the parent while audit children are retained, or delete both at the appropriate incident deadline. Schedule retention independently and make maintenance failure observable without taking the ingestion service down.

### 13. P1 — Medication Undo does not undo an already uploaded dose

Evidence: `ios/CadenceCompanion/Medication/DoseLogModel.swift:63–71`, `ios/CadenceCompanion/Sync/EventSyncManager.swift:315–330`.

Undo removes local diary history and withdraws only unsynced queue rows. If upload already completed or is in flight, the backend keeps the dose while the phone says it was undone. Backend timing calculations can then use a dose the wearer explicitly corrected.

**Improve:** represent corrections as durable, idempotent retraction events referencing the original dose ID. Derive dose history from effective, nonretracted events on both sides. Test undo before, during, and after delivery.

### 14. P1 — Empty segmentation is treated as proof a room is safe

Evidence: `backend/app/services/reality_check.py:53–67,119–151`, `ios/CadenceCompanion/Views/RealityCheckView.swift:81–83`.

A successful provider response with no accepted living masks produces “Everything looks clear and safe. No one is in that area.” Detecting an object also leads to categorical absence claims. Confidence/area filtering does not prove absence, full-room coverage, or safety. The provider-success flag named `sam_verified` overstates what was verified.

**Improve:** report bounded observations, such as “I can see a coat rack in this photo; I can't confirm whether someone else is there.” Use an uncertain result for empty, low-quality, partial, or unsupported scenes. Keep positive label allowlists, which are a good defense against model-generated advice, but separate grounding from confidence and scene coverage.

### 15. P1 — Early fall resolution can disable later fall detection

Evidence: `ios/CadenceCompanion/DSP/FallDetector.swift:202–222,244`, `ios/CadenceCompanion/Emergency/FallAlertCoordinator.swift:240–254,349–396`.

After Stage 3, the detector ignores subsequent samples until `evaluateCheckInOutcome` returns it to monitoring. The timer's resolution path calls that method, but button cancellation and early speech callbacks bypass it. `standDown` resets UI/audio state without resetting the detector, so future falls can be ignored. The existing second-fall regression waits for timer expiry first, exercising the path that already resets correctly.

**Improve:** give the coordinator an explicit detector lifecycle transition for every terminal check-in route. Test two sensor-driven falls with the first resolved by button cancel, early affirmative, and early distress, without waiting for timer expiry. Include this finding in the first delivery-and-isolation work phase below.

## Architecture improvements

### Preserve the current deployment shape

Keep one FastAPI application and the edge/cloud split. Domain modules already provide useful seams. Split `main.py` into thin routers for auth, telemetry, falls, exams, and reports when touching those areas, rather than undertaking a rewrite. SQLite remains reasonable for a single-instance demonstration; durability and transaction semantics matter sooner than a database migration.

### Add explicit boundaries and one event contract

Recommended flow: motion adapter → pure detector → typed event → local tenant-bound outbox → ingestion transaction → durable caregiver dispatch job → provider attempt → signed callback → observable status.

The detector currently writes through `EventSyncManager.shared` and speaks through `AudioCueEngine.shared`. Move those side effects behind injected interfaces, preferably returning a detector event to a coordinator. This makes crash behavior and hardware-free tests tractable. Apply the same idea to DSP and exam measurement validity; avoid untyped `[String: Any]` payloads as the long-term contract.

Generate or validate Swift request/response types against FastAPI's OpenAPI schema. Add contract fixtures for acknowledgments, incomplete measurements, correction events, and status transitions. Version detector/scorer configuration and record source device, placement, sample rate, and capture quality with each measurement so later reports remain interpretable.

### Give audio one owner and expose actual protection health

Several components configure audio sessions and use different audio engines. No interruption/route-change recovery observer was found. The silent keepalive sets `isActive` after a `try? engine.start()` even if startup failed; sensor-start flags likewise do not prove samples keep arriving. Own session routing, input/output, cue preemption, interruptions, and recovery centrally, and add sample-heartbeat health rather than reporting protection solely from startup flags.

Apple documents that interruptions deactivate audio sessions and require handling: [Handling audio interruptions](https://developer.apple.com/documentation/AVFAudio/handling-audio-interruptions). Physical-device locked-screen, call interruption, Bluetooth disconnect, and reconnect drills are release gates. Treat force-killed operation as unavailable and communicate that explicitly.

### Make latency limits enforceable

`RequestDeadlineContext` calculates a remaining budget, but provider calls pass it into HTTPX timeouts without an outer wall-clock cancellation scope. HTTPX separates connect/read/write/pool timeouts, and read timeout is per received chunk, so this does not establish the advertised hard four-second request deadline. See [HTTPX timeout semantics](https://www.python-httpx.org/advanced/timeouts/).

Wrap the entire interactive pipeline in an outer `asyncio.timeout`, use shared managed HTTP clients for pooling, and retain stage budgets inside it. Cache or precompute report narratives; dashboard availability should not depend on an LLM on every GET. Move CPU-bound image processing off the event loop and bound decoded dimensions, request sizes, and concurrency.

### Strengthen data and deployment discipline

- Normalize API timestamps to timezone-aware UTC values, validate finite numeric values and coordinate ranges, and reject impossible/far-future timestamps. Current timestamp strings can sort inconsistently and can move report anchors.
- Add schema migrations. `CREATE TABLE IF NOT EXISTS` does not upgrade an existing deployment after a column changes.
- Add CI for Python tests, Swift package tests with fake audio, and an iOS Simulator build of the Xcode app target including DAT. No tracked CI workflow was found. Pin reproducible backend dependencies instead of relying only on broad minimum versions.
- Add structured event/attempt correlation IDs and metrics for oldest unsynced fall, failed queue persistence, dispatch latency, pending candidates, overdue dispatch leases, failed callbacks, and sensor heartbeat gaps. Keep sensitive payloads out of diagnostic logs.
- Establish a complete local-data lifecycle: synced queue rows currently accumulate, while diary, task history, and photos have separate stores. A server wipe alone must not be described as erasing every local copy or preventing pending data from reappearing.
- Before expanding beyond one wearer, add revocable device credentials/refresh, patient-specific contacts, and tenant-bound local storage. Thirty-day self-contained device tokens currently have no account revocation lookup.

## Implementation plan review

The plan is useful as a requirements archive but no longer a reliable execution board. It mixes future tasks, embedded example code, superseded choices, and completed implementation. The prior architecture review has grown to 1,026 lines and includes historical verdicts/test counts that are no longer current. Keep that history, but label it and create one concise current status record.

Specific drift:

- The plan and diagram still specify a 12-second check-in; runtime is 30 seconds. The Info.plist usage description and detector comments retain 12 seconds.
- The plan says Fireworks was cut; current code and README actively include it.
- Authentication documentation describes shared role tokens while account login now issues JWTs.
- The plan promises startup and daily retention; only startup exists, with the foreign-key issue above.
- SAM handwriting refinement appears in architecture diagrams, but the handwriting endpoint runs OpenCV and only accepts simulated refinement values; no live refinement call occurs there.
- “Under 50 ms” refers to DSP work, not full freeze-onset-to-cue latency. Current code uses a spectral history window and consecutive 0.5-second hops. Publish measured onset-to-cue latency separately from transform execution time.
- The schedule reserves hardware verification for Day 2 and failure drills for Day 7, but hardware and delivery contracts are prerequisites for confidence in every dependent feature. The plan needs recorded evidence, not assumed completion from dates.
- README test counts of 56 backend and 158 Swift are not current verification results. Update from CI output, and distinguish package compilation from device validation.

### Suggested remaining sequence

The following technical sequence remains useful, but the hackathon gates in the new section below precede feature expansion and determine submission scope.

1. **Delivery and isolation first.** Close findings 1–8: explicit production transport, ownership-scoped SQL, durable dispatch responsibility, crash recovery, patient contacts, versioned local queue, factual UI, and speech arbitration. Exit criterion: complete a mocked fault matrix plus a separately authorized real-phone delivery drill with documented provider SIDs and caregiver acknowledgment.
2. **Data truth next.** Close findings 9–14: incomplete measurements, current time-bounded reports with UNKNOWN coverage, safe dashboard rendering, retention, dose retractions, and uncertain visual responses. Exit criterion: deterministic regression cases for each issue and agreement between local diary and backend report.
3. **Hardware integration gates.** Build the actual iOS app target; record live IMU frequency, timestamps, coordinate conventions, capture quality, audio routing and background behavior. Test locked screen, permissions denied, interruption, disconnect/reconnect, and process relaunch. Capture which source is active and when protection is degraded.
4. **Reproducibility and demo freeze.** Add CI and lockfiles, refresh diagrams/README from implemented behavior, and script a repeatable synthetic demonstration isolated from real transports. Freeze feature additions while these gates are open. Keep meal estimation, passive monitoring, extra providers, and visual polish secondary.

For each task, record one owner, dependencies, acceptance tests, evidence location, and an explicit status: planned / implemented / verified with mocks / verified on device / verified with provider. Do not infer those statuses from test count or calendar date.

## Recommended first three changes

1. Resolve the guide's medical-advice/nutrition anti-project risk and choose a focused, evidenced Meta-model demonstration.
2. Establish durable, tenant-scoped ownership of caregiver dispatch, with production simulation forbidden, and fix detector rearming.
3. Make measurement validity and report coverage explicit, then put the app target and failure-path contracts into CI. Track submission evidence alongside engineering work.

## Hackathon brief: requirements, architecture fit, and submission plan

### Source and confidence

Source: [Details – Meta Global AI Developer Hackathon – Cerebral Valley.pdf](./Details%20%E2%80%93%20Meta%20Global%20AI%20Developer%20Hackathon%20%E2%80%93%20Cerebral%20Valley.pdf), 12 pages, printed October 28, 2026 at 3:12 PM. All pages were text-extracted; key rules, submission, rubric, and bonus-prize pages were rendered for visual inspection. Some table descriptions/rightmost columns are clipped in the supplied PDF, including portions of pages 9–12. The category weights and open-weight bonus model names are readable; missing text has not been reconstructed.

This section evaluates the supplied snapshot, not subsequent website or Discord updates. A requirement is attributed to its PDF page; recommendations and eligibility judgments are explicitly distinguished from organizer rules.

### H1. P0 submission risk — Clinical and nutrition positioning conflicts with the anti-project guidance

**Guide evidence, page 5:** the examples to avoid include projects using AI to generate and give medical advice, AI nutrition coaches, and simple image analyzers. Page 4 also reserves disqualification for policy violations. The guide does not explicitly name Parkinson's companions or prohibit every accessibility application.

**Project evidence:** README and implementation-plan language describe a clinical companion, medication absorption conflict analysis, ON/OFF classification, symptom burden, motor scores, and a neurologist report. The meal pipeline estimates protein and evaluates dose proximity. The reality-check UI says it tells the user what is really present, while templates can assert safety. These are more consequential than a generic accessibility utility.

**Assessment:** this is a substantial eligibility risk, not proof of disqualification. Deterministic scoring, generic wellness disclaimers, or changing visible labels do not settle whether the submitted functionality fits the organizer's examples. Plain-language output guards already in the implementation are helpful, but do not by themselves resolve the underlying scope.

**Recommended action:** request an organizer determination through the guide's questions/office-hours channels using the actual outputs and workflows, especially dose/protein warnings and medication-state scoring. Suggested question: “Does an accessibility companion offering user-triggered scene descriptions, prescribed-schedule reminders, raw measurement logging, and caregiver contact fit the rules if it provides no diagnostic or medication advice? Are our proposed motor-state labels and meal/dose conflict outputs excluded?” This review does not send that message or claim permission was obtained.

Meanwhile, independently prepare a narrower submission focused on voice-first accessibility, user-triggered bounded scene descriptions, factual logs, reminders of an existing prescribed schedule, and explicitly demonstrated caregiver contact. Remove advice-bearing and diagnostic/nutrition outputs from the submitted execution path unless clarified as acceptable. Describe actual limitations. This is a proposed scope reduction, not an assurance of eligibility, and requires behavior changes rather than a cosmetic rebrand. Retain truthful limitations for any motion cueing demonstrated.

### H2. The plan incorrectly attributes hardware claims to page 5

**Project evidence:** the opening IMPORTANT block of `docs/IMPLEMENTATION_PLAN.md` calls no-display/no-native-app glasses architecture a “Page 5 Hardware Constraint” from this handbook.

**Guide evidence:** page 5 covers anti-projects and Meta API credits. This PDF does not establish those hardware constraints or require a glasses implementation.

**Recommended action:** correct the source attribution in the next plan revision. Support hardware capabilities separately with the actual toolkit documentation and measured device evidence. Treat glasses as a product choice that strengthens the demo when working, rather than an organizer mandate. This review has not independently verified the toolkit claims.

### H3. Meta-model use is an eligibility gate; extra providers are not

**Guide evidence, pages 1 and 8:** the project must incorporate Meta models and fit a problem statement; Stage One is a pass/fail viability/theme/Meta-usage gate. Page 1 lists available model families, not a requirement to integrate every model. Nothing in this PDF requires glasses, all seven pipelines, all inference partners, custom training, or an LLM in the emergency path.

**Project fit:** “Build for Your World” is the clearest problem-statement fit: an accessibility workflow for a specific daily need. Choose Indie Developer or Startups separately; those are competition tracks, not the two problem statements. The appropriate competition track depends on the entrant's status and is not established by the repository.

**Architecture implication:** preserve deterministic local cueing and fall logic. Prove substantive live Meta use in the bounded scene-description workflow (camera → SAM labels → constrained response), optionally paired with Muse transcription. Save sanitized request metadata, exact model IDs, timings, and examples showing how the model affects behavior. Configured adapters and simulated masks are not evidence that live integration works.

**Bonus-prize distinction, page 11:** the $10,000 open-weight award names Muse Glimmer or Muse Spark Open, served locally or through partners. Generic Llama integration does not by itself establish fit for this named award. The guide's Baseten instruction on page 7 specifies `meta-models/muse-spark-open-1026`, matching the project's configured default; live execution is still unverified. Inspection of `baseten_llm.py` during this follow-up shows its day-summary function is deterministic; only the scene-label selection method makes a Baseten request. Do not describe the deterministic summary as demonstrated Muse reasoning. Fireworks' existing Llama models may serve other purposes, but expanding providers solely to chase this bonus is lower priority than a working eligible core.

The agentic bonus describes meaningful tasks/decisions/multistep workflows. An FSM plus an API call is not sufficient evidence for winning it. Show actual model-grounded workflow behavior if pursuing it; do not give an LLM control over emergency decisions to strengthen a prize claim. The guide does not require targeting any bonus award.

### H4. Use the published rubric to reduce demo scope

**Guide evidence, page 9:** Impact 30%; Use of Meta AI Tooling 25%; Technical Depth & Execution 20%; Demo 25%. Scored submissions are rated on a 0–10 scale, and the top five per competition track advance to final judging using the same rubric. No score for Cadence is assigned here because live behavior and user impact evidence remain incomplete.

**Impact:** explain one concrete user's problem and one observable improvement, such as completing a hands-free task. Use consented user feedback or clearly labeled example scenarios. Do not substitute unvalidated clinical outcomes for evidence of usefulness.

**Meta tooling:** visibly demonstrate why Meta's models matter. Show a real input, the grounded label set, the constrained result, and an uncertainty/failure case. That is stronger evidence than listing model/provider names or displaying stored fixtures as live inference.

**Execution:** show the edge/cloud split, honest dispatch states, latency, and one failure recovery. Fix the highest-risk defects that affect the demo; defer platform rewrites and extra provider integrations.

**Demo:** one complete working journey is easier to judge than a tour of seven partly verified pipelines. Suggested three-minute allocation: 0:00–0:25 user need and scope; 0:25–1:35 live camera/voice → Meta inference → bounded spoken result; 1:35–2:15 one labeled caregiver/offline-recovery demonstration; 2:15–2:45 factual diary and architecture explanation; 2:45–3:00 original contribution and limitations. This is an editorial recommendation, not an organizer-specified video structure. If the physical glasses path is unready, label the phone fallback visibly and explain it rather than implying glasses validation.

### H5. Submission readiness requires artifacts and provenance

**Guide evidence, pages 4 and 8:** the repository must be public; the video must be accessible and three minutes long; the demo must identify functionality built during the event; all contributors must be listed; teams have up to four members and appoint one representative; each team/startup submits one project. Judges use the video, code, and live product. Late submissions are not considered.

**Evidence still needed:** confirm public access in a signed-out browser, clean-clone setup, accessible video and any required live link, entrant track, contributor list, representative, third-party code/data/asset rights, and explicit attribution of original work. The configured Git remote is `https://github.com/theloopsmith/Cadence.git`, but remote configuration does not establish public visibility. No repository publication or submission was performed by this review.

**Provenance ambiguity:** local Git history begins October 26 at 21:50 Pacific, after the page-3 October 26 kickoff but before the page-4 “Building period: Oct 27 – Nov 4” label. The PDF itself therefore leaves a start-boundary question. Preserve the real history and clarify that boundary with organizers; do not assert ineligibility or rewrite commit dates. Add an original-contributions section explaining the starting point, work done during the permitted period, libraries used, and synthetic/demo inputs. Commit timestamps alone do not establish when every line was written.

**Deadline stated by this snapshot:** November 4, 2026 at 9:00 PM EST, which is **6:00 PM Pacific**. Use an internal deadline of November 3 at 6:00 PM Pacific to leave recovery time. The guide identifies November 3 as the last full day for submission questions/troubleshooting. The internal buffer is a recommendation, not an organizer deadline.

### H6. Sponsor credits are conditional resources

**Guide evidence, pages 5–7:** Meta provides $150 per accepted participant with an individual claim process; a payment method is required and the guide describes a spend-limit notification. Partner credits are discretionary. Baseten's $100 and 2M TPM are application/selection-dependent; Modal's $100 has a participant cap; Fireworks' $100 is offered to selected teams. These are not guaranteed project budgets.

**Recommended action:** track actual approvals, balances, exact model availability, measured per-demo cost, and fallback behavior. Separate a notification threshold from an enforced spending cap. Avoid blocking the submission on unused sponsor credits or training integrations. Credit claims and account changes remain user actions; none were made here.

### Revised hackathon delivery gates

1. **Scope and eligibility:** document the page-5 issue; prepare the narrower behavior and organizer question; record the chosen competition track and permitted-work provenance. Do not assume a disclaimer resolves the risk.
2. **Prove one live Meta workflow:** real capture/transcription or segmentation, bounded output, explicit uncertainty, measured latency, and sanitized evidence. Prioritize this before expanding deterministic features, because Meta use is part of Stage One and worth 25% of Stage Two.
3. **Stabilize what the demo promises:** close delivery/identity/rearming bugs, truthful contact status, incomplete measurements, report coverage, and unsafe scene claims in the submitted scope. Verify actual hardware or explicitly show the fallback. Keep the existing technical review as the defect backlog.
4. **Package by the internal buffer:** public-access and rights checks, original-contribution notes, reproducible setup, contributor/representative details, a three-minute accessible video, and required live-product information. Submit through CV by the snapshot's November 4, 6:00 PM Pacific deadline.

Acceptance evidence should say “verified with mock”, “verified on phone/glasses”, or “verified with provider” separately. Simulations are useful for fault demonstrations when labeled, but must not stand in for the working Meta-model demonstration or a real delivery claim.
