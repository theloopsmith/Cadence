import Foundation

/// What the 10-second timed walk measured. These are the gait inputs the
/// backend scores in `motor_exam.py`.
public struct WalkTestResult: Equatable {
    public let durationSec: Double
    public let stepCount: Int
    public let cadenceSpm: Double
    public let meanFreezeIndex: Double
    public let peakFreezeIndex: Double
    public let fogCount: Int
}

/// Collects IMU samples during Task 3 of the Home Motor Exam and turns them
/// into cadence, Freeze Index and freeze count.
///
/// Steps are vertical-acceleration peaks above a small threshold with a
/// refractory gap, which is enough for a straight-line walk. Freeze metrics
/// reuse the same spectral analysis the live detector runs, hopped every
/// half second, so the exam and the ambient FoG log agree on what a freeze is.
public final class WalkTestRecorder {
    private var samples: [IMUSample] = []
    private var continuous = true
    public var hasUsableRecording: Bool { continuous && samples.count >= 16 && elapsedSec >= 3 }
    private let spectral = FoGDetector()

    /// Peaks closer than this are one footfall, not two.
    public var minStepIntervalSec: Double = 0.30
    /// Dynamic vertical acceleration a footfall must exceed, in g.
    public var stepThresholdG: Double = 0.12

    public init() {}

    public func reset() {
        samples.removeAll()
        continuous = true
    }

    public func ingest(_ sample: IMUSample) {
        let values = [sample.timestamp,sample.ax,sample.ay,sample.az,sample.gx,sample.gy,sample.gz]
        guard values.allSatisfy({ $0.isFinite }) else { continuous = false; return }
        if let last = samples.last {
            guard sample.timestamp > last.timestamp else { continuous = false; return }
            if sample.timestamp - last.timestamp > 0.5 { continuous = false }
        }
        samples.append(sample)
    }

    public var elapsedSec: Double {
        guard let first = samples.first, let last = samples.last else { return 0 }
        return last.timestamp - first.timestamp
    }

    public func finish() -> WalkTestResult {
        guard samples.count >= 2 else {
            return WalkTestResult(
                durationSec: 0, stepCount: 0, cadenceSpm: 0,
                meanFreezeIndex: 0, peakFreezeIndex: 0, fogCount: 0
            )
        }
        let duration = elapsedSec
        let steps = countSteps()
        let cadence = duration > 0 ? Double(steps) / duration * 60.0 : 0.0
        let freeze = freezeMetrics()
        return WalkTestResult(
            durationSec: duration,
            stepCount: steps,
            cadenceSpm: cadence,
            meanFreezeIndex: freeze.mean,
            peakFreezeIndex: freeze.peak,
            fogCount: freeze.episodes
        )
    }

    // MARK: - Steps

    private func countSteps() -> Int {
        // Dynamic vertical component, smoothed over five samples so sensor
        // jitter does not read as a footfall.
        let dynamic = samples.map { $0.ay - 1.0 }
        var smoothed: [Double] = []
        smoothed.reserveCapacity(dynamic.count)
        for i in 0..<dynamic.count {
            let lo = max(0, i - 2)
            let hi = min(dynamic.count - 1, i + 2)
            let window = dynamic[lo...hi]
            smoothed.append(window.reduce(0, +) / Double(window.count))
        }

        var steps = 0
        var lastStepAt: Double = -.infinity
        for i in 1..<(smoothed.count - 1) {
            let v = smoothed[i]
            guard v > stepThresholdG, v >= smoothed[i - 1], v > smoothed[i + 1] else { continue }
            let t = samples[i].timestamp
            guard t - lastStepAt >= minStepIntervalSec else { continue }
            steps += 1
            lastStepAt = t
        }
        return steps
    }

    // MARK: - Freeze

    private func freezeMetrics() -> (mean: Double, peak: Double, episodes: Int) {
        let stream = SensorStreamManager()
        var hopIndices: [Double] = []
        var lastHop: Double? = nil
        var freezeHopFlags: [Bool] = []

        for sample in samples {
            stream.appendSample(sample)
            if let last = lastHop, sample.timestamp - last < stream.hopDurationSec { continue }
            lastHop = sample.timestamp
            guard stream.bufferedDurationSec >= 2.4 else { continue }
            let window = stream.uniformResampledWindow()
            guard window.count >= 16 else { continue }
            let m = spectral.computeSpectralMetrics(window: window, sampledHz: stream.estimatedSampleRateHz)
            hopIndices.append(m.freezeIndex)
            freezeHopFlags.append(
                m.totalDynamicEnergy > spectral.thresholds.dynamicEnergyFloor
                    && m.freezeIndex > spectral.thresholds.freezeIndexTrigger
            )
        }

        guard !hopIndices.isEmpty else { return (0, 0, 0) }
        let mean = hopIndices.reduce(0, +) / Double(hopIndices.count)
        let peak = hopIndices.max() ?? 0

        // Three consecutive freeze hops (1.5 s) is one episode, matching the
        // live detector's trigger rule.
        var episodes = 0
        var run = 0
        var counted = false
        for flag in freezeHopFlags {
            if flag {
                run += 1
                if run >= 3 && !counted {
                    episodes += 1
                    counted = true
                }
            } else {
                run = 0
                counted = false
            }
        }
        return (mean, peak, episodes)
    }
}
