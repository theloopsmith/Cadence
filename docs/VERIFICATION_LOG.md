# Verification and acceptance

This is the current evidence index. The [earlier implementation diary](https://github.com/theloopsmith/Cadence/blob/a4bd5f1/docs/VERIFICATION_LOG.md) and superseded screenshots remain in Git history; they are not current acceptance results. Provider traces below contain no credentials or media. Private input photos are not published.

**Evidence grades:** automated/mocked checks verify code behavior; live checks verify a provider or deployment answered; physical-device acceptance verifies the actual iPhone/glasses journey. None establishes clinical validity.

## Current verified behavior

- Local and hosted CI checks cover backend contracts, durable alert recovery, account-bound queues, erase generations, dose retractions, task validity, voice routing reducers, silent web playback, browser security and iOS compilation with the pinned DAT SDK. The [CI workflow](../.github/workflows/ci.yml) is the reproducible source; test counts are snapshots, not hardware proof.
- [Published hardening CI](https://github.com/theloopsmith/Cadence/actions/runs/41367894618) passed all three jobs at `a4bd5f1`: backend/dashboard, Swift package and iOS app compilation. That pass contained 247 backend tests and 29 JavaScript checks. Later work is recorded below and validated on its own revision.
- Cloud deployment checks passed HTTPS, anonymous/static-token rejection, read-only role enforcement, stable server identity, and saved synthetic records/pre-restart JWTs surviving restart. A prior reader JWT expired at its normal 12-hour boundary; a fresh baseline was used for the restart check. No account or database reset was used to hide a failure.
- Motor rows pair task status with source. The dashboard's table, serial comparison and narrative identify simulated samples; device source is client-reported, not hardware attestation. [Source-column screenshot](verification/dashboard-source-2026-11-01.png).
- Production and public-demo startup reject enabled research metrics. Typed report/history/photo responses and nested projection keep legacy health scores, medication-state labels and nutrition outputs out of default reports. Meal logging records time only.
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
6. Finish the accessible demo video, contributor/representative declaration, asset-rights confirmation and original-contribution statement. Retire the public judging accounts and invalidate tokens afterward; automatic account expiry is not configured.

## Scope and positioning (Oct 29)

Cadence is an accessibility/daily-living prototype: rhythmic cues, possible-fall check-ins, bounded photo observations, reminders of an existing prescribed plan and factual timestamps/task measurements. It provides no diagnosis, nutrition coaching or medication-state inference in submitted mode. The presence of legacy research columns/formulas is not evidence that they are exposed or validated. This boundary is not organizer approval.

### Organizer clarification draft (not sent)

> We are building Cadence for Build for Your World: a voice-first accessibility companion with rhythmic walking cues, suspected-fall check-ins and caregiver contact, user-requested bounded photo descriptions, reminders of a user's existing prescribed routine, and factual activity/meal-time logs. The submitted mode does not provide diagnosis, medication-state interpretation, nutrient estimates, or advice about medication or nutrition. It reports uncertainty and distinguishes queued alerts from provider acceptance and caregiver acknowledgment. Would this scope fit the event's anti-project guidance? The repository retains legacy experimental formulas behind a disabled-by-default research setting; should those be excluded from the public submission entirely?
>
> Our first commits were after the October 26 kickoff, while the PDF also labels the building period October 27–November 4. Could you confirm the permitted start boundary? We will identify original contributions and preserve the actual history.

Owner-supplied organizer clarification says every runtime model call must use a Meta model and built-in system speech output is allowed. No agent posted this draft to Discord or submitted an event entry.

## Repository and walkthrough maintenance

Reviewed the tracked components and each maintained guide. Runtime adapters, recovery/state code, tests, deployment scripts, rules snapshot and static-art provenance remain necessary. Legacy research code is retained behind the forbidden-in-public flag because destructive schema/API removal would be a separate migration. Superseded tour/native-launch screenshots and the redundant initial caregiver readiness-only record were removed from the working tree; their history remains in Git. The failed caregiver attempt and initial failed photo result remain available above.

The public README retains its original animated overview byte-for-byte and adds a source-checked implementation SVG. Detailed usage moved to the app guide; icon provenance was merged into the static-artwork guide; the doc index gives each retained guide a distinct purpose. Local setup now uses the same locked dependency manifest as CI/deployment; the redundant floating requirements list was removed.

The tour now orders motor check (01, 07:45), medication (02, 08:00), walking, surroundings and care. Playback and its virtual-time harness read HTML chapter order. Regressions verify first-click navigation, the complete motor-to-medication transition, numbering/time order and completion through the care view.

Cleanup validation: 248 backend tests, 30 silent JavaScript checks, source-checked diagram freshness, local Markdown links and diff whitespace checks passed. The first README GIF's bytes match the pre-cleanup revision. The new SVG was rasterized and visually checked for legibility/overflow. Live browser playback started at motor step 1/11 and advanced into medication step 1/5; skip/explore links target the motor scene. [Deployed motor-first view](verification/walkthrough-motor-first.png). Browser console had no warnings/errors. Post-restart cloud checks preserved HTTPS, role restrictions, original sandbox JWTs, server identity and saved synthetic records. This verification did not call a caregiver or send new media to an inference provider.
