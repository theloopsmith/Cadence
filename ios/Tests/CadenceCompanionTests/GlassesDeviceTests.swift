import XCTest
@testable import CadenceCompanion

@MainActor
final class GlassesDeviceTests: XCTestCase {
    private func walkingSamples() -> [IMUSample] {
        LabeledCaptureLibrary.referenceCaptures().first { $0.label == .walking }!.samples
    }

    /// The mock reports what the real toolkit reports: connection, wear state,
    /// capabilities, and an IMU stream the engine can consume.
    func testMockDeviceConnectsAndStreamsIMU() {
        let device = MockGlassesDevice(name: "Ray-Ban Meta (mock)", loopSamples: walkingSamples())
        XCTAssertEqual(device.connectionState, .disconnected)
        XCTAssertEqual(device.wearState, .unknown)

        var changes = 0
        device.onStateChange = { _ in changes += 1 }
        device.connect()
        XCTAssertEqual(device.connectionState, .connected)
        XCTAssertEqual(device.wearState, .worn, "the mock dons the glasses on connect")
        XCTAssertTrue(device.capabilities.imu)
        XCTAssertEqual(device.capabilities.imuSampleRateHz, 50)
        XCTAssertGreaterThan(changes, 0)

        var received: [IMUSample] = []
        device.motion.start { received.append($0) }
        XCTAssertTrue(device.motion.isActive)
        for _ in 0..<120 { device.pumpOneSample() }
        XCTAssertEqual(received.count, 120)
        XCTAssertGreaterThan(received[119].timestamp, received[0].timestamp)
        device.motion.stop()
        XCTAssertFalse(device.motion.isActive)
    }

    func testMockDeviceLoopsItsSamplesWithMonotonicTime() {
        let short = Array(walkingSamples().prefix(50))
        let device = MockGlassesDevice(name: "mock", loopSamples: short)
        device.connect()
        var stamps: [Double] = []
        device.motion.start { stamps.append($0.timestamp) }
        for _ in 0..<130 { device.pumpOneSample() }
        XCTAssertEqual(stamps.count, 130)
        XCTAssertEqual(stamps, stamps.sorted())
        XCTAssertEqual(Set(stamps).count, 130, "time never repeats across the loop seam")
    }

    func testMockCameraReturnsAFrameOrAClearError() {
        let withCamera = MockGlassesDevice(name: "mock", loopSamples: [], frame: Data([0xFF, 0xD8]))
        withCamera.connect()
        var captured: Result<Data, GlassesError>?
        withCamera.captureFrame { captured = $0 }
        XCTAssertEqual(try captured?.get(), Data([0xFF, 0xD8]))

        let noCamera = MockGlassesDevice(name: "mock", loopSamples: [], frame: nil)
        noCamera.connect()
        var failed: Result<Data, GlassesError>?
        noCamera.captureFrame { failed = $0 }
        if case .failure(let error) = failed {
            XCTAssertEqual(error, .cameraUnavailable)
        } else {
            XCTFail("expected a camera error")
        }

        let disconnected = MockGlassesDevice(name: "mock", loopSamples: [], frame: Data([1]))
        var offline: Result<Data, GlassesError>?
        disconnected.captureFrame { offline = $0 }
        if case .failure(let error) = offline {
            XCTAssertEqual(error, .notConnected)
        } else {
            XCTFail("a disconnected device cannot take a photo")
        }
    }

    /// Glasses motion goes through the same engine as phone motion and the
    /// calibrated detector cues on the freeze capture.
    func testGlassesMotionReachesTheDetector() {
        let freeze = LabeledCaptureLibrary.referenceCaptures().first { $0.label == .freeze }!.samples
        let device = MockGlassesDevice(
            name: "mock",
            loopSamples: LabeledCaptureLibrary.concatenate([walkingSamples(), freeze], sampleRateHz: 50)
        )
        device.connect()
        let feed = MotionFeed()
        feed.attach(fogDetector: FoGDetector(), fallDetector: FallDetector())

        XCTAssertTrue(feed.start(source: device.motion, label: device.name) { nil })
        XCTAssertEqual(feed.activeSourceLabel, "mock")
        for _ in 0..<(walkingSamples().count + freeze.count) { device.pumpOneSample() }
        XCTAssertTrue(feed.isFoGActive, "the freeze must cue through the glasses stream")
        AudioCueEngine.shared.stopRASMetronome()
        feed.stopSource()
        XCTAssertFalse(device.motion.isActive)
    }
}

@MainActor
final class GlassesSessionManagerTests: XCTestCase {
    func testWithoutGlassesThePhoneIsTheMotionSource() {
        let phone = MockMotionSource(available: true)
        let session = GlassesSessionManager(phoneMotion: phone)
        XCTAssertEqual(session.connectionState, .notPaired)
        XCTAssertTrue(session.preferredMotionSource === phone)
        XCTAssertEqual(session.preferredSourceLabel, "iPhone")
        XCTAssertNil(session.isWorn, "no glasses means wear state is unknown")
    }

    func testConnectedGlassesWithIMUBecomeTheSource() {
        let phone = MockMotionSource(available: true)
        let walking = LabeledCaptureLibrary.referenceCaptures().first { $0.label == .walking }!.samples
        let device = MockGlassesDevice(name: "Ray-Ban Meta (mock)", loopSamples: walking)
        let session = GlassesSessionManager(phoneMotion: phone)
        session.attach(device)
        XCTAssertEqual(session.connectionState, .disconnected)
        XCTAssertTrue(session.preferredMotionSource === phone, "disconnected glasses do not steal the stream")

        session.connect()
        XCTAssertEqual(session.connectionState, .connected)
        XCTAssertEqual(session.wearState, .worn)
        XCTAssertTrue(session.preferredMotionSource === device.motion)
        XCTAssertEqual(session.preferredSourceLabel, "Ray-Ban Meta (mock)")
        XCTAssertEqual(session.isWorn, true)

        device.setWearState(.notWorn)
        XCTAssertEqual(session.wearState, .notWorn)
        XCTAssertEqual(session.isWorn, false)

        session.disconnect()
        XCTAssertEqual(session.connectionState, .disconnected)
        XCTAssertTrue(session.preferredMotionSource === phone)
    }

    func testGlassesWithoutIMUFallBackToThePhone() {
        let phone = MockMotionSource(available: true)
        let device = MockGlassesDevice(
            name: "mock", loopSamples: [],
            capabilities: GlassesCapabilities(imu: false, microphone: true, camera: true, audioOutput: true, imuSampleRateHz: nil)
        )
        let session = GlassesSessionManager(phoneMotion: phone)
        session.attach(device)
        session.connect()
        XCTAssertTrue(session.preferredMotionSource === phone)
        XCTAssertEqual(session.preferredSourceLabel, "iPhone")
    }
}

@MainActor
final class WearStateOnFallCheckInTests: XCTestCase {
    /// The coordinator holds its wear-state source weakly; the test owns it.
    private var wear: FixedWearState?

    private func makeCoordinator(wear: FixedWearState) -> (FallAlertCoordinator, EventSyncManager) {
        self.wear = wear
        let sync = EventSyncManager(
            databasePath: NSTemporaryDirectory() + "wear-\(UUID().uuidString).sqlite",
            startPeriodicDrain: false
        )
        let c = FallAlertCoordinator(
            screen: NoopScreenController(), dialer: RecordingPhoneDialer(), sync: sync,
            locationProvider: MockLocationProvider(), speechListener: MockSpeechCheckInListener(),
            checkInWindow: 0.05
        )
        c.wearStateProvider = wear
        return (c, sync)
    }

    /// Suppression is off by default, so glasses that report "not worn" still
    /// escalate on silence. A dropped pair must never silence a real fall.
    func testNotWornStillEscalatesWhileSuppressionIsDisabled() async {
        let (c, _) = makeCoordinator(wear: FixedWearState(isWorn: false))
        c.beginCheckIn(eventUUID: "wear-off-001")
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(c.isDispatched)
        XCTAssertEqual(c.lastOutcome, "confirmed_waiting_dispatch")
        AudioCueEngine.shared.deactivateBystanderSiren()
    }

    /// With the calibrated gate explicitly enabled, "not worn" plus total
    /// silence is recorded as a dropped pair rather than a fall.
    func testNotWornWithSuppressionEnabledAndSilenceIsSuppressed() async {
        let (c, _) = makeCoordinator(wear: FixedWearState(isWorn: false))
        c.detector.enableUnwornDropSuppression = true
        c.beginCheckIn(eventUUID: "wear-off-002")
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(c.isDispatched)
        XCTAssertEqual(c.lastOutcome, "suppressed_unworn_drop")
    }

    /// Worn glasses with the gate enabled escalate as usual.
    func testWornWithSuppressionEnabledEscalates() async {
        let (c, _) = makeCoordinator(wear: FixedWearState(isWorn: true))
        c.detector.enableUnwornDropSuppression = true
        c.beginCheckIn(eventUUID: "wear-on-001")
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(c.isDispatched)
        AudioCueEngine.shared.deactivateBystanderSiren()
    }

    /// Unknown wear state (no glasses) is treated as worn: fail safe.
    func testUnknownWearStateIsTreatedAsWorn() async {
        let (c, _) = makeCoordinator(wear: FixedWearState(isWorn: nil))
        c.detector.enableUnwornDropSuppression = true
        c.beginCheckIn(eventUUID: "wear-unknown-001")
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(c.isDispatched)
        AudioCueEngine.shared.deactivateBystanderSiren()
    }
}

/// Test doubles.
final class MockMotionSource: MotionSource {
    let isAvailable: Bool
    private(set) var isActive = false
    init(available: Bool) { isAvailable = available }
    func start(_ onSample: @escaping (IMUSample) -> Void) { isActive = true }
    func stop() { isActive = false }
}

final class FixedWearState: WearStateProviding {
    let isWorn: Bool?
    init(isWorn: Bool?) { self.isWorn = isWorn }
}
