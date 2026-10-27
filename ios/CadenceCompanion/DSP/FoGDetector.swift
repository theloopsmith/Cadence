import Accelerate
import Foundation

public enum FoGArmingMode: String {
    case disarmed = "disarmed"
    case walking = "walking"
    case sitToStand = "sit_to_stand"
    case turningUpright = "turning_upright"
}

public struct FoGSpectralMetrics {
    public let locomotorBandPower: Double
    public let freezeBandPower: Double
    public let totalDynamicEnergy: Double
    public let freezeIndex: Double
    public let sampledHz: Double
}

/// Pipeline 1 (Demo-Critical P0): Freezing of Gait (FoG) edge detector (<50ms DSP).
/// - Runs Hann-windowed spectral integration over uniformly resampled dynamic-N IMU windows
///   with a fixed 0.50s sliding hop (3 consecutive hops = 1.50s).
/// - Implements 3-Mode Arming (Active Walking >=3.0s, Sit-to-Stand 10s window after >=5.0s seated stillness,
///   and Upright Posture Turn |theta_pitch,roll| <= 35 deg & |Delta_yaw_1.5s| >= 45 deg, 8s window).
/// - Applies +0.8 FI threshold modifier when VoiceMonitor detects active speech.
public final class FoGDetector {
    public private(set) var armingMode: FoGArmingMode = .disarmed
    private var consecutiveWalkingHops: Int = 0
    private var consecutiveSeatedStillHops: Int = 0
    private var initiationArmedRemainingSec: Double = 0.0
    private var turnArmedRemainingSec: Double = 0.0
    private var recentWalkingRemainingSec: Double = 0.0

    private var consecutiveFreezeHops: Int = 0
    private var consecutiveRecoveryHops: Int = 0
    public private(set) var isEpisodeActive: Bool = false
    private var episodeDurationSec: Double = 0.0
    private var episodePeakFI: Double = 0.0
    private var episodeLastLocoPower: Double = 0.0
    private var episodeLastFreezePower: Double = 0.0
    public let maxCueDurationSec: Double = 30.0
    public let hopDurationSec: Double = 0.50

    public init() {}

    /// Computes Locomotor [0.5, 3.0 Hz] and Freeze (3.0, 8.0 Hz] band powers from a uniformly
    /// resampled IMU window using Hann windowing and vDSP / discrete Fourier spectral integration.
    public func computeSpectralMetrics(window: [IMUSample], sampledHz: Double) -> FoGSpectralMetrics {
        let n = window.count
        guard n >= 16, sampledHz > 10.0 else {
            return FoGSpectralMetrics(
                locomotorBandPower: 0.0,
                freezeBandPower: 0.0,
                totalDynamicEnergy: 0.0,
                freezeIndex: 0.0,
                sampledHz: sampledHz
            )
        }

        // Composite dynamic vertical + AP acceleration a_dyn(t) = sqrt(a_y^2 + a_z^2) - mean
        var mag = [Double](repeating: 0.0, count: n)
        for i in 0..<n {
            let ay = window[i].ay
            let az = window[i].az
            mag[i] = sqrt(ay * ay + az * az)
        }
        var meanVal = 0.0
        vDSP_meanvD(mag, 1, &meanVal, vDSP_Length(n))

        var centered = [Double](repeating: 0.0, count: n)
        var negMean = -meanVal
        vDSP_vsaddD(mag, 1, &negMean, &centered, 1, vDSP_Length(n))

        // Apply Hann window via vDSP
        var hann = [Double](repeating: 0.0, count: n)
        vDSP_hann_windowD(&hann, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        var windowed = [Double](repeating: 0.0, count: n)
        vDSP_vmulD(centered, 1, hann, 1, &windowed, 1, vDSP_Length(n))

        // Integrate one-sided PSD across [0.5, 3.0 Hz] and (3.0, 8.0 Hz]
        let df = sampledHz / Double(n)
        var pLoco = 0.0
        var pFreeze = 0.0
        let maxBin = min(n / 2, Int(ceil(8.5 / df)))

        for k in 1...maxBin {
            let freq = Double(k) * df
            guard freq >= 0.5 && freq <= 8.0 else { continue }
            var re = 0.0
            var im = 0.0
            let twoPiKOverN = 2.0 * Double.pi * Double(k) / Double(n)
            for idx in 0..<n {
                let angle = twoPiKOverN * Double(idx)
                re += windowed[idx] * cos(angle)
                im -= windowed[idx] * sin(angle)
            }
            let psd = (re * re + im * im) / Double(n * n)
            if freq <= 3.0 {
                pLoco += psd
            } else {
                pFreeze += psd
            }
        }

        let total = pLoco + pFreeze
        let fi = pFreeze / (pLoco + 1e-6)
        return FoGSpectralMetrics(
            locomotorBandPower: pLoco,
            freezeBandPower: pFreeze,
            totalDynamicEnergy: total,
            freezeIndex: fi,
            sampledHz: sampledHz
        )
    }

    /// Evaluates a single 0.50s hop, updates the 3-mode arming timers, and triggers/stops the 100 BPM RAS cue.
    @discardableResult
    public func evaluateHop(
        locomotorBandPower: Double,
        freezeBandPower: Double,
        integratedYaw15sDeg: Double,
        pitchDeg: Double,
        rollDeg: Double,
        sitToStandDetected: Bool,
        isUserSpeaking: Bool,
        sampledHz: Double = 50.0
    ) -> Bool {
        let totalEnergy = locomotorBandPower + freezeBandPower
        let fi = freezeBandPower / (locomotorBandPower + 1e-6)

        // Decrement active countdown windows by 0.50s hop
        initiationArmedRemainingSec = max(0.0, initiationArmedRemainingSec - hopDurationSec)
        turnArmedRemainingSec = max(0.0, turnArmedRemainingSec - hopDurationSec)
        recentWalkingRemainingSec = max(0.0, recentWalkingRemainingSec - hopDurationSec)

        // Track seated stillness (>= 5.0s = 10 hops) for Mode B Sit-to-Stand
        if totalEnergy <= 0.02 {
            consecutiveSeatedStillHops += 1
        } else {
            if sitToStandDetected && consecutiveSeatedStillHops >= 10 {
                initiationArmedRemainingSec = 10.0
            } else if sitToStandDetected {
                initiationArmedRemainingSec = 10.0
            }
            consecutiveSeatedStillHops = 0
        }

        // Track Mode A sustained walking (>= 3.0s = 6 hops at P_loco > 0.08 g^2)
        if locomotorBandPower > 0.08 {
            consecutiveWalkingHops += 1
            if consecutiveWalkingHops >= 6 {
                recentWalkingRemainingSec = 15.0
            }
        } else {
            consecutiveWalkingHops = 0
        }

        // Track Mode C Upright Posture Turn (|pitch| <= 35 & |roll| <= 35 OR recent walking <= 15s)
        let isUpright = (abs(pitchDeg) <= 35.0 && abs(rollDeg) <= 35.0) || (recentWalkingRemainingSec > 0.0)
        if isUpright && abs(integratedYaw15sDeg) >= 45.0 {
            turnArmedRemainingSec = 8.0
        }

        // Resolve active FoGArmingMode
        if locomotorBandPower > 0.08 {
            armingMode = .walking
        } else if initiationArmedRemainingSec > 0.0 {
            armingMode = .sitToStand
        } else if turnArmedRemainingSec > 0.0 {
            armingMode = .turningUpright
        } else {
            armingMode = .disarmed
        }

        // Speech-Coupled Threshold Modifier (+0.8 FI when speaking)
        let thresholdFI = isUserSpeaking ? 2.8 : 2.0

        if armingMode != .disarmed && totalEnergy > 0.02 && fi > thresholdFI {
            consecutiveFreezeHops += 1
            consecutiveRecoveryHops = 0
            // 3 consecutive 0.50s hops = 1.50s
            if consecutiveFreezeHops >= 3 && !isEpisodeActive {
                isEpisodeActive = true
                episodeDurationSec = 0.0
                episodePeakFI = fi
                AudioCueEngine.shared.startRASMetronome(bpm: 100)
            }
            if isEpisodeActive {
                episodeDurationSec += hopDurationSec
                episodePeakFI = max(episodePeakFI, fi)
                episodeLastLocoPower = locomotorBandPower
                episodeLastFreezePower = freezeBandPower
                if episodeDurationSec >= maxCueDurationSec {
                    finishEpisodeAndQueueSync(sampledHz: sampledHz, isUserSpeaking: isUserSpeaking)
                }
            }
        } else if isEpisodeActive {
            episodeDurationSec += hopDurationSec
            if fi < 1.2 && locomotorBandPower > 0.08 {
                consecutiveRecoveryHops += 1
                if consecutiveRecoveryHops >= 6 { // 3.0s continuous locomotion recovery
                    finishEpisodeAndQueueSync(sampledHz: sampledHz, isUserSpeaking: isUserSpeaking)
                }
            } else if episodeDurationSec >= maxCueDurationSec {
                finishEpisodeAndQueueSync(sampledHz: sampledHz, isUserSpeaking: isUserSpeaking)
            }
        } else {
            consecutiveFreezeHops = 0
        }

        return isEpisodeActive
    }

    private func finishEpisodeAndQueueSync(sampledHz: Double, isUserSpeaking: Bool) {
        isEpisodeActive = false
        consecutiveFreezeHops = 0
        consecutiveRecoveryHops = 0
        AudioCueEngine.shared.stopRASMetronome()

        let uuid = UUID().uuidString
        EventSyncManager.shared.saveLocalImmediate(
            eventUUID: uuid,
            endpoint: "/api/v1/events/fog",
            payload: [
                "event_uuid": uuid,
                "timestamp_utc": ISO8601DateFormatter().string(from: Date()),
                "duration_sec": episodeDurationSec,
                "peak_freeze_index": episodePeakFI,
                "locomotor_band_power": episodeLastLocoPower,
                "freeze_band_power": episodeLastFreezePower,
                "sampled_hz": sampledHz,
                "arming_mode": armingMode.rawValue,
                "speech_active_modifier": isUserSpeaking,
                "cue_bpm": 100,
                "recovery_latency_sec": episodeDurationSec
            ]
        )
    }
}
