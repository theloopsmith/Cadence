import XCTest
@testable import CadenceCompanion

@MainActor
final class CompanionQuestionsTests: XCTestCase {
    func testQuestionsAreSeparatedFromCommands() {
        for (text, question) in [
            ("Did I take my medication today?", CompanionQuestion.doseHistory),
            ("When did I last take Levodopa?", .doseHistory),
            ("When was my last dose?", .doseHistory),
            ("When is my next dose?", .nextDose),
            ("What medications do I take?", .medicationPlan),
            ("What were my last motor check results?", .lastMotorCheck),
            ("Has my caregiver acknowledged the alert?", .caregiverStatus),
            ("What can I ask you?", .capabilities)
        ] { XCTAssertEqual(CompanionQuestion.parse(text), question, text) }
        for text in ["I took my medication", "call my caregiver", "record my dose", "start a motor check"] {
            XCTAssertNil(CompanionQuestion.parse(text), text)
        }
    }

    func testMedicationHistoryIsNamedFactualAndDoesNotClaimIngestion() {
        let now = Date()
        let plan = [MedicationSchedule(medicationName: "First medicine", doseTimes: []),
                    MedicationSchedule(medicationName: "Second medicine", doseTimes: [])]
        let events = [DiaryEvent(kind: .doseTaken, at: now.addingTimeInterval(-60), detail: "Second medicine")]
        let answer = CompanionAnswers.medication(.doseHistory, text: "Did I take Second medicine today?", plan: plan, events: events, now: now)
        XCTAssertTrue(answer.contains("You recorded Second medicine"))
        XCTAssertFalse(answer.contains("First medicine"))
        XCTAssertTrue(answer.contains("not proof of ingestion"))
        let missing = CompanionAnswers.medication(.doseHistory, text: "Did I take First medicine today?", plan: plan, events: events, now: now)
        XCTAssertTrue(missing.contains("no dose record"))
        XCTAssertTrue(missing.contains("today"))
    }

    func testNextTimeIncludesAllMedicationsAtTheSameTime() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 7))!
        let time = DoseTime(hour: 8, minute: 0)
        let plan = [MedicationSchedule(medicationName: "First", doseTimes: [time], calendar: cal),
                    MedicationSchedule(medicationName: "Second", doseTimes: [time], calendar: cal)]
        let answer = CompanionAnswers.medication(.nextDose, text: "When is my next dose?", plan: plan, events: [], now: now, calendar: cal)
        XCTAssertTrue(answer.contains("First, Second"))
        XCTAssertTrue(answer.contains("not a recommendation"))
    }

    func testQuestionAbandonsPendingActionAndNeverCallsOrLogs() async throws {
        let speaker = SpokenLog()
        let voice = VoiceCompanion(listener: MockTranscriptListener(), speaker: speaker, echo: QuietQuestionEcho())
        defer { voice.stop() }
        let answered = expectation(description: "Read only answer")
        var effects: [CompanionIntent] = []
        voice.execute = { effects.append($0); return "Action" }
        voice.answerQuestion = { question, _ in
            XCTAssertEqual(question, .caregiverStatus)
            answered.fulfill(); return "No acknowledgment is verified."
        }
        voice.start(); voice.submit("record my dose")
        voice.submit("Has my caregiver responded?")
        await fulfillment(of: [answered], timeout: 2)
        // Yield until the answer has been published.
        for _ in 0..<20 where !voice.lastReply.contains("No acknowledgment") { await Task.yield() }
        voice.submit("yes")
        XCTAssertTrue(effects.isEmpty)
        XCTAssertTrue(speaker.spoken.contains("No acknowledgment is verified."))
    }

    func testMetaInterpretationRoutesNaturalQuestionToLocalFactsWithTodayScope() async {
        let voice = VoiceCompanion(listener: MockTranscriptListener(), speaker: SpokenLog(), echo: QuietQuestionEcho())
        defer { voice.stop() }
        let answered = expectation(description: "Grounded answer")
        voice.understand = { text, _ in
            XCTAssertEqual(text, "Catch me up on my pill log from this morning")
            return .doseHistoryTodayQuestion
        }
        voice.answerQuestion = { question, text in
            XCTAssertEqual(question, .doseHistory)
            XCTAssertTrue(text.hasSuffix(" today"))
            answered.fulfill()
            return "Your saved record, not a model-invented fact."
        }
        voice.execute = { _ in XCTFail("A question cannot execute an action"); return "" }
        voice.start(); voice.submit("Catch me up on my pill log from this morning")
        await fulfillment(of: [answered], timeout: 2)
        for _ in 0..<20 where !voice.lastReply.contains("saved record") { await Task.yield() }
        XCTAssertTrue(voice.lastReply.contains("saved record"))
    }

    func testKnownQuestionUsesLocalAnswerWhenModelIsUnavailable() async {
        let voice = VoiceCompanion(listener: MockTranscriptListener(), speaker: SpokenLog(), echo: QuietQuestionEcho())
        defer { voice.stop() }
        let answered = expectation(description: "Offline local answer")
        voice.understand = { _, _ in XCTFail("Known questions must not require a model call"); return nil }
        voice.answerQuestion = { question, _ in
            XCTAssertEqual(question, .nextDose); answered.fulfill(); return "Saved reminder"
        }
        voice.start(); voice.submit("When is my next dose?")
        await fulfillment(of: [answered], timeout: 2)
    }

    func testStoppedQuestionCannotSpeakALateAnswer() async {
        let voice = VoiceCompanion(listener: MockTranscriptListener(), speaker: SpokenLog(), echo: QuietQuestionEcho())
        var continuation: CheckedContinuation<String, Never>?
        let started = expectation(description: "Question reading")
        voice.answerQuestion = { _, _ in await withCheckedContinuation { continuation = $0; started.fulfill() } }
        voice.start(); voice.submit("When is my next dose?")
        await fulfillment(of: [started], timeout: 2)
        voice.stop(); continuation?.resume(returning: "Stale patient answer")
        await Task.yield()
        XCTAssertNotEqual(voice.lastReply, "Stale patient answer")
    }
}

private final class QuietQuestionEcho: EchoGuarding {
    func isInEchoWindow(at date: Date) -> Bool { false }
}
