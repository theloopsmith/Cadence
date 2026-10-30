import XCTest
@testable import CadenceCompanion

final class PromptArbiterTests: XCTestCase {
    func testEmergencyPreemptsAndOldCompletionCannotClearReplacement() throws {
        var policy = PromptArbiter()
        let old = try XCTUnwrap(policy.request("Scene description", priority: 2, now: 0))
        let emergency = try XCTUnwrap(policy.request("Are you okay?", priority: 0, now: 1))
        policy.finished(old.id)
        XCTAssertEqual(policy.active, emergency)
        XCTAssertNil(policy.request("Step to the beat", priority: 1, now: 2))
        policy.finished(emergency.id)
        XCTAssertNil(policy.active)
    }

    func testNoSpeechBacklogAndCueCooldownAcrossEpisodes() throws {
        var policy = PromptArbiter()
        let first = try XCTUnwrap(policy.request("Step to the beat", priority: 1, now: 100, cue: true))
        XCTAssertNil(policy.request("Step to the beat", priority: 1, now: 101, cue: true))
        XCTAssertTrue(policy.cancel(priority: 1))
        XCTAssertNil(policy.request("Step to the beat", priority: 1, now: 110, cue: true))
        let next = try XCTUnwrap(policy.request("Step to the beat", priority: 1, now: 146, cue: true))
        XCTAssertNotEqual(first.id, next.id)
        policy.finished(first.id)
        XCTAssertEqual(policy.active, next)
    }

    func testEqualPriorityReplacesInsteadOfQueueingAndCancelIsScoped() throws {
        var policy = PromptArbiter()
        _ = policy.request("First", priority: 2, now: 0)
        let second = try XCTUnwrap(policy.request("Second", priority: 2, now: 1))
        XCTAssertEqual(policy.active, second)
        XCTAssertFalse(policy.cancel(priority: 1))
        XCTAssertEqual(policy.active, second)
        XCTAssertTrue(policy.cancel())
    }
}

final class AudioRecoveryTests: XCTestCase {
    func testInterruptionClearsSpeechAndDoesNotResumeWithoutPermission() {
        let audio = AudioCueEngine(playbackEnabled: false)
        audio.startRASMetronome()
        XCTAssertEqual(audio.activePromptText, "Step to the beat")
        audio.interruptionBegan()
        XCTAssertNil(audio.activePromptText)
        XCTAssertFalse(audio.isAudioAvailable)
        audio.interruptionEnded(shouldResume: false)
        XCTAssertFalse(audio.isAudioAvailable)
        audio.speakPrompt("Should not play")
        XCTAssertNil(audio.activePromptText)
        audio.retryAudio()
        XCTAssertTrue(audio.isAudioAvailable)
        XCTAssertTrue(audio.isMetronomeActive)
        XCTAssertNil(audio.activePromptText, "resuming PCM must not replay old speech")
        audio.stopRASMetronome()
    }

    func testStoppedCueCannotRestartAfterInterruptionAndSirenPreemptsSpeech() {
        let audio = AudioCueEngine(playbackEnabled: false)
        audio.speakPrompt("Long scene description")
        audio.activateBystanderSiren()
        XCTAssertNil(audio.activePromptText)
        audio.stopRASMetronome()
        XCTAssertTrue(audio.isSirenActive, "stale walking stop cannot clear emergency intent")
        audio.interruptionBegan()
        audio.deactivateBystanderSiren()
        audio.interruptionEnded(shouldResume: true)
        XCTAssertFalse(audio.isSirenActive)
        XCTAssertFalse(audio.isMetronomeActive)
    }

    func testResetRequiresExplicitRetryAndFailedRestartRemainsUnavailable() {
        enum Failure: Error { case unavailable }
        var fail = true
        let audio = AudioCueEngine(playbackEnabled: false, engineStarter: { if fail { throw Failure.unavailable } })
        audio.mediaServicesReset()
        XCTAssertFalse(audio.isAudioAvailable)
        audio.retryAudio()
        XCTAssertFalse(audio.isAudioAvailable)
        XCTAssertNotNil(audio.audioProblem)
        fail = false
        audio.retryAudio()
        XCTAssertTrue(audio.isAudioAvailable)
        XCTAssertNil(audio.audioProblem)
    }

    func testStoppingCueCancelsSpeechButPreservesEmergencyPrompt() {
        let audio = AudioCueEngine(playbackEnabled: false)
        audio.startRASMetronome()
        audio.stopRASMetronome()
        XCTAssertNil(audio.activePromptText)
        audio.speakPrompt("Are you okay?", priority: 0)
        audio.cancelNonEmergencySpeech()
        XCTAssertEqual(audio.activePromptText, "Are you okay?")
        audio.cancelSpeech()
        XCTAssertNil(audio.activePromptText)
    }

    func testOrdinaryHeadphonesAreNotClassifiedAsGlasses() {
        XCTAssertFalse(AudioRouteManager.isGlassesName("AirPods Pro"))
        XCTAssertFalse(AudioRouteManager.isGlassesName("Bluetooth LE Headset"))
        XCTAssertTrue(AudioRouteManager.isGlassesName("Ray-Ban Meta"))
    }

    func testResetDuringInterruptionCannotAutoResumeOrReopenMicrophone() {
        let audio = AudioCueEngine(playbackEnabled: false)
        audio.interruptionBegan()
        XCTAssertFalse(audio.prepareMicrophoneSession())
        audio.mediaServicesReset()
        audio.interruptionEnded(shouldResume: true)
        XCTAssertFalse(audio.isAudioAvailable)
        XCTAssertFalse(audio.prepareMicrophoneSession())
        audio.retryAudio()
        XCTAssertTrue(audio.isAudioAvailable)
        XCTAssertTrue(audio.prepareMicrophoneSession())
    }

    func testInterruptedAffirmationCannotCancelButDistressSurvives() {
        var evidence = DualRecognizerCheckIn()
        evidence.record("I'm okay", from: .local)
        XCTAssertFalse(evidence.transcriptForResolution.isEmpty)
        evidence.invalidateAffirmations()
        XCTAssertEqual(evidence.transcriptForResolution, "")
        evidence.record("help", from: .cloud)
        evidence.invalidateAffirmations()
        XCTAssertEqual(evidence.transcriptForResolution, "help")
    }

    func testDisconnectDoesNotUnexpectedlyResumeOnAnotherSpeaker() {
        let audio = AudioCueEngine(playbackEnabled: false)
        audio.startRASMetronome()
        audio.outputDeviceDisconnected()
        XCTAssertFalse(audio.isAudioAvailable)
        XCTAssertNil(audio.activePromptText)
        audio.interruptionBegan()
        audio.interruptionEnded(shouldResume: true)
        XCTAssertFalse(audio.isAudioAvailable, "a later call ending cannot undo an explicit route-loss pause")
        audio.stopRASMetronome()
        audio.retryAudio()
        XCTAssertTrue(audio.isAudioAvailable)
        XCTAssertFalse(audio.isMetronomeActive)
    }
}

private final class ControlledMotionSource: MotionSource {
    var isAvailable = true
    var isActive = false
    var callback: ((IMUSample) -> Void)?
    func start(_ onSample: @escaping (IMUSample) -> Void) { isActive = true; callback = onSample }
    func stop() { isActive = false }
    func emit(_ timestamp: Double, ay: Double = 1) {
        callback?(IMUSample(timestamp: timestamp, ax: 0, ay: ay, az: 0, gx: 0, gy: 0, gz: 0))
    }
}

@MainActor
final class ProtectionHealthTests: XCTestCase {
    func testStreamGapDiscardsPartialFallButPreservesActiveCheckIn() {
        let detector = FallDetector()
        detector.eventSync = EventSyncManager(databasePath: NSTemporaryDirectory() + "partial-\(UUID()).sqlite", startPeriodicDrain: false)
        let fall = [
            IMUSample(timestamp:1,ax:0.1,ay:0.1,az:0.1,gx:0,gy:0,gz:0,pitchDeg:4,rollDeg:2),
            IMUSample(timestamp:1.1,ax:0.2,ay:3.85,az:0.3,gx:3,gy:2,gz:1,pitchDeg:25,rollDeg:10),
            IMUSample(timestamp:1.8,ax:0.98,ay:0.15,az:0.05,gx:0.01,gy:0.01,gz:0.01,pitchDeg:76,rollDeg:4)
        ]
        _ = detector.processIMUSample(fall[0])
        detector.resetForStreamGap()
        if case .monitoring = detector.stage {} else { XCTFail("partial fall must reset") }
        for sample in fall { _ = detector.processIMUSample(sample) }
        if case .stage3CheckInActive = detector.stage {} else { XCTFail("expected sensor-driven check-in") }
        detector.resetForStreamGap()
        if case .stage3CheckInActive = detector.stage {} else { XCTFail("gap must not cancel an active check-in") }
        detector.resetAfterResolution()
        AudioCueEngine.shared.cancelSpeech()
    }

    func testFreshnessExpiresWithoutSamplesAndDuplicateOrInvalidInputCannotHideIt() {
        var now = 0.0
        let feed = MotionFeed(uptime: { now }, automaticHealthChecks: false)
        feed.attach(fogDetector: FoGDetector(), fallDetector: FallDetector())
        let source = ControlledMotionSource()
        XCTAssertTrue(feed.start(source: source, label: "test") { nil })
        XCTAssertEqual(feed.health, .starting)
        source.emit(10)
        XCTAssertEqual(feed.health, .healthy)
        now = 3
        source.emit(10) // duplicated timestamp
        source.emit(11, ay: .nan)
        feed.checkHealth()
        XCTAssertEqual(feed.health, .stale)
        source.emit(12)
        XCTAssertEqual(feed.health, .healthy)
        source.isActive = false
        feed.checkHealth()
        XCTAssertEqual(feed.health, .stale)
    }

    func testRetiredSourceCallbacksCannotRestoreProtection() {
        let feed = MotionFeed(automaticHealthChecks: false)
        feed.attach(fogDetector: FoGDetector(), fallDetector: FallDetector())
        let first = ControlledMotionSource(), second = ControlledMotionSource()
        _ = feed.start(source: first, label: "A") { nil }
        let retired = first.callback
        _ = feed.start(source: second, label: "B") { nil }
        retired?(IMUSample(timestamp: 30, ax: 0, ay: 1, az: 0, gx: 0, gy: 0, gz: 0))
        XCTAssertEqual(feed.samplesSeen, 0)
        XCTAssertEqual(feed.health, .starting)
        feed.stopSource()
        second.emit(31)
        XCTAssertEqual(feed.samplesSeen, 0)
        XCTAssertEqual(feed.health, .off)
    }

    func testStaleFreezeStopsAudioAndClearsArmingWithoutLoggingRecovery() {
        var now = 0.0
        let feed = MotionFeed(uptime: { now }, automaticHealthChecks: false)
        let detector = FoGDetector()
        let queue = EventSyncManager(databasePath: NSTemporaryDirectory() + "gap-\(UUID()).sqlite", startPeriodicDrain: false)
        detector.eventSync = queue
        feed.attach(fogDetector: detector, fallDetector: FallDetector())
        let source = ControlledMotionSource()
        _ = feed.start(source: source, label: "test") { nil }
        let captures = LabeledCaptureLibrary.referenceCaptures()
        let samples = LabeledCaptureLibrary.concatenate([
            captures.first { $0.label == .walking }!.samples,
            captures.first { $0.label == .freeze }!.samples
        ], sampleRateHz: 50)
        samples.forEach { source.callback?($0) }
        XCTAssertTrue(detector.isEpisodeActive)
        XCTAssertTrue(AudioCueEngine.shared.isMetronomeActive)
        now = 3
        feed.checkHealth()
        XCTAssertEqual(feed.health, .stale)
        XCTAssertFalse(detector.isEpisodeActive)
        XCTAssertEqual(detector.armingMode, .disarmed)
        XCTAssertFalse(AudioCueEngine.shared.isMetronomeActive)
        XCTAssertEqual(queue.pendingCount(), 0, "input loss is not an observed recovery")
    }

    func testWalkingStatusRequiresFreshSamplesAndWorkingAudio() {
        var now = 0.0
        let feed = MotionFeed(uptime: { now }, automaticHealthChecks: false)
        let source = ControlledMotionSource()
        let audio = AudioCueEngine(playbackEnabled: false)
        let fall = FallAlertCoordinator(screen: NoopScreenController(), dialer: RecordingPhoneDialer(),
            sync: EventSyncManager(databasePath: NSTemporaryDirectory() + "health-\(UUID()).sqlite", startPeriodicDrain: false),
            locationProvider: MockLocationProvider(), speechListener: MockSpeechCheckInListener())
        let keepAlive = RecordingKeepAlive()
        let model = WalkingModel(motion: feed, fallAlert: fall, location: MockLocationProvider(),
            glasses: GlassesSessionManager(phoneMotion: source), keepAlive: keepAlive, audio: audio)
        model.setProtection(enabled: true)
        XCTAssertTrue(model.isProtectionRequested)
        XCTAssertFalse(model.isProtectionOn)
        source.emit(1)
        model.refreshProtectionHealth()
        XCTAssertTrue(model.isProtectionOn)
        audio.interruptionBegan()
        model.refreshProtectionHealth()
        XCTAssertFalse(model.isProtectionOn)
        audio.interruptionEnded(shouldResume: true)
        model.refreshProtectionHealth()
        XCTAssertTrue(model.isProtectionOn)
        now = 3
        model.refreshProtectionHealth()
        XCTAssertFalse(model.isProtectionOn)
        XCTAssertTrue(model.isProtectionRequested, "the wearer must still be able to turn a degraded stream off")
        model.stopWalkingAudio()
        XCTAssertFalse(model.isProtectionRequested)
        XCTAssertFalse(feed.isRunning)
        XCTAssertFalse(keepAlive.isActive)
    }
}
