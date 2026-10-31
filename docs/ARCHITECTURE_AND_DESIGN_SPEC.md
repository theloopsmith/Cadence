# Cadence architecture and design contract

## Delivery sequence

Walking cueing is the current acceptance gate. Verify detection, cue start, recovery, calibration provenance, persistence and the labeled demo before adding features. Subsequent gates are fall check-in and delivery, medication/meal records, surroundings checks, and diary/reporting. Home motor tasks are stretch work. Existing implementations stay available, but compilation and simulated tests do not establish physical acceptance.

## Components and ownership

SwiftUI presents Today, Diary and Help, with setup under Settings. CadenceAppModel coordinates those surfaces. MotionFeed selects the active motion source and feeds the local spectral and fall detectors. FoGCalibrationController derives thresholds through FoGCalibrator using labeled recordings. LabeledCaptureStore persists clips locally; the recorder retains a failed save in memory for explicit retry. Phone and glasses data must form separate complete calibration sets because sensor placement changes the signal. Synthetic reference motion is labeled as reference rather than personal validation.

WalkingModel owns requested protection, health and the explicit demo. AudioCueEngine owns output priority, interruption handling and route recovery. The voice companion listens while foregrounded and yields to safety and voice measurement. Microphone permission is configured once; everyday interaction uses speech. Meta handoff releases the microphone, and Siri's app-opening command returns to Cadence. Native assistant and Cadence microphone concurrency is not assumed.

Use the checked-in DAT adapter and the SDK resolved by the app project for capability discovery. Show the actual sensing source; fall back to the phone when glasses motion is unavailable. Keep the phone in a consistent pocket placement for phone recordings. Do not infer support from Bluetooth pairing alone. Camera video is ephemeral and must never be archived as a continuous recording.

FastAPI handles authenticated model requests and reports. Model calls must remain Meta-only per the supplied organizer clarification. OS speech output and on-device recognition remain explicitly identified OS features. SQL-backed event and caregiver recovery services commit durable state before acknowledging it. A model may interpret a bounded intent; medication writes, calling and emergency decisions remain guarded local/service actions.

## Event and storage contract

The backend schema in app/db.py is authoritative. fog_events records patient ID, unique event UUID, UTC time, duration, peak freeze index, locomotor/freeze powers, sample rate, arming mode, speech modifier, cue tempo and optional recovery latency. fall_events and caregiver_alerts separate detection, dispatch and human acknowledgment. medication_logs and medication_retractions preserve dose idempotency and Undo. motor_exams records task validity as well as nullable measurements. patient_wipes provides the per-patient erase boundary. login_attempts persists expiring login budgets without submitted passwords.

The phone keeps profile-scoped diary files, labeled capture files and a SQLite outbox. Account/server boundaries and erase generations prevent old records from being reassigned. Raw camera and voice input is transient for inference; a deliberately saved medication reference image and explicitly labeled research captures require visible purpose and local storage controls. A save error must never be reported as success.

## Design variables and behavior

Use San Francisco via dynamic system fonts, semantic grouped backgrounds and card surfaces, 16-point card corners, 12-point control corners, and 20-point action spacing. Existing minimum targets are 44 points; primary wearer controls use 72 or 88 points. A screen has one clear main action, with readable status text and VoiceOver labels. Respect Dynamic Type, reduced motion and light/dark appearance. Color must be accompanied by text or shape. The existing palette has not been established as AAA compliant; contrast must be measured for each foreground/background state before claiming that standard.

Use plain companion language: a beat helps stepping, a surroundings check describes a view, and task trends are observations. Avoid diagnostic scores, disease severity claims and suggestions to change medication timing or dose. Report missing data and uncertain coverage explicitly. A simulated demonstration must remain labeled and must not be presented as a real incident.

## Walking acceptance

Automated tests must cover labeled-data thresholds, turns/sit-to-stand/stillness traps, cue onset, recovery, signal gaps, false-positive rejection, demo cancellation and capture persistence failures. Physical acceptance requires the actual installed iPhone/glasses route, worn-device recordings, a safe simulated trigger, audible cue stop/recovery, reconnect and interruption recovery. Do not ask a wearer to induce a fall or intentionally provoke a freeze. Synthetic-only calibration and unmeasured device latency remain disclosed limitations.
