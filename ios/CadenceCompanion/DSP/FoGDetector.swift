import Accelerate
import Foundation

public enum FoGArmingMode: String {
    case disarmed = "disarmed"
    case walking = "walking"
    case sitToStand = "sit_to_stand"
    case turningUpright = "turning_upright"
}

/// Pipeline 1 (Demo-Critical P0): Freezing of Gait (FoG) edge detector (<50ms DSP).
/// Evaluates uniformly resampled dynamic-N FFT windows with a 0.50s hop (3 hops = 1.50s).
public final class FoGDetector {
    public private(set) var armingMode: FoGArmingMode = .disarmed
    private var consecutiveFreezeHops: Int = 0
    private var consecutiveRecoveryHops: Int = 0
    public private(set) var isEpisodeActive: Bool = false

    public init() {}

    /// Evaluates a single 0.50s hop from pre-computed band powers and posture angles.
    public func evaluateHop(
        locomotorBandPower: Double,
        freezeBandPower: Double,
        integratedYaw15sDeg: Double,
        pitchDeg: Double,
        rollDeg: Double,
        sitToStandDetected: Bool,
        isUserSpeaking: Bool
    ) -> Bool {
        let totalEnergy = locomotorBandPower + freezeBandPower
        let fi = freezeBandPower / (locomotorBandPower + 1e-6)

        // 3-Mode Arming State Machine (Active Walk, Sit-to-Stand, Upright Posture Turn)
        let isUpright = abs(pitchDeg) <= 35.0 && abs(rollDeg) <= 35.0
        if locomotorBandPower > 0.08 {
            armingMode = .walking
        } else if sitToStandDetected {
            armingMode = .sitToStand
        } else if isUpright && abs(integratedYaw15sDeg) >= 45.0 {
            armingMode = .turningUpright
        }

        // Speech-Coupled Threshold Modifier (+0.8 FI when speaking)
        let thresholdFI = isUserSpeaking ? 2.8 : 2.0

        if armingMode != .disarmed && totalEnergy > 0.02 && fi > thresholdFI {
            consecutiveFreezeHops += 1
            consecutiveRecoveryHops = 0
            // 3 consecutive 0.50s hops = 1.50s
            if consecutiveFreezeHops >= 3 && !isEpisodeActive {
                isEpisodeActive = true
                AudioCueEngine.shared.startRASMetronome(bpm: 100)
            }
        } else if isEpisodeActive && fi < 1.2 && locomotorBandPower > 0.08 {
            consecutiveRecoveryHops += 1
            if consecutiveRecoveryHops >= 6 { // 3.0s continuous recovery
                isEpisodeActive = false
                consecutiveFreezeHops = 0
                AudioCueEngine.shared.stopRASMetronome()
            }
        } else {
            consecutiveFreezeHops = 0
        }

        return isEpisodeActive
    }
}
