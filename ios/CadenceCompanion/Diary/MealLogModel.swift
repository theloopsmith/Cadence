import Combine
import Foundation

/// Photos remain in the account-bound phone profile, never in inference requests.
public struct MealPhotoStore {
    public let directory: URL
    public init(diary: DiaryStore) { directory = diary.directory.appendingPathComponent("MealPhotos", isDirectory: true) }
    private func file(_ id: String) -> URL? {
        guard UUID(uuidString: id) != nil else { return nil }
        return directory.appendingPathComponent(id + ".jpg")
    }
    public func save(_ data: Data, id: String) throws {
        guard let file = file(id) else { throw CocoaError(.fileWriteInvalidFileName) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
    }
    public func load(id: String) -> Data? { file(id).flatMap { try? Data(contentsOf: $0) } }
    public func remove(id: String) { if let file = file(id) { try? FileManager.default.removeItem(at: file) } }
}

@MainActor
public final class MealLogModel: ObservableObject {
    @Published public private(set) var savedEvent: DiaryEvent?
    @Published public private(set) var message: String?
    @Published public private(set) var error: String?
    @Published public private(set) var sharingNeedsRetry = false
    private let diary: DiaryStore
    private let sync: EventSyncManager
    private let photos: MealPhotoStore
    private let owner: String?
    private let destination: String
    private let clock: () -> Date

    public init(diary: DiaryStore, sync: EventSyncManager, clock: @escaping () -> Date = Date.init) {
        self.diary = diary; self.sync = sync; self.photos = MealPhotoStore(diary: diary)
        self.owner = EventSyncManager.owner(for: sync.deviceBearerToken)
        self.destination = sync.backendBaseURL; self.clock = clock
    }
    private var sessionMatches: Bool {
        owner == EventSyncManager.owner(for: sync.deviceBearerToken) && destination == sync.backendBaseURL
    }
    @discardableResult public func save(at date: Date, note: String, photo: Data?) -> Bool {
        guard savedEvent == nil else { return false }
        guard sessionMatches else { error = "Your account or server changed. Close this screen and reopen your meal diary."; return false }
        guard date <= clock().addingTimeInterval(60) else { error = "Choose a meal time that has already happened."; return false }
        var event = DiaryEvent(kind: .mealLogged, at: date, detail: String(note.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)))
        event.hasMealPhoto = photo != nil
        if let owner { event.mealSharing = MealSharingContext(owner: owner, destination: destination, generation: sync.currentDataGeneration) }
        do {
            if let photo { try photos.save(photo, id: event.id) }
            try diary.append(event)
        } catch {
            photos.remove(id: event.id)
            self.error = "The meal could not be saved on this phone. Check storage and try again."
            return false
        }
        savedEvent = event; error = nil
        queue(event)
        return true
    }
    private func queue(_ event: DiaryEvent) {
        guard let context = event.mealSharing, context.owner == owner, context.destination == destination, sessionMatches else {
            message = "Meal saved on this phone. Sign in to share future meal times."; return
        }
        guard context.generation == sync.currentDataGeneration else {
            sharingNeedsRetry = false; message = "Meal stays on this phone; the server diary was reset."; return
        }
        let result = sync.saveLocalImmediate(eventUUID: event.id, endpoint: "/api/v1/meals/log", payload: [
            "event_uuid": event.id, "timestamp_utc": ISO8601DateFormatter().string(from: event.at)
        ], dataGeneration: context.generation)
        if case .failure = result {
            sharingNeedsRetry = true
            message = "Meal saved on this phone. Sharing could not be queued; keep Cadence open and retry."
        } else {
            sharingNeedsRetry = false
            message = "Meal saved on this phone. Its time is queued to share when connected. Photos and notes stay here."
        }
    }
    public func retrySharing() { sync.retryPersistingBufferedEvents(); if let event = savedEvent { queue(event) } }
    public func newMeal() { savedEvent = nil; message = nil; error = nil; sharingNeedsRetry = false }
    /// Recover the diary→outbox crash gap, without changing owner or erase generation.
    public func recoverPendingSharing() {
        guard sessionMatches, let owner else { return }
        for offset in 0..<30 {
            guard let day = Calendar.current.date(byAdding: .day, value: -offset, to: clock()) else { continue }
            guard let events = try? diary.events(on: day) else { continue }
            for event in events where event.kind == .mealLogged {
                guard let context = event.mealSharing, context.owner == owner, context.destination == destination,
                      context.generation == sync.currentDataGeneration, !sync.hasRecordedEvent(event.id) else { continue }
                _ = sync.saveLocalImmediate(eventUUID: event.id, endpoint: "/api/v1/meals/log", payload: [
                    "event_uuid": event.id, "timestamp_utc": ISO8601DateFormatter().string(from: event.at)
                ], dataGeneration: context.generation)
            }
        }
    }
}
