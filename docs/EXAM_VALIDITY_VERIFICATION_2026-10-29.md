# Partial motor checks — October 29, 2026

## Completed

This closes item 4, incomplete exam measurements, from the current hackathon readiness review. The phone, API, stored records, dashboard, local trends and shared summary now distinguish an observed value from a task that was not measured.

- Each new check resets its entire measurement state, previous-result display and session identity. Only explicitly measured, finite values are sent. Invalid values become unavailable instead of breaking JSON serialization or entering trends.
- Each task carries `measured`, `skipped` or `unavailable` status. The backend additionally uses `legacy_unverified` when an older request/record provides no reliable validity information. Measurement source distinguishes device reports and simulated fixtures.
- Missing task values are nullable. A task marked measured must supply its required values; the API rejects nonfinite numbers. Explicitly measured zeros remain zeros: zero voice variance and zero observed walking cadence are different from no measurement.
- Partial checks cannot produce a composite score or exam medication-state classification. Legacy scoring runs only when research mode is explicitly enabled and every task is marked measured. Default accessibility mode no longer computes exam scores internally.
- Starting a second check cannot reuse the first check's numeric measurements. Stale photo responses, timers and network completions are fenced by session identity. A canceled demo cannot proceed to submit fixture measurements.
- All three tasks can be skipped. Unreadable photos and missing/invalid sensor streams remain unavailable. Walking requires at least three seconds, sixteen samples and a continuous finite, increasing stream; a gap over 0.5 seconds invalidates the recording. These are software capture checks, not validated clinical quality thresholds.
- Voice validity uses captured sample count rather than positive variance, so a genuinely flat recording is not rejected merely for having zero variance. Interruption handling from item 3 still invalidates interrupted recordings.
- A demo only marks tasks measured when it receives an explicit fixture. Fixtures are labeled simulated and rejected outside demo mode.
- API completion replays return the committed result rather than narrating a different replacement body. Another wearer's matching exam ID cannot expose the existing record.
- Local records contain nil for unmeasured values; diary wording, trends and PDF summaries retain that absence. Voice-only diary records now name the voice measurement. Phone-history write errors are surfaced, and completion copy uses the actual save outcome.
- Dashboard task cells and comparisons handle null safely, preserve genuine zeros and withhold comparisons when either check lacks a measurement. These task cells use text nodes. Other stored-HTML paths remain item 5's separate security work.

## Existing installations and deployment

`motor_exam_validity_v1` is an atomic, recorded SQLite migration. It rebuilds the old NOT NULL measurement columns as nullable columns and adds task validity/source. It preserves original IDs and raw historical values. Existing values are **not** assumed to be actual observations merely because the old schema required a number.

History/report projections withhold unverified legacy task numbers and regenerate their factual summary. The original stored data remains available for audit; this change does not guess or retroactively certify which historical defaults were real measurements. A repeated startup does not rebuild the migrated table again.

Deploy the **backend before the updated phone app**. The old backend cannot accept the new partial payload. The new backend accepts older queued requests but labels their task validity unverified and does not turn their defaults into measured results. Retake a task with the updated app to obtain a newly reported measurement; do not silently adopt old values.

## Verification

- **152 Python tests pass**, including new tests for missing required values, nullable partial results, real zeros, no default-mode scoring, legacy requests, idempotent completion, nonfinite rejection, simulated-source rejection, and an old-schema upgrade followed by a repeated startup and a new partial insert.
- **262 Swift tests pass** with the explicit XCTest silent-audio flag. New coverage includes a full check followed by a partial second check, offline payload/local-history agreement, flat voice capture, invalid numbers, unseeded demos, old network completion fencing, actual shared-PDF text, and interrupted/zero-step walk recordings.
- **Dashboard JavaScript rendering check passes**: executes the actual report renderer against DOM/fetch test doubles with nulls, zeros and inert markup in a task timestamp. Command: `node --test backend/tests/dashboard_exam_validity.test.cjs`. This verifies rendering logic, not browser layout.
- The actual **iOS Simulator app target builds successfully** with the updated task flow. `git diff --check` passes.

No app was launched, audio played, provider request sent or caregiver contacted for this task. Physical capture quality, clinical validity, hardware continuity, report time/coverage, broader account isolation, dose retraction, and remaining dashboard injection paths remain separate work. Prior dependency/toolchain warnings remain.
