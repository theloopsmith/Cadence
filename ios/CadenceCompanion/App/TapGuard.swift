import Foundation

#if canImport(UIKit)
import UIKit
#endif

/// Lets one tap through and swallows the echo a trembling finger produces.
/// Each control gets its own guard so neighbouring buttons stay independent.
public final class TapGuard {
    public let windowSec: TimeInterval
    private var lastAccepted: Date?

    public init(windowSec: TimeInterval = 0.6) {
        self.windowSec = windowSec
    }

    /// Runs `action` unless another tap was accepted within the window.
    public func perform(at now: Date = Date(), _ action: () -> Void) {
        if let last = lastAccepted, now.timeIntervalSince(last) < windowSec { return }
        lastAccepted = now
        action()
    }
}

/// "Yes, I heard you": a short physical confirmation on every accepted tap.
public enum Haptics {
    public static func tap() {
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        #endif
    }

    public static func success() {
        #if os(iOS)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
    }

    public static func warning() {
        #if os(iOS)
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        #endif
    }
}
