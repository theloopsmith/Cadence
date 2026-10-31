import Combine
import Foundation

/// The medication card on Today: the next dose, one big Taken button, and
/// an Undo that stays until the next action. Also decides simple mode from
/// the predicted off window.
@MainActor
public final class DoseLogModel: ObservableObject {
    @Published public private(set) var saveError: String?
    private var historyUnavailable = false
    @Published public private(set) var headline = ""
    @Published public private(set) var detail = ""
    @Published public private(set) var isDoseDue = false
    @Published public private(set) var canUndo = false
    @Published public private(set) var isSimpleMode = false
    @Published public private(set) var takenToday: [Date] = []

    public var onDoseTaken: ((Date, MedicationSchedule) -> Void)?
    public var schedule: MedicationSchedule {
        didSet {
            if oldValue.medicationName != schedule.medicationName { lastLogged = nil; canUndo = false }
            reloadTakenToday(); refresh()
        }
    }

    private let diary: DiaryStore
    private let sync: EventSyncManager
    private let clock: () -> Date
    private var lastLogged: (eventUUID: String, diaryID: String, at: Date, dataGeneration: Int)?
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
    @discardableResult
    public func markTaken() -> Bool {
        let now = clock()
        let eventUUID = UUID().uuidString
        let dataGeneration = sync.currentDataGeneration
        let diaryEvent = DiaryEvent(kind: .doseTaken, at: now, detail: schedule.medicationName)
        do { try diary.append(diaryEvent) }
        catch { saveError = "I couldn't save the dose on this phone. Nothing was logged. Check storage and try again."; return false }
        saveError = nil
        let queued = sync.saveLocalImmediate(
            eventUUID: eventUUID,
            endpoint: "/api/v1/medication/dose",
            payload: [
                "event_uuid": eventUUID,
                "timestamp_utc": ISO8601DateFormatter().string(from: now),
                "medication_name": schedule.medicationName,
            ], dataGeneration: dataGeneration
        )
        lastLogged = (eventUUID, diaryEvent.id, now, dataGeneration)
        reloadTakenToday()
        canUndo = true
        if case .failure = queued { saveError = "The dose is recorded on this phone, but sharing could not be saved. Keep Cadence open and check storage." }
        refresh()
        onDoseTaken?(now, schedule)
        return true
    }

    /// Takes the last dose back. Available until the next action.
    @discardableResult
    public func undo() -> Bool {
        guard let last = lastLogged else { return false }
        let now = clock()
        do { try diary.remove(id: last.diaryID) }
        catch { saveError = "I couldn't undo that dose record on this phone. Check storage and try again."; return false }
        saveError = nil
        let withdrawn = sync.withdrawPending(last.eventUUID)
        if !withdrawn || sync.isEventSynced(last.eventUUID) {
            let retractionUUID = UUID().uuidString
            _ = sync.saveLocalImmediate(
                eventUUID: retractionUUID,
                endpoint: "/api/v1/medication/dose/retract",
                payload: [
                    "event_uuid": retractionUUID,
                    "retracted_event_uuid": last.eventUUID,
                    "timestamp_utc": ISO8601DateFormatter().string(from: now),
                    "reason": "user_undo"
                ], dataGeneration: last.dataGeneration
            )
        }
        takenToday.removeAll { $0 == last.at }
        lastLogged = nil
        canUndo = false
        refresh()
        return true
    }

    public var lastDoseTaken: Date? { takenToday.max() }

    // MARK: - Text

    private func reloadTakenToday() {
        let now = clock()
        do {
            let events = try diary.events(on: now)
            takenToday = events.filter { $0.kind == .doseTaken && $0.detail == schedule.medicationName }.map(\.at)
            historyUnavailable = false
        } catch {
            historyUnavailable = true
            saveError = "Medication history could not be read. I can't reliably tell which doses were logged."
        }
    }

    private func refresh() {
        let now = clock()
        isSimpleMode = schedule.isPredictedOffPeriod(at: now, lastDoseTaken: lastDoseTaken)

        if historyUnavailable {
            isDoseDue = false; headline = "Medication history unavailable"; detail = saveError ?? "Check phone storage."; return
        }
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
