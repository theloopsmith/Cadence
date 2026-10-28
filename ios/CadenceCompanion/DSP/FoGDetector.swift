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

/// Caches `vDSP_DFT_Setup` objects by window length.
///
/// Creating a setup allocates and precomputes twiddle factors, which costs far
/// more than the transform itself. The detector sees one window length for a
/// whole session (N is derived from the estimated sample rate), so a setup is
/// built once and reused across every 0.50s hop.
///
/// `vDSP_DFT_Setup` is a C object with no ARC; setups live for the process
/// lifetime and are intentionally never destroyed. The cache is serialized
/// because hops are driven from the sensor callback queue while tests and the
/// Home Motor Exam may touch it from elsewhere.
final class FFTSetupCache: @unchecked Sendable {
    static let shared = FFTSetupCache()

    private let lock = NSLock()
    private var setups: [Int: vDSP_DFT_Setup] = [:]

    private init() {}

    /// Returns a real-to-complex forward DFT setup for `n`, or nil if vDSP
    /// cannot serve that length (it requires n = f * 2^k for f in 1, 3, 5, 15).
    func realForwardSetup(n: Int) -> vDSP_DFT_Setup? {
        lock.lock()
        defer { lock.unlock() }
        if let existing = setups[n] { return existing }
        guard let created = vDSP_DFT_zrop_CreateSetupD(
            nil, vDSP_Length(n), vDSP_DFT_Direction.FORWARD
        ) else {
            return nil
        }
        setups[n] = created
        return created
    }
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
    /// Tests point this at a private queue. Production uses the shared one.
    public var eventSync: EventSyncManager = .shared
    private var episodeDurationSec: Double = 0.0
    private var episodePeakFI: Double = 0.0
    private var episodeLastLocoPower: Double = 0.0
    private var episodeLastFreezePower: Double = 0.0
    /// The mode that opened the episode. Later hops often disarm before the
    /// cue ends, and the logged event has to keep the mode it started in.
    private var episodeArmingMode: FoGArmingMode = .disarmed
    public let maxCueDurationSec: Double = 30.0
    public let hopDurationSec: Double = 0.50

    public init() {}

    /// Mean-removes and Hann-windows the composite dynamic acceleration
    /// a_dyn(t) = sqrt(a_y^2 + a_z^2), the signal both spectral paths consume.
    static func prepareWindowedSignal(_ window: [IMUSample]) -> [Double] {
        let n = window.count
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

        var hann = [Double](repeating: 0.0, count: n)
        vDSP_hann_windowD(&hann, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        var windowed = [Double](repeating: 0.0, count: n)
        vDSP_vmulD(centered, 1, hann, 1, &windowed, 1, vDSP_Length(n))
        return windowed
    }

    /// Splits a one-sided PSD into the locomotor and freeze bands.
    ///
    /// `psd[k]` is the power at bin k, so k spans 1 ... n/2. Band edges follow
    /// the specification exactly: locomotor is [0.5, 3.0 Hz] and freeze is
    /// (3.0, 8.0 Hz]. Both paths share this so a change to the edges cannot
    /// make the FFT and the reference transform disagree.
    static func integrateBands(
        psd: [Double],
        n: Int,
        sampledHz: Double
    ) -> (loco: Double, freeze: Double) {
        let df = sampledHz / Double(n)
        var pLoco = 0.0
        var pFreeze = 0.0
        let maxBin = min(n / 2, Int(ceil(8.5 / df)))
        guard maxBin >= 1 else { return (0.0, 0.0) }
        for k in 1...maxBin {
            let freq = Double(k) * df
            guard freq >= 0.5 && freq <= 8.0 else { continue }
            if freq <= 3.0 {
                pLoco += psd[k]
            } else {
                pFreeze += psd[k]
            }
        }
        return (pLoco, pFreeze)
    }

    /// Reference O(bins x N) direct transform, retained as the correctness
    /// oracle for the vDSP path. Not used in the hot path; `computeSpectralMetrics`
    /// falls back to it only when vDSP cannot build a setup for the window length.
    static func referencePSD(windowed: [Double], n: Int) -> [Double] {
        var psd = [Double](repeating: 0.0, count: n / 2 + 1)
        guard n > 0 else { return psd }
        for k in 0...(n / 2) {
            var re = 0.0
            var im = 0.0
            let twoPiKOverN = 2.0 * Double.pi * Double(k) / Double(n)
            for idx in 0..<n {
                let angle = twoPiKOverN * Double(idx)
                re += windowed[idx] * cos(angle)
                im -= windowed[idx] * sin(angle)
            }
            psd[k] = (re * re + im * im) / Double(n * n)
        }
        return psd
    }

    /// One-sided PSD via Accelerate's real-to-complex DFT.
    ///
    /// vDSP's `zrop` packs a real input of length n into n/2 complex pairs in
    /// split form, and its output carries an implicit factor of 2 relative to
    /// the textbook DFT, so each term is halved before squaring to match
    /// `referencePSD` bin for bin. DC and Nyquist arrive packed together in
    /// real[0] and imag[0]; neither lies in the 0.5-8.0 Hz band, but they are
    /// unpacked correctly so the returned spectrum is right at every bin.
    static func acceleratePSD(windowed: [Double], n: Int) -> [Double]? {
        guard n >= 16, n % 2 == 0,
              let setup = FFTSetupCache.shared.realForwardSetup(n: n) else {
            return nil
        }
        let half = n / 2

        // Deinterleave even/odd samples into the split-complex input vDSP wants.
        var inReal = [Double](repeating: 0.0, count: half)
        var inImag = [Double](repeating: 0.0, count: half)
        for i in 0..<half {
            inReal[i] = windowed[2 * i]
            inImag[i] = windowed[2 * i + 1]
        }

        var outReal = [Double](repeating: 0.0, count: half)
        var outImag = [Double](repeating: 0.0, count: half)
        vDSP_DFT_ExecuteD(setup, &inReal, &inImag, &outReal, &outImag)

        let invNSquared = 1.0 / Double(n * n)
        var psd = [Double](repeating: 0.0, count: half + 1)

        // Packed: outReal[0] holds DC and outImag[0] holds Nyquist, both purely
        // real. Every term carries vDSP's implicit factor of 2, undone here by
        // the 0.5 so the result matches `referencePSD` bin for bin.
        let dc = outReal[0] * 0.5
        let nyquist = outImag[0] * 0.5
        psd[0] = dc * dc * invNSquared
        psd[half] = nyquist * nyquist * invNSquared

        for k in 1..<half {
            let re = outReal[k] * 0.5
            let im = outImag[k] * 0.5
            psd[k] = (re * re + im * im) * invNSquared
        }
        return psd
    }

    /// Computes Locomotor [0.5, 3.0 Hz] and Freeze (3.0, 8.0 Hz] band powers from a uniformly
    /// resampled IMU window using Hann windowing and an Accelerate real-to-complex FFT.
    ///
    /// Falls back to the direct transform when vDSP cannot build a setup for
    /// the window length, so an unusual N degrades in speed rather than
    /// silently returning no spectrum and disarming freeze detection.
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

        let windowed = Self.prepareWindowedSignal(window)
        let psd = Self.acceleratePSD(windowed: windowed, n: n)
            ?? Self.referencePSD(windowed: windowed, n: n)
        let bands = Self.integrateBands(psd: psd, n: n, sampledHz: sampledHz)

        let total = bands.loco + bands.freeze
        let fi = bands.freeze / (bands.loco + 1e-6)
        return FoGSpectralMetrics(
            locomotorBandPower: bands.loco,
            freezeBandPower: bands.freeze,
            totalDynamicEnergy: total,
            freezeIndex: fi,
            sampledHz: sampledHz
        )
    }

    /// Reference-transform variant of `computeSpectralMetrics`, for tests and
    /// benchmarks that need to compare the two paths on identical input.
    public func computeSpectralMetricsReference(
        window: [IMUSample],
        sampledHz: Double
    ) -> FoGSpectralMetrics {
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
        let windowed = Self.prepareWindowedSignal(window)
        let psd = Self.referencePSD(windowed: windowed, n: n)
        let bands = Self.integrateBands(psd: psd, n: n, sampledHz: sampledHz)
        let total = bands.loco + bands.freeze
        return FoGSpectralMetrics(
            locomotorBandPower: bands.loco,
            freezeBandPower: bands.freeze,
            totalDynamicEnergy: total,
            freezeIndex: bands.freeze / (bands.loco + 1e-6),
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
        if sitToStandDetected {
            initiationArmedRemainingSec = 10.0
            consecutiveSeatedStillHops = 0
        } else if totalEnergy <= 0.02 {
            consecutiveSeatedStillHops += 1
        } else {
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
        if locomotorBandPower > 0.08 || recentWalkingRemainingSec > 0.0 {
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
                episodeArmingMode = armingMode
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
        eventSync.saveLocalImmediate(
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
                "arming_mode": episodeArmingMode.rawValue,
                "speech_active_modifier": isUserSpeaking,
                "cue_bpm": 100,
                "recovery_latency_sec": episodeDurationSec
            ]
        )
    }
}
