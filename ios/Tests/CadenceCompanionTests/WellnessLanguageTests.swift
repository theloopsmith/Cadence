import XCTest
@testable import CadenceCompanion

/// Terms that would turn a description into a clinical claim. Cadence shows
/// events and raw measurements only.
private let clinicalTerms = try! NSRegularExpression(
    pattern: #"\b(ON|OFF|WEARING[_ -]?OFF|[Ss]core|[Cc]omposite|/ ?100|[Cc]linical|[Ss]ymptom|[Mm]icrographia|[Hh]allucinat\w*|[Dd]iagnos\w*|[Ss]everity)\b"#
)

/// Phrasing that tells someone what to do with their medication.
private let medicationAdvice = try! NSRegularExpression(
    pattern: #"(?i)\b(recommend\w*|should take|take your \w+ now|wait \d+|before eating|after your dose|skip (a|your) dose|change your dose)"#
)

private func clinicalTerm(in text: String) -> String? {
    let range = NSRange(text.startIndex..., in: text)
    for pattern in [clinicalTerms, medicationAdvice] {
        if let match = pattern.firstMatch(in: text, range: range), let r = Range(match.range, in: text) {
            return String(text[r])
        }
    }
    return nil
}

final class TaskMetricsSummaryTests: XCTestCase {
    private func measurements(voice: Double?, letters: Double?, cadence: Double?, freezes: Int?) -> TaskMetricsRecord {
        TaskMetricsRecord(
            date: Date(), voiceMeanDbfs: voice, handwritingDecayPct: letters,
            walkStepsPerMinute: cadence, walkFreezes: freezes
        )
    }

    func testFirstCheckDescribesEachMeasurementPlainly() {
        let lines = TaskMetricsSummary.lines(
            current: measurements(voice: -26.4, letters: -22.0, cadence: 96.0, freezes: 1),
            previous: nil
        )
        XCTAssertEqual(lines.map(\.title), ["Letter size", "Voice", "Walking"])
        XCTAssertEqual(lines[0].value, "22% smaller across the line")
        XCTAssertEqual(lines[1].value, "−26 dB")
        XCTAssertEqual(lines[2].value, "96 steps a minute · 1 pause")
        for line in lines {
            XCTAssertNil(clinicalTerm(in: line.title + " " + line.value + " " + (line.comparison ?? "")))
        }
    }

    /// The trend is a plain comparison with the previous check.
    func testTrendComparesWithThePreviousCheck() {
        let lines = TaskMetricsSummary.lines(
            current: measurements(voice: -24.0, letters: -15.0, cadence: 104.0, freezes: 0),
            previous: measurements(voice: -27.0, letters: -22.0, cadence: 96.0, freezes: 1)
        )
        XCTAssertEqual(lines[0].comparison, "Last time: 22% smaller")
        XCTAssertEqual(lines[1].comparison, "3 dB louder than last time")
        XCTAssertEqual(lines[2].comparison, "8 more steps a minute than last time")
    }

    func testSmallChangesReadAsAboutTheSame() {
        let lines = TaskMetricsSummary.lines(
            current: measurements(voice: -25.5, letters: -3.0, cadence: 100.0, freezes: 0),
            previous: measurements(voice: -25.0, letters: -2.0, cadence: 101.0, freezes: 0)
        )
        XCTAssertEqual(lines[0].value, "About the same size across the line")
        XCTAssertEqual(lines[1].comparison, "About the same as last time")
        XCTAssertEqual(lines[2].comparison, "About the same as last time")
    }

    /// Something not measured is said to be not measured, never filled in.
    func testUnmeasuredStepsAreSaidPlainly() {
        let lines = TaskMetricsSummary.lines(
            current: measurements(voice: nil, letters: nil, cadence: nil, freezes: nil),
            previous: nil
        )
        XCTAssertEqual(lines.map(\.value), ["Not measured this time", "Not measured this time", "Not measured this time"])
    }

    func testTheDiaryLineIsPlain() {
        let text = TaskMetricsSummary.diaryDetail(measurements(voice: -26, letters: -22, cadence: 96, freezes: 0))
        XCTAssertEqual(text, "Letters 22% smaller across the line · 96 steps a minute")
        XCTAssertNil(clinicalTerm(in: text))
    }
}

final class TaskMetricsHistoryTests: XCTestCase {
    func testRecordsAreSavedAndTheLatestComesBack() throws {
        let store = TaskMetricsHistory(directory: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("metrics-\(UUID().uuidString)"))
        XCTAssertNil(store.latest())
        let first = TaskMetricsRecord(date: Date(timeIntervalSince1970: 100), voiceMeanDbfs: -27,
                                      handwritingDecayPct: -22, walkStepsPerMinute: 96, walkFreezes: 1)
        let second = TaskMetricsRecord(date: Date(timeIntervalSince1970: 200), voiceMeanDbfs: -24,
                                       handwritingDecayPct: -15, walkStepsPerMinute: 104, walkFreezes: 0)
        try store.append(first)
        try store.append(second)
        XCTAssertEqual(store.latest()?.walkStepsPerMinute, 104)
        XCTAssertEqual(store.all().count, 2)
    }
}

@MainActor
final class MotorCheckWordingTests: XCTestCase {
    func testTheExamManagerNeverSpeaksOrShowsAScore() async {
        let result = try! JSONDecoder().decode(
            HomeMotorExamResult.self,
            from: Data(#"{"exam_uuid":"e","medication_state_label":"WEARING_OFF","voice_score":86.5,"handwriting_score":72.8,"gait_score":71.5,"composite_motor_score":76.4,"clinical_summary":"x"}"#.utf8)
        )
        let sync = EventSyncManager(databasePath: NSTemporaryDirectory() + "wording-\(UUID().uuidString).sqlite", startPeriodicDrain: false)
        let mgr = HomeMotorExamManager(submitter: StubExamSubmitter(result: result), audio: .shared, sync: sync)
        mgr.stepPauseSec = 0
        let summary = await mgr.runDemoExam()
        XCTAssertNil(clinicalTerm(in: summary), summary)
        XCTAssertNil(clinicalTerm(in: mgr.lastResultSummary ?? ""), mgr.lastResultSummary ?? "")
        XCTAssertFalse(summary.contains("76"))
    }
}

/// Every string literal on screen, checked at the source.
final class ScreenCopyLintTests: XCTestCase {
    func testNoScreenShowsAClinicalTerm() throws {
        let viewsDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // CadenceCompanionTests
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // ios
            .appendingPathComponent("CadenceCompanion/Views")
        let files = try FileManager.default.contentsOfDirectory(at: viewsDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
            + [viewsDir.deletingLastPathComponent().appendingPathComponent("App/EmergencySOSView.swift")]
        XCTAssertFalse(files.isEmpty)
        let literal = try NSRegularExpression(pattern: #""((?:[^"\\\n]|\\.)*)""#)
        var problems: [String] = []
        for file in files {
            let source = try String(contentsOf: file)
            for (number, line) in source.components(separatedBy: "\n").enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("///") { continue }
                // `case "…":` matches API values, which are data, not copy.
                if trimmed.hasPrefix("case \"") { continue }
                let range = NSRange(line.startIndex..., in: line)
                for match in literal.matches(in: line, range: range) {
                    guard let r = Range(match.range(at: 1), in: line) else { continue }
                    let text = String(line[r])
                    if let term = clinicalTerm(in: text) {
                        problems.append("\(file.lastPathComponent):\(number + 1) \"\(text)\" (\(term))")
                    }
                }
            }
        }
        XCTAssertTrue(problems.isEmpty, problems.joined(separator: "\n"))
    }
}
