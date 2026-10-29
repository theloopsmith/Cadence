# Phase 0 and 1: Accessibility scope and emergency integrity

These phase names refer to the first two workstreams agreed in chat: the pasted plan calls them Phase 1 (positioning) and Phase 2 (emergency/sensor safety). The default product is an accessibility and daily-living companion. This document supersedes the historical clinical/nutrition specification for the submitted product.

## Phase 0: Product behavior and positioning

- README and entry-point copy describe accessibility, routine logging, and limited visual observations.
- `/api/v1/meals/log` saves a timestamp without requesting a camera or inference. The phone no longer transmits meal photos. The old meal-protein URL remains a compatibility alias; in the default mode it also only records the meal time.
- `ENABLE_RESEARCH_METRICS=false` is the default. The normal report, exam completion/history, and handwriting API omit interpreted health states and scores. Legacy wire names and database columns are retained to avoid a destructive migration. Experimental formulas still exist internally; setting the flag true exposes legacy research behavior and is outside the accessibility submission scope.
- Scene descriptions state which object can be identified in a photo and acknowledge that the whole scene cannot be verified. Empty segmentation cannot establish safety or absence.
- Historical plans are labeled as superseded; their page-5 hardware attribution is corrected. Separate toolkit/device evidence is still needed.

### Organizer clarification draft — not sent

> We are building Cadence for Build for Your World: a voice-first accessibility companion with rhythmic walking cues, suspected-fall check-ins and caregiver contact, user-requested bounded photo descriptions, reminders of a user's existing prescribed routine, and factual activity/meal-time logs. The submitted mode does not provide diagnosis, medication-state interpretation, nutrient estimates, or advice about medication or nutrition. It reports uncertainty and distinguishes queued alerts from provider acceptance and caregiver acknowledgment. Would this scope fit the event's anti-project guidance? The repository retains legacy experimental formulas behind a disabled-by-default research setting; should those be excluded from the public submission entirely?
>
> Our first commits were after the October 26 kickoff, while the PDF also labels the building period October 27–November 4. Could you confirm the permitted start boundary? We will identify original contributions and preserve the actual history.

Organizer approval has not been obtained. This scope change does not itself establish eligibility. Publication, credit claims, Discord posting, and submission were not performed.

## Phase 1: Emergency and sensor behavior

- Production cannot fabricate simulated Twilio dispatch or All-Clear success, even if demo mode is explicitly enabled. Missing transport configuration returns no provider IDs. The fall HTTP endpoint returns 503 for a failed or unconfirmed dispatch so the phone retains it for retry.
- Unsigned callbacks fail closed in production when no verification secret is available. Signed callbacks retain the existing validator.
- Fall mutations check ownership before updating another wearer's row or canceling an active task. SQL conflict updates and claims enforce wearer identity. Globally unique IDs remain for compatibility; a composite-key migration is deferred.
- Duplicate fall requests can acknowledge previously accepted provider work without placing another call. Provider acceptance is not caregiver acknowledgment or proof of delivery.
- The phone checks the fall response body, retries malformed/unconfirmed fall responses, prioritizes fall queue rows, prevents overlapping drains, and only acknowledges the exact payload revision sent.
- SOS/diary wording describes saved/requested alerts and contact attempts, including an offline/retry explanation. It does not claim that a caregiver has already received a request.
- Button cancellation resets the detector immediately. The active alert retains ownership until it is resolved.
- Spoken affirmatives remain provisional until the full check-in window ends. Distress from either live recognizer escalates immediately and is latched; cancellation requires local affirmation and no contradictory cloud result (or cloud absence). The manual cancel button remains immediate. The spelling “OK” is normalized to “okay”.

## Verification

Current verification is recorded in [RECOVERY_VERIFICATION.md](RECOVERY_VERIFICATION.md): **122 backend tests** and **237 Swift package tests** pass, and the actual iOS Simulator app builds and launches with the isolated mock kit. The earlier environment-blocked app build has been superseded by this successful build with Simulator access. Silent-audio unit tests and mock-kit launch evidence do not establish physical-device/audio behavior.

Backend tests cover missing production credentials (including an explicitly enabled demo flag), failed-dispatch HTTP semantics, cross-wearer mutations, closed production callbacks, timing-only meal logging without inference, default report output boundaries, and uncertain visual language. Existing legacy formula tests explicitly enable research metrics; default-mode boundary tests explicitly disable them.

Swift tests cover fall response acknowledgments, rearming before timer expiry, provisional affirmation followed by distress, meal requests without image data, and existing integration behavior. `CADENCE_TEST_SILENT_AUDIO=1` suppresses playback only inside XCTest, allowing logic tests to run on a host without usable Core Audio services. It is not used for device/audio verification, and has no effect in a normal app process.

## Remaining work and verification gates

Crash recovery, durable dispatch/check-in jobs, account-bound local queues, explicit persistence failures, and provider callback correlation are now implemented and covered by the recovery tests. See [RECOVERY_VERIFICATION.md](RECOVERY_VERIFICATION.md) for semantics, evidence, and limits.

Physical hardware remains unverified; the user selected mock-kit verification. The live caregiver drill is an explicit separate check and must be reported from its actual signed acknowledgment evidence, not from a configured provider key or a passing mock. Contacts remain single-wearer server configuration. The other Phase 3 review items remain separate work.
