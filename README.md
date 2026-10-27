# Cadence — Ambient Parkinson's Companion for Meta Gen 3 AI Glasses

Cadence is an audio-first, privacy-preserving clinical companion for **Meta Gen 3 AI Glasses**, built for the **Meta Global AI Developer Hackathon** (*"Build for Your World"*).

## Architecture & Clinical Pipelines

- **Architecture Diagrams**:
  - [`docs/cadence_high_level.drawio`](./docs/cadence_high_level.drawio)
  - [`docs/cadence_detailed_architecture.drawio`](./docs/cadence_detailed_architecture.drawio)
  - [`docs/IMPLEMENTATION_PLAN.md`](./docs/IMPLEMENTATION_PLAN.md)
- **Core Capabilities**:
  1. **Pipeline 1 (`P0`) — Freezing of Gait (FoG) Detection & Rhythmic Cueing**: Uniformly resampled dynamic-Hz FFT (`0.5–3.0 Hz` locomotor vs. `3.0–8.0 Hz` freeze band) with 3-mode arming (Active Walk, Sit-to-Stand, Upright Posture Turn) and `<50 ms` on-device `100 BPM` auditory metronome cueing.
  2. **Pipeline 2 (`P0`) — Fail-Safe Fall Detection & Signed Twilio Escalation**: 3-stage impact detector with immediate local SQLite persistence, hardware `wearState` primary check, 12-second dual-STT check-in (affirmative phrase required; distress/negation/groans always escalate), `CoreLocation` GPS SMS + Twilio `<Gather numDigits="1">` voice call, `X-Twilio-Signature` validation, `90 s` / terminal-status secondary escalation, `60 s` retry loop, All-Clear SMS on cancel, and launch-configured `.speaker` `0 dBFS` Bystander Siren + Flashing SOS Screen Beacon.
  3. **Pipeline 3 (`P1`) — Prescribed Dose & Plate-Normalized Meal Protein Logger**: `SAM 3.1` food and plate mask ratio (`A_mask / A_plate`) mapped to `PROTEIN_LOOKUP_TABLE` and checked against `[Dose - 45 min, Dose + 60 min]`.
  4. **Pipeline 4 (`P0`) — Verifiable Hallucination Reality Check**: `SAM 3.1` ground-truth instance masks (`L_sam`) + deterministic grounding gate locking the spoken inanimate object slot strictly to `L_sam` + Baseten `muse-spark-open-1026` + `Muse Voice` TTS under a shared `4.0 s` deadline.
  5. **Pipeline 5 (`P1`) — Voice Volume & Method-Invariant Handwriting Micrographia**: Always-on `<8 ms` CPU OpenCV deskew and stroke-height decay (`opencv_cc_decay_pct`) driving `handwriting_score` + `SAM 3.1` visual refinement (`sam_3_1_decay_pct`).
  6. **Pipeline 6 (`P0`) — Guided 3-Step Home Motor Exam**: Prompted 5s sustained vowel phonation (`"Ahhh"`), prompted handwriting line, and prompted 10s timed walk scored 0–100.
  7. **Pipeline 7 (`P0`) — Pure Motor $S(t_k)$ ON/OFF Diary & Web Neurologist Report**: Ordered, exhaustive 4-state classifier (`OFF` -> `NO_DOSE` -> `WEARING_OFF` -> `ON`) and print-ready clinician report at `GET /dashboard`.

## Quick Start (One-Command Demo, Backend & Swift Edge DSP Tests)

```bash
# 1. Run the FastAPI Clinical Orchestrator & open http://127.0.0.1:8000/dashboard
./scripts/run_demo.sh

# 2. Run the Python backend test suite (13 tests across all 7 pipelines)
cd backend && .venv/bin/pytest -v

# 3. Compile & test the Swift Edge DSP & Audio Engine (FoG FFT, 3-Stage Fall Detector, VoiceMonitor)
cd ../ios && swift test
```
