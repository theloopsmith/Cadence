# Report accuracy verification — October 29, 2026

Review item 6 is implemented. Reports now distinguish recorded activity, unknown observation coverage, provider acceptance and caregiver acknowledgment.

## Behavior

- The backend reads one consistent SQLite snapshot and reports the exact trailing 24 hours, using the half-open UTC interval `[start, end)`. It anchors on generation time, even for inactive accounts. Stale, invalid and future timestamps do not enter the report. Offset timestamps normalize to UTC.
- Counts and the 48 timeline buckets include every matching row. Detail arrays contain at most 100 rows each; metadata explicitly identifies truncated arrays. The dashboard displays all supplied rows and discloses truncation. No additional six/four/five-row display caps remain.
- Metadata supplies interval, generation time and latest observation within that interval. Event logs cannot establish continuous monitoring. Empty buckets say “No observations”; a dose or scene log establishes a point observation, never a healthy period. Older responses without observation metadata remain conservative while still showing explicitly recorded pauses/falls/checks.
- Report narratives use deterministic facts. Walking-pause records no longer assert that audio played. Pending, canceled and suppressed candidates do not inflate the fall-alert count. Other logged observations are not described as an empty day.
- Report rows and the delivery endpoint use the same incident-bound projection. A real provider SID establishes acceptance, not receipt. A correlated real call acknowledgment establishes acknowledgment. Simulated attempts/SIDs establish neither. A legacy SID never establishes human acknowledgment. Mixed simulated and real attempt history preserves each fact separately.
- The phone polls delivery evidence for its active incident. Responses must match the incident, captured token and normalized backend destination. SOS wording and accessibility text reflect verified status. Repeated observations do not inflate local acceptance/acknowledgment counts. Sample data cannot seed either delivery fact.
- Shared phone summaries label locally queued alerts “Alerts requested.” Historical `helpSent` details that claimed contact render as unverified requests in the diary and PDF; raw stored text remains intact. Future local events and measurements are excluded. Local exports explicitly use phone logs and calendar-day ranges through the displayed cutoff/time zone; server reports use a rolling UTC window. These are separate sources, not reconciled copies.

## Verification

- Backend: **161 tests pass**. New checks cover microsecond boundaries, time-zone offsets, stale/future/invalid timestamps, owner isolation, empty/dose-only periods, 130-row totals versus 100-row detail lists, and agreement between report and delivery evidence for queued, accepted, acknowledged, simulated, pending and canceled incidents.
- Swift: **267 tests pass**, with `CADENCE_TEST_SILENT_AUDIO=1`. Regressions cover incident matching, acceptance versus acknowledgment, simulated evidence, stale status, session rejection, normalized destinations, local fact deduplication, unknown coverage, future records and legacy contact wording in extracted PDF text.
- Dashboard: **five JavaScript checks pass**, including freshness, coverage, truncation and contact-state rendering. An isolated headless Chrome check passes stored-markup and CSP enforcement with zero unexpected network requests.
- Actual iOS simulator app target compiles successfully with signing disabled. The app was not launched; no test audio played. No live SMS/call was sent.

## Limits and rollout

Deploy the backend, dashboard asset/HTML and phone together for the new evidence presentation. Older servers supply no verified delivery state, so the phone retains an unverified state.

This does not verify physical-device routes, background continuity or actual caregiver receipt. Live caregiver configuration and signed DTMF evidence remain item 7. Phone delivery polling currently follows the active incident; it is not historical reconciliation after relaunch. Local diary/account separation, local write-failure handling and coordinated deletion remain item 8. Shared-PDF delivery counts reflect facts observed and stored by that phone; the backend is the durable audit source.
