import Foundation

#if canImport(UIKit)
import UIKit
#endif

/// Three signals that must be told apart by feel: the walking cue, a
/// reminder, and an alert. Each is a list of pulse lengths in milliseconds
/// with equal gaps between pulses.
public enum HapticPattern: String, CaseIterable {
    /// Two quick taps, in time with the beat.
    case cue
    /// One long, soft buzz.
    case reminder
    /// Three strong pulses.
    case alert

    public var pulsesMs: [Int] {
        switch self {
        case .cue: return [60, 60]
        case .reminder: return [400]
        case .alert: return [250, 250, 250]
        }
    }

    public var gapMs: Int { 120 }

    public var totalDurationMs: Int {
        pulsesMs.reduce(0, +) + gapMs * max(0, pulsesMs.count - 1)
    }
}

public protocol HapticPatternPlaying: AnyObject {
    func play(_ pattern: HapticPattern)
}

/// The iPhone's own motor.
public final class PhoneHaptics: HapticPatternPlaying {
    public init() {}

    public func play(_ pattern: HapticPattern) {
        #if os(iOS)
        let generator: UIImpactFeedbackGenerator
        switch pattern {
        case .cue: generator = UIImpactFeedbackGenerator(style: .light)
        case .reminder: generator = UIImpactFeedbackGenerator(style: .medium)
        case .alert: generator = UIImpactFeedbackGenerator(style: .heavy)
        }
        generator.prepare()
        var delayMs = 0
        for pulse in pattern.pulsesMs {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delayMs)) {
                generator.impactOccurred()
            }
            delayMs += pulse + pattern.gapMs
        }
        #endif
    }
}

/// Sends each signal where it will be felt: the glasses when they can
/// buzz, the phone otherwise. Alerts go to both.
@MainActor
public final class HapticRouter {
    private let phone: HapticPatternPlaying
    private let glasses: GlassesSessionManager

    public init(phone: HapticPatternPlaying, glasses: GlassesSessionManager) {
        self.phone = phone
        self.glasses = glasses
    }

    public func play(_ pattern: HapticPattern) {
        let glassesCan = glasses.connectionState == .connected
            && glasses.capabilities?.haptics == true
            && glasses.device != nil
        if glassesCan {
            glasses.device?.playHaptic(pattern)
            if pattern == .alert { phone.play(pattern) }
        } else {
            phone.play(pattern)
        }
    }
}
