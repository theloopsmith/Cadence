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

## Native Meta assistant integration investigation — 2026-10-31

This is a proposed integration, not an implemented or device-tested capability. Public sources checked: [Meta AI Connectors](https://dev.meta.ai/products/connectors), [Wearables FAQ](https://developers.meta.com/wearables/faq/), and Meta's [iOS Voice Invocations guide](https://github.com/meta/meta-wearables-dat-ios/blob/main/plugins/mwdat-ios/skills/voice-invocations/SKILL.md).

Meta AI Connectors expose a service's API as tools inside Meta AI's conversation, across glasses/app/web. The public onboarding page describes REST endpoints, guided UI or MCP onboarding, and OAuth account linking. Developer preview access is selected in waves; public publishing is a later phase. Access for this project's account has not been verified. The public material does not establish a drop-in Meta AI text-to-speech API, control of exact spoken wording/rate, access to uninterrupted raw phonation audio, camera image forwarding, phone motion capture, or proactive caregiver announcements. Detailed developer documentation and acceptable-use policy redirected to sign-in; compatibility of this particular accessibility/medication use case must be verified during preview onboarding.

Cadence implications from code inspection:

- Start a preview proof of concept with a patient-scoped read-only dose-history tool. Answer factual recorded-dose questions and identify server sync freshness; missing server records must not be interpreted as proof of non-ingestion or absence of an unsynced phone record.
- Next-dose questions require a new authenticated medication-plan sync/read contract: AppSettings currently persists the medication plan locally; backend medication_logs stores dose events rather than the configured plan.
- Existing account tokens are not an OAuth authorization-code/account-linking flow. Add account consent, revocation and least-privilege patient-bound scopes after Meta's exact onboarding requirements are available. Never share the static development token or clinician credentials with a connector.
- Dose writes should follow read-only validation. Preserve event UUID idempotency, authenticated patient binding, erase generations, explicit medication/time readback and confirmation, Undo semantics, and phone/server reconciliation. Do not assume the assistant's verbal confirmation supplies a server-verifiable confirmation protocol.
- A medication assistance request must not be submitted as a fall event to reuse the caregiver pipeline. Existing callCaregiver opens the phone dialer; this is not an acknowledged server caregiver request. A separate request lifecycle would be needed.
- Keep native motor capture in the iPhone app until actual connector capabilities prove otherwise. REST tool calls alone do not provide the timed microphone/IMU capture the current check requires.

A separate, nearer-term option is DAT Voice Invocations. The pinned iOS SDK 1.0.1 exposes VoiceInvocationsStream, LaunchApp, and ResponseHandle.sendSuccess/sendFailure(actionOutput: String?). Cadence does not currently instantiate that stream. Meta's guide requires bundle registration, Voice Invocation approval, and a spoken app name in Wearables Developer Center; it is experimental for development/beta channels. LaunchApp is app activation, not a documented arbitrary feature-command payload or ongoing TTS service. ResponseHandle's optional action output is not proof of arbitrary native voice playback. Register listeners before starting, acknowledge every invocation exactly once, surface permission/channel failures, and clean up listeners on disconnect.

Suggested acceptance sequence: confirm connector preview access and native invocation approval; prototype an isolated synthetic read-only API; verify account linking and tenant separation; test one real glasses query with a consenting test account; then decide whether to add write tools. Separately test native app invocation with MockDeviceKit and actual glasses before replacing the current return guidance. Do not depend on unapproved preview access for the hackathon's core demonstration. No application was submitted and no service was published as part of this investigation.
