import Combine
import Foundation

/// One explicit edit session. Camera presentation never reloads or discards it.
@MainActor
public final class MedicationPlanEditor: ObservableObject {
    public struct Item: Identifiable {
        public let id = UUID()
        public var originalName: String
        public var name: String
        public var times: [DoseTime]
        public var photo: Data?
        public var photoChanged = false
    }
    @Published public var items: [Item] = []
    @Published public private(set) var isEditing = false
    @Published public private(set) var error: String?
    @Published public private(set) var receipt: String?
    private let settings: AppSettings
    private let loadPhoto: (String) -> Data?
    private let savePhoto: (Data?, String) -> String?

    public init(settings: AppSettings, loadPhoto: @escaping (String) -> Data?, savePhoto: @escaping (Data?, String) -> String?) {
        self.settings = settings; self.loadPhoto = loadPhoto; self.savePhoto = savePhoto
    }
    public func begin() {
        guard !isEditing else { return }
        items = settings.medications.map { Item(originalName: $0.medicationName, name: $0.medicationName, times: $0.doseTimes, photo: loadPhoto($0.medicationName)) }
        isEditing = true; error = nil; receipt = nil
    }
    public func add() { begin(); items.append(Item(originalName: "", name: "", times: [])) }
    public func cancel() { items = []; isEditing = false; error = nil }
    @discardableResult public func save() -> Bool {
        guard isEditing else { return false }
        error = nil
        do {
            try settings.saveMedicationPlan(items.map { MedicationSchedule(medicationName: $0.name, doseTimes: $0.times) })
            for index in items.indices {
                let name = items[index].name.trimmingCharacters(in: .whitespacesAndNewlines)
                if items[index].photoChanged || (name != items[index].originalName && items[index].photo != nil) {
                    if let problem = savePhoto(items[index].photo, name) {
                        error = "Reminder times are saved. " + problem
                        return false
                    }
                    items[index].photoChanged = false
                }
                items[index].originalName = name
                items[index].name = name
            }
            let count = settings.medications.count
            let reminders = settings.medications.reduce(0) { $0 + $1.doseTimes.count }
            receipt = count == 0 ? "Your medication routine is now empty." : "Saved \(count) medication\(count == 1 ? "" : "s") with \(reminders) reminder\(reminders == 1 ? "" : "s")."
            isEditing = false
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
}
