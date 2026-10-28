import XCTest
@testable import CadenceCompanion

final class WalkTestRecorderTests: XCTestCase {
    private func feed(
        _ recorder: WalkTestRecorder,
        seconds: Double,
        fs: Double = 100.0,
        signal: (Double) -> (ay: Double, az: Double)
    ) {
        let count = Int(seconds * fs)
        for i in 0..<count {
            let t = Double(i) / fs
            let s = signal(t)
            recorder.ingest(
                IMUSample(
                    timestamp: t,
                    ax: 0.0, ay: 1.0 + s.ay, az: s.az,
                    gx: 0.0, gy: 0.0, gz: 0.0,
                    pitchDeg: 4.0, rollDeg: 2.0
                )
            )
        }
    }

    /// A 1.8 Hz vertical bob is 108 steps a minute.
    func testSteadyWalkingCadenceIsCountedFromVerticalPeaks() {
        let recorder = WalkTestRecorder()
        feed(recorder, seconds: 10.0) { t in
            (ay: 0.45 * sin(2.0 * .pi * 1.8 * t), az: 0.1 * sin(2.0 * .pi * 1.8 * t))
        }
        let result = recorder.finish()

        XCTAssertEqual(result.durationSec, 10.0, accuracy: 0.05)
        XCTAssertEqual(result.cadenceSpm, 108.0, accuracy: 8.0)
        XCTAssertLessThan(result.meanFreezeIndex, 1.2)
        XCTAssertEqual(result.fogCount, 0)
    }

    /// Four seconds of 5.5 Hz trembling in the middle of the walk is one freeze.
    func testAFreezeInTheMiddleOfTheWalkIsCounted() {
        let recorder = WalkTestRecorder()
        feed(recorder, seconds: 10.0) { t in
            if t >= 3.0 && t < 7.0 {
                return (ay: 0.6 * sin(2.0 * .pi * 5.5 * t), az: 0.15 * cos(2.0 * .pi * 5.5 * t))
            }
            return (ay: 0.45 * sin(2.0 * .pi * 1.8 * t), az: 0.1 * sin(2.0 * .pi * 1.8 * t))
        }
        let result = recorder.finish()

        XCTAssertEqual(result.fogCount, 1)
        XCTAssertGreaterThan(result.meanFreezeIndex, 1.2)
        XCTAssertGreaterThan(result.peakFreezeIndex, 2.0)
    }

    /// Standing still is zero cadence, not a division by zero.
    func testStandingStillYieldsZeroCadence() {
        let recorder = WalkTestRecorder()
        feed(recorder, seconds: 4.0) { _ in (ay: 0.0, az: 0.0) }
        let result = recorder.finish()

        XCTAssertEqual(result.cadenceSpm, 0.0)
        XCTAssertEqual(result.fogCount, 0)
    }

    func testAnEmptyRecordingIsSafe() {
        let result = WalkTestRecorder().finish()
        XCTAssertEqual(result.durationSec, 0.0)
        XCTAssertEqual(result.cadenceSpm, 0.0)
        XCTAssertEqual(result.stepCount, 0)
    }
}
