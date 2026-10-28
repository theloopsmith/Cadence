import Foundation

// MARK: - Labeled captures

/// What the wearer was doing while a capture was recorded.
public enum GaitLabel: String, Codable, CaseIterable {
    /// Steady forward walking.
    case walking
    /// Feet stuck, legs trembling: the event a cue should break.
    case freeze
    /// Sitting or lying without moving.
    case still
    /// Turning in place while upright.
    case turnUpright
    /// Rising from a chair.
    case sitToStand
    /// Rolling over in bed.
    case bedRoll
}

public enum CaptureSource: String, Codable {
    /// Generated from the kinematic reference scenarios. Shipped so the app
    /// calibrates out of the box; not a substitute for a real recording.
    case syntheticReference = "synthetic_reference"
    /// Recorded on the iPhone's motion sensors with the label chosen by hand.
    case phoneRecording = "phone_recording"
    /// Recorded from the glasses' motion stream.
    case glassesRecording = "glasses_recording"
}

extension IMUSample: Codable {
    enum CodingKeys: String, CodingKey {
        case timestamp = "t", ax, ay, az, gx, gy, gz, pitchDeg = "pitch", rollDeg = "roll"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            timestamp: try c.decode(Double.self, forKey: .timestamp),
            ax: try c.decode(Double.self, forKey: .ax),
            ay: try c.decode(Double.self, forKey: .ay),
            az: try c.decode(Double.self, forKey: .az),
            gx: try c.decode(Double.self, forKey: .gx),
            gy: try c.decode(Double.self, forKey: .gy),
            gz: try c.decode(Double.self, forKey: .gz),
            pitchDeg: try c.decodeIfPresent(Double.self, forKey: .pitchDeg) ?? 0,
            rollDeg: try c.decodeIfPresent(Double.self, forKey: .rollDeg) ?? 0
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(timestamp, forKey: .timestamp)
        try c.encode(ax, forKey: .ax)
        try c.encode(ay, forKey: .ay)
        try c.encode(az, forKey: .az)
        try c.encode(gx, forKey: .gx)
        try c.encode(gy, forKey: .gy)
        try c.encode(gz, forKey: .gz)
        try c.encode(pitchDeg, forKey: .pitchDeg)
        try c.encode(rollDeg, forKey: .rollDeg)
    }
}

/// One labeled stretch of motion data.
public struct LabeledCapture: Codable, Identifiable {
    public var id: String
    public var label: GaitLabel
    public var source: CaptureSource
    public var sampleRateHz: Double
    public var recordedAt: Date
    public var samples: [IMUSample]

    public init(
        id: String = UUID().uuidString,
        label: GaitLabel,
        source: CaptureSource,
        sampleRateHz: Double,
        recordedAt: Date = Date(),
        samples: [IMUSample]
    ) {
        self.id = id
        self.label = label
        self.source = source
        self.sampleRateHz = sampleRateHz
        self.recordedAt = recordedAt
        self.samples = samples
    }

    public var durationSec: Double {
        guard let first = samples.first, let last = samples.last else { return 0 }
        return last.timestamp - first.timestamp
    }
}

// MARK: - Thresholds

/// Everything the detector compares against. Produced by `FoGCalibrator`.
public struct FoGThresholds: Equatable, Codable {
    /// Freeze index above which a hop counts toward a freeze.
    public var freezeIndexTrigger: Double
    /// Freeze index below which locomotion counts as recovered.
    public var recoveryFreezeIndex: Double
    /// Locomotor band power that marks a hop as active walking.
    public var locomotorArmingPower: Double
    /// Total dynamic energy below which the wearer is treated as still.
    public var dynamicEnergyFloor: Double
    /// Added to the trigger while the wearer is talking, because speech
    /// moves the head in the freeze band. A specification rule, not a
    /// calibrated value.
    public var speakingTriggerBonus: Double = 0.8

    public init(
        freezeIndexTrigger: Double,
        recoveryFreezeIndex: Double,
        locomotorArmingPower: Double,
        dynamicEnergyFloor: Double,
        speakingTriggerBonus: Double = 0.8
    ) {
        self.freezeIndexTrigger = freezeIndexTrigger
        self.recoveryFreezeIndex = recoveryFreezeIndex
        self.locomotorArmingPower = locomotorArmingPower
        self.dynamicEnergyFloor = dynamicEnergyFloor
        self.speakingTriggerBonus = speakingTriggerBonus
    }

    /// Thresholds calibrated from the bundled reference captures. Computed
    /// once; there is no literal fallback.
    public static let calibratedReference: FoGThresholds = {
        do {
            return try FoGCalibrator().calibrate(LabeledCaptureLibrary.referenceCaptures()).thresholds
        } catch {
            preconditionFailure("reference capture set failed to calibrate: \(error)")
        }
    }()
}

// MARK: - Calibration

public enum FoGCalibrationError: Error, Equatable, LocalizedError {
    case missingLabel(GaitLabel)
    case tooFewHops(GaitLabel, Int)
    case insufficientSeparation(walkingP95: Double, freezeP05: Double)

    public var errorDescription: String? {
        switch self {
        case let .missingLabel(label):
            return "No \(label.rawValue) capture was provided."
        case let .tooFewHops(label, count):
            return "The \(label.rawValue) capture is too short (\(count) analysis windows)."
        case let .insufficientSeparation(w, f):
            return String(
                format: "Walking (FI p95 %.2f) and freezing (FI p05 %.2f) overlap; relabel or re-record.",
                w, f
            )
        }
    }
}

/// What the calibration saw, kept so the app can show where its thresholds
/// came from and how much margin each false-positive trap has.
public struct FoGCalibrationReport: Equatable {
    public let source: CaptureSource
    public let captureCount: Int
    public let walkingFreezeIndexP95: Double
    public let freezeFreezeIndexP05: Double
    public let walkingLocomotorP10: Double
    public let stillEnergyP95: Double
    /// Trigger minus the label's peak freeze index. Positive means safe.
    public let trapMargins: [GaitLabel: Double]
}

public struct FoGCalibrationResult {
    public let thresholds: FoGThresholds
    public let report: FoGCalibrationReport
}

/// Derives detector thresholds from labeled captures.
///
/// Every capture is run through the same resampler and spectral analysis
/// the live detector uses, hop by hop, so the thresholds describe exactly
/// the numbers the detector will see.
public struct FoGCalibrator {
    /// Hops a label needs before its percentiles mean anything.
    public var minimumHopsPerLabel = 4
    /// The freeze p05 must exceed the walking p95 by this factor.
    public var minimumSeparationRatio = 1.25

    public init() {}

    struct HopMetrics {
        let locomotor: Double
        let freeze: Double
        let energy: Double
        let freezeIndex: Double
    }

    public func calibrate(_ captures: [LabeledCapture]) throws -> FoGCalibrationResult {
        var hopsByLabel: [GaitLabel: [HopMetrics]] = [:]
        for capture in captures {
            hopsByLabel[capture.label, default: []] += Self.hops(for: capture)
        }

        for required in [GaitLabel.walking, .freeze, .still] {
            guard let hops = hopsByLabel[required], !hops.isEmpty else {
                throw FoGCalibrationError.missingLabel(required)
            }
            guard hops.count >= minimumHopsPerLabel else {
                throw FoGCalibrationError.tooFewHops(required, hops.count)
            }
        }

        let still = hopsByLabel[.still]!
        let stillEnergyP95 = Self.percentile(still.map(\.energy), 0.95)
        // Twice the quietest-state ceiling: sitting still never reads as moving.
        let energyFloor = max(stillEnergyP95 * 2.0, 1e-4)

        let walkingMoving = hopsByLabel[.walking]!.filter { $0.energy > energyFloor }
        let freezeMoving = hopsByLabel[.freeze]!.filter { $0.energy > energyFloor }
        guard walkingMoving.count >= minimumHopsPerLabel else {
            throw FoGCalibrationError.tooFewHops(.walking, walkingMoving.count)
        }
        guard freezeMoving.count >= minimumHopsPerLabel else {
            throw FoGCalibrationError.tooFewHops(.freeze, freezeMoving.count)
        }

        let walkingFIP95 = Self.percentile(walkingMoving.map(\.freezeIndex), 0.95)
        let freezeFIP05 = Self.percentile(freezeMoving.map(\.freezeIndex), 0.05)
        guard freezeFIP05 > walkingFIP95 * minimumSeparationRatio, walkingFIP95 > 0 else {
            throw FoGCalibrationError.insufficientSeparation(walkingP95: walkingFIP95, freezeP05: freezeFIP05)
        }

        // Geometric midpoint: the freeze index is a ratio, so the gap is
        // multiplicative, and the midpoint sits an equal factor from each side.
        let trigger = sqrt(walkingFIP95 * freezeFIP05)
        // Recovery sits at the walking p90, strictly below the trigger, so a
        // cue stops on real strides and not on a single quieter hop.
        let recovery = min(Self.percentile(walkingMoving.map(\.freezeIndex), 0.90), trigger * 0.6)

        let walkingLocoP10 = Self.percentile(walkingMoving.map(\.locomotor), 0.10)
        // Half the quietest walking hop: the slowest stride in the data arms.
        let locomotorArming = walkingLocoP10 * 0.5

        var trapMargins: [GaitLabel: Double] = [:]
        for trap in [GaitLabel.turnUpright, .sitToStand, .bedRoll] {
            guard let hops = hopsByLabel[trap] else { continue }
            let moving = hops.filter { $0.energy > energyFloor }
            let peak = moving.map(\.freezeIndex).max() ?? 0
            trapMargins[trap] = trigger - peak
        }

        let source = captures.first?.source ?? .syntheticReference
        return FoGCalibrationResult(
            thresholds: FoGThresholds(
                freezeIndexTrigger: trigger,
                recoveryFreezeIndex: recovery,
                locomotorArmingPower: locomotorArming,
                dynamicEnergyFloor: energyFloor
            ),
            report: FoGCalibrationReport(
                source: source,
                captureCount: captures.count,
                walkingFreezeIndexP95: walkingFIP95,
                freezeFreezeIndexP05: freezeFIP05,
                walkingLocomotorP10: walkingLocoP10,
                stillEnergyP95: stillEnergyP95,
                trapMargins: trapMargins
            )
        )
    }

    /// Spectral metrics for every half-second hop in a capture, computed the
    /// way `LiveEdgeEngine` computes them.
    static func hops(for capture: LabeledCapture) -> [HopMetrics] {
        let stream = SensorStreamManager()
        let detector = FoGDetector(thresholds: FoGThresholds(
            freezeIndexTrigger: 1, recoveryFreezeIndex: 1, locomotorArmingPower: 1, dynamicEnergyFloor: 1
        ))
        var lastHop: Double?
        var out: [HopMetrics] = []
        for sample in capture.samples {
            stream.appendSample(sample)
            if let last = lastHop, sample.timestamp - last < stream.hopDurationSec { continue }
            lastHop = sample.timestamp
            guard stream.bufferedDurationSec >= 2.4 else { continue }
            let window = stream.uniformResampledWindow()
            guard window.count >= 16 else { continue }
            let m = detector.computeSpectralMetrics(window: window, sampledHz: stream.estimatedSampleRateHz)
            out.append(HopMetrics(
                locomotor: m.locomotorBandPower,
                freeze: m.freezeBandPower,
                energy: m.totalDynamicEnergy,
                freezeIndex: m.freezeIndex
            ))
        }
        return out
    }

    static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let rank = p * Double(sorted.count - 1)
        let lower = Int(rank.rounded(.down))
        let upper = min(lower + 1, sorted.count - 1)
        let frac = rank - Double(lower)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * frac
    }
}

// MARK: - Choosing a source

/// Which capture set the app calibrates from.
public struct FoGCalibrationSource {
    public let source: CaptureSource
    public let captures: [LabeledCapture]

    /// Recorded data wins when it covers the labels the calibrator needs;
    /// otherwise the shipped reference set is used and shown as such.
    public static func choose(recorded: [LabeledCapture], reference: [LabeledCapture]) -> FoGCalibrationSource {
        let recordedLabels = Set(recorded.map(\.label))
        let required: Set<GaitLabel> = [.walking, .freeze, .still]
        if required.isSubset(of: recordedLabels), let source = recorded.first?.source {
            return FoGCalibrationSource(source: source, captures: recorded)
        }
        return FoGCalibrationSource(source: .syntheticReference, captures: reference)
    }
}

// MARK: - Storage

/// Reads and writes labeled captures as JSON files in one directory.
public struct LabeledCaptureStore {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// The app's default location: Documents/LabeledCaptures.
    public static var `default`: LabeledCaptureStore {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return LabeledCaptureStore(directory: docs.appendingPathComponent("LabeledCaptures", isDirectory: true))
    }

    public func save(_ capture: LabeledCapture) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(capture)
        try data.write(to: fileURL(for: capture.id), options: .atomic)
    }

    public func loadAll() throws -> [LabeledCapture] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        return try files
            .filter { $0.pathExtension == "json" }
            .map { try decoder.decode(LabeledCapture.self, from: Data(contentsOf: $0)) }
            .sorted { $0.recordedAt < $1.recordedAt }
    }

    public func remove(id: String) throws {
        let url = fileURL(for: id)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func fileURL(for id: String) -> URL {
        directory.appendingPathComponent("\(id).json")
    }
}

// MARK: - Reference captures

/// Deterministic Gaussian noise so the reference set is identical on every
/// run. Box-Muller over a 64-bit xorshift.
struct SeededGaussian {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x9E3779B97F4A7C15 : seed
    }

    private mutating func uniform() -> Double {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return Double(state >> 11) / Double(1 << 53)
    }

    mutating func next() -> Double {
        let u1 = max(uniform(), 1e-12)
        let u2 = uniform()
        return sqrt(-2.0 * log(u1)) * cos(2.0 * .pi * u2)
    }
}

/// Labeled captures synthesised from a head-worn motion model.
///
/// These exist so the app calibrates before any real recording has been
/// made. They carry what a real sensor carries — gait harmonics that land in
/// the freeze band, sensor noise, breathing and head sway at rest — so the
/// thresholds they produce are not artefacts of a clean sine wave. They are
/// still synthetic, say so in `source`, and the Settings screen shows that
/// provenance until phone or glasses recordings replace them.
public enum LabeledCaptureLibrary {
    public static func referenceCaptures(sampleRateHz fs: Double = 50.0) -> [LabeledCapture] {
        [
            LabeledCapture(
                id: "ref-walking-normal", label: .walking, source: .syntheticReference,
                sampleRateHz: fs, samples: walking(seconds: 12, fs: fs, strideHz: 1.8, bobG: 0.45, seed: 11)
            ),
            LabeledCapture(
                id: "ref-walking-brisk", label: .walking, source: .syntheticReference,
                sampleRateHz: fs, samples: walking(seconds: 12, fs: fs, strideHz: 2.1, bobG: 0.55, seed: 12)
            ),
            LabeledCapture(
                id: "ref-walking-slow", label: .walking, source: .syntheticReference,
                sampleRateHz: fs, samples: walking(seconds: 12, fs: fs, strideHz: 1.3, bobG: 0.30, seed: 13)
            ),
            LabeledCapture(
                id: "ref-freeze-strong", label: .freeze, source: .syntheticReference,
                sampleRateHz: fs, samples: freeze(seconds: 8, fs: fs, trembleHz: 5.5, trembleG: 0.80, residualG: 0.04, seed: 21)
            ),
            LabeledCapture(
                id: "ref-freeze-weak", label: .freeze, source: .syntheticReference,
                sampleRateHz: fs, samples: freeze(seconds: 8, fs: fs, trembleHz: 4.5, trembleG: 0.40, residualG: 0.10, seed: 22)
            ),
            LabeledCapture(
                id: "ref-still-seated", label: .still, source: .syntheticReference,
                sampleRateHz: fs, samples: still(seconds: 10, fs: fs, pitchDeg: 2.0, swayG: 0.025, seed: 31)
            ),
            LabeledCapture(
                id: "ref-still-lying", label: .still, source: .syntheticReference,
                sampleRateHz: fs, samples: still(seconds: 10, fs: fs, pitchDeg: 74.0, swayG: 0.012, seed: 32)
            ),
            LabeledCapture(
                id: "ref-sit-to-stand", label: .sitToStand, source: .syntheticReference,
                sampleRateHz: fs, samples: sitToStand(fs: fs, seed: 41)
            ),
            LabeledCapture(
                id: "ref-turn-upright", label: .turnUpright, source: .syntheticReference,
                sampleRateHz: fs, samples: uprightTurn(seconds: 6, fs: fs, seed: 51)
            ),
            LabeledCapture(
                id: "ref-bed-roll", label: .bedRoll, source: .syntheticReference,
                sampleRateHz: fs, samples: bedRoll(seconds: 6, fs: fs, seed: 61)
            ),
        ]
    }

    /// Joins clips end to end with continuous timestamps, one sample period
    /// apart at each seam, so a replayed sequence never runs backwards.
    public static func concatenate(_ parts: [[IMUSample]], sampleRateHz: Double) -> [IMUSample] {
        var out: [IMUSample] = []
        var offset = 0.0
        for part in parts {
            guard let first = part.first else { continue }
            for s in part {
                out.append(IMUSample(
                    timestamp: s.timestamp - first.timestamp + offset, ax: s.ax, ay: s.ay, az: s.az,
                    gx: s.gx, gy: s.gy, gz: s.gz, pitchDeg: s.pitchDeg, rollDeg: s.rollDeg
                ))
            }
            if let last = out.last {
                offset = last.timestamp + 1.0 / sampleRateHz
            }
        }
        return out
    }

    /// Sensor noise on each axis, in g.
    private static let noiseG = 0.015

    /// Walking as seen at the head: a stride fundamental with second and
    /// third harmonics (the second lands in the freeze band above 1.5 Hz),
    /// a slow head nod, and noise.
    private static func walking(
        seconds: Double, fs: Double, strideHz: Double, bobG: Double, seed: UInt64
    ) -> [IMUSample] {
        var noise = SeededGaussian(seed: seed)
        return (0..<Int(seconds * fs)).map { i in
            let t = Double(i) / fs
            let w = 2.0 * .pi * strideHz * t
            let bob = bobG * sin(w) + 0.35 * bobG * sin(2 * w + 0.4) + 0.15 * bobG * sin(3 * w + 0.9)
            let nod = 0.04 * sin(2.0 * .pi * 0.3 * t)
            return IMUSample(
                timestamp: t,
                ax: 0.12 * bobG * cos(w) + noiseG * noise.next(),
                ay: 1.0 + bob + nod + noiseG * noise.next(),
                az: 0.5 * bobG * sin(w + 1.2) + noiseG * noise.next(),
                gx: 0.05 * noise.next(),
                gy: 0.3 * sin(w) + 0.05 * noise.next(),
                gz: 0.05 * noise.next(),
                pitchDeg: 4.0 + 2.0 * sin(w),
                rollDeg: 1.5 + 1.0 * cos(w)
            )
        }
    }

    /// A freeze: the feet are stuck and the legs tremble at 4–7 Hz. A little
    /// stride energy remains as the wearer tries to step.
    private static func freeze(
        seconds: Double, fs: Double, trembleHz: Double, trembleG: Double, residualG: Double, seed: UInt64
    ) -> [IMUSample] {
        var noise = SeededGaussian(seed: seed)
        return (0..<Int(seconds * fs)).map { i in
            let t = Double(i) / fs
            // The tremble wanders in frequency a little, as real trembling does.
            let f = trembleHz + 0.3 * sin(2.0 * .pi * 0.2 * t)
            let tremble = trembleG * sin(2.0 * .pi * f * t)
            let residual = residualG * sin(2.0 * .pi * 1.5 * t)
            return IMUSample(
                timestamp: t,
                ax: 0.03 + noiseG * noise.next(),
                ay: 1.0 + tremble + residual + noiseG * noise.next(),
                az: 0.5 * tremble + noiseG * noise.next(),
                gx: 0.15 + 0.05 * noise.next(),
                gy: 0.9 * sin(2.0 * .pi * f * t) + 0.05 * noise.next(),
                gz: 0.12 + 0.05 * noise.next(),
                pitchDeg: 6.5,
                rollDeg: 2.0
            )
        }
    }

    /// Sitting or lying quietly: breathing, a slow sway, and sensor noise.
    private static func still(
        seconds: Double, fs: Double, pitchDeg: Double, swayG: Double, seed: UInt64
    ) -> [IMUSample] {
        var noise = SeededGaussian(seed: seed)
        let lying = pitchDeg > 60
        return (0..<Int(seconds * fs)).map { i in
            let t = Double(i) / fs
            let breathing = 0.012 * sin(2.0 * .pi * 0.25 * t)
            let sway = swayG * sin(2.0 * .pi * 0.8 * t + 0.3)
            let vertical = 1.0 + breathing + sway + noiseG * noise.next()
            return IMUSample(
                timestamp: t,
                ax: (lying ? 0.96 : 0.02) + noiseG * noise.next(),
                ay: lying ? 0.15 + breathing + noiseG * noise.next() : vertical,
                az: 0.03 + noiseG * noise.next(),
                gx: 0.01 * noise.next(),
                gy: 0.01 * noise.next(),
                gz: 0.01 * noise.next(),
                pitchDeg: pitchDeg + 0.5 * sin(2.0 * .pi * 0.25 * t),
                rollDeg: lying ? 20.0 : 1.0
            )
        }
    }

    /// Six seconds seated, then a two-second forward lean and rise, then two
    /// seconds standing. The rise must not read as a freeze.
    private static func sitToStand(fs: Double, seed: UInt64) -> [IMUSample] {
        var noise = SeededGaussian(seed: seed)
        return (0..<Int(10.0 * fs)).map { i in
            let t = Double(i) / fs
            if t < 6.0 {
                let breathing = 0.012 * sin(2.0 * .pi * 0.25 * t)
                return IMUSample(
                    timestamp: t,
                    ax: 0.02 + noiseG * noise.next(),
                    ay: 1.0 + breathing + 0.02 * sin(2.0 * .pi * 0.8 * t) + noiseG * noise.next(),
                    az: 0.03 + noiseG * noise.next(),
                    gx: 0.01 * noise.next(), gy: 0.01 * noise.next(), gz: 0.01 * noise.next(),
                    pitchDeg: 2.0, rollDeg: 1.0
                )
            }
            if t < 8.0 {
                let phase = (t - 6.0) / 2.0
                let rise = 0.45 * sin(.pi * phase)
                return IMUSample(
                    timestamp: t,
                    ax: 0.10 + noiseG * noise.next(),
                    ay: 1.0 + rise + noiseG * noise.next(),
                    az: 0.20 * sin(.pi * phase) + noiseG * noise.next(),
                    gx: 0.35 * sin(.pi * phase) + 0.03 * noise.next(),
                    gy: 0.05 * noise.next(),
                    gz: 0.03 * noise.next(),
                    pitchDeg: 20.0 * sin(.pi * phase),
                    rollDeg: 2.0
                )
            }
            return IMUSample(
                timestamp: t,
                ax: 0.02 + noiseG * noise.next(),
                ay: 1.0 + 0.03 * sin(2.0 * .pi * 0.9 * t) + noiseG * noise.next(),
                az: 0.02 + noiseG * noise.next(),
                gx: 0.02 * noise.next(), gy: 0.02 * noise.next(), gz: 0.02 * noise.next(),
                pitchDeg: 4.0, rollDeg: 2.0
            )
        }
    }

    /// Standing upright and turning through about 90° over two seconds, with
    /// the shuffle-steps and sway that go with it. Must never read as a freeze.
    private static func uprightTurn(seconds: Double, fs: Double, seed: UInt64) -> [IMUSample] {
        var noise = SeededGaussian(seed: seed)
        return (0..<Int(seconds * fs)).map { i in
            let t = Double(i) / fs
            let turning = t >= 2.0 && t < 4.0
            let yawRate = turning ? 0.8 : 0.0
            // Small pivot steps at about 1.6 Hz while turning.
            let pivot = turning ? 0.12 * sin(2.0 * .pi * 1.6 * t) : 0.0
            let sway = 0.05 * sin(2.0 * .pi * 0.9 * t)
            return IMUSample(
                timestamp: t,
                ax: 0.03 * sin(2.0 * .pi * 0.9 * t) + noiseG * noise.next(),
                ay: 1.0 + sway + pivot + noiseG * noise.next(),
                az: 0.05 * cos(2.0 * .pi * 0.9 * t) + noiseG * noise.next(),
                gx: 0.02 * noise.next(),
                gy: yawRate + 0.03 * noise.next(),
                gz: 0.02 * noise.next(),
                pitchDeg: 4.0, rollDeg: 2.0
            )
        }
    }

    /// Lying down and rolling over: large slow orientation change, no gait.
    private static func bedRoll(seconds: Double, fs: Double, seed: UInt64) -> [IMUSample] {
        var noise = SeededGaussian(seed: seed)
        return (0..<Int(seconds * fs)).map { i in
            let t = Double(i) / fs
            let roll = 72.0 + 15.0 * sin(2.0 * .pi * 0.4 * t)
            return IMUSample(
                timestamp: t,
                ax: 0.94 + noiseG * noise.next(),
                ay: 0.15 + 0.05 * sin(2.0 * .pi * 0.4 * t) + noiseG * noise.next(),
                az: 0.10 + noiseG * noise.next(),
                gx: 0.4 * sin(2.0 * .pi * 0.4 * t) + 0.02 * noise.next(),
                gy: 0.8 * cos(2.0 * .pi * 0.4 * t) + 0.02 * noise.next(),
                gz: 0.2 + 0.02 * noise.next(),
                pitchDeg: roll,
                rollDeg: 25.0
            )
        }
    }
}
