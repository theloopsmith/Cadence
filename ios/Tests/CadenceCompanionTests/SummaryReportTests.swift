import PDFKit
import XCTest
@testable import CadenceCompanion

final class SummaryReportTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }()

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    private func makeDiary() throws -> DiaryStore {
        let diary = DiaryStore(
            directory: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sum-\(UUID().uuidString)"),
            calendar: calendar
        )
        // Today, Oct 28
        try diary.append(DiaryEvent(kind: .doseTaken, at: date(28, 8, 0), detail: "Levodopa"))
        try diary.append(DiaryEvent(kind: .mealLogged, at: date(28, 8, 30), detail: "About 28 g protein"))
        try diary.append(DiaryEvent(kind: .cue, at: date(28, 10, 0), detail: "A steady beat helped you step again"))
        try diary.append(DiaryEvent(kind: .checkInAnswered, at: date(28, 11, 0), detail: "You said you were okay"))
        try diary.append(DiaryEvent(kind: .protectionOn, at: date(28, 7, 0), detail: ""))
        try diary.append(DiaryEvent(kind: .doseTaken, at: date(28, 12, 30), detail: "Levodopa"))
        try diary.append(DiaryEvent(kind: .mealLogged, at: date(28, 15, 0), detail: "About 12 g protein"))
        // Earlier days
        try diary.append(DiaryEvent(kind: .doseTaken, at: date(27, 8, 0), detail: "Levodopa"))
        try diary.append(DiaryEvent(kind: .cue, at: date(27, 9, 0), detail: ""))
        try diary.append(DiaryEvent(kind: .cue, at: date(27, 17, 0), detail: ""))
        try diary.append(DiaryEvent(kind: .helpSent, at: date(26, 16, 0), detail: "Your caregiver was contacted"))
        try diary.append(DiaryEvent(kind: .doseTaken, at: date(10, 8, 0), detail: "Levodopa"))
        return diary
    }

    private func history() throws -> TaskMetricsHistory {
        let history = TaskMetricsHistory(directory: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hist-\(UUID().uuidString)"))
        try history.append(TaskMetricsRecord(date: date(27, 14), voiceMeanDbfs: -27, handwritingDecayPct: -22,
                                             walkStepsPerMinute: 96, walkFreezes: 1))
        try history.append(TaskMetricsRecord(date: date(28, 14), voiceMeanDbfs: -24, handwritingDecayPct: -15,
                                             walkStepsPerMinute: 104, walkFreezes: 0))
        return history
    }

    private func build(_ range: SummaryRange) throws -> SummaryReport {
        SummaryReportBuilder(diary: try makeDiary(), metrics: try history(), calendar: calendar)
            .build(range: range, endingAt: date(28, 18), name: "Pat")
    }

    func testTheLastDayCountsAndListsTodaysEvents() throws {
        let report = try build(.lastDay)
        XCTAssertEqual(report.title, "Cadence summary for Pat")
        XCTAssertEqual(report.count("Doses logged"), 2)
        XCTAssertEqual(report.count("Beats played"), 1)
        XCTAssertEqual(report.count("Check-ins answered okay"), 1)
        XCTAssertEqual(report.count("Alerts requested"), 0)
        XCTAssertEqual(report.days.count, 1)
        let entries = report.days[0].entries
        XCTAssertEqual(entries.first?.word, "Dose taken")
        XCTAssertFalse(entries.contains { $0.word.hasPrefix("Protection") }, "switching protection is not a health event")
    }

    func testALongerRangeSummarisesEachDay() throws {
        let report = try build(.lastWeek)
        XCTAssertEqual(report.count("Doses logged"), 3)
        XCTAssertEqual(report.count("Beats played"), 3)
        XCTAssertEqual(report.count("Alerts requested"), 1)
        XCTAssertEqual(report.count("Provider accepted alerts"), 0)
        XCTAssertEqual(report.count("Caregiver acknowledged alerts"), 0)
        XCTAssertEqual(report.days.count, 7)
        let oct27 = try XCTUnwrap(report.days.first { calendar.component(.day, from: $0.date) == 27 })
        XCTAssertEqual(oct27.countsLine, "1 dose · 2 beats")
        XCTAssertTrue(oct27.entries.isEmpty, "longer ranges show a line per day, not every event")
        let empty = try XCTUnwrap(report.days.first { calendar.component(.day, from: $0.date) == 23 })
        XCTAssertEqual(empty.countsLine, "Nothing logged")
    }

    func testOlderEventsFallOutsideTheRange() throws {
        XCTAssertEqual(try build(.lastWeek).count("Doses logged"), 3)
        XCTAssertEqual(try build(.lastMonth).count("Doses logged"), 4)
    }

    func testMotorChecksShowMeasurementsAndChange() throws {
        let report = try build(.lastWeek)
        XCTAssertEqual(report.motorChecks.count, 2)
        let latest = try XCTUnwrap(report.motorChecks.last)
        XCTAssertTrue(latest.lines.contains { $0.contains("15% smaller") && $0.contains("Last time: 22% smaller") })
    }

    func testMealsCloseToADoseAreNotedFactually() throws {
        let report = try build(.lastDay)
        XCTAssertEqual(report.meals.count, 2)
        XCTAssertEqual(report.meals[0].text, "About 28 g protein, within an hour of a dose")
        XCTAssertEqual(report.meals[1].text, "About 12 g protein")
    }

    func testEverythingReadsPlainly() throws {
        let text = try build(.lastMonth).plainText
        XCTAssertTrue(text.contains("not a medical device"))
        let banned = try NSRegularExpression(pattern: #"\b(ON|OFF|[Ss]core|[Cc]linical|[Ss]ymptom|[Rr]ecommend\w*)\b"#)
        let hits = banned.matches(in: text, range: NSRange(text.startIndex..., in: text))
        XCTAssertTrue(hits.isEmpty, hits.compactMap { Range($0.range, in: text).map { String(text[$0]) } }.joined(separator: ", "))
    }

    func testAnEmptyDiaryStillMakesAUsefulSummary() throws {
        let empty = DiaryStore(directory: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("e-\(UUID().uuidString)"), calendar: calendar)
        let none = TaskMetricsHistory(directory: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("n-\(UUID().uuidString)"))
        let report = SummaryReportBuilder(diary: empty, metrics: none, calendar: calendar)
            .build(range: .lastDay, endingAt: date(28, 18), name: "")
        XCTAssertEqual(report.title, "Cadence summary")
        XCTAssertTrue(report.isEmpty)
        XCTAssertTrue(report.plainText.contains("Nothing was logged"))
    }

    // MARK: - PDF

    func testThePDFContainsTheSummaryText() throws {
        let report = try build(.lastDay)
        let data = SummaryPDFRenderer().render(report)
        let pdf = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertGreaterThanOrEqual(pdf.pageCount, 1)
        let text = (0..<pdf.pageCount).compactMap { pdf.page(at: $0)?.string }.joined(separator: "\n")
        XCTAssertTrue(text.contains("Cadence summary for Pat"), text)
        XCTAssertTrue(text.contains("Doses logged"))
        XCTAssertTrue(text.contains("not a medical device"))
    }

    func testALongReportFlowsOntoMorePages() throws {
        let diary = DiaryStore(directory: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("long-\(UUID().uuidString)"), calendar: calendar)
        for minute in stride(from: 0, to: 600, by: 5) {
            try diary.append(DiaryEvent(kind: .cue, at: date(28, 7).addingTimeInterval(Double(minute) * 60), detail: "A steady beat helped you step again"))
        }
        let none = TaskMetricsHistory(directory: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("n-\(UUID().uuidString)"))
        let report = SummaryReportBuilder(diary: diary, metrics: none, calendar: calendar)
            .build(range: .lastDay, endingAt: date(28, 18), name: "Pat")
        let pdf = try XCTUnwrap(PDFDocument(data: SummaryPDFRenderer().render(report)))
        XCTAssertGreaterThan(pdf.pageCount, 1)
        let last = pdf.page(at: pdf.pageCount - 1)?.string ?? ""
        XCTAssertTrue(last.contains("not a medical device"), "the note closes the document")
    }

    /// Writes a sample to /tmp for a visual check when CADENCE_WRITE_SAMPLE_PDF is set.
    func testWriteSamplePDFWhenAsked() throws {
        guard ProcessInfo.processInfo.environment["CADENCE_WRITE_SAMPLE_PDF"] != nil else { return }
        let data = SummaryPDFRenderer().render(try build(.lastDay))
        try data.write(to: URL(fileURLWithPath: "/tmp/cadence_sample_summary.pdf"))
        let week = SummaryPDFRenderer().render(try build(.lastWeek))
        try week.write(to: URL(fileURLWithPath: "/tmp/cadence_sample_week.pdf"))
    }

    func testTheFileHasAPlainName() throws {
        let report = try build(.lastWeek)
        let url = try SummaryPDFRenderer().writeTemporaryFile(report)
        XCTAssertEqual(url.lastPathComponent, "Cadence summary 2026-10-28.pdf")
        XCTAssertNotNil(PDFDocument(url: url))
    }

    func testLegacyContactClaimsRenderAsUnverifiedRequestsInPDF() throws {
        let diary = try makeDiary()
        let report = SummaryReportBuilder(diary: diary, metrics: try history(), calendar: calendar)
            .build(range: .lastDay, endingAt: date(26, 18), name: "Pat")
        XCTAssertEqual(report.count("Alerts requested"), 1)
        XCTAssertEqual(report.count("Caregiver acknowledged alerts"), 0)
        let pdf = try XCTUnwrap(PDFDocument(data: SummaryPDFRenderer().render(report)))
        let text = (0..<pdf.pageCount).compactMap { pdf.page(at: $0)?.string }.joined(separator: " ")
        XCTAssertFalse(text.contains("Your caregiver was contacted"))
        XCTAssertTrue(text.contains("receipt is unverified"))
        XCTAssertTrue(text.contains("coverage is unknown"))
    }

    func testFutureLocalEventsAndChecksAreExcludedAndDeliveryFactsAreDistinct() throws {
        let diary = try makeDiary()
        let accepted = DiaryEvent(id: "accepted-incident", kind: .alertAccepted, at: date(28, 16), detail: "Provider accepted", incidentID: "incident")
        try diary.append(accepted)
        try diary.append(accepted) // repeated polling cannot inflate the count
        try diary.append(DiaryEvent(kind: .caregiverAcknowledged, at: date(28, 17), detail: "Acknowledged", incidentID: "incident"))
        try diary.append(DiaryEvent(kind: .helpSent, at: date(28, 23), detail: "Future"))
        let report = SummaryReportBuilder(diary: diary, metrics: try history(), calendar: calendar)
            .build(range: .lastDay, endingAt: date(28, 18), name: "Pat")
        XCTAssertEqual(report.count("Provider accepted alerts"), 1)
        XCTAssertEqual(report.count("Caregiver acknowledged alerts"), 1)
        XCTAssertEqual(report.count("Alerts requested"), 0)
        XCTAssertFalse(report.plainText.contains("Future"))
        let early = SummaryReportBuilder(diary: diary, metrics: try history(), calendar: calendar)
            .build(range: .lastDay, endingAt: date(28, 9), name: "Pat")
        XCTAssertTrue(early.motorChecks.isEmpty)
    }
}
