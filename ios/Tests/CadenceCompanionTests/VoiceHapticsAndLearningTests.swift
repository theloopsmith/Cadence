import XCTest
@testable import CadenceCompanion

// MARK: - Voice dose logging

final class MockTranscriptListener: TranscriptListening {
    private(set) var isListening = false
    private var onTranscript: ((String) -> Void)?
    var startCount = 0

    func startListening(onTranscript: @escaping (String) -> Void) {
        isListening = true
        startCount += 1
        self.onTranscript = onTranscript
    }

    func stopListening() {
        isListening = false
        onTranscript = nil
    }

    func hear(_ text: String) { onTranscript?(text) }
}

final class SpokenLog: PromptSpeaking {
    var spoken: [String] = []
    func speak(_ text: String) { spoken.append(text) }
}

final class DoseVoiceIntentTests: XCTestCase {
    func testManyWaysOfSayingTakenAreUnderstood() {
        for phrase in ["taken", "I took it", "took my pill", "I have taken my medication",
                       "medication taken", "I've had my levodopa", "yes I took them"] {
            XCTAssertEqual(DoseVoiceIntent.parse(phrase), .taken, phrase)
        }
    }

    func testConfirmationsAndRefusalsAreUnderstood() {
        for phrase in ["yes", "yeah", "yep", "that's right", "correct", "I did"] {
            XCTAssertEqual(DoseVoiceIntent.parse(phrase), .yes, phrase)
        }
        for phrase in ["no", "nope", "not yet", "I haven't", "wrong"] {
            XCTAssertEqual(DoseVoiceIntent.parse(phrase), .no, phrase)
        }
    }

    func testUnclearSpeechIsUnclearNotNo() {
        XCTAssertEqual(DoseVoiceIntent.parse("um the weather"), .unclear)
        XCTAssertEqual(DoseVoiceIntent.parse(""), .unclear)
    }

    /// Soft, slurred speech still gets through on the key word.
    func testPartialWordsStillMatch() {
        XCTAssertEqual(DoseVoiceIntent.parse("tak... taken"), .taken)
        XCTAssertEqual(DoseVoiceIntent.parse("ye-yes"), .yes)
    }
}

@MainActor
final class VoiceDoseAssistantTests: XCTestCase {
    private func make(now: Date = Date()) -> (VoiceDoseAssistant, MockTranscriptListener, SpokenLog, DoseLogModel) {
        let diary = DiaryStore(directory: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vd-\(UUID().uuidString)"))
        let sync = EventSyncManager(
            databasePath: NSTemporaryDirectory() + "vd-\(UUID().uuidString).sqlite", startPeriodicDrain: false
        )
        let schedule = MedicationSchedule(medicationName: "Levodopa", doseTimes: [DoseTime(hour: 0, minute: 0)])
        let doses = DoseLogModel(schedule: schedule, diary: diary, sync: sync, clock: { now })
        let listener = MockTranscriptListener()
        let speaker = SpokenLog()
        let assistant = VoiceDoseAssistant(doses: doses, listener: listener, speaker: speaker, silenceWindowSec: 20)
        return (assistant, listener, speaker, doses)
    }

    /// Nothing is logged until the readback is confirmed.
    func testTakenIsReadBackAndLoggedOnlyAfterYes() {
        let (assistant, listener, speaker, doses) = make()
        assistant.begin()
        XCTAssertEqual(assistant.state, .listening)
        XCTAssertTrue(listener.isListening)
        XCTAssertTrue(speaker.spoken.last?.contains("Did you take") == false, "ask one question at a time")

        listener.hear("I took my pill")
        XCTAssertEqual(assistant.state, .confirming)
        XCTAssertTrue(speaker.spoken.last?.contains("Levodopa") == true)
        XCTAssertTrue(speaker.spoken.last?.lowercased().contains("yes or no") == true)
        XCTAssertEqual(doses.takenToday.count, 0, "not yet")

        listener.hear("yes")
        XCTAssertEqual(assistant.state, .done)
        XCTAssertEqual(doses.takenToday.count, 1)
        XCTAssertTrue(doses.canUndo)
        XCTAssertFalse(listener.isListening)
        XCTAssertTrue(speaker.spoken.last?.lowercased().contains("logged") == true)
    }

    func testNoAtReadbackLogsNothingAndIsWarm() {
        let (assistant, listener, speaker, doses) = make()
        assistant.begin()
        listener.hear("taken")
        listener.hear("no")
        XCTAssertEqual(assistant.state, .cancelled)
        XCTAssertEqual(doses.takenToday.count, 0)
        let last = speaker.spoken.last?.lowercased() ?? ""
        XCTAssertTrue(last.contains("no problem"))
        XCTAssertFalse(last.contains("error"))
    }

    /// Unclear speech gets a patient re-ask, never a "speak louder".
    func testUnclearSpeechIsReaskedWithoutScolding() {
        let (assistant, listener, speaker, _) = make()
        assistant.begin()
        listener.hear("hmm the garden")
        XCTAssertEqual(assistant.state, .listening)
        let last = speaker.spoken.last?.lowercased() ?? ""
        XCTAssertFalse(last.contains("louder"))
        XCTAssertFalse(last.contains("clearly"))
        XCTAssertTrue(last.contains("taken") || last.contains("when you"))
    }

    /// Silence for the long window ends gently and logs nothing.
    func testLongSilenceEndsGently() async {
        let (assistant, _, speaker, doses) = make()
        assistant.silenceWindowSec = 0.1
        assistant.begin()
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(assistant.state, .cancelled)
        XCTAssertEqual(doses.takenToday.count, 0)
        XCTAssertTrue(speaker.spoken.last?.lowercased().contains("when you can") == true)
    }

    func testCancelStopsListening() {
        let (assistant, listener, _, _) = make()
        assistant.begin()
        assistant.cancel()
        XCTAssertFalse(listener.isListening)
        XCTAssertEqual(assistant.state, .idle)
    }
}

// MARK: - Pill photo

final class PillPhotoStoreTests: XCTestCase {
    func testPhotoIsSavedLoadedAndRemoved() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pill-\(UUID().uuidString)")
        let store = PillPhotoStore(directory: dir)
        XCTAssertNil(store.load())
        try store.save(Data([0xFF, 0xD8, 0x01]))
        XCTAssertEqual(store.load(), Data([0xFF, 0xD8, 0x01]))
        try store.remove()
        XCTAssertNil(store.load())
    }
}

// MARK: - Haptic patterns

final class RecordingHapticSink: HapticPatternPlaying {
    var played: [HapticPattern] = []
    func play(_ pattern: HapticPattern) { played.append(pattern) }
}

final class HapticPatternTests: XCTestCase {
    /// Cue, reminder and alert must be told apart by feel alone.
    func testPatternsAreDistinctAndReasonable() {
        let all = HapticPattern.allCases
        let signatures = Set(all.map { $0.pulsesMs.description })
        XCTAssertEqual(signatures.count, all.count)
        for pattern in all {
            XCTAssertFalse(pattern.pulsesMs.isEmpty)
            XCTAssertLessThanOrEqual(pattern.totalDurationMs, 2_000, "\(pattern) is too long to feel like one signal")
        }
        XCTAssertGreaterThan(HapticPattern.alert.totalDurationMs, HapticPattern.cue.totalDurationMs)
    }

    @MainActor
    func testTheRouterSendsToTheGlassesWhenTheyCanAndThePhoneOtherwise() {
        let phone = RecordingHapticSink()
        let glassesSink = RecordingHapticSink()
        let device = MockGlassesDevice(
            name: "mock", loopSamples: [],
            capabilities: GlassesCapabilities(imu: false, microphone: true, camera: true, audioOutput: true, imuSampleRateHz: nil, haptics: true)
        )
        device.hapticSink = glassesSink
        let session = GlassesSessionManager(phoneMotion: MockMotionSource(available: true))
        let router = HapticRouter(phone: phone, glasses: session)

        router.play(.reminder)
        XCTAssertEqual(phone.played, [.reminder], "no glasses: the phone buzzes")

        session.attach(device)
        session.connect()
        router.play(.cue)
        XCTAssertEqual(glassesSink.played, [.cue])
        XCTAssertEqual(phone.played, [.reminder], "the phone stays quiet when the glasses took it")

        // An alert goes to both: the phone may be in a pocket, the glasses on the floor.
        router.play(.alert)
        XCTAssertEqual(glassesSink.played, [.cue, .alert])
        XCTAssertEqual(phone.played, [.reminder, .alert])
    }
}

// MARK: - Learned simple-mode hours

final class OffHourLearnerTests: XCTestCase {
    private func store() -> DiaryStore {
        DiaryStore(directory: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("learn-\(UUID().uuidString)"))
    }

    private func date(daysAgo: Int, hour: Int, from now: Date) -> Date {
        let cal = Calendar.current
        let day = cal.date(byAdding: .day, value: -daysAgo, to: now)!
        return cal.date(bySettingHour: hour, minute: 10, second: 0, of: day)!
    }

    /// Freezes that cluster at the same hour on several recent days make
    /// that hour a simple-mode hour.
    func testAnHourWithRepeatedFreezesIsLearned() throws {
        let diary = store()
        let now = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
        for daysAgo in 1...3 {
            for _ in 0..<2 {
                try diary.append(DiaryEvent(kind: .cue, at: date(daysAgo: daysAgo, hour: 17, from: now), detail: ""))
            }
        }
        try diary.append(DiaryEvent(kind: .cue, at: date(daysAgo: 1, hour: 9, from: now), detail: ""))

        let hours = OffHourLearner(diary: diary).learnedHours(asOf: now)
        XCTAssertEqual(hours, [17])
    }

    func testOneBusyDayIsNotAPattern() throws {
        let diary = store()
        let now = Date()
        for _ in 0..<6 {
            try diary.append(DiaryEvent(kind: .cue, at: date(daysAgo: 1, hour: 15, from: now), detail: ""))
        }
        XCTAssertEqual(OffHourLearner(diary: diary).learnedHours(asOf: now), [])
    }

    func testAnEmptyDiaryLearnsNothing() {
        XCTAssertEqual(OffHourLearner(diary: store()).learnedHours(asOf: Date()), [])
    }
}
