import XCTest
@testable import CadenceCompanion

// MARK: - The app must never answer its own question

final class EchoFilterTests: XCTestCase {
    /// What the microphone hears while the phone is speaking is the prompt,
    /// not the wearer. Only speech after the prompt counts.
    func testSpeechHeardDuringThePromptIsDiscarded() {
        var filter = EchoFilteredTranscript()
        XCTAssertNil(filter.update(fullTranscript: "Hard impact detected say I am okay", echoActive: true))
        XCTAssertEqual(filter.update(fullTranscript: "Hard impact detected say I am okay I'm fine", echoActive: false), "I'm fine")
    }

    func testWithoutAPromptEverythingCounts() {
        var filter = EchoFilteredTranscript()
        XCTAssertEqual(filter.update(fullTranscript: "help me", echoActive: false), "help me")
        XCTAssertEqual(filter.update(fullTranscript: "help me please", echoActive: false), "help me please")
    }

    func testASecondPromptMovesTheStartingPointAgain() {
        var filter = EchoFilteredTranscript()
        _ = filter.update(fullTranscript: "taken", echoActive: false)
        XCTAssertNil(filter.update(fullTranscript: "taken is that right yes or no", echoActive: true))
        XCTAssertEqual(filter.update(fullTranscript: "taken is that right yes or no yes", echoActive: false), "yes")
    }

    func testARevisedShorterTranscriptAddsNothing() {
        var filter = EchoFilteredTranscript()
        _ = filter.update(fullTranscript: "say I am okay to cancel", echoActive: true)
        XCTAssertNil(filter.update(fullTranscript: "say I am", echoActive: false))
    }

    func testTheEchoWindowCoversSpeechAndAShortTail() {
        var window = EchoWindow(tailSec: 0.8)
        let t0 = Date(timeIntervalSince1970: 1000)
        XCTAssertFalse(window.isActive(at: t0))
        window.speechStarted()
        XCTAssertTrue(window.isActive(at: t0))
        window.speechEnded(at: t0)
        XCTAssertTrue(window.isActive(at: t0.addingTimeInterval(0.5)))
        XCTAssertFalse(window.isActive(at: t0.addingTimeInterval(1.0)))
    }

    /// Backstop: the spoken prompt itself contains no phrase that cancels
    /// and no word that escalates.
    func testTheCheckInPromptContainsNoTriggerWords() {
        let spoken = FallDetector.normalizeTranscript(FallDetector.checkInPrompt)
        for phrase in FallDetector.affirmativeCancelPhrases {
            XCTAssertFalse(FallDetector.containsPhrase(spoken, phrase), "prompt contains \(phrase)")
        }
        for word in FallDetector.distressAndNegationKeywords {
            XCTAssertFalse(FallDetector.containsDistressPhrase(spoken, word), "prompt contains \(word)")
        }
    }

    func testTheDosePromptsContainNoAnswerWords() {
        for prompt in VoiceDoseAssistant.allPrompts(medicationName: "Levodopa") {
            XCTAssertEqual(DoseVoiceIntent.parse(prompt), .unclear, "“\(prompt)” would answer itself")
        }
    }
}

// MARK: - A natural voice

final class VoiceSelectionTests: XCTestCase {
    private let voices = [
        VoiceCandidate(identifier: "compact.samantha", name: "Samantha", language: "en-US", quality: .standard),
        VoiceCandidate(identifier: "enhanced.ava", name: "Ava", language: "en-US", quality: .enhanced),
        VoiceCandidate(identifier: "premium.zoe", name: "Zoe", language: "en-US", quality: .premium),
        VoiceCandidate(identifier: "premium.daniel", name: "Daniel", language: "en-GB", quality: .premium),
        VoiceCandidate(identifier: "premium.marie", name: "Marie", language: "fr-FR", quality: .premium),
    ]

    func testTheBestAmericanEnglishVoiceIsChosen() {
        XCTAssertEqual(VoiceSelection.best(from: voices, preferred: nil)?.identifier, "premium.zoe")
    }

    func testAChosenVoiceIsKeptWhileItIsInstalled() {
        XCTAssertEqual(VoiceSelection.best(from: voices, preferred: "enhanced.ava")?.identifier, "enhanced.ava")
        XCTAssertEqual(VoiceSelection.best(from: voices, preferred: "deleted.voice")?.identifier, "premium.zoe")
    }

    func testAnyEnglishVoiceBeatsNoneAndOtherLanguagesAreNeverPicked() {
        let british = voices.filter { $0.language != "en-US" }
        XCTAssertEqual(VoiceSelection.best(from: british, preferred: nil)?.identifier, "premium.daniel")
        XCTAssertNil(VoiceSelection.best(from: voices.filter { $0.language == "fr-FR" }, preferred: nil))
    }

    func testTheChoiceListIsEnglishBestFirst() {
        let list = VoiceSelection.choices(from: voices)
        XCTAssertEqual(list.map(\.identifier), ["premium.zoe", "premium.daniel", "enhanced.ava", "compact.samantha"])
    }

    func testWithOnlyTheBasicVoiceADownloadIsSuggested() {
        let basic = [voices[0]]
        XCTAssertTrue(VoiceSelection.betterVoiceAvailableToDownload(installed: basic))
        XCTAssertFalse(VoiceSelection.betterVoiceAvailableToDownload(installed: voices))
    }

    func testNoveltyVoicesAreExcluded() {
        let pool = voices + [
            VoiceCandidate(identifier: "com.apple.speech.synthesis.voice.Albert", name: "Albert", language: "en-US", quality: .standard),
            VoiceCandidate(identifier: "com.apple.speech.synthesis.voice.BadNews", name: "Bad News", language: "en-US", quality: .standard),
            VoiceCandidate(identifier: "com.apple.eloquence.en-US.Eddy", name: "Eddy", language: "en-US", quality: .standard),
            VoiceCandidate(identifier: "com.apple.speech.synthesis.voice.Zarvox", name: "Zarvox", language: "en-US", quality: .standard),
        ]
        let list = VoiceSelection.choices(from: pool)
        XCTAssertFalse(list.contains { $0.name == "Albert" })
        XCTAssertFalse(list.contains { $0.name == "Bad News" })
        XCTAssertFalse(list.contains { $0.name == "Eddy" })
        XCTAssertFalse(list.contains { $0.name == "Zarvox" })
    }

    func testAnExcludedPreferredVoiceFallsBackToNaturalVoice() {
        let pool = [
            VoiceCandidate(identifier: "com.apple.speech.synthesis.voice.Albert", name: "Albert", language: "en-US", quality: .standard),
            VoiceCandidate(identifier: "compact.samantha", name: "Samantha", language: "en-US", quality: .standard),
        ]
        // Even if Albert was stored in user preferences, best must refuse it and pick Samantha
        let chosen = VoiceSelection.best(from: pool, preferred: "com.apple.speech.synthesis.voice.Albert")
        XCTAssertEqual(chosen?.identifier, "compact.samantha")
    }
}

// MARK: - Muse Voice Transcribe as a second listener

final class CloudEarTests: XCTestCase {
    func testBacklogDropsIncompleteSpeechAndAcceptsFreshAudio() {
        let sent = expectation(description: "fresh clip")
        let ear = CloudEar(windowSec: 3, strideSec: 1, transcribe: { _ in
            sent.fulfill(); return nil
        }, onTranscript: { _ in })
        ear.processingQueue.suspend()
        for _ in 0..<12 { ear.feed(samples: [Float](repeating: 0.3, count: 1024), sampleRate: 48000) }
        ear.processingQueue.resume()
        ear.processingQueue.sync {}
        XCTAssertEqual(ear.bufferedSeconds, 0)
        ear.feed(samples: speech(seconds: 1.2), sampleRate: 48000)
        wait(for: [sent], timeout: 2)
        ear.stop()
    }

    func testPromptInvalidatesAlreadySubmittedCloudReply() {
        let started = expectation(description: "request started")
        let delivered = expectation(description: "stale reply suppressed")
        delivered.isInverted = true
        let gate = DispatchSemaphore(value: 0)
        let ear = CloudEar(windowSec: 3, strideSec: 1, transcribe: { _ in
            started.fulfill(); gate.wait(); return "I'm okay"
        }, onTranscript: { _ in delivered.fulfill() })
        ear.feed(samples: speech(seconds: 1.2), sampleRate: 48000)
        wait(for: [started], timeout: 2)
        ear.feed(samples: [0], sampleRate: 48000, echoActive: true)
        gate.signal()
        wait(for: [delivered], timeout: 0.2)
        ear.stop()
    }

    func testInvalidPCMDoesNotTrapOrProduceInvalidSamples() {
        XCTAssertTrue(CloudEar.resample([0], from: .nan).isEmpty)
        XCTAssertEqual(CloudEar.resample([.nan, .infinity], from: 16000), [0, 0])
    }

    private func speech(seconds: Double, rate: Double = 48000, amplitude: Float = 0.3) -> [Float] {
        (0..<Int(seconds * rate)).map { amplitude * sin(Float($0) * 0.05) }
    }

    func testAWindowIsSentAsA16kMonoWAVOnceEnoughNewAudioArrives() {
        let sent = expectation(description: "sent")
        var clips: [Data] = []
        let ear = CloudEar(windowSec: 4, strideSec: 2, transcribe: { wav in
            clips.append(wav); sent.fulfill(); return "I'm fine"
        }, onTranscript: { _ in }, deliverOn: .main)

        ear.feed(samples: speech(seconds: 1.0), sampleRate: 48000)
        XCTAssertTrue(clips.isEmpty, "not enough audio yet")
        ear.feed(samples: speech(seconds: 1.5), sampleRate: 48000)
        wait(for: [sent], timeout: 2)

        let wav = clips[0]
        XCTAssertEqual(String(data: wav.prefix(4), encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: wav[8..<12], encoding: .ascii), "WAVE")
        let rate = wav[24..<28].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        let channels = wav[22..<24].withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }
        let bits = wav[34..<36].withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }
        XCTAssertEqual(rate, 16000)
        XCTAssertEqual(channels, 1)
        XCTAssertEqual(bits, 16)
        let samples = (wav.count - 44) / 2
        XCTAssertEqual(Double(samples), 2.5 * 16000, accuracy: 400, "48 kHz in, 16 kHz out")
    }

    func testTranscriptsArriveThroughTheCallback() {
        let heard = expectation(description: "heard")
        let ear = CloudEar(windowSec: 3, strideSec: 1, transcribe: { _ in "help me" },
                           onTranscript: { text in XCTAssertEqual(text, "help me"); heard.fulfill() },
                           deliverOn: .main)
        ear.feed(samples: speech(seconds: 1.2), sampleRate: 48000)
        wait(for: [heard], timeout: 2)
    }

    func testSilenceIsNeverSent() {
        var calls = 0
        let ear = CloudEar(windowSec: 3, strideSec: 1, transcribe: { _ in calls += 1; return "" },
                           onTranscript: { _ in }, deliverOn: .main)
        ear.feed(samples: speech(seconds: 3, amplitude: 0.001), sampleRate: 48000)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(calls, 0)
    }

    /// The prompt playing out of the speaker must never reach Meta either.
    func testAudioDuringThePromptIsDroppedAndNotSent() {
        var clips: [Data] = []
        let ear = CloudEar(windowSec: 3, strideSec: 1, transcribe: { wav in clips.append(wav); return "" },
                           onTranscript: { _ in }, deliverOn: .main)
        ear.feed(samples: speech(seconds: 3), sampleRate: 48000, echoActive: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertTrue(clips.isEmpty)
        XCTAssertEqual(ear.bufferedSeconds, 0, accuracy: 0.01)
    }

    func testAfterStopNothingIsDelivered() {
        var delivered = 0
        let gate = DispatchSemaphore(value: 0)
        let ear = CloudEar(windowSec: 3, strideSec: 1, transcribe: { _ in
            gate.wait(); return "I'm fine"
        }, onTranscript: { _ in delivered += 1 }, deliverOn: .main)
        ear.feed(samples: speech(seconds: 1.2), sampleRate: 48000)
        ear.stop()
        gate.signal()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(delivered, 0)
    }

    func testOnlyOneRequestIsInFlightAtATime() {
        var calls = 0
        let gate = DispatchSemaphore(value: 0)
        let ear = CloudEar(windowSec: 3, strideSec: 1, transcribe: { _ in
            calls += 1; gate.wait(); return ""
        }, onTranscript: { _ in }, deliverOn: .main)
        ear.feed(samples: speech(seconds: 1.2), sampleRate: 48000)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        ear.feed(samples: speech(seconds: 2.4), sampleRate: 48000)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(calls, 1)
        gate.signal()
        ear.stop()
    }
}

final class TranscribeClientTests: XCTestCase {
    func testTheClipIsSentWithItsPurpose() async throws {
        let transport = RecordingJSONTransport()
        transport.responses = [Data(#"{"available":true,"transcript":"I'm fine","source":"muse_voice_transcribe"}"#.utf8)]
        let client = CadenceAPIClient(baseURL: "http://example.test", bearerToken: "t", transport: transport)
        let text = try await client.transcribe(wav: Data([0x52, 0x49, 0x46, 0x46]), purpose: .fallCheckIn, keywords: ["Sinemet"])
        XCTAssertEqual(text, "I'm fine")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: transport.requests[0].body!) as? [String: Any])
        XCTAssertEqual(transport.requests[0].url.path, "/api/v1/speech/transcribe")
        XCTAssertEqual(body["purpose"] as? String, "fall_check_in")
        XCTAssertEqual(body["keywords"] as? [String], ["Sinemet"])
        XCTAssertNotNil(body["audio_base64"])
    }

    func testAnUnavailableTranscriberReturnsNil() async throws {
        let transport = RecordingJSONTransport()
        transport.responses = [Data(#"{"available":false,"transcript":"","source":"muse_voice_transcribe"}"#.utf8)]
        let client = CadenceAPIClient(baseURL: "http://example.test", bearerToken: "t", transport: transport)
        let text = try await client.transcribe(wav: Data([1]), purpose: .dose, keywords: [])
        XCTAssertNil(text)
    }
}
