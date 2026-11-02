import Foundation
@testable import CadenceCompanion

/// Tests explicitly supply a fixture credential; the shipped app has none.
func makeTestEventSyncManager(transport: EventTransport? = nil, databasePath: String? = nil, startPeriodicDrain: Bool = true) -> EventSyncManager {
    let queue = EventSyncManager(transport: transport, databasePath: databasePath, startPeriodicDrain: startPeriodicDrain)
    queue.configureSession(baseURL: queue.backendBaseURL, bearerToken: "cadence-dev-device-writer-token-2026", replaceTransport: false)
    return queue
}
