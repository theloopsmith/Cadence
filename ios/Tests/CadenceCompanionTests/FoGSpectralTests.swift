import Accelerate
import XCTest
@testable import CadenceCompanion

/// Deterministic pseudo-random source so every run exercises the same signals.
private struct SeededNoise {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed | 1 }
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double((state >> 33) % 10_000) / 10_000.0 - 0.5
    }
}

/// Builds an IMU window whose vertical axis carries the given (frequency,
/// amplitude) components plus a little noise.
func makeIMUWindow(
    n: Int,
    fs: Double,
    components: [(hz: Double, amp: Double)],
    seed: UInt64 = 1
) -> [IMUSample] {
    var noise = SeededNoise(seed: seed)
    var out: [IMUSample] = []
    out.reserveCapacity(n)
    for i in 0..<n {
        let t = Double(i) / fs
        var v = 0.0
        for c in components { v += c.amp * sin(2.0 * .pi * c.hz * t) }
        v += 0.02 * noise.next()
        out.append(
            IMUSample(
                timestamp: t,
                ax: 0.0, ay: 1.0 + v, az: 0.3 * v,
                gx: 0.0, gy: 0.0, gz: 0.0,
                pitchDeg: 4.0, rollDeg: 2.0
            )
        )
    }
    return out
}

final class FoGSpectralTests: XCTestCase {

    private static let signalCases: [(name: String, components: [(hz: Double, amp: Double)])] = [
        ("pure freeze 5.5Hz",       [(5.5, 0.80)]),
        ("pure locomotor 1.8Hz",    [(1.8, 0.60)]),
        ("mixed walk plus freeze",  [(1.8, 0.50), (5.5, 0.70)]),
        ("three-component",         [(0.9, 0.40), (4.2, 0.35), (7.1, 0.25)]),
        ("straddling 3Hz edge",     [(2.9, 0.50), (3.1, 0.50)]),
        ("noise only",              []),
    ]

    private static let sizeCases: [(fs: Double, n: Int)] = [
        (50.0, 128),    // estimated 50 Hz stream
        (100.0, 256),   // estimated 100 Hz stream
        (200.0, 512),   // high-rate stream
        (50.0, 256),
        (100.0, 128),
    ]

    /// The vDSP path must agree with the direct transform bin for bin.
    ///
    /// vDSP's real-to-complex `zrop` output carries an implicit factor of two
    /// and packs DC with Nyquist, so the scaling is easy to get subtly wrong.
    /// A wrong constant factor would not crash: it would quietly shift every
    /// Freeze Index against the 2.0 / 2.8 thresholds and change when the
    /// metronome fires.
    func testAccelerateMatchesReferenceTransform() {
        let detector = FoGDetector()
        var worst = 0.0

        for size in Self.sizeCases {
            for (idx, signal) in Self.signalCases.enumerated() {
                let window = makeIMUWindow(
                    n: size.n, fs: size.fs,
                    components: signal.components,
                    seed: UInt64(idx + 1) &* 7919
                )
                let fast = detector.computeSpectralMetrics(window: window, sampledHz: size.fs)
                let ref = detector.computeSpectralMetricsReference(window: window, sampledHz: size.fs)

                func relative(_ a: Double, _ b: Double) -> Double {
                    abs(a - b) / max(abs(a), abs(b), 1e-12)
                }
                let label = "\(signal.name) @ fs=\(size.fs) N=\(size.n)"
                let dLoco = relative(fast.locomotorBandPower, ref.locomotorBandPower)
                let dFreeze = relative(fast.freezeBandPower, ref.freezeBandPower)
                let dFI = relative(fast.freezeIndex, ref.freezeIndex)

                XCTAssertLessThan(dLoco, 1e-9, "locomotor power diverged: \(label)")
                XCTAssertLessThan(dFreeze, 1e-9, "freeze power diverged: \(label)")
                XCTAssertLessThan(dFI, 1e-9, "freeze index diverged: \(label)")
                worst = max(worst, max(dLoco, max(dFreeze, dFI)))
            }
        }
        print("[spectral] worst relative deviation across \(Self.sizeCases.count * Self.signalCases.count) cases: \(worst)")
    }

    /// The whole point of the band split: a freeze-band oscillation must read
    /// as a high Freeze Index and a walking-band one must not.
    func testFreezeIndexSeparatesFreezeFromWalking() {
        let detector = FoGDetector()

        let freezing = detector.computeSpectralMetrics(
            window: makeIMUWindow(n: 256, fs: 100.0, components: [(5.5, 0.80)]),
            sampledHz: 100.0
        )
        XCTAssertGreaterThan(freezing.freezeIndex, 2.0, "5.5 Hz must exceed the 2.0 arming threshold")

        let walking = detector.computeSpectralMetrics(
            window: makeIMUWindow(n: 256, fs: 100.0, components: [(1.8, 0.80)]),
            sampledHz: 100.0
        )
        XCTAssertLessThan(walking.freezeIndex, 1.0, "1.8 Hz walking must stay well below threshold")
    }

    /// Repeated hops must reuse the cached setup and stay numerically stable;
    /// a setup leak or mutation would show up as drift across calls.
    func testRepeatedCallsAreStableAndReuseTheCachedSetup() {
        let detector = FoGDetector()
        let window = makeIMUWindow(n: 256, fs: 100.0, components: [(1.8, 0.5), (5.5, 0.7)])
        let first = detector.computeSpectralMetrics(window: window, sampledHz: 100.0)
        for _ in 0..<200 {
            let again = detector.computeSpectralMetrics(window: window, sampledHz: 100.0)
            XCTAssertEqual(again.freezeIndex, first.freezeIndex, accuracy: 1e-12)
        }
    }

    /// The end-to-end cost of one 0.50s hop: resample the raw stream, transform
    /// it, and run the arming state machine. This is the number the 50 ms DSP
    /// budget actually governs, and it is what should be re-measured on device
    /// during the Day-2 spike.
    func testFullHopPipelineStaysWithinBudget() {
        let iterations = 100

        for size in [(fs: 50.0, n: 128), (fs: 100.0, n: 256), (fs: 200.0, n: 512)] {
            let stream = SensorStreamManager()
            // Fill the resampler with a realistic jittery stream.
            var noise = SeededNoise(seed: 4242)
            for i in 0..<(size.n + 32) {
                let jitter = 0.1 * noise.next() / size.fs
                let t = Double(i) / size.fs + jitter
                let v = 0.5 * sin(2.0 * .pi * 1.8 * t) + 0.7 * sin(2.0 * .pi * 5.5 * t)
                stream.appendSample(
                    IMUSample(
                        timestamp: t,
                        ax: 0.0, ay: 1.0 + v, az: 0.3 * v,
                        gx: 0.0, gy: 0.0, gz: 0.0,
                        pitchDeg: 4.0, rollDeg: 2.0
                    )
                )
            }

            let detector = FoGDetector()
            // Warm the setup cache and the resampler.
            _ = detector.computeSpectralMetrics(
                window: stream.uniformResampledWindow(), sampledHz: stream.estimatedSampleRateHz
            )

            let start = CFAbsoluteTimeGetCurrent()
            for _ in 0..<iterations {
                let w = stream.uniformResampledWindow()
                let m = detector.computeSpectralMetrics(
                    window: w, sampledHz: stream.estimatedSampleRateHz
                )
                _ = detector.evaluateHop(
                    locomotorBandPower: m.locomotorBandPower,
                    freezeBandPower: m.freezeBandPower,
                    integratedYaw15sDeg: 10.0,
                    pitchDeg: 4.0,
                    rollDeg: 2.0,
                    sitToStandDetected: false,
                    isUserSpeaking: false,
                    sampledHz: stream.estimatedSampleRateHz
                )
            }
            let perHopMs = (CFAbsoluteTimeGetCurrent() - start) / Double(iterations) * 1000.0
            print(String(
                format: "[bench] full hop fs=%.0f N=%d: %.4f ms (budget 50 ms, %.1f%% used)",
                size.fs, size.n, perHopMs, perHopMs / 50.0 * 100.0
            ))
            XCTAssertLessThan(perHopMs, 25.0, "full hop at fs=\(size.fs) exceeded half the budget")
            AudioCueEngine.shared.stopRASMetronome()
        }
    }

    /// Windows too short to transform return zeros rather than arming on noise.
    func testUndersizedWindowReturnsZeroedMetrics() {
        let detector = FoGDetector()
        let m = detector.computeSpectralMetrics(
            window: makeIMUWindow(n: 8, fs: 50.0, components: [(5.5, 0.8)]),
            sampledHz: 50.0
        )
        XCTAssertEqual(m.freezeIndex, 0.0)
        XCTAssertEqual(m.totalDynamicEnergy, 0.0)
    }

    /// Every hop must finish well inside the 50 ms DSP budget. The assertion is
    /// deliberately loose (10 ms) so it flags a real regression on CI hardware
    /// without failing on an unlucky scheduling blip; the printed figures are
    /// the actual measurement.
    func testSpectralMetricsStayWithinTheFiftyMillisecondBudget() {
        let detector = FoGDetector()
        let iterations = 200

        for size in [(fs: 50.0, n: 128), (fs: 100.0, n: 256), (fs: 200.0, n: 512)] {
            let window = makeIMUWindow(
                n: size.n, fs: size.fs, components: [(1.8, 0.5), (5.5, 0.7)]
            )
            // Warm the setup cache so the first call is not timed.
            _ = detector.computeSpectralMetrics(window: window, sampledHz: size.fs)

            let start = CFAbsoluteTimeGetCurrent()
            for _ in 0..<iterations {
                _ = detector.computeSpectralMetrics(window: window, sampledHz: size.fs)
            }
            let perCallMs = (CFAbsoluteTimeGetCurrent() - start) / Double(iterations) * 1000.0

            let refStart = CFAbsoluteTimeGetCurrent()
            for _ in 0..<iterations {
                _ = detector.computeSpectralMetricsReference(window: window, sampledHz: size.fs)
            }
            let refPerCallMs = (CFAbsoluteTimeGetCurrent() - refStart) / Double(iterations) * 1000.0

            print(String(
                format: "[bench] fs=%.0f N=%d  fft=%.4f ms  direct=%.4f ms  speedup=%.1fx  budget=50 ms",
                size.fs, size.n, perCallMs, refPerCallMs, refPerCallMs / max(perCallMs, 1e-9)
            ))
            XCTAssertLessThan(
                perCallMs, 10.0,
                "FFT hop at fs=\(size.fs) N=\(size.n) took \(perCallMs) ms, far outside the 50 ms budget"
            )
        }
    }
}

final class FoGSpectralFallbackTests: XCTestCase {

    /// vDSP only serves lengths of the form f * 2^k for f in {1, 3, 5, 15}.
    /// A length it refuses must fall back to the direct transform and still
    /// produce a spectrum: returning nothing would silently disarm freeze
    /// detection for the whole session.
    func testUnsupportedWindowLengthFallsBackInsteadOfFailing() {
        let detector = FoGDetector()
        // 124 = 4 * 31, not expressible as f * 2^k for the supported radices.
        let odd = makeIMUWindow(n: 124, fs: 50.0, components: [(5.5, 0.80)])
        let metrics = detector.computeSpectralMetrics(window: odd, sampledHz: 50.0)

        XCTAssertGreaterThan(metrics.totalDynamicEnergy, 0.0, "fallback must still produce a spectrum")
        XCTAssertGreaterThan(metrics.freezeIndex, 2.0, "a 5.5 Hz freeze must still be detected")

        let reference = detector.computeSpectralMetricsReference(window: odd, sampledHz: 50.0)
        XCTAssertEqual(metrics.freezeIndex, reference.freezeIndex, accuracy: 1e-9)
    }

    /// Whichever path runs, the band edges are shared, so a component sitting
    /// just either side of 3.0 Hz lands in the expected band.
    func testBandEdgesAreAppliedConsistently() {
        let detector = FoGDetector()
        // At N=256, fs=100 the bin spacing is 0.39 Hz; 2.34 Hz and 3.52 Hz sit
        // cleanly on opposite sides of the 3.0 Hz edge.
        let below = detector.computeSpectralMetrics(
            window: makeIMUWindow(n: 256, fs: 100.0, components: [(2.34, 0.8)]),
            sampledHz: 100.0
        )
        XCTAssertGreaterThan(below.locomotorBandPower, below.freezeBandPower)

        let above = detector.computeSpectralMetrics(
            window: makeIMUWindow(n: 256, fs: 100.0, components: [(3.52, 0.8)]),
            sampledHz: 100.0
        )
        XCTAssertGreaterThan(above.freezeBandPower, above.locomotorBandPower)
    }

    /// Content outside 0.5-8.0 Hz must not leak into either band: a slow
    /// postural drift or a high-frequency tap should not arm the detector.
    func testOutOfBandContentIsExcluded() {
        let detector = FoGDetector()
        let inBand = detector.computeSpectralMetrics(
            window: makeIMUWindow(n: 256, fs: 100.0, components: [(5.5, 0.8)]),
            sampledHz: 100.0
        )
        let outOfBand = detector.computeSpectralMetrics(
            window: makeIMUWindow(n: 256, fs: 100.0, components: [(18.0, 0.8)]),
            sampledHz: 100.0
        )
        XCTAssertLessThan(
            outOfBand.totalDynamicEnergy, inBand.totalDynamicEnergy * 0.05,
            "18 Hz content must stay out of the 0.5-8.0 Hz bands"
        )
    }
}
