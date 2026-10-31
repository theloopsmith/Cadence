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

    @Published public private(set) var targetSource: CaptureSource = .phoneRecording
    public let store: LabeledCaptureStore
    private let detector: FoGDetector
    private let calibrator = FoGCalibrator()

    public init(store: LabeledCaptureStore = .default, detector: FoGDetector) {
        self.store = store
        self.detector = detector
    }

    /// Loads recordings, picks a source, calibrates, and applies the result.
    public func recalibrate(for target: CaptureSource? = nil) {
        if let target { targetSource = target }
        let recorded: [LabeledCapture]
        var loadProblem: String?
        do {
            recorded = try store.loadAll()
        } catch {
            recorded = []
            loadProblem = "Saved recordings could not be read. Using built-in reference motion."
        }
        recordedCaptures = recorded

        let reference = LabeledCaptureLibrary.referenceCaptures()
        let chosen = FoGCalibrationSource.choose(recorded: recorded, reference: reference, preferredSource: targetSource)

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
            problem = "Calibration needs walking, stillness and a labeled freeze clip from the same sensor. Using built-in reference motion until suitable recordings are available."
        } else {
            problem = loadProblem
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
        do {
            try store.remove(id: id)
            recalibrate()
        } catch {
            problem = "The recording could not be deleted. Your saved calibration is unchanged."
        }
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
            return "Built-in synthetic reference motion. Personal motion has not been validated."
        case .phoneRecording:
            return "Your iPhone recordings (\(recordedCaptures.filter { $0.source == .phoneRecording }.count) clips)."
        case .glassesRecording:
            return "Your glasses recordings (\(recordedCaptures.filter { $0.source == .glassesRecording }.count) clips)."
        }
    }
}

/// Records a labeled stretch of live motion for calibration.
@MainActor
public final class LabeledCaptureRecorder: ObservableObject {
    @Published public private(set) var saveError: String?
    @Published public private(set) var pendingCapture: LabeledCapture?
    @Published public private(set) var isRecording = false
    @Published public private(set) var label: GaitLabel?
    @Published public private(set) var sampleCount = 0
    @Published public private(set) var elapsedSec = 0.0

    private let motion: MotionFeed
    private let store: LabeledCaptureStore
    private let source: CaptureSource
    private var samples: [IMUSample] = []
    private var recordingStreamID: UUID?
    private var recordingSource: CaptureSource?
    private var sinkToken: UUID?

    public init(motion: MotionFeed, store: LabeledCaptureStore = .default, source: CaptureSource) {
        self.motion = motion
        self.store = store
        self.source = source
    }

    public func start(label: GaitLabel) {
        guard !isRecording, pendingCapture == nil else { return }
        saveError = nil
        self.label = label
        recordingStreamID = motion.streamID
        recordingSource = motion.activeCaptureSource ?? source
        samples.removeAll()
        sampleCount = 0
        elapsedSec = 0
        isRecording = true
        sinkToken = motion.addSink { [weak self] sample in
            guard let self, self.isRecording else { return }
            guard self.recordingStreamID == self.motion.streamID else {
                self.cancel()
                self.saveError = "Motion source changed. The incomplete recording was discarded; start a new recording."
                return
            }
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
        guard recordingStreamID == motion.streamID else {
            cancel()
            saveError = "Motion source changed. The incomplete recording was discarded; start a new recording."
            return nil
        }
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
        let capture = LabeledCapture(label: label, source: recordingSource ?? source, sampleRateHz: rate, samples: rebased)
        pendingCapture = capture
        return retrySaving()
    }

    @discardableResult
    public func retrySaving() -> LabeledCapture? {
        guard let capture = pendingCapture else { return nil }
        do {
            try store.save(capture)
            pendingCapture = nil
            saveError = nil
            return capture
        } catch {
            saveError = "Recording could not be saved. It is kept in memory while Cadence stays open. Retry saving or discard it."
            return nil
        }
    }

    public func discardPendingRecording() {
        pendingCapture = nil
        saveError = nil
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
