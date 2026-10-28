import Combine
import Foundation

/// The medication card on Today: the next dose, one big Taken button, and
/// an Undo that stays until the next action. Also decides simple mode from
/// the predicted off window.
@MainActor
public final class DoseLogModel: ObservableObject {
    @Published public private(set) var headline = ""
    @Published public private(set) var detail = ""
    @Published public private(set) var isDoseDue = false
    @Published public private(set) var canUndo = false
    @Published public private(set) var isSimpleMode = false
    @Published public private(set) var takenToday: [Date] = []

    public var schedule: MedicationSchedule {
        didSet { refresh() }
    }

    private let diary: DiaryStore
    private let sync: EventSyncManager
    private let clock: () -> Date
    private var lastLogged: (eventUUID: String, diaryID: String, at: Date)?
    private var timer: AnyCancellable?

    public init(
        schedule: MedicationSchedule,
        diary: DiaryStore,
        sync: EventSyncManager,
        clock: @escaping () -> Date = Date.init
    ) {
        self.schedule = schedule
        self.diary = diary
        self.sync = sync
        self.clock = clock
        reloadTakenToday()
        refresh()
        timer = Timer.publish(every: 60, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.refresh() }
    }

    /// Logs the dose now. Queued for the backend, written to the diary.
    public func markTaken() {
        let now = clock()
        let eventUUID = UUID().uuidString
        let diaryEvent = DiaryEvent(kind: .doseTaken, at: now, detail: schedule.medicationName)
        try? diary.append(diaryEvent)
        sync.saveLocalImmediate(
            eventUUID: eventUUID,
            endpoint: "/api/v1/medication/dose",
            payload: [
                "event_uuid": eventUUID,
                "timestamp_utc": ISO8601DateFormatter().string(from: now),
                "medication_name": schedule.medicationName,
            ]
        )
        lastLogged = (eventUUID, diaryEvent.id, now)
        takenToday.append(now)
        canUndo = true
        refresh()
    }

    /// Takes the last dose back. Available until the next action.
    public func undo() {
        guard let last = lastLogged else { return }
        try? diary.remove(id: last.diaryID)
        sync.withdrawPending(last.eventUUID)
        takenToday.removeAll { $0 == last.at }
        lastLogged = nil
        canUndo = false
        refresh()
    }

    public var lastDoseTaken: Date? { takenToday.max() }

    // MARK: - Text

    private func reloadTakenToday() {
        let now = clock()
        let events = (try? diary.events(on: now)) ?? []
        takenToday = events.filter { $0.kind == .doseTaken }.map(\.at)
    }

    private func refresh() {
        let now = clock()
        isSimpleMode = schedule.isPredictedOffPeriod(at: now, lastDoseTaken: lastDoseTaken)

        if schedule.isEmpty {
            isDoseDue = false
            headline = "No medication times set"
            detail = "A care partner can add your dose times in setup."
            return
        }

        if let due = schedule.dueDose(at: now, takenToday: takenToday) {
            isDoseDue = true
            headline = "\(schedule.medicationName) · \(Self.timeString(due, calendar: schedule.calendar))"
            detail = now > due
                ? "Ready when you are. Tap Taken when you have had it."
                : "Coming up. Tap Taken once you have had it."
            return
        }

        isDoseDue = false
        if canUndo, let last = lastLogged {
            headline = "Logged at \(Self.timeString(last.at, calendar: schedule.calendar))"
        } else if let last = lastDoseTaken {
            headline = "Last dose at \(Self.timeString(last, calendar: schedule.calendar))"
        } else {
            headline = "Nothing due right now"
        }
        if let next = schedule.nextDose(after: now) {
            detail = "Next: \(schedule.medicationName) at \(Self.timeString(next, calendar: schedule.calendar))"
        } else {
            detail = ""
        }
    }

    static func timeString(_ date: Date, calendar: Calendar) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "H:mm"
        return f.string(from: date)
    }
}
