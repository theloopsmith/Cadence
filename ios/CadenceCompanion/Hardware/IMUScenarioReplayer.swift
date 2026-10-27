import Combine
import Foundation

public enum IMUScenario: String, CaseIterable, Identifiable {
    case freezeOfGaitWithRecovery = "FoG Walk -> Freeze -> RAS Recovery"
    case hardFallWithImpact = "Hard Fall (Drop -> 3.8g Impact -> Stillness)"
    case bedRollSuppression = "Bed Roll False-Alarm Suppression"
    case sitToStandInitiation = "Sit-to-Stand Arming After Seated Stillness"

    public var id: String { rawValue }

    public var durationSeconds: Double {
        switch self {
        case .freezeOfGaitWithRecovery: return 16.0
        case .hardFallWithImpact: return 4.0
        case .bedRollSuppression: return 3.5
        case .sitToStandInitiation: return 7.5
        }
    }
}

/// Plays back realistic 50–100 Hz kinematic Parkinson's IMU scenarios at true
/// wall-clock speed or generates synthetic sample batches for automated testing.
@MainActor
public final class IMUScenarioReplayer: ObservableObject {
    public static let shared = IMUScenarioReplayer()

    @Published public private(set) var isPlaying: Bool = false
    @Published public private(set) var activeScenario: IMUScenario?
    @Published public private(set) var progress: Double = 0.0

    private var playbackTask: Task<Void, Never>?

    public init() {}

    /// Generates the full deterministic batch of IMU samples for a given scenario.
    public nonisolated static func generateSamples(
        scenario: IMUScenario,
        sampleRateHz: Double = 50.0
    ) -> [IMUSample] {
        let totalSamples = Int(scenario.durationSeconds * sampleRateHz)
        let dt = 1.0 / sampleRateHz
        var samples: [IMUSample] = []
        samples.reserveCapacity(totalSamples)

        for i in 0..<totalSamples {
            let t = Double(i) * dt
            let sample: IMUSample

            switch scenario {
            case .freezeOfGaitWithRecovery:
                // 0.0s..5.5s: Active sustained walking (1.8 Hz locomotor rhythm, > 3.0s arming)
                if t < 5.5 {
                    let gait = 0.70 * sin(2.0 * .pi * 1.8 * t)
                    sample = IMUSample(
                        timestamp: t,
                        ax: 0.10 * cos(2.0 * .pi * 1.8 * t),
                        ay: 1.0 + gait,
                        az: 0.25 * sin(2.0 * .pi * 1.8 * t),
                        gx: 0.05,
                        gy: 0.30 * sin(2.0 * .pi * 1.8 * t),
                        gz: 0.05,
                        pitchDeg: 4.0,
                        rollDeg: 1.5
                    )
                }
                // 5.5s..9.5s: Freeze of Gait episode (5.5 Hz trembling in AP/vertical axes)
                else if t < 9.5 {
                    let freezeOsc = 0.85 * sin(2.0 * .pi * 5.5 * t)
                    sample = IMUSample(
                        timestamp: t,
                        ax: 0.03,
                        ay: 1.0 + freezeOsc,
                        az: 0.45 * cos(2.0 * .pi * 5.5 * t),
                        gx: 0.15,
                        gy: 0.95 * sin(2.0 * .pi * 5.5 * t),
                        gz: 0.12,
                        pitchDeg: 6.5,
                        rollDeg: 2.0
                    )
                }
                // 9.5s..16.0s: Recovery entrained to 100 BPM (1.67 Hz) metronome (flushes window & recovers)
                else {
                    let recoveryGait = 0.65 * sin(2.0 * .pi * 1.67 * (t - 9.5))
                    sample = IMUSample(
                        timestamp: t,
                        ax: 0.08 * cos(2.0 * .pi * 1.67 * (t - 9.5)),
                        ay: 1.0 + recoveryGait,
                        az: 0.20 * sin(2.0 * .pi * 1.67 * (t - 9.5)),
                        gx: 0.04,
                        gy: 0.28 * sin(2.0 * .pi * 1.67 * (t - 9.5)),
                        gz: 0.04,
                        pitchDeg: 4.5,
                        rollDeg: 1.0
                    )
                }

            case .hardFallWithImpact:
                // 0.0s..2.0s: Worn standing baseline (RMS ~ 0.05g)
                if t < 2.0 {
                    let microMotion = 0.04 * sin(2.0 * .pi * 1.2 * t)
                    sample = IMUSample(
                        timestamp: t,
                        ax: 0.02,
                        ay: 1.0 + microMotion,
                        az: 0.02,
                        gx: 0.02,
                        gy: 0.02,
                        gz: 0.02,
                        pitchDeg: 5.0,
                        rollDeg: 2.0
                    )
                }
                // 2.0s..2.12s: Stage 1 Free-fall (< 0.45g)
                else if t < 2.12 {
                    sample = IMUSample(
                        timestamp: t,
                        ax: 0.08,
                        ay: 0.18,
                        az: 0.10,
                        gx: 0.8,
                        gy: 1.2,
                        gz: 0.5,
                        pitchDeg: 12.0,
                        rollDeg: 6.0
                    )
                }
                // 2.12s..2.22s: Stage 2 Hard floor impact (> 2.8g, jerk > 35g/s)
                else if t < 2.22 {
                    sample = IMUSample(
                        timestamp: t,
                        ax: 0.45,
                        ay: 3.85,
                        az: 0.60,
                        gx: 4.2,
                        gy: 3.1,
                        gz: 2.5,
                        pitchDeg: 35.0,
                        rollDeg: 18.0
                    )
                }
                // 2.22s..4.0s: Stage 3 Horizontal post-impact stillness (pitch ~78°, low energy)
                else {
                    sample = IMUSample(
                        timestamp: t,
                        ax: 0.98,
                        ay: 0.14,
                        az: 0.04,
                        gx: 0.005,
                        gy: 0.005,
                        gz: 0.005,
                        pitchDeg: 78.0,
                        rollDeg: 5.0
                    )
                }

            case .bedRollSuppression:
                // Wearer is lying down (pitch > 65°), turning in bed:
                // |pitch/roll| > 35° must NEVER arm FoG Mode C Upright Turn.
                let rollAngle = 72.0 + 15.0 * sin(2.0 * .pi * 0.4 * t)
                sample = IMUSample(
                    timestamp: t,
                    ax: 0.94,
                    ay: 0.15,
                    az: 0.10,
                    gx: 0.4 * sin(2.0 * .pi * 0.4 * t),
                    gy: 0.8 * cos(2.0 * .pi * 0.4 * t),
                    gz: 0.2,
                    pitchDeg: rollAngle,
                    rollDeg: 25.0
                )

            case .sitToStandInitiation:
                // 0.0s..5.5s: Quiet seated stillness (consecutiveSeatedStillHops >= 10)
                if t < 5.5 {
                    sample = IMUSample(
                        timestamp: t,
                        ax: 0.01,
                        ay: 0.99,
                        az: 0.02,
                        gx: 0.005,
                        gy: 0.005,
                        gz: 0.005,
                        pitchDeg: 2.0,
                        rollDeg: 1.0
                    )
                }
                // 5.5s..7.5s: Forward torso lean and rise (sit-to-stand transition)
                else {
                    let rise = 0.45 * sin(2.0 * .pi * 0.5 * (t - 5.5))
                    sample = IMUSample(
                        timestamp: t,
                        ax: 0.10,
                        ay: 1.0 + rise,
                        az: 0.25,
                        gx: 0.35,
                        gy: 0.10,
                        gz: 0.05,
                        pitchDeg: 18.0 * sin(2.0 * .pi * 0.5 * (t - 5.5)),
                        rollDeg: 2.0
                    )
                }
            }

            samples.append(sample)
        }

        return samples
    }

    /// Plays a scenario live at true speed, delivering each sample to the provided handler.
    public func playScenario(
        _ scenario: IMUScenario,
        sampleRateHz: Double = 50.0,
        onSample: @escaping (IMUSample) -> Void,
        onCompletion: (() -> Void)? = nil
    ) {
        stop()
        isPlaying = true
        activeScenario = scenario
        progress = 0.0

        let samples = Self.generateSamples(scenario: scenario, sampleRateHz: sampleRateHz)
        let intervalNs = UInt64((1.0 / sampleRateHz) * 1_000_000_000)

        playbackTask = Task { [weak self] in
            for (idx, sample) in samples.enumerated() {
                guard !Task.isCancelled else { break }

                onSample(sample)

                if idx % 10 == 0 {
                    let pct = Double(idx) / Double(samples.count)
                    await MainActor.run { [weak self] in
                        self?.progress = pct
                    }
                }

                try? await Task.sleep(nanoseconds: intervalNs)
            }

            await MainActor.run { [weak self] in
                guard let self = self else { return }
                self.isPlaying = false
                self.activeScenario = nil
                self.progress = 1.0
                onCompletion?()
            }
        }
    }

    public func stop() {
        playbackTask?.cancel()
        playbackTask = nil
        isPlaying = false
        activeScenario = nil
        progress = 0.0
    }
}
