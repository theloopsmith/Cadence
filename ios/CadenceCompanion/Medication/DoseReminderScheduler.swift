import Foundation
import UserNotifications

/// A reminder the phone shows at a dose time, whether or not Cadence is open.
public struct DoseReminderRequest: Equatable {
    public let identifier: String
    public let title: String
    public let body: String
    public let hour: Int
    public let minute: Int
    /// Daily at the given time, or a one-off on a specific day.
    public let repeatsDaily: Bool
    public let onDay: DateComponents?
}

/// What the scheduler needs from the system notification centre.
public protocol DoseNotificationCentering: AnyObject {
    func requestAuthorization() async -> Bool
    func add(_ request: DoseReminderRequest)
    func removePending(withIdentifiers ids: [String])
    func removeAllPending()
}

public final class SystemNotificationCenter: DoseNotificationCentering {
    /// `UNUserNotificationCenter.current()` aborts outside an app bundle
    /// (for example under `swift test`), so it is created on first use and
    /// only when a bundle identifier exists.
    private lazy var center: UNUserNotificationCenter? = {
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }()

    public init() {}

    public func requestAuthorization() async -> Bool {
        guard let center else { return false }
        return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    public func add(_ request: DoseReminderRequest) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = request.title
        content.body = request.body
        content.sound = .default
        content.interruptionLevel = .timeSensitive

        var components = request.onDay ?? DateComponents()
        components.hour = request.hour
        components.minute = request.minute
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: request.repeatsDaily)
        center.add(UNNotificationRequest(identifier: request.identifier, content: content, trigger: trigger))
    }

    public func removePending(withIdentifiers ids: [String]) {
        center?.removePendingNotificationRequests(withIdentifiers: ids)
    }

    public func removeAllPending() {
        center?.removeAllPendingNotificationRequests()
    }
}

/// Turns the medication schedule into daily reminders and keeps them in
/// step as the schedule or today's doses change. Reminders only; the words
/// never suggest a change to the schedule.
@MainActor
public final class DoseReminderScheduler: ObservableObject {
    public enum Status: Equatable { case unknown, scheduled(Int), notAllowed, none }

    @Published public private(set) var status: Status = .unknown

    private let center: DoseNotificationCentering
    private static let prefix = "cadence.dose."

    public init(center: DoseNotificationCentering = SystemNotificationCenter()) {
        self.center = center
    }

    /// Replaces every pending reminder with one per dose time.
    public func sync(_ schedule: MedicationSchedule) async {
        center.removeAllPending()
        guard !schedule.isEmpty else {
            status = .none
            return
        }
        guard await center.requestAuthorization() else {
            status = .notAllowed
            return
        }
        for time in schedule.doseTimes {
            center.add(Self.dailyRequest(for: time, schedule: schedule))
        }
        status = .scheduled(schedule.doseTimes.count)
    }

    /// Today's dose was logged: withdraw today's reminder for it and put the
    /// daily one back from tomorrow, so the phone does not nag about a pill
    /// already taken.
    public func doseTaken(at date: Date, schedule: MedicationSchedule) {
        let cal = schedule.calendar
        guard let due = schedule.dueDose(at: date, takenToday: []) ?? nearestDoseTime(to: date, schedule: schedule) else {
            return
        }
        let time = DoseTime(hour: cal.component(.hour, from: due), minute: cal.component(.minute, from: due))
        let id = Self.identifier(for: time)
        center.removePending(withIdentifiers: [id])

        guard let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: date)) else { return }
        // A repeating calendar trigger cannot begin in the future, so tomorrow
        // gets a one-off and the daily series is restored by the next `sync`.
        let tomorrowComponents = cal.dateComponents([.year, .month, .day], from: tomorrow)
        center.add(Self.request(for: time, schedule: schedule, repeatsDaily: false, onDay: tomorrowComponents,
                                identifierSuffix: ".next"))
    }

    private func nearestDoseTime(to date: Date, schedule: MedicationSchedule) -> Date? {
        schedule.doseDates(on: date).min { abs($0.timeIntervalSince(date)) < abs($1.timeIntervalSince(date)) }
    }

    static func identifier(for time: DoseTime) -> String {
        String(format: "%@%02d-%02d", prefix, time.hour, time.minute)
    }

    static func dailyRequest(for time: DoseTime, schedule: MedicationSchedule) -> DoseReminderRequest {
        request(for: time, schedule: schedule, repeatsDaily: true, onDay: nil, identifierSuffix: "")
    }

    static func request(
        for time: DoseTime,
        schedule: MedicationSchedule,
        repeatsDaily: Bool,
        onDay: DateComponents?,
        identifierSuffix: String
    ) -> DoseReminderRequest {
        DoseReminderRequest(
            identifier: identifier(for: time) + identifierSuffix,
            title: "Time for your \(schedule.medicationName)",
            body: "Whenever you're ready, take your \(schedule.medicationName). Then open Cadence and tap Taken, or just say it.",
            hour: time.hour,
            minute: time.minute,
            repeatsDaily: repeatsDaily,
            onDay: onDay
        )
    }
}
