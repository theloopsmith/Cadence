# Cadence app guide

## Connect the app

Install the app using `ios/App/CadenceCompanionApp.xcodeproj`. Today, My routine and Settings are the root tabs. Today begins with walking support; glasses/audio details expand separately. Settings remains in the bottom tab bar.

For a local backend, run `python3 scripts/run_phone_backend.py` from the repository root and leave the Mac awake on the iPhone's Wi-Fi. In **Settings → Advanced → Show developer tools → Find my Mac server**, choose your Mac, then use **Connection → Connect and sign in** using the private `.local/phone-login.txt`. Allow Local Network access. If discovery fails, enter the address printed by the launcher and open its `/health` URL in iPhone Safari. Never enter `localhost` for a server running on the Mac.

For the hosted sandbox, open **Settings → Connection**, choose **Use hosted demo**, enter the phone account, and tap **Connect and sign in**. There is no separate address-apply step. A fresh unbound installation prefills the hosted demo in the form without changing an existing profile. Use the HTTPS origin and account in the [cloud runbook](GOOGLE_CLOUD_DEMO.md). A different server/account is a separate profile: preserve/export existing records before resetting it. Never bypass the account-bound queue guard to move another wearer's pending records.

A 401 requires signing in again to the same account/server, not erasing the local profile. Surroundings can retain a photo in memory while opening sign-in, then retry it. The LAN launcher persists its signing key in ignored `.local/phone-jwt-secret`; never publish that key or the login file.

## Glasses camera and audio

Pair/register glasses in the Meta AI app, enable Developer Mode where required, and grant the app's requested permissions. Bluetooth pairing alone does not establish DAT camera access. Check actual readiness in **Today → Glasses & audio**.

Open **Glasses camera** for live preview. Capture, review, then say “use this photo” or “retake.” Short shutter presses are handled when DAT exposes that input. Photos taken outside the active Cadence camera session are not automatically imported. Preview and local medication-reference saving do not need the backend; online analysis and sync do.

The displayed input/output routes reflect the route iOS actually selected. Physical microphone/output routing, capture-button behavior and the complete guided journey still need device acceptance testing.

## Voice companion

Tap **Talk to Cadence** on Today to start a conversation, and **Pause listening** to stop. Continuous listening is off by default; upgrading from the former automatic mode requires a fresh opt-in once. Optional **Settings → Hands-free voice companion** starts listening while foregrounded; a one-session Talk tap does not enable automatic startup. Backgrounding pauses everyday conversation. Unknown speech no longer triggers spoken menu repetition; two unrelated turns pause listening quietly. Idle general conversation pauses after 40 seconds, while an active task retains its listening window. Confirmation expiry pauses without taking the action. During a task, address “Cadence” explicitly for free-form model interpretation; ordinary task commands still work. This is not a dedicated wake-word detector, and recognized commands can still be picked up from nearby conversation. Walking support and its safety check-ins are independent of this listening preference.

Try:

- “I need help” to choose a task.
- “Start a motor exam,” “check my surroundings,” or “help with my medication.”
- “When is my next dose?”, “Did I record my medication today?”, “What about yesterday?”, or “What were my last motor check results?”
- “Capture,” “use this photo,” “retake,” “retry,” or “cancel” within the current task.
- “Stop listening” to disable the companion.

Known questions use local saved facts. Unfamiliar wording can use Meta interpretation when online; the model supplies an intent, not patient facts. Dose records, Undo, calls and protection changes require a separate clear confirmation. Unclear speech repeats the current step rather than restarting the menu. Calls open the iOS dialer and may require OS confirmation.

The motor check prepares the microphone before its spoken start cue, then records a five-second voice sample. Insufficient input offers retry/skip. Writing uses the displayed sentence in three slow phrases with pauses; say “repeat” or use replay. The ten-second walk starts after its cue and only when the user chooses to proceed. Leaving or backgrounding cancels measurement. Results are observations, not a diagnosis.

## Use native Hey Meta

Cadence's active Bluetooth microphone can cause Hey Meta to ask you to hang up. Say “let me use Meta” while Cadence is listening to release its microphone/camera route. Use Hey Meta separately, then say “Siri, open Cadence” to return; unlocking may be required. Native Hey Meta invocation inside Cadence is not integrated.

Everyday Cadence voice, camera and walking audio are unavailable during this handoff. A fall check-in reclaims audio. Locked-screen conversation and conversational barge-in are not implemented acceptance claims.

## Speech voice

Cadence prefers the best installed Apple Premium, Enhanced, then Standard voice, subject to a saved explicit choice. In iPhone Settings, open Accessibility's spoken-content/read-and-speak voice settings and download an English Premium or Enhanced voice if available. Labels vary by iOS. Return to **Cadence Settings → Voice & Audio Cues → Automatically use the best installed voice**, or choose and audition one. Cadence cannot install voices itself. No external AI voice-output service is called.

## Medication routine

Use **Today → Edit routine** or **My routine**. Reminder permission warnings and retry controls appear here alongside the medication plan. Add each medication and its existing prescribed reminder times, then choose **Save routine**. The page returns to a saved-routine summary with a visible receipt. Discard changes leaves the saved plan intact. Camera presentation does not reload your draft. Say “save routine” or “discard changes” while editing. A reference photo follows capture → review → use, and stays local.

Today's selector chooses the medication used by Taken/Undo. By voice, say “I took [saved medication name].” With multiple medications, a generic request asks for the full saved name and then a separate confirmation. Ambiguous names are not guessed. Recording is not proof of ingestion and never changes a prescribed dose.

Reminders repeat daily for all saved medications. Logging dismisses the matching delivered reminder while preserving future reminders; an early dose record may still be followed by that day's scheduled reminder. Its wording asks you to check the saved schedule/record. Undo preserves recurrence. Failed updates appear under Medications with **Retry reminders**; notification permission is controlled in iPhone Settings. Valid existing reminders survive a failed update.

## Help, privacy and developer tools

**I need help** opens help actions; it does not immediately place a call. The phone's saved caregiver number controls its manual dialer. Automated server dispatch is separately configured for a single-wearer deployment; editing the phone number does not change server routing. The public demo and LAN launcher simulate caregiver transport.

Local reset and server wipe are separate actions. Pending records remain bound to their account, destination and erase generation. Signing out or seeing a persistence error does not mean a queued action was delivered.

Developer controls are hidden under **Settings → Advanced → Show developer tools**. They include diagnostics, labeled replays, calibration, safety tests, camera checks, diary fixtures and the offline queue. Do not induce a fall or provoke a freeze to test the prototype.

See [architecture and contracts](ARCHITECTURE_AND_DESIGN_SPEC.md) and [current verification evidence](VERIFICATION_LOG.md) for implementation and acceptance boundaries.


## Surroundings and meal follow-through

For surroundings, general questions use Muse image proposals followed by SAM verification; specific named objects skip proposal. The server allows 12 seconds and the iPhone's photo request allows 20 seconds including upload/network time. Service unavailability, no supported match and partial evidence have distinct statuses. The confirmed photo stays available while the screen is open: clarify the question and choose **Check photo with this question** without recapturing. No result certifies the whole scene as safe.

Meal diary asks whether you want an optional glasses/iPhone photo. Review/use the photo, choose the meal time, add an optional note and save, or choose **Log meal without photo**. A receipt confirms the local save and separately describes queued sharing. Only the timestamp goes to the backend; photos and notes stay in the profile's diary and appear in the local timeline. The entry works offline. Failed local writes do not claim success; failed sharing can be retried without duplicating the entry. A 30-day diary reconciliation repairs interrupted journal-to-queue writes only at the original account, destination and erase generation. After saving, say “another meal” or “done.” There is no food/nutrient recognition or medication-timing advice.
