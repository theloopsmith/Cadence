# iPhone server connection and glasses photo journey — October 29, 2026

This follow-up prioritizes the working product entry point over adding features: connect a real iPhone to the Mac backend, take a requested photo from Meta glasses, receive Meta-backed observations, and hear the result.

Launch fix: an unbound profile no longer replaces the app with Settings. Today, Diary and Help open before setup, after sign-out, and when a login fails offline. A connection notice/button opens Settings from Today. Hardware attachment/startup now reaches the normal launch path before server setup. Only an explicit pending reset or unreadable local profile blocks normal navigation. The launch regression and reset guard are covered by the current **289 passing Swift tests** and a successful actual app build; no app was launched or audio played during these checks.

## Findings and changes

The existing backend listener was bound to **127.0.0.1:8000**. On an iPhone, localhost addresses the phone, so that configuration cannot reach the Mac. The previous profile guard also made a mistyped/loopback server address require erasing the local profile. Photo actions were inconsistent: surroundings used raw device capture, pill setup silently opened the phone camera after a glasses failure, and the handwriting/developer entry points emphasized the phone. The real SAM response may omit a confidence score, while iOS required one.

Implemented:

- A repeatable LAN launcher, `python3 scripts/run_phone_backend.py`, defaults to port **8001**, binds **0.0.0.0**, detects a port conflict, and prints the Mac's `.local` URL. It uses a separate `.local/phone-server.sqlite` development database and a randomly generated phone account; credentials are written with mode 0600 to `.local/phone-login.txt`. `.local/` is ignored by Git. Provider credentials still load from `backend/.env`; all Twilio/contact settings are overridden empty, so caregiver delivery is simulated. No public tunnel is created.
- Authenticated `GET /api/v1/device/connection` returns a persistent database/server ID and the authenticated patient binding. IDs survive database initialization and remain separate across databases.
- Settings can test and repair an existing localhost connection without erasing phone history. A legacy profile without a stored server ID requires an explicit localhost-to-LAN confirmation; this is a deliberate first-time destination choice, not proof that the old and new databases are identical. Once learned, the server ID must match for later address moves. Account changes remain blocked. Sign-in can target the entered address, including when the old address is unreachable.
- Only that owner's queued records migrate to the new destination. A journal in the profile plus a queue transaction recovers if the process stops between the two commits. Active help/upload conditions, sign-out, stale responses and reset are fenced. Existing records already stored on another server stay there; this does not merge databases.
- Surroundings, pill setup, handwriting and developer checks offer Meta glasses as their primary camera. A phone camera is an explicit alternative, never an automatic response to a glasses error. Settings exposes glasses status and Connect outside the Developer tab.
- All package-level glasses captures use one controller: capability checks, duplicate-request rejection, main-thread completion, timeout, disconnect/replacement cancellation, empty-result rejection and stale-callback protection. A stalled connection ends with an actionable Meta AI message.
- The DAT adapter cancels camera/listener/task resources on completion, failure, disconnect and pause. Request/session IDs prevent old permission/state/photo callbacks from capturing or completing a new request. Captures normalize to JPEG before upload. The SDK lifecycle was checked against the installed Meta DAT interfaces; the actual adapter is compiled in the app target.
- Scene requests disable duplicate actions and fence results against dismissal, reset and session changes. SAM masks with null/omitted confidence decode without inventing values.

## Use on the phone

The user confirmed the Mac and iPhone share Wi-Fi and the glasses are paired in Meta AI.

1. Rebuild/install the updated app from `ios/App/CadenceCompanionApp.xcodeproj`. Compilation here did not install or launch an app on the phone.
2. The LAN development backend started during this work on port 8001. In iPhone Safari, open **http://192.168.86.249:8001/health**. The hostname alternative is **http://Avantis-MacBook-Air.local:8001/health**. The IP can change when Wi-Fi changes; use the hostname or the Mac's current LAN address.
3. In Cadence Settings, enter **http://192.168.86.249:8001** or **http://Avantis-MacBook-Air.local:8001** as the Mac server address. For an existing localhost profile, select Connect and confirm the destination. For fresh setup, use the address and sign in with the account in `.local/phone-login.txt`. Allow iOS Local Network access. No reset is needed for the supported localhost repair.
4. Connect Meta glasses in Settings; complete app registration/camera permission in Meta AI if prompted. Open Check Surroundings and choose **Take Photo with Meta Glasses**. A capture failure stays visible; it does not open the phone camera.
5. To restart the backend later, run `python3 scripts/run_phone_backend.py` from the repository. The original loopback server on port 8000 was left intact. This process is for same-LAN development; it is not an internet deployment or a publicly reachable Twilio callback service.

Local networking behavior and permission descriptions follow [Apple's local-network guidance](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy). The camera path follows the [Meta DAT camera lifecycle](https://github.com/facebook/meta-wearables-dat-ios/blob/main/samples/CameraAccess/README.md) and the locally installed 1.0.1 interfaces. Standalone photo support still depends on the glasses/app/release-channel capability.

## Verification

- **163 backend tests pass**, including authentication/role checks and durable server identity across initialization/separate databases.
- **289 Swift tests pass** with `CADENCE_TEST_SILENT_AUDIO=1`. Regressions cover launch before setup/after sign-out/offline login, owner-preserving address repair, server-ID mismatch rejection, recovery between queue/profile commits, stale sign-out responses, bytes from the glasses, overlap rejection, timeout/empty-frame handling, replacement/disconnect, stalled connections and optional SAM confidence.
- The actual iOS simulator app target builds, including DAT. No app was launched and no audio was played.
- The running backend returned HTTP 200 through **127.0.0.1:8001**, **192.168.86.249:8001**, and the `.local` hostname using macOS curl. The authenticated connection endpoint also returned HTTP 200 via the LAN IP. Python's hostname lookup did not resolve `.local`, so an explicit LAN-IP alternative is documented. These are Mac-side checks, not proof of an iPhone request.
- No live photo/inference or caregiver notification was initiated in this run. Provider credentials were not printed.

## What remains

The next acceptance check is physical: iPhone Safari reachability, app registration/camera permission, one glasses photo, the real Meta response and audible output on the intended route. Pairing alone does not prove that chain. Measure capture-to-result time and verify cancel/retry while testing it. A real-photo result is still needed for submission evidence.

Server-wipe/offline-upload coordination, server caregiver setup/acknowledgment, account-specific automated recipients, CI/reproduction, eligibility clarification and submission materials remain open in the readiness review. This work does not claim the whole app is finished.
