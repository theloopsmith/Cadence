import Combine
import Foundation

/// Keeps the live detector on thresholds derived from whatever labeled data
/// the phone has: recordings when they are complete, the reference set when
/// they are not. Publishes where the thresholds came from so Settings can
/// show it honestly.
@MainActor
public final class FoGCalibrationController: ObservableObject {
    @Published public private(set) var source: CaptureSource = .syntheticReference
    @Published public private(set) var thresholds: FoGThresholds = .calibratedReference
    @Published public private(set) var report: FoGCalibrationReport?
    /// Why recordings were not used, in plain language. Nil when all is well.
    @Published public private(set) var problem: String?
    @Published public private(set) var recordedCaptures: [LabeledCapture] = []

    public let store: LabeledCaptureStore
    private let detector: FoGDetector
    private let calibrator = FoGCalibrator()

    public init(store: LabeledCaptureStore = .default, detector: FoGDetector) {
        self.store = store
        self.detector = detector
    }

    /// Loads recordings, picks a source, calibrates, and applies the result.
    public func recalibrate() {
        let recorded: [LabeledCapture]
        do {
            recorded = try store.loadAll()
        } catch {
            recorded = []
            problem = "Saved recordings could not be read."
        }
        recordedCaptures = recorded

        let reference = LabeledCaptureLibrary.referenceCaptures()
        let chosen = FoGCalibrationSource.choose(recorded: recorded, reference: reference)

        if chosen.source != .syntheticReference {
            do {
                let result = try calibrator.calibrate(chosen.captures)
                apply(result, source: chosen.source)
                problem = nil
                return
            } catch {
                problem = (error as? LocalizedError)?.errorDescription
                    ?? "Your recordings could not be used for calibration."
            }
        } else if !recorded.isEmpty {
            problem = "Record walking, a freeze, and sitting still to calibrate from your own motion."
        } else {
            problem = nil
        }

        do {
            let result = try calibrator.calibrate(reference)
            apply(result, source: .syntheticReference)
        } catch {
            // The reference set is tested to calibrate; keep the compiled-in result.
            detector.thresholds = .calibratedReference
            thresholds = .calibratedReference
            source = .syntheticReference
        }
    }

    public func deleteRecording(id: String) {
        try? store.remove(id: id)
        recalibrate()
    }

    private func apply(_ result: FoGCalibrationResult, source: CaptureSource) {
        detector.thresholds = result.thresholds
        thresholds = result.thresholds
        report = result.report
        self.source = source
    }

    /// Plain-language provenance for the Settings screen.
    public var sourceDescription: String {
        switch source {
        case .syntheticReference:
            return "Built-in reference motion. Record your own walking, a freeze, and sitting still to personalise."
        case .phoneRecording:
            return "Your iPhone recordings (\(recordedCaptures.count) clips)."
        case .glassesRecording:
            return "Your glasses recordings (\(recordedCaptures.count) clips)."
        }
    }
}

/// Records a labeled stretch of live motion for calibration.
@MainActor
public final class LabeledCaptureRecorder: ObservableObject {
    @Published public private(set) var isRecording = false
    @Published public private(set) var label: GaitLabel?
    @Published public private(set) var sampleCount = 0
    @Published public private(set) var elapsedSec = 0.0

    private let motion: MotionFeed
    private let store: LabeledCaptureStore
    private let source: CaptureSource
    private var samples: [IMUSample] = []
    private var sinkToken: UUID?

    public init(motion: MotionFeed, store: LabeledCaptureStore = .default, source: CaptureSource) {
        self.motion = motion
        self.store = store
        self.source = source
    }

    public func start(label: GaitLabel) {
        guard !isRecording else { return }
        self.label = label
        samples.removeAll()
        sampleCount = 0
        elapsedSec = 0
        isRecording = true
        sinkToken = motion.addSink { [weak self] sample in
            guard let self, self.isRecording else { return }
            self.samples.append(sample)
            self.sampleCount = self.samples.count
            if let first = self.samples.first {
                self.elapsedSec = sample.timestamp - first.timestamp
            }
        }
    }

    /// Stops and writes the clip. Returns nil when nothing was captured.
    @discardableResult
    public func stopAndSave() -> LabeledCapture? {
        guard isRecording, let label else { return nil }
        isRecording = false
        if let sinkToken { motion.removeSink(sinkToken) }
        sinkToken = nil
        defer {
            samples.removeAll()
            sampleCount = 0
            elapsedSec = 0
            self.label = nil
        }
        guard samples.count >= 2, let first = samples.first, let last = samples.last,
              last.timestamp > first.timestamp else {
            return nil
        }
        let rate = Double(samples.count - 1) / (last.timestamp - first.timestamp)
        let rebased = samples.map {
            IMUSample(
                timestamp: $0.timestamp - first.timestamp, ax: $0.ax, ay: $0.ay, az: $0.az,
                gx: $0.gx, gy: $0.gy, gz: $0.gz, pitchDeg: $0.pitchDeg, rollDeg: $0.rollDeg
            )
        }
        let capture = LabeledCapture(label: label, source: source, sampleRateHz: rate, samples: rebased)
        do {
            try store.save(capture)
        } catch {
            return nil
        }
        return capture
    }

    public func cancel() {
        isRecording = false
        if let sinkToken { motion.removeSink(sinkToken) }
        sinkToken = nil
        samples.removeAll()
        sampleCount = 0
        elapsedSec = 0
        label = nil
    }
}
