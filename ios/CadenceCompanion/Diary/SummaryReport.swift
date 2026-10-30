import Foundation

/// How far back a shared summary reaches.
public enum SummaryRange: String, CaseIterable, Identifiable {
    case lastDay, lastWeek, lastMonth

    public var id: String { rawValue }

    public var buttonTitle: String {
        switch self {
        case .lastDay: return "Last day"
        case .lastWeek: return "Last week"
        case .lastMonth: return "Last month"
        }
    }

    /// Calendar days covered, counting the end day.
    var dayCount: Int {
        switch self {
        case .lastDay: return 1
        case .lastWeek: return 7
        case .lastMonth: return 30
        }
    }
}

/// Everything the PDF shows, already in plain words. Counts of logged events
/// and raw measurements only.
public struct SummaryReport {
    public struct Count: Equatable {
        public let label: String
        public let value: Int
    }

    public struct Entry: Equatable {
        public let time: String
        public let word: String
        public let detail: String
    }

    public struct Day {
        public let date: Date
        public let heading: String
        public let countsLine: String
        /// Every event, for a one-day summary. Empty for longer ranges.
        public let entries: [Entry]
    }

    public struct MotorCheck {
        public let heading: String
        public let lines: [String]
    }

    public struct Meal: Equatable {
        public let time: String
        public let text: String
    }

    public let title: String
    public let rangeText: String
    public let range: SummaryRange
    public let counts: [Count]
    public let days: [Day]
    public let motorChecks: [MotorCheck]
    public let meals: [Meal]
    public let fileDateStamp: String

    public static let disclaimer =
        "Cadence is a daily-living companion, not a medical device. These are counts of logged events and raw "
        + "measurements, not an assessment of health. This summary uses phone logs; continuous monitoring coverage is unknown. Alert requests do not confirm caregiver receipt. Questions about health or medication are for the care team."

    public static let nothingLogged = "Nothing was logged in this period."

    public func count(_ label: String) -> Int {
        counts.first { $0.label == label }?.value ?? 0
    }

    public var isEmpty: Bool {
        counts.allSatisfy { $0.value == 0 } && motorChecks.isEmpty
    }

    /// The whole document as text, in reading order.
    public var plainText: String {
        var parts = [title, rangeText]
        if isEmpty {
            parts.append(Self.nothingLogged)
        } else {
            parts += counts.map { "\($0.label): \($0.value)" }
            for day in days {
                parts.append("\(day.heading): \(day.countsLine)")
                parts += day.entries.map { "\($0.time) \($0.word) \($0.detail)" }
            }
            for check in motorChecks {
                parts.append(check.heading)
                parts += check.lines
            }
            parts += meals.map { "\($0.time) \($0.text)" }
        }
        parts.append(Self.disclaimer)
        return parts.joined(separator: "\n")
    }
}

/// Builds a summary entirely from what is on the phone: the diary and the
/// motor check history. No server involved.
public struct SummaryReportBuilder {
    public let diary: DiaryStore
    public let metrics: TaskMetricsHistory
    public let calendar: Calendar

    public init(diary: DiaryStore, metrics: TaskMetricsHistory, calendar: Calendar = .current) {
        self.diary = diary
        self.metrics = metrics
        self.calendar = calendar
    }

    /// Kinds that describe the day. Switching protection on or off does not.
    private static let reportedKinds: Set<DiaryEventKind> = [
        .doseTaken, .cue, .helpSent, .alertAccepted, .caregiverAcknowledged, .checkInAnswered, .environmentCheck, .mealLogged, .motorCheck,
    ]

    public func build(range: SummaryRange, endingAt end: Date, name: String) -> SummaryReport {
        let lastDay = calendar.startOfDay(for: end)
        let dayStarts: [Date] = (0..<range.dayCount).reversed().compactMap {
            calendar.date(byAdding: .day, value: -$0, to: lastDay)
        }
        let firstDay = dayStarts.first ?? lastDay
        let rangeEnd = end

        var eventsByDay: [Date: [DiaryEvent]] = [:]
        for day in dayStarts {
            let events = ((try? diary.events(on: day)) ?? [])
                .filter { Self.reportedKinds.contains($0.kind) && $0.at <= end }
                .sorted { $0.at < $1.at }
            eventsByDay[day] = events
        }
        let allEvents = dayStarts.flatMap { eventsByDay[$0] ?? [] }

        func tally(_ kind: DiaryEventKind) -> Int { allEvents.filter { $0.kind == kind }.count }

        let counts = [
            SummaryReport.Count(label: "Doses logged", value: tally(.doseTaken)),
            SummaryReport.Count(label: "Beats played", value: tally(.cue)),
            SummaryReport.Count(label: "Alerts requested", value: tally(.helpSent)),
            SummaryReport.Count(label: "Provider accepted alerts", value: tally(.alertAccepted)),
            SummaryReport.Count(label: "Caregiver acknowledged alerts", value: tally(.caregiverAcknowledged)),
            SummaryReport.Count(label: "Check-ins answered okay", value: tally(.checkInAnswered)),
            SummaryReport.Count(label: "Look-arounds", value: tally(.environmentCheck)),
            SummaryReport.Count(label: "Meals noted", value: tally(.mealLogged)),
        ]

        let days = dayStarts.map { day -> SummaryReport.Day in
            let events = eventsByDay[day] ?? []
            return SummaryReport.Day(
                date: day,
                heading: format(day, "EEEE, MMMM d"),
                countsLine: countsLine(events),
                entries: range == .lastDay
                    ? events.map { SummaryReport.Entry(time: format($0.at, "h:mm a"), word: $0.kind.word, detail: $0.factualDetail) }
                    : []
            )
        }

        let history = metrics.all()
        let motorChecks = history.enumerated().compactMap { index, record -> SummaryReport.MotorCheck? in
            guard record.date >= firstDay, record.date <= rangeEnd else { return nil }
            let previous = index > 0 ? history[index - 1] : nil
            let lines = TaskMetricsSummary.lines(current: record, previous: previous).map { line in
                var text = "\(line.title): \(line.value)"
                if let comparison = line.comparison { text += " · \(comparison)" }
                return text
            }
            return SummaryReport.MotorCheck(heading: "Motor check, " + format(record.date, "EEEE, MMMM d, h:mm a"), lines: lines)
        }

        let allCounts = counts + [SummaryReport.Count(label: "Motor checks", value: motorChecks.count)]

        let doses = allEvents.filter { $0.kind == .doseTaken }.map(\.at)
        let meals = allEvents.filter { $0.kind == .mealLogged }.map { meal -> SummaryReport.Meal in
            let nearDose = doses.contains { dose in
                let minutes = meal.at.timeIntervalSince(dose) / 60
                return minutes >= -45 && minutes <= 60
            }
            let base = meal.detail.isEmpty ? "Meal noted" : meal.detail
            return SummaryReport.Meal(
                time: format(meal.at, range == .lastDay ? "h:mm a" : "MMM d, h:mm a"),
                text: nearDose ? "\(base), within an hour of a dose" : base
            )
        }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return SummaryReport(
            title: trimmedName.isEmpty ? "Cadence summary" : "Cadence summary for \(trimmedName)",
            rangeText: range == .lastDay
                ? format(lastDay, "EEEE, MMMM d, yyyy") + " · Through " + format(end, "h:mm a z")
                : "\(format(firstDay, "MMMM d")) to \(format(lastDay, "MMMM d, yyyy")) · Through " + format(end, "h:mm a z"),
            range: range,
            counts: allCounts,
            days: days,
            motorChecks: motorChecks,
            meals: meals,
            fileDateStamp: format(lastDay, "yyyy-MM-dd")
        )
    }

    private func countsLine(_ events: [DiaryEvent]) -> String {
        func part(_ kind: DiaryEventKind, _ one: String, _ many: String) -> String? {
            let n = events.filter { $0.kind == kind }.count
            return n == 0 ? nil : "\(n) \(n == 1 ? one : many)"
        }
        let parts = [
            part(.doseTaken, "dose", "doses"),
            part(.cue, "beat", "beats"),
            part(.helpSent, "alert requested", "alerts requested"),
            part(.alertAccepted, "provider acceptance", "provider acceptances"),
            part(.caregiverAcknowledged, "caregiver acknowledgment", "caregiver acknowledgments"),
            part(.checkInAnswered, "check-in", "check-ins"),
            part(.motorCheck, "motor check", "motor checks"),
            part(.mealLogged, "meal", "meals"),
            part(.environmentCheck, "environment check", "environment checks"),
        ].compactMap { $0 }
        return parts.isEmpty ? "Nothing logged" : parts.joined(separator: " · ")
    }

    private func format(_ date: Date, _ pattern: String) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = pattern
        return f.string(from: date)
    }
}
