import Combine
import Foundation

#if canImport(UIKit)
import UIKit
#endif

/// Where a fall alert currently sits, from the wearer's point of view.
public enum FallAlertPhase: Equatable {
    /// No active alert.
    case idle
    /// Stage 3 confirmed; the 12-second spoken check-in window is open and the
    /// wearer can still cancel without any caregiver being contacted.
    case checkIn(eventUUID: String, deadline: Date)
    /// Check-in resolved as a real fall. Siren, beacon and caregiver dispatch
    /// are all active until a human cancels on the device.
    case dispatched(eventUUID: String)
}

/// Abstracts screen brightness so the alert logic runs in tests and on macOS.
public protocol ScreenController {
    /// Raises brightness to full for the SOS beacon and remembers the previous
    /// level. Called when an alert begins.
    func engageEmergencyBrightness()
    /// Restores the brightness the wearer had before the alert.
    func restoreBrightness()
    /// Keeps the display awake for the duration of an alert.
    func setIdleTimerDisabled(_ disabled: Bool)
}

/// Abstracts placing a call so tests can assert the dialed number without
/// actually invoking the dialer.
public protocol PhoneDialer {
    /// Opens the system dialer for `number`. iOS cannot place a call without
    /// the user confirming, which is why the SOS screen offers a tap target
    /// rather than auto-dialing.
    func dial(_ number: String)
}

#if canImport(UIKit)
/// Live screen control. Brightness is restored rather than pinned to a
/// constant, so cancelling an alert leaves the phone as the wearer had it.
public final class UIKitScreenController: ScreenController {
    private var savedBrightness: CGFloat?

    public init() {}

    public func engageEmergencyBrightness() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.engageEmergencyBrightness() }
            return
        }
        if savedBrightness == nil {
            savedBrightness = UIScreen.main.brightness
        }
        UIScreen.main.brightness = 1.0
    }

    public func restoreBrightness() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.restoreBrightness() }
            return
        }
        if let saved = savedBrightness {
            UIScreen.main.brightness = saved
            savedBrightness = nil
        }
    }

    public func setIdleTimerDisabled(_ disabled: Bool) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.setIdleTimerDisabled(disabled) }
            return
        }
        UIApplication.shared.isIdleTimerDisabled = disabled
    }
}

public final class UIKitPhoneDialer: PhoneDialer {
    public init() {}

    public func dial(_ number: String) {
        let digits = number.filter { $0.isNumber || $0 == "+" }
        guard let url = URL(string: "tel://\(digits)") else { return }
        DispatchQueue.main.async {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        }
    }
}
#endif

/// No-op implementations used on macOS and in tests.
public final class NoopScreenController: ScreenController {
    public private(set) var isEmergencyBrightnessEngaged = false
    public private(set) var isIdleTimerDisabled = false
    public init() {}
    public func engageEmergencyBrightness() { isEmergencyBrightnessEngaged = true }
    public func restoreBrightness() { isEmergencyBrightnessEngaged = false }
    public func setIdleTimerDisabled(_ disabled: Bool) { isIdleTimerDisabled = disabled }
}

public final class RecordingPhoneDialer: PhoneDialer {
    public private(set) var dialedNumbers: [String] = []
    public init() {}
    public func dial(_ number: String) { dialedNumbers.append(number) }
}

/// Owns the fall alert from Stage 3 confirmation through resolution, keeping
/// the detector, the audio engine, the screen and the backend in one state.
///
/// The view previously drove this by synthesizing a fake `"I'm okay"`
/// transcript whenever the cancel button was tapped, which conflated two
/// distinct cancellation routes the specification keeps apart: a recognized
/// spoken phrase, and an explicit button press. A tap is a direct, unambiguous
/// cancellation and is recorded as one.
@MainActor
public final class FallAlertCoordinator: ObservableObject {
    @Published public private(set) var phase: FallAlertPhase = .idle
    @Published public var persistenceWarning: String?
    @Published public private(set) var lastOutcome: String?

    /// Caregiver number offered as a one-tap call on the SOS screen. Falls back
    /// to the local emergency number when unset.
    public var caregiverPhoneNumber: String?
    public var emergencyNumber: String = "911"
    /// Hardware wear state from the glasses. Nil, or an unknown answer, is
    /// treated as worn so a missing sensor can never silence a fall.
    public weak var wearStateProvider: WearStateProviding?

    /// Seconds the wearer has to answer before anyone is contacted. Long on
    /// purpose: slowness after a fall is normal, and the window can be
    /// answered by voice or by a tap at any point.
    public nonisolated static let checkInWindowSec: TimeInterval = 30.0

    /// The detector whose Stage 3 opens each check-in. Resolving the check-in
    /// returns it to monitoring, so IMU samples must be fed to this instance.
    public let detector: FallDetector
    private let audio: AudioCueEngine
    private let screen: ScreenController
    private let dialer: PhoneDialer
    private let sync: EventSyncManager
    private let locationProvider: LocationProvider
    public let speechListener: SpeechCheckInListenerProtocol
    private let checkInWindow: TimeInterval
    private var checkInTask: Task<Void, Never>?

    public init(
        detector: FallDetector = FallDetector(),
        audio: AudioCueEngine = .shared,
        screen: ScreenController? = nil,
        dialer: PhoneDialer? = nil,
        sync: EventSyncManager = .shared,
        locationProvider: LocationProvider? = nil,
        speechListener: SpeechCheckInListenerProtocol? = nil,
        checkInWindow: TimeInterval = FallAlertCoordinator.checkInWindowSec
    ) {
        self.detector = detector
        detector.eventSync = sync
        self.audio = audio
        self.sync = sync
        self.checkInWindow = checkInWindow

        let isRunningInTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil

        if let loc = locationProvider {
            self.locationProvider = loc
        } else if isRunningInTest {
            self.locationProvider = MockLocationProvider()
        } else {
            self.locationProvider = LiveLocationProvider.shared
        }

        if let speech = speechListener {
            self.speechListener = speech
        } else if isRunningInTest {
            self.speechListener = MockSpeechCheckInListener()
        } else {
            self.speechListener = LiveSpeechCheckInListener.shared
        }

        #if canImport(UIKit)
        self.screen = screen ?? UIKitScreenController()
        self.dialer = dialer ?? UIKitPhoneDialer()
        #else
        self.screen = screen ?? NoopScreenController()
        self.dialer = dialer ?? RecordingPhoneDialer()
        #endif
    }

    public var isAlertVisible: Bool {
        if case .idle = phase { return false }
        return true
    }

    /// True once the alert has escalated: the siren is sounding and the beacon
    /// should flash. During check-in the wearer is only being asked a question,
    /// so the screen stays calm.
    public var isDispatched: Bool {
        if case .dispatched = phase { return true }
        return false
    }

    public var activeEventUUID: String? {
        switch phase {
        case .idle: return nil
        case let .checkIn(uuid, _): return uuid
        case let .dispatched(uuid): return uuid
        }
    }

    /// Called when `FallDetector` completes Stage 3. Opens the check-in window
    /// and starts the countdown that escalates on silence.
    public func beginCheckIn(eventUUID: String, now: Date = Date()) {
        persistenceWarning = sync.persistenceError?.message
        checkInTask?.cancel()
        phase = .checkIn(
            eventUUID: eventUUID,
            deadline: now.addingTimeInterval(checkInWindow)
        )
        // Request fresh location as soon as impact is confirmed
        locationProvider.requestFreshLocation()

        // The screen comes up immediately, bright and awake, so a wearer on the
        // floor can find the cancel button without hunting for the phone.
        screen.engageEmergencyBrightness()
        screen.setIdleTimerDisabled(true)

        let window = checkInWindow
        checkInTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(window * 1_000_000_000))
            guard !Task.isCancelled, let self,
                  case let .checkIn(active, _) = self.phase, active == eventUUID else { return }
            let (transcript, maxDbfs) = self.speechListener.stopListening()
            self.resolveSilentTimeout(
                transcript: transcript.isEmpty ? nil : transcript,
                maxVocalLevelDbfs: maxDbfs
            )
        }

        let listener = speechListener
        listener.startListening(
            onTranscriptUpdate: { _, _ in },
            onEarlyResolution: { [weak self] earlyOutcome in
                guard let self = self else { return }
                if earlyOutcome == "canceled_false_alarm" {
                    let (transcript, _) = listener.stopListening()
                    self.cancelByUser(reason: "canceled_false_alarm", transcript: transcript)
                } else {
                    _ = listener.stopListening()
                    self.escalate(status: earlyOutcome)
                }
            }
        )
    }

    /// The window closed with no transcript and no voice.
    private func resolveSilentTimeout(transcript: String? = nil, maxVocalLevelDbfs: Double = -160.0) {
        // The glasses' own wear sensor is the primary signal. With no glasses,
        // or no answer from them, the pair is treated as worn. Suppression of
        // an unworn drop is additionally gated by the detector's calibration
        // flag, which is off until the supine-versus-table recording is done.
        resolveFromSpeech(
            transcript: transcript,
            maxVocalLevelDbfs: maxVocalLevelDbfs,
            hardwareWearStateWorn: wearStateProvider?.isWorn ?? true,
            preImpactWearRmsG: 0.0,
            preImpactRespPower: 0.0,
            preImpactPitchDeg: 0.0
        )
    }

    /// Escalates the current check-in into a dispatched alert: siren on,
    /// beacon flashing, event queued for the caregiver pipeline.
    public func escalate(
        status: String = "confirmed_waiting_dispatch",
        peakImpactG: Double = 0.0,
        peakJerkGs: Double = 0.0,
        postImpactTiltDeg: Double = 0.0,
        latitude: Double? = nil,
        longitude: Double? = nil,
        horizontalAccuracyM: Double? = nil
    ) {
        guard case let .checkIn(uuid, _) = phase else { return }
        checkInTask?.cancel()
        phase = .dispatched(eventUUID: uuid)
        lastOutcome = status
        audio.activateBystanderSiren()

        var resolvedLat = latitude
        var resolvedLon = longitude
        var resolvedAcc = horizontalAccuracyM
        if resolvedLat == nil, let loc = locationProvider.currentLocation {
            resolvedLat = loc.latitude
            resolvedLon = loc.longitude
            resolvedAcc = loc.horizontalAccuracyM
        }

        var payload: [String: Any] = [
            "event_uuid": uuid,
            "timestamp_utc": ISO8601DateFormatter().string(from: Date()),
            "peak_impact_g": peakImpactG,
            "peak_jerk_gs": peakJerkGs,
            "post_impact_tilt_deg": postImpactTiltDeg,
            "status": status,
            "local_siren_activated": true,
        ]
        if let lat = resolvedLat, let lon = resolvedLon {
            payload["latitude"] = lat
            payload["longitude"] = lon
        }
        if let acc = resolvedAcc { payload["horizontal_accuracy_m"] = acc }
        if case let .failure(error) = persist(
            eventUUID: uuid, endpoint: "/api/v1/events/fall", payload: payload
        ) {
            persistenceWarning = error.message
            lastOutcome = "local_persistence_failed"
        }
    }

    /// Resolves the alert from the spoken check-in, applying the detector's
    /// phrase and groan rules.
    @discardableResult
    public func resolveFromSpeech(
        transcript: String?,
        maxVocalLevelDbfs: Double,
        hardwareWearStateWorn: Bool,
        preImpactWearRmsG: Double,
        preImpactRespPower: Double,
        preImpactPitchDeg: Double
    ) -> String {
        let outcome = detector.evaluateCheckInOutcome(
            transcript: transcript,
            maxVocalLevelDbfs: maxVocalLevelDbfs,
            hardwareWearStateWorn: hardwareWearStateWorn,
            preImpactWearRmsG: preImpactWearRmsG,
            preImpactRespPower: preImpactRespPower,
            preImpactPitchDeg: preImpactPitchDeg
        )
        switch outcome {
        case "canceled_false_alarm":
            cancelByUser(reason: "canceled_false_alarm", transcript: transcript)
        case "suppressed_unworn_drop":
            standDown(outcome: outcome)
        default:
            escalate(status: outcome)
        }
        return outcome
    }

    /// The wearer or a bystander tapped "I'M OKAY — CANCEL".
    ///
    /// This is a cancellation in its own right, not a synthesized transcript.
    /// If caregivers were already contacted, the backend is told so it can halt
    /// the retry loop and send the All-Clear SMS.
    public func cancelByUser() {
        cancelByUser(reason: "canceled_by_user_button", transcript: nil)
    }

    private func cancelByUser(reason: String, transcript: String?) {
        let wasDispatched = isDispatched
        let uuid = activeEventUUID
        standDown(outcome: reason)

        guard let uuid else { return }
        if wasDispatched {
            // Caregivers are already being called: cancelling must reach the
            // backend so the retry loop stops and the All-Clear SMS goes out.
            persist(
                eventUUID: "\(uuid)-cancel",
                endpoint: "/api/v1/events/fall/\(uuid)/cancel",
                payload: ["event_uuid": uuid]
            )
        } else {
            // Cancelled inside the check-in window: no caregiver was contacted,
            // so the event is recorded as a resolved false alarm.
            persist(
                eventUUID: uuid,
                endpoint: "/api/v1/events/fall",
                payload: [
                    "event_uuid": uuid,
                    "timestamp_utc": ISO8601DateFormatter().string(from: Date()),
                    "peak_impact_g": 0.0,
                    "peak_jerk_gs": 0.0,
                    "post_impact_tilt_deg": 0.0,
                    "status": "canceled_false_alarm",
                    "cancel_transcript": transcript ?? "canceled on device",
                    "local_siren_activated": false,
                ]
            )
        }
    }

    @discardableResult
    private func persist(eventUUID: String, endpoint: String, payload: [String: Any]) -> Result<Void, QueueStorageError> {
        let result = sync.saveLocalImmediate(eventUUID: eventUUID, endpoint: endpoint, payload: payload)
        if case let .failure(error) = result { persistenceWarning = error.message }
        return result
    }

    /// Clears the alert: siren off, brightness and idle timer restored.
    private func standDown(outcome: String) {
        checkInTask?.cancel()
        checkInTask = nil
        _ = speechListener.stopListening()
        detector.resetAfterResolution()
        phase = .idle
        lastOutcome = outcome
        audio.deactivateBystanderSiren()
        screen.restoreBrightness()
        screen.setIdleTimerDisabled(false)
    }

    // MARK: - One-tap calling

    /// iOS cannot place a call unattended, so these open the dialer with the
    /// number filled in and the wearer confirms.
    public func callCaregiver() {
        dialer.dial(caregiverPhoneNumber ?? emergencyNumber)
    }

    public func callEmergencyServices() {
        dialer.dial(emergencyNumber)
    }

    public var caregiverButtonTitle: String {
        caregiverPhoneNumber == nil ? "CALL \(emergencyNumber)" : "CALL CAREGIVER"
    }
}
