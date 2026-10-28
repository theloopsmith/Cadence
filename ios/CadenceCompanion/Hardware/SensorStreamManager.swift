import Foundation

public struct IMUSample {
    public let timestamp: TimeInterval
    public let ax: Double
    public let ay: Double
    public let az: Double
    public let gx: Double
    public let gy: Double
    public let gz: Double
    public let pitchDeg: Double
    public let rollDeg: Double

    public init(
        timestamp: TimeInterval,
        ax: Double,
        ay: Double,
        az: Double,
        gx: Double,
        gy: Double,
        gz: Double,
        pitchDeg: Double = 0.0,
        rollDeg: Double = 0.0
    ) {
        self.timestamp = timestamp
        self.ax = ax
        self.ay = ay
        self.az = az
        self.gx = gx
        self.gy = gy
        self.gz = gz
        self.pitchDeg = pitchDeg
        self.rollDeg = rollDeg
    }
}

/// Estimates real-time IMU sample rate f_s and linearly interpolates onto a uniform time grid
/// before running dynamic-N FFT windows with a fixed 0.50s sliding hop.
public final class SensorStreamManager {
    public static let shared = SensorStreamManager()
    private var rawBuffer: [IMUSample] = []
    public private(set) var estimatedSampleRateHz: Double = 50.0
    public let hopDurationSec: Double = 0.50

    /// Time spanned by the samples currently held. The spectral hop waits until
    /// this covers the analysis window, so a short buffer is not padded into a
    /// fake spectrum.
    public var bufferedDurationSec: Double {
        guard let first = rawBuffer.first, let last = rawBuffer.last else { return 0 }
        return last.timestamp - first.timestamp
    }

    public init() {}

    public func appendSample(_ sample: IMUSample) {
        rawBuffer.append(sample)
        if rawBuffer.count > 400 {
            rawBuffer.removeFirst(rawBuffer.count - 400)
        }
        updateEstimatedRate()
    }

    private func updateEstimatedRate() {
        guard rawBuffer.count >= 12 else { return }
        let recent = rawBuffer.suffix(100)
        var deltas: [Double] = []
        var prev: TimeInterval?
        for s in recent {
            if let p = prev, s.timestamp > p {
                deltas.append(s.timestamp - p)
            }
            prev = s.timestamp
        }
        guard !deltas.isEmpty else { return }
        let sorted = deltas.sorted()
        let medianDt = sorted[sorted.count / 2]
        if medianDt > 0.002 && medianDt < 0.1 {
            estimatedSampleRateHz = round(1.0 / medianDt)
        }
    }

    /// Dynamic power-of-2 FFT window covering ~2.56 seconds: N = 2^ceil(log2(2.56 * f_s))
    public var dynamicFFTWindowLength: Int {
        let target = 2.56 * estimatedSampleRateHz
        let exp = ceil(log2(max(32.0, target)))
        return Int(pow(2.0, exp))
    }

    /// Linearly resamples the latest window onto a strictly uniform grid at dt = 1 / f_s.
    public func uniformResampledWindow() -> [IMUSample] {
        let n = dynamicFFTWindowLength
        guard rawBuffer.count >= 4, let last = rawBuffer.last else { return [] }
        let dt = 1.0 / max(25.0, estimatedSampleRateHz)
        let startTime = last.timestamp - Double(n - 1) * dt
        var uniform: [IMUSample] = []
        uniform.reserveCapacity(n)

        var idx = 0
        for k in 0..<n {
            let t = startTime + Double(k) * dt
            while idx + 1 < rawBuffer.count && rawBuffer[idx + 1].timestamp < t {
                idx += 1
            }
            if idx + 1 < rawBuffer.count {
                let s0 = rawBuffer[idx]
                let s1 = rawBuffer[idx + 1]
                let span = max(1e-6, s1.timestamp - s0.timestamp)
                let alpha = max(0.0, min(1.0, (t - s0.timestamp) / span))
                uniform.append(
                    IMUSample(
                        timestamp: t,
                        ax: s0.ax + alpha * (s1.ax - s0.ax),
                        ay: s0.ay + alpha * (s1.ay - s0.ay),
                        az: s0.az + alpha * (s1.az - s0.az),
                        gx: s0.gx + alpha * (s1.gx - s0.gx),
                        gy: s0.gy + alpha * (s1.gy - s0.gy),
                        gz: s0.gz + alpha * (s1.gz - s0.gz),
                        pitchDeg: s0.pitchDeg + alpha * (s1.pitchDeg - s0.pitchDeg),
                        rollDeg: s0.rollDeg + alpha * (s1.rollDeg - s0.rollDeg)
                    )
                )
            } else {
                uniform.append(rawBuffer[idx])
            }
        }
        return uniform
    }
}
