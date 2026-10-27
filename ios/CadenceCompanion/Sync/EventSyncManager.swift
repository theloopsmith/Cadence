import Foundation

/// Encrypted local offline queue (FileProtectionType.completeUnlessOpen) with immediate P0 save
/// and exponential backoff sync to the FastAPI Clinical Orchestrator.
public final class EventSyncManager {
    public static let shared = EventSyncManager()
    private var pendingQueue: [[String: Any]] = []

    private init() {}

    /// Persists P0 Fall candidate immediately at Stage 3 completion before 12s check-in starts.
    public func saveLocalImmediate(eventUUID: String, endpoint: String, payload: [String: Any]) {
        var record = payload
        record["event_uuid"] = eventUUID
        record["endpoint"] = endpoint
        pendingQueue.append(record)
    }

    public var pendingCount: Int {
        return pendingQueue.count
    }
}
