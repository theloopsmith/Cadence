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
    func pendingIdentifiers() async -> [String]
    func add(_ request: DoseReminderRequest) async throws
    func removePending(withIdentifiers ids: [String])
    func removeAllPending()
    func removeDelivered(withIdentifiers ids: [String])
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

    public func pendingIdentifiers() async -> [String] {
        guard let center else { return [] }
        return await center.pendingNotificationRequests().map(\.identifier)
    }

    public func add(_ request: DoseReminderRequest) async throws {
        guard let center else { throw CocoaError(.featureUnsupported) }
        let content = UNMutableNotificationContent()
        content.title = request.title
        content.body = request.body
        content.sound = .default
        content.interruptionLevel = .timeSensitive

        var components = request.onDay ?? DateComponents()
        components.hour = request.hour
        components.minute = request.minute
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: request.repeatsDaily)
        try await center.add(UNNotificationRequest(identifier: request.identifier, content: content, trigger: trigger))
    }

    public func removePending(withIdentifiers ids: [String]) {
        center?.removePendingNotificationRequests(withIdentifiers: ids)
    }

    public func removeDelivered(withIdentifiers ids: [String]) {
        center?.removeDeliveredNotifications(withIdentifiers: ids)
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
    public enum Status: Equatable { case unknown, scheduled(Int), notAllowed, none, failed }

    @Published public private(set) var status: Status = .unknown

    private let center: DoseNotificationCentering
    private static let prefix = "cadence.dose."
    private var suspended = false

    public init(center: DoseNotificationCentering = SystemNotificationCenter()) {
        self.center = center
    }

    /// Reconciles medication reminders with one repeating request per saved time.
    public func sync(_ schedule: MedicationSchedule) async { await sync([schedule]) }

    private var syncID = UUID()
    private var syncTask: Task<Void, Never>?
    public func sync(_ schedules: [MedicationSchedule]) async {
        let id = UUID(); syncID = id
        let previous = syncTask
        let task = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, !self.suspended, self.syncID == id else { return }
            await self.apply(schedules, id: id)
        }
        syncTask = task
        await task.value
    }

    private func apply(_ schedules: [MedicationSchedule], id: UUID) async {
        let requests = schedules.flatMap { schedule in
            schedule.doseTimes.map { Self.dailyRequest(for: $0, schedule: schedule) }
        }
        let desired = Set(requests.map(\.identifier))
        let existing = await center.pendingIdentifiers()
        guard !suspended, syncID == id else { return }
        if requests.isEmpty {
            center.removePending(withIdentifiers: existing.filter { $0.hasPrefix(Self.prefix) })
            status = .none
            return
        }
        let authorized = await center.requestAuthorization()
        guard !suspended, syncID == id else { return }
        guard authorized else { status = .notAllowed; return }
        // Remove obsolete dose times, including old one-offs, without clearing
        // other notification categories or valid reminders before replacement.
        center.removePending(withIdentifiers: existing.filter { $0.hasPrefix(Self.prefix) && !desired.contains($0) })
        var failed = false
        for request in requests {
            guard !suspended, syncID == id else { return }
            do { try await center.add(request) } catch { failed = true }
            if suspended {
                // An in-flight system add may finish after local reset.
                center.removePending(withIdentifiers: [request.identifier])
                return
            }
        }
        guard syncID == id else { return }
        status = failed ? .failed : .scheduled(requests.count)
    }

    /// Dismiss the visible reminder while preserving its repeating request.
    /// Removing a pending repeat cancels every future occurrence, not just today.
    /// An early record can still be followed by today's scheduled reminder.
    public func doseTaken(at date: Date, schedule: MedicationSchedule) {
        guard !suspended else { return }
        let cal = schedule.calendar
        guard let due = schedule.dueDose(at: date, takenToday: []) ?? nearestDoseTime(to: date, schedule: schedule) else {
            return
        }
        let time = DoseTime(hour: cal.component(.hour, from: due), minute: cal.component(.minute, from: due))
        let id = Self.identifier(for: time, medication: schedule.medicationName)
        center.removeDelivered(withIdentifiers: [id])
    }

    public func suspendForLocalReset() {
        suspended = true
        center.removeAllPending()
        status = .none
    }

    private func nearestDoseTime(to date: Date, schedule: MedicationSchedule) -> Date? {
        schedule.doseDates(on: date).min { abs($0.timeIntervalSince(date)) < abs($1.timeIntervalSince(date)) }
    }

    static func identifier(for time: DoseTime, medication: String = "") -> String {
        let key = Data(medication.utf8).base64EncodedString()
        return String(format: "%@%@.%02d-%02d", prefix, key, time.hour, time.minute)
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
            identifier: identifier(for: time, medication: schedule.medicationName) + identifierSuffix,
            title: "Check your \(schedule.medicationName) reminder",
            body: "Check your saved schedule and dose record for \(schedule.medicationName). If you already took it, record it in Cadence. If unsure, ask your caregiver or pharmacist before deciding what to do.",
            hour: time.hour,
            minute: time.minute,
            repeatsDaily: repeatsDaily,
            onDay: onDay
        )
    }
}
