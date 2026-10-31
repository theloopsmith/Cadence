import Foundation

/// Discovery is asynchronous even when glasses are already paired in Meta AI.
/// Session creation must wait for a selector to publish an actual device.
public enum GlassesDeviceReadiness {
    public static func waitForDevice<Updates: AsyncSequence>(
        current: String?, updates: Updates
    ) async throws -> String where Updates.Element == String? {
        try Task.checkCancellation()
        if let current, !current.isEmpty { return current }
        for try await identifier in updates {
            try Task.checkCancellation()
            if let identifier, !identifier.isEmpty { return identifier }
        }
        try Task.checkCancellation()
        throw GlassesError.notConnected
    }
}
