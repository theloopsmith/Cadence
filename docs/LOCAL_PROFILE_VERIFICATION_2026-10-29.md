# Single-wearer local profile — October 29, 2026

The local-history portion of review item 8 is implemented as **one wearer and one server per installation**, with an explicit reset before reassignment. This is not a multi-account device switcher.

Follow-up: [authenticated address repair](PHONE_AND_GLASSES_JOURNEY_2026-10-29.md) now permits correcting a localhost/LAN address without erasing the phone. A first-time legacy localhost repair requires explicit destination confirmation; subsequent moves must match the learned server ID. Queue/profile migration is journaled. Changing wearer still requires reset. The text below records the original implementation snapshot.

## Behavior

- A durable, atomically written profile manifest binds the installation to a local identity key and normalized server destination. JWT subject/patient claims identify the local partition; opaque credentials use their hash. Credentials and passwords are not stored in the manifest. The backend still verifies authorization independently.
- Refreshing a JWT for the same subject/patient is allowed. A different subject, patient or destination is rejected before the credential change reaches the API, outbox, exam manager or caregiver configuration. Direct developer key edits use the same guard and an explicit Apply button. Signing out pauses transmission and keeps only the provisioned wearer's offline history accessible. The development key cannot silently reactivate after sign-out and relaunch.
- Production app construction now uses `Documents/CadenceDevice/<profile UUID>/` for the diary, task history, pill photo, labeled captures and queue. Summary identity, schedule, contacts, voice and other personal preferences use that profile's namespace. All app windows share one app model. The FoG detector, fall coordinator, exam manager and dose logger use the provisioned queue.
- First-time setup finishes before starting collection. Settings now exposes sign-in, sign-out, account notices and a confirmed local reset. A late login response after sign-out or reset cannot install its token.
- Existing unassigned legacy files and global personal preferences are **not imported or reassigned automatically**. They remain separate from the new profile. This upgrade may require re-entering setup. It preserves legacy files rather than guessing their owner; erasing the current profile does not claim to erase those legacy files or copies previously exported/shared.

## Local reset

Settings → **Erase local profile for a new wearer** presents the concrete deletion scope before confirmation. Preparing the reset:

1. Refuses to cancel an active help alert and refuses while the event queue has a request in flight.
2. Suspends the old queue against delivery, new events, buffered retries and credential reconfiguration.
3. Writes a durable reset marker before clearing credentials and personal preferences. If writing the marker fails, reset is not claimed and queue operation is restored.
4. Invalidates pending login/delivery work, stops motion/audio, cancels the exam and voice-dose listener, detaches glasses, stops capture, and removes reminders. A late notification-permission response cannot recreate reminders.
5. Shows a restart gate. On the next full app launch, profile files (including pending uploads) are removed **before** a new profile, queue or producer is opened. Interrupted erasure retries at the next launch. Failure opens no history and displays a storage notice. A fresh profile requires new credentials and cannot adopt a stale Keychain value.

The marker also remembers retired preference namespaces, so cleanup can resume even if the process stops between file erasure and preference cleanup. The old process cannot resume collection through the normal app UI while awaiting restart.

## Verification

**279 Swift tests pass** with `CADENCE_TEST_SILENT_AUDIO=1`. New regressions exercise:

- Durable binding, refreshed JWTs, different subjects/patients/servers, direct key edits and sign-out/relogin.
- Preference isolation, legacy non-adoption, distinct new profile directories and physical erasure of the retired directory.
- Queued events removed with the retired profile, rejected stale producers, and reset blocked until an in-flight queue request completes.
- Corrupt manifests, failed binding writes, failed reset-marker writes and crash recovery before credential clearing.
- Late sign-in and notification-permission responses, active-help reset rejection and stale diary/photo callbacks.
- Sign-out across relaunch without development-token fallback.

The actual iOS simulator app target builds successfully with signing disabled. No app was launched, no audio played, and no live provider/contact request was sent. Existing backend/dashboard verification remains the prior 161 backend tests, five JavaScript checks and isolated browser check; this change does not modify backend routes.

## Remaining boundaries

This is an application routing and provisioning boundary, not an authentication lock for an unlocked phone. Signing out intentionally preserves this wearer's offline access. The binding is local; it does not change the backend's deployment-wide caregiver routing.

**Local reset leaves server records unchanged.** Interactive requests already sent can finish in their original server account. The dashboard's separate server-data wipe is not coordinated with an offline phone's pending uploads; preventing those records from returning after a server wipe remains open and must not be claimed as fixed by this local reset. Physical-device reset/setup UI execution and live caregiver delivery remain unverified.
