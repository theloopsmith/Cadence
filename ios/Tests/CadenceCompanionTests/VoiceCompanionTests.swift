import XCTest
@testable import CadenceCompanion

private final class CompanionEcho: EchoGuarding {
    var active = false
    func isInEchoWindow(at date: Date) -> Bool { active }
}

private final class UnavailableTranscript: TranscriptListening {
    var isListening: Bool { false }
    var failureReason: String? { "The glasses microphone has no usable audio input." }
    func startListening(onTranscript: @escaping (String) -> Void) {}
    func stopListening() {}
}

private final class DelayedReleaseTranscript: TranscriptListening {
    var isListening = false
    var waitsForMicrophoneReleaseBeforeSpeech: Bool { true }
    var onWait: (() -> Void)?
    var release: CheckedContinuation<Void, Never>?
    func startListening(onTranscript: @escaping (String) -> Void) { isListening = true }
    func stopListening() { isListening = false }
    func waitUntilStopped() async {
        await withCheckedContinuation { continuation in
            release = continuation
            onWait?()
        }
    }
}

@MainActor
final class VoiceCompanionTests: XCTestCase {
    func testStartupFailureKeepsActualMicrophoneReasonAndRetryPreference() async throws {
        let voice = VoiceCompanion(listener: UnavailableTranscript(), speaker: SpokenLog(), echo: CompanionEcho(),
                                   promptDelaySeconds: 0.001, listenerHealthDelaySeconds: 0.005)
        voice.start()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(voice.isEnabled)
        XCTAssertTrue(voice.preservesVoicePreferenceOnStop)
        XCTAssertEqual(voice.status, "The glasses microphone has no usable audio input.")
    }

    func testStartingWhilePausedExplainsPauseAndResumesWhenReleased() async throws {
        let listener = MockTranscriptListener()
        let voice = VoiceCompanion(listener: listener, speaker: SpokenLog(), echo: CompanionEcho(), promptDelaySeconds: 0.001)
        defer { voice.stop() }
        voice.setPaused("App in background", true)
        voice.start()
        XCTAssertEqual(voice.status, "Voice paused: App in background")
        XCTAssertEqual(listener.startCount, 0)
        voice.setPaused("App in background", false)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertTrue(listener.isListening)
    }
    func testHandoffAndMicrophoneFailureCanPreserveSetupButExplicitStopDoesNot() {
        let (voice, _, _) = make()
        voice.start()
        voice.submit("let me use Meta")
        XCTAssertTrue(voice.preservesVoicePreferenceOnStop)
        voice.start()
        voice.submit("stop listening")
        XCTAssertFalse(voice.preservesVoicePreferenceOnStop)
    }
    func testAReplyDroppedByWalkingCuesIsReportedNotShownAsSpeaking() async {
        let (voice, log, _) = make()
        voice.start()
        for _ in 0..<4 { await Task.yield() }
        let greetings = log.spoken.count
        log.refusesSpeech = true
        voice.say("Opening your motor check.")
        for _ in 0..<4 { await Task.yield() }
        XCTAssertEqual(log.spoken.count, greetings, "the dropped reply must not be logged as spoken")
        XCTAssertNotEqual(voice.status, "Speaking")
        XCTAssertTrue(voice.status.lowercased().contains("walking cues"), voice.status)
    }

    private func make() -> (VoiceCompanion, SpokenLog, CompanionEcho) {
        let log = SpokenLog(); let echo = CompanionEcho()
        return (VoiceCompanion(listener: MockTranscriptListener(), speaker: log, echo: echo), log, echo)
    }

    func testNaturalRequestsRouteAndDoNotConfuseStartWithStartingAFeature() {
        for (text, intent) in [
            ("I want to do a motor exam", CompanionIntent.motor),
            ("Start a motor check!", .motor), ("Help with my medications", .medication),
            ("I need help with my surroundings", .surroundings), ("call 911", .emergency),
            ("please do not call my caregiver", .cancel), ("I haven't taken my medication", .cancel),
            ("I didn't quite get that", .unknown),
            ("help with medication or surroundings", .help), ("I'm ready", .start)
        ] { XCTAssertEqual(CompanionIntent.parse(text), intent, text) }
    }

    func testPlainHelpAsksWhichKindAndNeverCallsAnyone() {
        let (voice, log, _) = make(); defer { voice.stop() }
        var effects: [CompanionIntent] = []
        voice.execute = { effects.append($0); return "result" }
        voice.start(); voice.submit("I need help")
        XCTAssertTrue(log.spoken.last?.contains("What do you need help with") == true)
        XCTAssertTrue(effects.isEmpty)
        voice.submit("medications")
        XCTAssertEqual(voice.destination, .medication)
        XCTAssertEqual(effects, [.medication])
    }

    func testMedicationRequiresFreshConfirmationAndRepeatedYesDoesNotLogTwice() {
        let (voice, _, _) = make(); defer { voice.stop() }
        var effects: [CompanionIntent] = []
        voice.execute = { effects.append($0); return "Recorded locally" }
        voice.start(); voice.submit("I took my medication yes")
        XCTAssertTrue(effects.isEmpty)
        voice.submit("Yes, please.")
        XCTAssertEqual(effects, [.logDose])
        voice.submit("yes")
        XCTAssertEqual(effects, [.logDose])
    }

    func testUnclearOrNegativeConfirmationNeverWritesOrCalls() {
        let (voice, _, _) = make(); defer { voice.stop() }
        var effects: [CompanionIntent] = []
        voice.execute = { effects.append($0); return "result" }
        voice.start(); voice.submit("call my caregiver"); voice.submit("maybe yes")
        voice.submit("I took my pill"); voice.submit("no")
        XCTAssertTrue(effects.isEmpty)
    }

    func testSafetyAndBackgroundPausesCannotBeClearedByOtherFlows() {
        let (voice, _, _) = make(); defer { voice.stop() }
        var effects: [CompanionIntent] = []
        voice.execute = { effects.append($0); return "result" }
        voice.start(); voice.submit("call 911")
        voice.setPaused("Safety check-in", true)
        voice.setPaused("App in background", true)
        voice.setPaused("App in background", false)
        voice.submit("yes")
        XCTAssertTrue(effects.isEmpty)
        voice.setPaused("Safety check-in", false)
        voice.submit("yes")
        XCTAssertTrue(effects.isEmpty, "Returning from a pause must not revive a stale confirmation")
    }

    func testAppSpeechCannotAnswerItsOwnQuestion() {
        let (voice, _, echo) = make(); defer { voice.stop() }
        var effects: [CompanionIntent] = []
        voice.execute = { effects.append($0); return "result" }
        voice.start(); voice.submit("I took my pill")
        echo.active = true; voice.submit("yes")
        XCTAssertTrue(effects.isEmpty)
        echo.active = false; voice.submit("yes")
        XCTAssertEqual(effects, [.logDose])
    }

    func testContextualPhotoCommandsAreActionsInsteadOfOpeningAnotherFeature() {
        let (voice, _, _) = make(); defer { voice.stop() }
        voice.start(); voice.submit("check my surroundings")
        voice.setContext(.surroundings)
        voice.submit("take a photo")
        XCTAssertEqual(voice.action, .capture)
        voice.setContext(.camera); voice.submit("use this photo")
        XCTAssertEqual(voice.action, .usePhoto)
    }

    func testStoppedCompanionIgnoresLateTranscripts() {
        let (voice, _, _) = make()
        voice.start(); voice.stop(); voice.submit("start a motor exam")
        XCTAssertNil(voice.destination)
        XCTAssertFalse(voice.isEnabled)
    }

    func testCancelingConfirmationDoesNotCancelCurrentTask() {
        let (voice, _, _) = make(); defer { voice.stop() }
        voice.start()
        voice.enterFlow(id: UUID(), destination: .motor, step: .handwriting)
        let previousAction = voice.actionID
        voice.submit("call my caregiver")
        voice.submit("cancel")
        XCTAssertEqual(voice.actionID, previousAction)
        XCTAssertEqual(voice.context, .motor)
    }

    func testCameraCancelKeepsOriginalActionContextAfterCameraCloses() {
        let (voice, _, _) = make(); defer { voice.stop() }
        let motor = UUID(), camera = UUID()
        voice.start()
        voice.enterFlow(id: motor, destination: .motor, step: .handwriting)
        voice.enterFlow(id: camera, destination: .camera, step: .photoReview)
        voice.submit("cancel")
        voice.leaveFlow(id: camera)
        XCTAssertEqual(voice.context, .motor)
        XCTAssertEqual(voice.actionContext, .camera)
    }

    func testConfirmationExpiryCannotBeRevivedByALateYes() async throws {
        let log = SpokenLog(); let echo = CompanionEcho()
        let voice = VoiceCompanion(listener: MockTranscriptListener(), speaker: log, echo: echo,
                                   promptDelaySeconds: 0.001, confirmationWindowSeconds: 0.01)
        defer { voice.stop() }
        var effects: [CompanionIntent] = []
        voice.execute = { effects.append($0); return "result" }
        voice.start(); voice.submit("call my caregiver")
        try await Task.sleep(nanoseconds: 80_000_000)
        voice.submit("yes")
        XCTAssertTrue(effects.isEmpty)
        XCTAssertTrue(log.spoken.contains { $0.contains("timed out") })
    }

    func testGrowingPartialTranscriptsAreDebouncedBeforeAnyAction() async throws {
        let listener = MockTranscriptListener(); let echo = CompanionEcho()
        let voice = VoiceCompanion(listener: listener, speaker: SpokenLog(), echo: echo,
                                   debounceSeconds: 0.02, promptDelaySeconds: 0.001)
        defer { voice.stop() }
        voice.start()
        try await Task.sleep(nanoseconds: 20_000_000)
        listener.hear("I took my medication")
        listener.hear("I haven't taken my medication")
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(voice.action, .cancel)
        XCTAssertEqual(voice.lastHeard, "I haven't taken my medication")
    }

    func testLateMetaInterpretationCannotStartAFlowAfterSafetyPreemption() async {
        let (voice, _, _) = make(); defer { voice.stop() }
        let started = expectation(description: "Meta interpretation started")
        var answer: CheckedContinuation<CompanionIntent?, Never>?
        voice.understand = { _, _ in
            await withCheckedContinuation { answer = $0; started.fulfill() }
        }
        voice.start(); voice.submit("Could we check how I'm moving today?")
        await fulfillment(of: [started], timeout: 1)
        voice.setPaused("Safety check-in", true)
        answer?.resume(returning: .motor)
        await Task.yield(); await Task.yield()
        XCTAssertNil(voice.destination)
    }

    func testPhotoReviewKeepsThePhotoAndAcceptsShortConfirmation() async throws {
        let (voice, log, _) = make(); defer { voice.stop() }
        let parent = UUID(), camera = UUID()
        voice.start()
        voice.enterFlow(id: parent, destination: .surroundings, step: .surroundings)
        voice.enterFlow(id: camera, destination: .camera, step: .photoReview)
        voice.submit("huh?")
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(voice.context, .camera)
        XCTAssertEqual(voice.step, .photoReview)
        XCTAssertTrue(log.spoken.last?.contains("I still have your photo") == true)
        voice.submit("Use it")
        XCTAssertEqual(voice.action, .usePhoto)
        voice.leaveFlow(id: camera)
        XCTAssertEqual(voice.context, .surroundings)
        XCTAssertEqual(voice.step, .surroundings)
    }

    func testCoveredMotorStepCannotStealCameraAndReturnsToWriting() async throws {
        let (voice, log, _) = make(); defer { voice.stop() }
        let motor = UUID(), camera = UUID()
        voice.start()
        voice.enterFlow(id: motor, destination: .motor, step: .handwriting)
        voice.enterFlow(id: camera, destination: .camera, step: .photoReview)
        voice.updateFlow(id: motor, step: .walkReady)
        XCTAssertEqual(voice.context, .camera)
        voice.submit("what now")
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertTrue(log.spoken.last?.contains("I still have your photo") == true)
        voice.leaveFlow(id: camera)
        XCTAssertEqual(voice.context, .motor)
        XCTAssertEqual(voice.step, .walkReady)
        voice.submit("I didn't quite get that")
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertTrue(log.spoken.last?.contains("walking step") == true)
        voice.submit("yes")
        XCTAssertEqual(voice.action, .start)
    }

    func testLeavingCoveredParentDoesNotResurrectIt() {
        let (voice, _, _) = make(); defer { voice.stop() }
        let motor = UUID(), camera = UUID()
        voice.start()
        voice.enterFlow(id: motor, destination: .motor, step: .handwriting)
        voice.enterFlow(id: camera, destination: .camera, step: .photoReview)
        voice.leaveFlow(id: motor)
        XCTAssertEqual(voice.context, .camera)
        voice.leaveFlow(id: camera)
        XCTAssertNil(voice.context)
    }

    func testThreeMotorStepsNeverFallBackToOpeningMenu() async throws {
        let (voice, log, _) = make(); defer { voice.stop() }
        let motor = UUID(), camera = UUID()
        voice.start()
        voice.enterFlow(id: motor, destination: .motor, step: .motorIntro)
        voice.submit("start")
        XCTAssertEqual(voice.action, .start)
        voice.updateFlow(id: motor, step: .motorVoiceReady)
        voice.submit("ready")
        XCTAssertEqual(voice.action, .start)
        voice.updateFlow(id: motor, step: .handwriting)
        voice.submit("take a photo")
        XCTAssertEqual(voice.action, .capture)
        voice.enterFlow(id: camera, destination: .camera, step: .photoReview)
        voice.submit("yes")
        XCTAssertEqual(voice.action, .usePhoto)
        voice.leaveFlow(id: camera)
        voice.updateFlow(id: motor, step: .walkReady)
        voice.submit("garbled")
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(voice.context, .motor)
        XCTAssertTrue(log.spoken.last?.contains("walking step") == true)
    }

    func testMetaHandoffStopsConversationBeforeReleasingDevice() {
        let (voice, _, _) = make()
        var released = false
        voice.onMetaHandoff = { released = !voice.isEnabled }
        voice.start(); voice.submit("let me use Meta")
        XCTAssertTrue(released)
        XCTAssertFalse(voice.isEnabled)
        XCTAssertEqual(voice.action, .unknown)
    }

    func testStepChangeRejectsLateMetaInterpretation() async {
        let (voice, _, _) = make(); defer { voice.stop() }
        let started = expectation(description: "interpretation started")
        var answer: CheckedContinuation<CompanionIntent?, Never>?
        voice.understand = { _, _ in await withCheckedContinuation { answer = $0; started.fulfill() } }
        let motor = UUID()
        voice.start(); voice.enterFlow(id: motor, destination: .motor, step: .motorIntro)
        voice.submit("maybe something else")
        await fulfillment(of: [started], timeout: 1)
        voice.updateFlow(id: motor, step: .handwriting)
        answer?.resume(returning: .surroundings)
        await Task.yield(); await Task.yield()
        XCTAssertNil(voice.destination)
        XCTAssertEqual(voice.step, .handwriting)
    }

    func testPromptWaitsForMicrophoneToCloseAndStopCancelsIt() async {
        let listener = DelayedReleaseTranscript()
        let spoken = SpokenLog()
        let voice = VoiceCompanion(listener: listener, speaker: spoken, echo: CompanionEcho())
        let waiting = expectation(description: "microphone closure awaited")
        listener.onWait = { waiting.fulfill() }
        voice.start()
        await fulfillment(of: [waiting], timeout: 1)
        XCTAssertTrue(spoken.spoken.isEmpty)
        voice.stop()
        listener.release?.resume()
        await Task.yield(); await Task.yield()
        XCTAssertTrue(spoken.spoken.isEmpty)
    }
}
