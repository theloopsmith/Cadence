# Audio control and protection health — October 29, 2026

## Scope and review

This implements item 3 from the hackathon readiness review after inspecting the current source and the user's item-1 changes. The prior architecture and remaining data/security/submission findings still apply; this is not a claim that the entire backlog has been fixed. Existing SAM work was preserved.

The SAM client now uses Responses requests, bounded concept calls, tokenized box parsing, optional confidence, and a real stage deadline. The checked-in evidence records a live synthetic red-circle request (3,632 ms) and live transcription of synthesized speech (1,999 ms). These establish live-service protocol checks, not a wearer/photo field trial. Baseten selection and a real-photo end-to-end scene result remain unrecorded. Follow-up review also found that the parser uses bounding-box area rather than decoded-mask area and silently drops malformed lines; parser diagnostics should eventually distinguish malformed output from a valid empty response. Those are separate item-1 follow-ups, not changed in this audio task.

## Implemented behavior

### Speech and walking controls

- `PromptArbiter` permits one active utterance and no speech backlog. Equal-priority prompts replace the old prompt; higher-priority speech preempts; lower-priority speech cannot queue behind it. Completion IDs prevent canceled utterances from completing replacements.
- Starting a siren cancels existing speech. An emergency check-in prompt stops walking audio. Starting a walking cue preempts lower-priority speech.
- The spoken “Step to the beat” instruction has a 45-second cooldown across cue episodes. The metronome can still play during that cooldown; the words do not repeat on every short retrigger.
- Stopping a cue cancels its speech as well as PCM playback. A stale walking stop cannot silence a subsequently activated siren.
- Today provides **Stop walking cues**, **Retry audio**, and **Retry protection** as appropriate. Stopping walking protection clears its detector state and non-emergency speech without canceling an active fall check-in or siren.

### Audio interruptions and recovery

- One session configuration path now serves cues, route setup, voice monitoring and both microphone listeners. Worker-queue microphone setup consults the main-thread interruption/recovery state before opening hardware.
- Interruption begin pauses playback, cancels stale speech and stops microphone capture. Provisional affirmatives are invalidated; distress already heard remains latched. The existing fall timer/manual actions continue to own the incident; input loss cannot silently resolve a check-in.
- Interruption end resumes requested PCM only when the system permits resuming and playback was eligible before interruption. Stopped cues cannot restart afterward, and old speech is never replayed.
- Loss of an output device pauses audio and requires explicit retry, preventing an earphone cue from unexpectedly continuing on another speaker. Repeated notifications do not repeatedly tear down the same session.
- Media-services reset invalidates old audio objects. Cue engine, player, synthesizer and background-audio nodes are rebuilt; microphone engines detect the reset generation before reuse/teardown. Playback requires a deliberate retry after reset, including when the reset occurs during an interruption.
- Session/start/routing failures remain visible as unavailable audio. The background-audio wrapper checks actual engine/node state instead of claiming success after an ignored start error. Its stable wrapper survives engine replacement.
- Today displays actual input and output port names. Bluetooth type alone no longer implies glasses; an SDK connection establishes the glasses connection tile state. Name-based microphone selection is a convenience, not proof of device identity or acoustic quality.
- Emergency copy no longer unconditionally says the siren is sounding when audio is unavailable, and the queued alert records the observed audio availability at activation.

### Sensor freshness

- Motion health distinguishes off, waiting for first sample, fresh and stale. By default, a two-second gap becomes unavailable on the next 0.5-second health tick. The first good sample is required before the UI reports protection on.
- Finite, strictly increasing sample timestamps are required. Duplicate timestamps, invalid values, and callbacks from a stopped/replaced source cannot keep protection healthy.
- A stale stream clears spectral/arming state and stops the walking cue without recording successful recovery. A source change begins with fresh buffers. Partial fall detection resets across gaps; an already active fall check-in stays active.
- Requested protection is separate from healthy protection, so the wearer can turn off or retry a degraded stream. Healthy UI status requires fresh samples, usable cue audio and active requested background audio.
- Losing sensors is not equivalent to the wearer recovering. Diary hooks suppress recovery wording when the stream has become stale/off.

## Automated verification

- **253 Swift package tests pass**, including 16 new audio/protection tests. They cover priority/preemption, stale completion IDs, cue cooldown, stop behavior, interrupted/reset/failed restart, microphone gating, headset classification, invalid/duplicate/stale input, retired-source fencing, partial-fall reset, active check-in preservation, and honest protection status.
- **137 backend tests pass**, including the user's SAM changes. No backend source was changed by this task.
- The actual **iOS Simulator app target builds successfully**, including DAT integration and the updated Today/SOS UI.
- `git diff --check` passes. Existing Swift 6 test-concurrency, package-cache, dependency deprecation and DAT deployment-target warnings remain; a successful build does not eliminate those warnings.

Swift tests use the explicit XCTest-only silent-audio configuration; some recovery tests inject a failing engine starter. They verify control logic, not physical output. The app was not launched, no tone/speech was played, and no caregiver contact/tunnel was started for this task.

## Remaining physical verification

On a consenting physical-device test, confirm: one walking prompt and beat; immediate Stop clearing speech/beat; another cue within 45 seconds without repeated words; a call/Siri interruption; Bluetooth disconnect/reconnect; microphone permission denial; manual audio retry; media-services reset; and screen-lock/background sensor continuity. Confirm the displayed ports and unavailable states match the actual route. Physical glasses IMU calibration and acoustic audibility remain unverified.

If the app is suspended or terminated, its timers and silent buffer cannot guarantee continued monitoring. A wall-clock freshness check can show stale state after execution resumes; it cannot run while the process is suspended. Engine/node activity also cannot prove a wearer heard the sound, the system volume is sufficient, or the intended physical speaker is audible. Keep those limits explicit in the demo.

Implementation follows Apple's [audio interruption guidance](https://developer.apple.com/documentation/avfaudio/handling-audio-interruptions) and [media-services reset guidance](https://developer.apple.com/documentation/avfaudio/avaudiosession/mediaserviceswereresetnotification). Actual Bluetooth and reset behavior still needs the separate physical drill above.
