import Foundation

/// Finds hours of the day when freezes keep happening, so the interface can
/// go simple at those hours before the wearer has to ask.
///
/// A pattern is at least two freezes in the same hour on at least two of the
/// last seven days. One rough afternoon is not a pattern.
public struct OffHourLearner {
    public let diary: DiaryStore
    public var lookbackDays = 7
    public var minimumFreezesPerDay = 2
    public var minimumDays = 2
    private let calendar: Calendar

    public init(diary: DiaryStore, calendar: Calendar = .current) {
        self.diary = diary
        self.calendar = calendar
    }

    /// Hours (0–23) that qualify, ascending.
    public func learnedHours(asOf now: Date) -> [Int] {
        var daysPerHour: [Int: Set<Int>] = [:]
        for daysAgo in 1...lookbackDays {
            guard let day = calendar.date(byAdding: .day, value: -daysAgo, to: now),
                  let events = try? diary.events(on: day) else { continue }
            var countByHour: [Int: Int] = [:]
            for event in events where event.kind == .cue {
                countByHour[calendar.component(.hour, from: event.at), default: 0] += 1
            }
            for (hour, count) in countByHour where count >= minimumFreezesPerDay {
                daysPerHour[hour, default: []].insert(daysAgo)
            }
        }
        return daysPerHour
            .filter { $0.value.count >= minimumDays }
            .keys
            .sorted()
    }

    public func isLearnedOffHour(_ date: Date) -> Bool {
        learnedHours(asOf: date).contains(calendar.component(.hour, from: date))
    }
}
