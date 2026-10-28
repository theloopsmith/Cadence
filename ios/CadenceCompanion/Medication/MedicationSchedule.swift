import Foundation

/// A time of day a dose is taken.
public struct DoseTime: Codable, Equatable, Hashable, Comparable {
    public var hour: Int
    public var minute: Int

    public init(hour: Int, minute: Int) {
        self.hour = hour
        self.minute = minute
    }

    public var minutesFromMidnight: Int { hour * 60 + minute }

    public static func < (lhs: DoseTime, rhs: DoseTime) -> Bool {
        lhs.minutesFromMidnight < rhs.minutesFromMidnight
    }
}

/// The wearer's own dose times, set up once by a care partner.
///
/// Also the source of the predicted off windows: the half hour before each
/// dose, and anything more than three hours after the last dose taken. These
/// are reminders and interface hints, never advice about the schedule itself.
public struct MedicationSchedule: Codable, Equatable {
    public var medicationName: String
    public var doseTimes: [DoseTime]

    /// Minutes before a dose time at which it becomes due.
    public static let dueLeadMinutes = 30
    /// Hours after a dose when its effect is assumed to be fading.
    public static let fadingAfterHours = 3.0

    private var calendarStorage: Calendar?

    public var calendar: Calendar {
        get { calendarStorage ?? .current }
        set { calendarStorage = newValue }
    }

    enum CodingKeys: String, CodingKey {
        case medicationName, doseTimes
    }

    public init(medicationName: String, doseTimes: [DoseTime], calendar: Calendar = .current) {
        self.medicationName = medicationName
        self.doseTimes = doseTimes.sorted()
        self.calendarStorage = calendar
    }

    public static func == (lhs: MedicationSchedule, rhs: MedicationSchedule) -> Bool {
        lhs.medicationName == rhs.medicationName && lhs.doseTimes == rhs.doseTimes
    }

    public var isEmpty: Bool { doseTimes.isEmpty }

    /// Dose times on the day containing `date`.
    public func doseDates(on date: Date) -> [Date] {
        let start = calendar.startOfDay(for: date)
        return doseTimes.compactMap {
            calendar.date(bySettingHour: $0.hour, minute: $0.minute, second: 0, of: start)
        }
    }

    /// The first dose strictly after `date`, rolling into tomorrow.
    public func nextDose(after date: Date) -> Date? {
        guard !isEmpty else { return nil }
        if let today = doseDates(on: date).first(where: { $0 > date }) { return today }
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: date) else { return nil }
        return doseDates(on: tomorrow).first
    }

    /// The scheduled dose currently waiting to be taken, if any: the most
    /// recent dose time whose due window has opened and that has not been
    /// matched by a dose taken today.
    public func dueDose(at date: Date, takenToday: [Date]) -> Date? {
        guard !isEmpty else { return nil }
        let lead = TimeInterval(Self.dueLeadMinutes * 60)
        let opened = doseDates(on: date).filter { $0.addingTimeInterval(-lead) <= date }
        guard let candidate = opened.last else { return nil }
        // A dose logged within the window after the previous dose time counts
        // as this one. Anything taken at or after (candidate - lead) matches.
        let matched = takenToday.contains { $0 >= candidate.addingTimeInterval(-lead) }
        return matched ? nil : candidate
    }

    public func isDoseDue(at date: Date, takenToday: [Date]) -> Bool {
        dueDose(at: date, takenToday: takenToday) != nil
    }

    /// Whether `date` falls in a predicted off window.
    public func isPredictedOffPeriod(at date: Date, lastDoseTaken: Date?) -> Bool {
        guard !isEmpty else { return false }
        if let next = nextDose(after: date),
           next.timeIntervalSince(date) <= TimeInterval(Self.dueLeadMinutes * 60) {
            return true
        }
        guard let last = lastDoseTaken else {
            // Nothing logged yet: before the first dose of the day is off.
            if let first = doseDates(on: date).first { return date < first }
            return false
        }
        return date.timeIntervalSince(last) > Self.fadingAfterHours * 3600
    }
}
