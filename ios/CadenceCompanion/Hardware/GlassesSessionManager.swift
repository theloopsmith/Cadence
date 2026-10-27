import Foundation

public enum GlassesWearState: String {
    case worn = "worn"
    case notWorn = "not_worn"
}

/// Wrapper for Meta Wearables Device Access Toolkit session + Simulator Scenario Replay.
public final class GlassesSessionManager {
    public static let shared = GlassesSessionManager()
    public var wearState: GlassesWearState = .worn
    public var isConnected: Bool = true

    private init() {}
}
