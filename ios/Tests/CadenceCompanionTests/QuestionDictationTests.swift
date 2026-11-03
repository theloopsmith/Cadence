import Combine
import XCTest
@testable import CadenceCompanion

private final class QuestionListenerFixture: TranscriptListening {
    var isListening = false
    var ready = true
    var isReady: Bool { isListening && ready }
    var failureReason: String?
    var starts = 0
    var dictationStarts = 0
    var callbacks: [(String) -> Void] = []
    var mixedCallback: ((String) -> Void)?
    func startListening(onTranscript: @escaping (String) -> Void) {
        starts += 1; isListening = true; callbacks.append(onTranscript); mixedCallback = onTranscript
    }
    func startQuestionDictation(onTranscript: @escaping (String) -> Void) {
        dictationStarts += 1; isListening = true; callbacks.append(onTranscript)
    }
    func stopListening() { isListening = false }
    func hear(_ text: String) { callbacks.last?(text) }
}

@MainActor
final class QuestionDictationTests: XCTestCase {
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while !condition(), ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(condition())
    }

    func testQuestionUsesOneCumulativeSourceAndIgnoresRollingCloudChunks() async throws {
        let listener = QuestionListenerFixture()
        let input = QuestionDictation(listener: listener, permission: { nil }, acquire: {}, release: {}, silenceTimeout: 1)
        defer { input.stop() }
        input.start(); try await wait { input.phase == .listening }
        XCTAssertEqual(listener.starts, 0)
        XCTAssertEqual(listener.dictationStarts, 1)
        listener.hear("Is there")
        listener.hear("Is there a chair next to the door")
        listener.mixedCallback?("the door")
        try await wait { input.transcript == "Is there a chair next to the door" }
        input.stop()
        XCTAssertEqual(input.transcript, "Is there a chair next to the door")
    }

    func testPermissionsDeniedDoNotEraseTheTypedQuestionOrClaimListening() async throws {
        let listener = QuestionListenerFixture()
        var paused = 0, question = "My existing question"
        let input = QuestionDictation(listener: listener, permission: { "Microphone permission denied" }, acquire: { paused += 1 }, release: {})
        let subscription = input.$transcript.sink { if !$0.isEmpty { question = $0 } }
        defer { subscription.cancel(); input.stop() }
        input.start(); try await wait { input.error != nil }
        XCTAssertEqual(question, "My existing question")
        XCTAssertEqual(input.phase, .idle)
        XCTAssertEqual(paused, 0)
        XCTAssertEqual(listener.dictationStarts, 0)
    }

    func testWaitsForMicrophoneHandoffAndActualReadiness() async throws {
        let listener = QuestionListenerFixture(); listener.ready = false
        var handoff: CheckedContinuation<Void, Never>?
        let input = QuestionDictation(listener: listener, permission: { nil }, acquire: {
            await withCheckedContinuation { handoff = $0 }
        }, release: {})
        defer { input.stop() }
        input.start(); try await wait { handoff != nil }
        XCTAssertEqual(listener.dictationStarts, 0)
        XCTAssertEqual(input.phase, .preparing)
        handoff?.resume()
        try await wait { listener.dictationStarts == 1 }
        XCTAssertEqual(input.phase, .preparing)
        listener.ready = true
        try await wait { input.phase == .listening }
    }

    func testCancelDuringPermissionPromptRejectsLateGrant() async throws {
        let listener = QuestionListenerFixture()
        var permission: CheckedContinuation<String?, Never>?
        let input = QuestionDictation(listener: listener, permission: {
            await withCheckedContinuation { permission = $0 }
        }, acquire: { XCTFail("Cancelled request acquired microphone") }, release: {})
        input.start(); try await wait { permission != nil }
        input.stop(); permission?.resume(returning: nil)
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(input.phase, .idle)
        XCTAssertEqual(listener.dictationStarts, 0)
    }

    func testStableQuestionFinishesWithoutDuplicateCallbacksExtendingTheTurn() async throws {
        let listener = QuestionListenerFixture(); var releases = 0
        let input = QuestionDictation(listener: listener, permission: { nil }, acquire: {}, release: { releases += 1 }, silenceTimeout: 0.03)
        input.start(); try await wait { input.phase == .listening }
        listener.hear("Where is the door?")
        try await wait { !input.transcript.isEmpty }
        listener.hear("Where is the door?")
        try await wait { input.phase == .idle && releases == 1 }
        XCTAssertEqual(input.transcript, "Where is the door?")
        XCTAssertNil(input.error)
    }

    func testNoSpeechAndMicrophoneFailureGiveActionableErrors() async throws {
        let listener = QuestionListenerFixture()
        let input = QuestionDictation(listener: listener, permission: { nil }, acquire: {}, release: {}, maximumDuration: 0.06)
        input.start(); try await wait { input.error != nil }
        XCTAssertTrue(input.error?.contains("No question") == true)
        let retry = QuestionDictation(listener: listener, permission: { nil }, acquire: {}, release: {})
        retry.start(); try await wait { retry.phase == .listening }
        listener.hear("Is there a table?")
        try await wait { retry.transcript == "Is there a table?" }
        listener.failureReason = "Audio input disconnected"
        try await wait { retry.phase == .idle }
        XCTAssertEqual(retry.error, "Audio input disconnected")
        XCTAssertEqual(retry.transcript, "Is there a table?")
    }

    func testOldCallbacksCannotReplaceANewQuestion() async throws {
        let listener = QuestionListenerFixture()
        let input = QuestionDictation(listener: listener, permission: { nil }, acquire: {}, release: {})
        defer { input.stop() }
        input.start(); try await wait { input.phase == .listening }
        let stale = try XCTUnwrap(listener.callbacks.first)
        input.stop(); input.start()
        try await wait { listener.dictationStarts == 2 && input.phase == .listening }
        listener.hear("Is there a table?"); stale("wrong old words")
        try await wait { input.transcript == "Is there a table?" }
    }

    func testSafetyPreemptionStopsQuestionInputAndRejectsLateSpeech() async throws {
        let listener = QuestionListenerFixture(); var allowed = true, releases = 0
        let input = QuestionDictation(listener: listener, permission: { nil }, acquire: {}, release: { releases += 1 }, canStart: { allowed })
        input.start(); try await wait { input.phase == .listening }
        let stale = try XCTUnwrap(listener.callbacks.last)
        allowed = false
        try await wait { input.phase == .idle && releases == 1 }
        stale("old question")
        for _ in 0..<5 { await Task.yield() }
        XCTAssertTrue(input.transcript.isEmpty)
    }
}
