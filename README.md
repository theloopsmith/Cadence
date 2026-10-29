# Cadence — Daily Living & Accessibility Companion

Current priorities and submission gates: [October 29 hackathon readiness review](docs/HACKATHON_READINESS_REVIEW_2026-10-29.md).

Cadence is an audio-first accessibility companion for a paired iPhone and Meta AI glasses, built for the Meta Global AI Developer Hackathon's **Build for Your World** problem statement.

It supports rhythmic walking cues, suspected-fall check-ins, attempts to contact a configured caregiver, user-requested descriptions of objects in a photo, and routine logging. Scene descriptions are limited observations, not proof that a room is safe. A queued alert does not mean a caregiver has received it.

## Current product scope

- **Walking cues:** local motion processing and a rhythmic beat; phone motion is the fallback when glasses motion is unavailable. Detector thresholds are experimental, not validated measures of health.
- **Fall check-in:** a 30-second voice/button check-in. Distress escalates immediately; spoken affirmatives remain provisional through the window. Cancellation rearms sensing. Alerts are saved locally and retried when remote dispatch is unavailable. A caregiver response is separate from provider acceptance.
- **Describe surroundings:** on-demand camera input, Meta segmentation, constrained object descriptions, and explicit uncertainty. No diagnosis or categorical absence/safety claim.
- **Routine diary:** reminders of an existing prescribed schedule, factual activity/task measurements, and meal timestamps. Meal logging does not estimate nutrients or advise on medication absorption or timing.
- **Daily summary:** counts and raw measurements. Derived medication states, symptom scores, and nutrition/conflict outputs are excluded by default (`ENABLE_RESEARCH_METRICS=false`). Legacy experimental formulas and API identifiers remain for compatibility; the optional research mode is outside the accessibility submission scope.

This scope is a product boundary, not a statement of organizer approval. The supplied guide lists medical-advice and nutrition-coaching anti-project examples. An organizer clarification is drafted in [docs/PHASE_0_1.md](docs/PHASE_0_1.md); it has not been sent. No inference provider, physical hardware path, or real caregiver delivery should be described as verified solely because its configuration or mock tests work.

## Run and test

```bash
./scripts/run_demo.sh
# Open http://127.0.0.1:8000/dashboard
cd backend && .venv/bin/python -m pytest -q
cd .. && ./scripts/test_ios.sh
./scripts/run_ios_sim.sh
```

Configure backend provider credentials and caregiver contacts locally. Production never substitutes simulated Twilio success for missing credentials; the API returns a retryable failure. Local development/demo may use visibly simulated transports. Automated contacts are currently configured on the server for a single-wearer deployment; the phone's caregiver number configures its manual dialer and does not change server routing.

The repo is inside iCloud Drive; Swift scratch builds should live outside it to avoid code-signing metadata errors. The test script uses a cache directory for this purpose.

## Architecture and delivery status

Swift owns motion sensing, audio, check-ins, and an offline event queue. FastAPI owns authenticated storage and caregiver orchestration. Provider adapters isolate external inference and transport. Emergency decisions remain deterministic.

- [Current phase scope and verification](docs/PHASE_0_1.md)
- [Crash recovery, account binding, and verification evidence](docs/RECOVERY_VERIFICATION.md)
- [Project review and hackathon requirements](docs/PROJECT_REVIEW_2026-10-28.md)
- [Historical implementation specification](docs/IMPLEMENTATION_PLAN.md)
- [Historical high-level diagram](docs/cadence_high_level.drawio)
- [Historical detailed diagram](docs/cadence_detailed_architecture.drawio)

The historical specification/diagrams contain superseded clinical positioning and are not the current product contract. The supplied brief requires a public repository, an accessible three-minute video, and clear attribution of work created during the event. Its stated submission deadline is November 4, 2026 at 6 PM Pacific. Publication, submission, and final eligibility have not been verified here.
