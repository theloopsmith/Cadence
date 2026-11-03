# Verification and acceptance

This is the current evidence index. The [earlier implementation diary](https://github.com/theloopsmith/Cadence/blob/a4bd5f1/docs/VERIFICATION_LOG.md) and superseded screenshots remain in Git history; they are not current acceptance results. Provider traces below contain no credentials or media. Private input photos are not published.

**Evidence grades:** automated/mocked checks verify code behavior; live checks verify a provider or deployment answered; physical-device acceptance verifies the actual iPhone/glasses journey. None establishes clinical validity.

## Current verified behavior

- Local and hosted CI checks cover backend contracts, durable alert recovery, account-bound queues, erase generations, dose retractions, task validity, voice routing reducers, silent web playback, browser security and iOS compilation with the pinned DAT SDK. The [CI workflow](../.github/workflows/ci.yml) is the reproducible source; test counts are snapshots, not hardware proof.
- [Published hardening CI](https://github.com/theloopsmith/Cadence/actions/runs/41367894618) passed all three jobs at `a4bd5f1`: backend/dashboard, Swift package and iOS app compilation. That pass contained 247 backend tests and 29 JavaScript checks. Later work is recorded below and validated on its own revision.
- Cloud deployment checks passed HTTPS, anonymous/static-token rejection, read-only role enforcement, stable server identity, and saved synthetic records/pre-restart JWTs surviving restart. A prior reader JWT expired at its normal 12-hour boundary; a fresh baseline was used for the restart check. No account or database reset was used to hide a failure.
- Motor rows pair task status with source. The dashboard's table, serial comparison and narrative identify simulated samples; device source is client-reported, not hardware attestation. [Source-column screenshot](verification/dashboard-source-2026-11-01.png).
- Experimental scoring, medication-state/symptom classifiers, protein estimation and their feature flag have been removed. Typed outputs and unconditional projection exclude legacy stored findings. Meal logging records time only.
- Default/relative SQLite paths resolve under `backend/`. The inactive root duplicate was archived intact under ignored `.local/database-archive`; the backend database was preserved. Static tokens have no built-in runtime values; the LAN launcher uses account sign-in.
- Paid inference is limited per account across ordinary routes (30/minute); check-in transcription has its own allowance (60/minute). The limiter is atomic and bounded but process-local: restart resets it, and it is not a billing cap. Durable account login lockout is separate.

## Live model evidence

- **SAM protocol:** [synthetic concept/box check](verification/sam-live-2026-10-29.json), Meta `sam-3.1`. This verifies the API protocol, not a wearer scene.
- **Muse transcription:** [audio-to-text trace](verification/muse-transcribe-live-2026-10-29.json), `muse-voice-transcribe-1.0`, using synthesized test speech. No physical microphone/audio-route acceptance is implied.
- **Muse intent:** [live fixed-text interpretation](verification/muse-intent-live-2026-11-01.json), Baseten `meta-models/muse-spark-open-1026`.
- **iPhone image:** [full SAM + Muse result](verification/real-photo-meta-2026-11-01.json), lamp, 2854ms end to end. The [initial filtered result](verification/real-photo-meta-2026-11-01-initial.json) and [decoded SAM diagnostic](verification/sam-live-2026-11-01.json) show why the small explicitly requested object gate was fixed. The sandboxed HEIC conversion produced a black image and was discarded before upload; the successful full-frame conversion was orientation-corrected, resized and stripped of EXIF/location.
- **Exported glasses image:** [SAM + Muse result](verification/glasses-photo-meta-2026-11-01.json), sofa, 3353ms end to end. Owner report and source EXIF identify Meta Smart Glasses. The uploaded derivative was stripped of metadata. Exported-image analysis does not verify capture within Cadence DAT, a physical shutter event or audible glasses output.

Model success, unavailable stages and deterministic fallback have separate provenance. One successful photo is not an accuracy study or a safety guarantee. Hosting providers and model authorship remain distinct; spoken replies use installed OS/browser voices.

## Safety and persistence boundaries

Fall decisions remain deterministic. Distress from either recognizer latches; spoken affirmation remains provisional through the check-in window, and cloud-only affirmation cannot silently cancel a fall. A button cancellation is explicit. Walking audio and everyday conversation yield to the check-in.

The phone saves candidate events locally and binds its outbox to account, destination, revision and data generation. Persistence errors are visible; memory buffers are not durable storage. Server `fall_jobs`/`fall_attempts` support leased, at-least-once recovery and correlated signed callbacks. No server recovery is possible before upload. Provider acceptance does not establish receipt or human acknowledgment. A server wipe cannot unsend an external request already handed off.

**Real caregiver delivery remains unverified.** The authorized callback-only drill obtained public readiness but no SMS/call IDs: [attempt](verification/caregiver-live.json). [Provider preflight](verification/caregiver-provider-preflight.json) found a trial account without a ready owned sender and with an unverified recipient. These failure records are retained. The public demo deliberately contains no Twilio credentials and simulates transport.

[Isolated dashboard security evidence](verification/dashboard-browser-security-2026-10-29.json) records inert stored markup, working authorized controls, CSP rejection of injected code and zero unexpected requests. The hardening pass repeated the real-browser check successfully. Reports use consistent trailing-24-hour snapshots, unknown coverage and explicit detail truncation.

## Still required

1. Obtain organizer decisions on scope and the October 26/27 contribution boundary. Preserve actual history and identify event-built work.
2. Install the current iPhone build; check live DAT preview/capture/shutter, actual microphone/output routes, prompt timing, Stop, interruption, disconnect/reconnect and denied permissions. Simulator builds and exported-photo traces do not close this gate.
3. Verify locked-screen/background behavior before claiming continuity. Everyday conversation currently requires the foreground. Native Hey Meta invocation and conversational barge-in are not integrated.
4. Conduct a separately configured, consenting caregiver delivery/acknowledgment drill before claiming real delivery. Never induce a fall or provoke a freeze for testing.
5. Verify actual notification delivery, backup/restore, incident retention and physical signal thresholds. Current metrics/heuristics are not clinically calibrated.
6. Finish the accessible demo video and actual portal submission. Review the contributor, artwork and contribution declarations; organizer scope/media decisions and any required pre-event-work confirmation remain pending. Public judging accounts have a retirement cutoff of 2026-11-18 08:00 UTC; individual JWT expiration still applies.

## Scope and positioning (Oct 29)

Cadence is an accessibility/daily-living prototype: rhythmic cues, possible-fall check-ins, bounded photo observations, reminders of an existing prescribed plan and factual timestamps/task measurements. It provides no diagnosis, nutrition coaching or medication-state inference in submitted mode. The presence of legacy research columns/formulas is not evidence that they are exposed or validated. This boundary is not organizer approval.

### Organizer clarification draft (not sent)

> We are building Cadence for Build for Your World: a voice-first accessibility companion with rhythmic walking cues, suspected-fall check-ins and caregiver contact, user-requested bounded photo descriptions, reminders of a user's existing prescribed routine, and factual activity/meal-time logs. The submitted mode does not provide diagnosis, medication-state interpretation, nutrient estimates, or advice about medication or nutrition. It reports uncertainty and distinguishes queued alerts from provider acceptance and caregiver acknowledgment. Would this scope fit the event's anti-project guidance? The submission excludes experimental scoring and nutrition inference.
>
> Our first commits were after the October 26 kickoff, while the PDF also labels the building period October 27–November 4. Could you confirm the permitted start boundary? We will identify original contributions and preserve the actual history.

Owner-supplied organizer clarification says every runtime model call must use a Meta model and built-in system speech output is allowed. No agent posted this draft to Discord or submitted an event entry.

## Repository and walkthrough maintenance

Reviewed the tracked components and each maintained guide. Runtime adapters, recovery/state code, tests, deployment scripts, rules snapshot and static-art provenance remain necessary. Legacy research code is retained behind the forbidden-in-public flag because destructive schema/API removal would be a separate migration. Superseded tour/native-launch screenshots and the redundant initial caregiver readiness-only record were removed from the working tree; their history remains in Git. The failed caregiver attempt and initial failed photo result remain available above.

The public README retains its original animated overview byte-for-byte and adds a source-checked implementation SVG. Detailed usage moved to the app guide; icon provenance was merged into the static-artwork guide; the doc index gives each retained guide a distinct purpose. Local setup now uses the same locked dependency manifest as CI/deployment; the redundant floating requirements list was removed.

The tour now orders motor check (01, 07:45), medication (02, 08:00), walking, surroundings and care. Playback and its virtual-time harness read HTML chapter order. Regressions verify first-click navigation, the complete motor-to-medication transition, numbering/time order and completion through the care view.

Cleanup validation: 248 backend tests, 30 silent JavaScript checks, source-checked diagram freshness, local Markdown links and diff whitespace checks passed. The first README GIF's bytes match the pre-cleanup revision. The new SVG was rasterized and visually checked for legibility/overflow. Live browser playback started at motor step 1/11 and advanced into medication step 1/5; skip/explore links target the motor scene. [Deployed motor-first view](verification/walkthrough-motor-first.png). Browser console had no warnings/errors. Post-restart cloud checks preserved HTTPS, role restrictions, original sandbox JWTs, server identity and saved synthetic records. This verification did not call a caregiver or send new media to an inference provider.

## Surroundings, medication editor and meal diary repair

The iOS review found a general-scene search restricted to people/pets/chair/coat, misleading lighting advice for service failures, an eight-second phone timeout that included upload time, question replacement by a returning camera's “use it” transcript, and no same-photo clarification flow. General questions now use bounded Muse image search terms alongside initial living-subject SAM probes, followed by independent object grounding (at most six concepts). Named-object questions skip proposal. Partial evidence is retained without certifying the scene; unavailable inference and no supported match have different status and wording. General replies list up to three verified labels; iOS removes duplicate labels. Confirmed photos can be retried in memory with a clearer question. Dictation, permission callbacks and responses are fenced by operation/profile identity.

A live source-pipeline check on the already approved, metadata-stripped exported glasses image completed in 8721ms: Muse proposed sofa/pillow/shelf, SAM independently returned pillow/sofa masks, and Muse selected from accepted labels. [General-scene trace](verification/general-scene-meta-2026-11-01.json). The earlier three-second proposal cap discarded useful output; the old eight-second phone budget could expire before a valid response. Server budget is now 12 seconds, proposal at most seven seconds, and the iPhone photo request 20 seconds including network/upload; other request timeouts stay unchanged. The optional vision breaker is separate from ordinary text interpretation. Cancellation closes outstanding SAM workers. This is not physical DAT or audio acceptance.

Medication setup was rebuilt as a saved-routine summary plus one explicit edit session. There is one persistent Save routine action, a clear receipt, direct reminder time pickers, multiple-medication support and discard. Stable medication IDs bind staged photos to their draft; camera return does not reload it. Partial photo-save failures leave the editor open and distinguish already-saved times. Save/discard voice commands use an editing context rather than medication ingestion routing.

Meal diary now asks for an optional glasses/iPhone photo, reviews it, accepts a time/note, and gives a visible/spoken local-save receipt with separate sharing state. Photo and note stay in the account-bound profile; only the timestamp is queued. The local timeline displays the photo. No food/protein recognition, nutrition recommendation or medication-timing advice was introduced. Repeated saves cannot duplicate an entry; disk failures cannot become success receipts. A 30-day reconciliation repairs interrupted diary-to-outbox writes at the original account/destination/erase generation without resetting existing queue retry state. Signed-out entries remain local. Photo follow-up waits for camera dismissal.

The full suite also exposed a preexisting all-clear race: another recovery worker can own the job before cancellation returns. The integration test now observes durable completion with a bounded deadline. Cancellation reports only the current owner's incident-specific persisted count, never the global clear-sweep count for other incidents. Its regression uses mocks; no real caregiver was contacted.


Final verification for this repair: 260 backend tests, 425 silent Swift tests and 30 JavaScript checks passed; the iOS target compiled with the actual Meta DAT SDK. [Deployed authenticated photo check](verification/general-scene-http-2026-11-01.json) returned identified pillow/sofa observations for a general question in 10418ms end to end, using live Muse vision proposals and SAM; final slot wording used the explicitly recorded deterministic fallback. Existing sandbox tokens, identity, records and role restrictions survived deployment. Private photos were not committed and no real caregiver was contacted. The native UI changes require an updated iPhone installation; physical camera/audio and visual usability acceptance are still pending.

## Connection setup simplification

Settings now exposes Connection above voice controls. A fresh unbound installation stages the hosted sandbox address in the form, with a public-demo disclosure; existing profile destinations remain unchanged. One Connect and sign in action submits the entered origin directly and persists the accepted session. Mac discovery, same-server address repair and local reset remain in Advanced developer tools. The normal flow no longer requires a separate address-apply button, a dev token, or a localhost warning. Signed-in users see their account and saved origin. Different server/account bindings still block reassignment and explain the local reset and data consequences; no automatic erase or queue migration was added.

Sign-in rejects page paths and embedded credentials before any network request. Timeout, DNS, certificate, malformed-response and HTTP errors now have separate messages. Reset-pending sign-in explains that a full restart is required. Regression tests cover direct cloud sign-in from an unbound profile, invalid addresses without credential transmission, and differentiated failures. All 428 silent Swift tests passed; the iOS Simulator target built with Meta DAT, and documentation/diagram checks passed. Visual and physical-device acceptance remain pending; installing the updated app is required.

## Quiet companion and explicit listening

Continuous voice listening now requires opt-in. A one-time upgrade resets the older automatic preference to off, then preserves subsequent explicit choices. Today/shared voice controls offer Talk to Cadence and Pause listening; a session tap does not enable automatic listening on future opens. Stopping invalidates pending activation and releases the companion microphone without changing walking protection. Installed speech and task narration remain separate.

Unknown speech no longer causes repeated spoken menus. In an active task, free-form model interpretation requires addressing Cadence; ordinary task commands remain available. Two unknown turns pause quietly, with the count reset on task-step changes. General idle listening stops after 40 seconds; active task turns retain their window. Expired confirmations pause without speaking or executing the action, and late yes replies cannot revive them. No dedicated wake-word detection was added: recognized commands from nearby conversation remain a limitation.

All 430 silent Swift tests passed, including opt-in migration, quiet writing conversation, idle pause, confirmation expiry and existing photo/motor ownership cases. The native iOS Simulator target compiled with Meta DAT; documentation checks passed. Physical glasses audio and conversation-interruption acceptance remain pending on an updated device build.

## Removal of experimental research features

Removed the feature flag and all conditional research execution. Deleted the motor/composite scoring service and protein estimator, medication-state/symptom classifiers and dose-effect helper, research-only schemas, the meal-protein endpoint, nutrition rendering, and obsolete iOS decoding properties. The diary now builds factual 30-minute event buckets without clinical states, symptom scores, nutrient estimates or medication-response comparisons. Handwriting returns measured stroke-height change only. The seed logs a meal timestamp without food inference.

Old SQLite columns are retained solely for compatibility with installed databases; new observations do not populate scores/state/nutrition estimates. The old NOT NULL handwriting classification column receives an inert compatibility value, which is never exposed or interpreted. Unconditional projections exclude legacy findings from responses. An obsolete environment variable cannot restore removed code. Regression coverage checks route/schema absence, legacy-value projection and ordinary measurement/logging paths. Historical verification entries above describe earlier versions; this removal supersedes their flag-based boundary.

Local verification: 246 backend tests, 430 silent Swift tests and 30 JavaScript checks passed; the native iOS Simulator build with Meta DAT, generated-diagram freshness, documentation links and diff checks passed. Tests for deleted formulas were removed; task validity, legacy-data upgrades, permission boundaries, durable recovery and factual measurements remain tested. Physical-device acceptance is separate.

## Submission closeout — November 2

The prior review's 260-test count is historical; tests for removed experimental calculations were intentionally retired. This closeout passes 250 backend tests, 431 silent Swift tests and 31 JavaScript checks, plus native iOS compilation with Meta DAT, diagram freshness and documentation checks.

Removed the three shipped development-token literals: AppSettings, EventSyncManager and HomeMotorExamManager now default to no credential. Tests inject their own explicit fixture sessions; a regression checks production defaults remain empty. Only a non-authenticating hash is retained to recognize old profile partitions. Account-bound queues and JWT sign-in remain intact. Backend .env loading is anchored to backend/ and verified from a repository-root working directory.

The active database now removes retired research columns transactionally from motor, handwriting and meal tables; observation values, IDs, indexes, server identity and account data are preserved. This supersedes the earlier inert-column compatibility decision. The installer snapshots legacy SQLite data privately before this migration. Simulated task statuses now read simulated at every public status position, including TaskEvidence; device measurements retain measured. Dashboard cells and comparisons require matching task status/source evidence, with missing and contradictory evidence withheld.

The public sandbox judging accounts and all their JWTs expire at 2026-11-10 08:00 UTC (midnight Pacific, after the November 9 closing day). Tests cover cutoff enforcement for existing tokens and new login, with ordinary accounts unaffected. Only the primary HTTPS origin is advertised to judges; the unreliable IP-derived fallback was removed from instructions.

Harshal Vaidya confirmed sole human contribution and representative identity and confirmed both disputed scene assets were generated with ChatGPT. [Submission declarations](SUBMISSION_DECLARATIONS.md) record those confirmations and the actual first-commit timestamp, AI development assistance, asset terms and limits. The website discloses ChatGPT-generated scenes. Organizer permission for offline-generated media and any contribution-boundary interpretation remain pending; no approval or portal submission was invented. Physical DAT/audio/background/threshold and caregiver-delivery gates remain open and claims remain explicitly scoped.

[Live closeout evidence](verification/submission-closeout-2026-11-02.json): deployed schema metadata confirms zero retired fields across all three tables, valid foreign keys and a private pre-migration backup. HTTPS, original sandbox JWTs, role restrictions, server identity and the saved synthetic baseline survived deployment. A fresh live judge token is capped at the cutoff; the generated-scene disclosure appears in the served page. The isolated real-browser check passed with zero unexpected requests after its walking fixture was updated to carry TaskEvidence. Expiration rejection is verified locally at a past cutoff, not by disabling current judging access.

## Judging access extension — November 2

At the owner's request, the judging-account retirement cutoff is extended to **2026-11-18 08:00 UTC (November 18, 00:00 Pacific)**. Source defaults, generated deployment configuration and current public instructions use the same cutoff. Earlier evidence records retain their original dates. Existing JWTs retain their immutable signed exp claims and normal lifetimes; this change does not silently extend an already issued JWT. Sign in again for a fresh token under the extended policy.

## Speak-question dictation repair — November 2

The old button mixed the shared on-device transcript with rolling six-second Muse command windows; later chunks could overwrite the beginning of a free-form question. The question button now invokes a dedicated cumulative system-recognition mode with rolling cloud windows excluded. Ordinary companion command recognition and the fall listener retain their existing behavior. A route failure during dictation now stops with a retained draft instead of silently restarting with only the tail of the question. Recognition errors in the assistant error domain are surfaced rather than all being discarded as cancellations.

QuestionDictation waits for explicit permission, companion microphone teardown and the speech echo window. Preparing and Listening reflect different states. The typed question is retained until actual speech arrives. Done or four quiet seconds completes the editable draft; there is no automatic photo submission. Startup/no-speech failures are bounded and visible. Permission prompts do not count as background cancellation. Generation fences reject stale permissions and transcripts; camera, sign-in, leaving/backgrounding, reset and safety-check transitions stop dictation. Safety preemption and teardown are covered by mocked tests.

All 439 silent Swift tests passed, including eight dedicated dictation regressions. The native iOS Simulator target built with Meta DAT; documentation and whitespace checks passed. Physical glasses microphone quality and word-recognition acceptance remain pending on the updated app build. No backend deployment or real caregiver contact was needed for this native repair.


### November 2 — Photo response relevance and accuracy claims (review branch)

A reported repeated person reply exposed deterministic living-subject priority: any accepted person/dog/cat box suppressed object descriptions. Replies now include both object and living candidates for general questions and prioritize matching named objects. Unrelated detections cannot turn an unanswered named-object question into an identified result. Partial concept failures are spoken explicitly. Labels remain tentative even when SAM omits confidence. Public copy, app labels and architecture wording distinguish concept-search results from verified identity; the illustrated web reply no longer invents a spatial relationship.

This is a response-logic repair, not evidence of improved model recognition accuracy. No representative labeled-image benchmark has been run. The accepted area fraction is bounding-box area, not decoded foreground-mask coverage. Existing private-photo traces demonstrate API operation only. These changes have not been deployed; physical-device and new live-image acceptance remain open.

Validation for this repair: 255 backend tests, 21 walkthrough/architecture JavaScript checks and 12 Swift API/meal-flow tests passed. Documentation links, generated-diagram synchronization and whitespace checks passed. No new live image calls or physical-device checks were performed.


### November 2 — Short photo replies

Removed the repeated whole-scene disclaimer from successful spoken object labels. Replies retain tentative wording; a persistent result-card note explains fallibility and lack of safety verification. Incomplete checks, missing matches, unanswered presence questions and explicit safety questions keep contextual spoken limitations. This copy change does not establish recognition accuracy. Changes are local and not deployed.
