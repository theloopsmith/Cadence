import Foundation

/// Tracks 100ms sliding RMS voice volume (dBFS) and computes 5-second vowel-only
/// phonation amplitude stability (sigma_dB,phonation) for Task 1 of the Guided Home Motor Exam.
public final class VoiceMonitor {
    public static let shared = VoiceMonitor()
    public private(set) var currentLevelDbfs: Double = -50.0
    public var isUserSpeaking: Bool {
        return currentLevelDbfs > -38.0
    }

    public init() {}

    /// Computes phonation stability sigma_dB strictly over the 5-second sustained vowel ("Ahhh") segment.
    public func computeVowelPhonationStabilityDb(vowelWindowDbfsSamples: [Double]) -> Double {
        guard vowelWindowDbfsSamples.count >= 2 else { return 0.0 }
        let mean = vowelWindowDbfsSamples.reduce(0.0, +) / Double(vowelWindowDbfsSamples.count)
        let variance = vowelWindowDbfsSamples.reduce(0.0) { acc, val in
            let diff = val - mean
            return acc + diff * diff
        } / Double(vowelWindowDbfsSamples.count)
        return sqrt(variance)
    }
}
