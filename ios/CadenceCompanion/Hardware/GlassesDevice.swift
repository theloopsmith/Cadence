import Foundation

// MARK: - Motion source

/// Anything that can stream IMU samples into the detectors: the iPhone's
/// CoreMotion today, the glasses' motion stream once the toolkit is wired.
public protocol MotionSource: AnyObject {
    var isAvailable: Bool { get }
    var isActive: Bool { get }
    func start(_ onSample: @escaping (IMUSample) -> Void)
    func stop()
}

extension PhoneMotionSource: MotionSource {}

// MARK: - Glasses

public enum GlassesConnectionState: Equatable {
    /// No glasses have ever been paired with this phone.
    case notPaired
    case connecting
    case connected
    case disconnected
}

public enum GlassesWearState: String {
    case worn = "worn"
    case notWorn = "not_worn"
    /// The device cannot say, or no device is attached.
    case unknown = "unknown"
}

public struct GlassesCapabilities: Equatable {
    public var imu: Bool
    public var microphone: Bool
    public var camera: Bool
    public var audioOutput: Bool
    public var imuSampleRateHz: Double?
    /// Whether the frames can vibrate. Unverified on hardware; assumed false
    /// until the toolkit says otherwise.
    public var haptics: Bool

    public init(
        imu: Bool, microphone: Bool, camera: Bool, audioOutput: Bool,
        imuSampleRateHz: Double?, haptics: Bool = false
    ) {
        self.imu = imu
        self.microphone = microphone
        self.camera = camera
        self.audioOutput = audioOutput
        self.imuSampleRateHz = imuSampleRateHz
        self.haptics = haptics
    }
}

public enum GlassesError: Error, Equatable, LocalizedError {
    case notConnected
    case cameraUnavailable
    case captureFailed
    case captureInProgress

    public var errorDescription: String? {
        switch self {
        case .notConnected: return "The glasses are not connected."
        case .cameraUnavailable: return "The glasses camera is unavailable. Check the connection and allow camera access in the Meta AI app."
        case .captureFailed: return "The photo could not be taken. Try again."
        case .captureInProgress: return "A glasses photo is already being taken. Please wait."
        }
    }
}

/// What Cadence needs from a pair of glasses.
///
/// The Meta Wearables Device Access Toolkit adapter conforms to this once
/// access is granted. Until then `MockGlassesDevice` stands in, and the
/// Settings screen says so. Nothing here names a toolkit API.
public protocol GlassesDevice: AnyObject {
    var connectionError: String? { get }
    func cancelPhotoCapture()
    var name: String { get }
    var connectionState: GlassesConnectionState { get }
    var wearState: GlassesWearState { get }
    var capabilities: GlassesCapabilities { get }
    /// IMU stream, usable while `connectionState == .connected` and
    /// `capabilities.imu` is true.
    var motion: MotionSource { get }
    /// Called on the main thread whenever connection or wear state changes.
    var onStateChange: ((GlassesDevice) -> Void)? { get set }

    func connect()
    func disconnect()
    /// One JPEG frame from the glasses camera.
    func captureFrame(_ completion: @escaping (Result<Data, GlassesError>) -> Void)
    /// Vibrates the frames, when `capabilities.haptics` is true.
    func playHaptic(_ pattern: HapticPattern)
}

public extension GlassesDevice {
    var connectionError: String? { nil }
    func cancelPhotoCapture() {}
}

/// Lets the fall check-in ask whether the glasses are on a head without
/// depending on a particular device type.
public protocol WearStateProviding: AnyObject {
    /// True or false from hardware; nil when there is no answer.
    var isWorn: Bool? { get }
}

// MARK: - Mock device

/// Replays a sample loop as if it came from the glasses, so every path that
/// depends on the glasses runs before the real toolkit is available.
public final class MockGlassesDevice: GlassesDevice {
    public let name: String
    public private(set) var connectionState: GlassesConnectionState = .disconnected
    public private(set) var wearState: GlassesWearState = .unknown
    public let capabilities: GlassesCapabilities
    public var onStateChange: ((GlassesDevice) -> Void)?

    private let loop: MockGlassesMotionSource
    private let frame: Data?
    /// Where mock haptics go, so tests can see them.
    public var hapticSink: HapticPatternPlaying?

    public var motion: MotionSource { loop }

    public init(
        name: String,
        loopSamples: [IMUSample],
        sampleRateHz: Double = 50.0,
        frame: Data? = nil,
        capabilities: GlassesCapabilities? = nil
    ) {
        self.name = name
        self.frame = frame
        self.capabilities = capabilities ?? GlassesCapabilities(
            imu: true, microphone: true, camera: true, audioOutput: true, imuSampleRateHz: sampleRateHz
        )
        self.loop = MockGlassesMotionSource(samples: loopSamples, sampleRateHz: sampleRateHz)
    }

    public func connect() {
        connectionState = .connected
        wearState = .worn
        onStateChange?(self)
    }

    public func disconnect() {
        loop.stop()
        connectionState = .disconnected
        wearState = .unknown
        onStateChange?(self)
    }

    public func setWearState(_ state: GlassesWearState) {
        wearState = state
        onStateChange?(self)
    }

    public func captureFrame(_ completion: @escaping (Result<Data, GlassesError>) -> Void) {
        guard connectionState == .connected else { return completion(.failure(.notConnected)) }
        guard capabilities.camera, let frame else { return completion(.failure(.cameraUnavailable)) }
        completion(.success(frame))
    }

    public static let sampleFrameJPEG: Data = {
        // Minimal valid 1x1 JPEG (63 bytes)
        Data([
            0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01,
            0x01, 0x01, 0x00, 0x48, 0x00, 0x48, 0x00, 0x00, 0xFF, 0xDB, 0x00, 0x43,
            0x00, 0x08, 0x06, 0x06, 0x07, 0x06, 0x05, 0x08, 0x07, 0x07, 0x07, 0x09,
            0x09, 0x08, 0x0A, 0x0C, 0x14, 0x0D, 0x0C, 0x0B, 0x0B, 0x0C, 0x19, 0x12,
            0x13, 0x0F, 0x14, 0x1D, 0x1A, 0x1F, 0x1E, 0x1D, 0x1A, 0x1C, 0x1C, 0x20,
            0x24, 0x2E, 0x27, 0x20, 0x22, 0x2C, 0x23, 0x1C, 0x1C, 0x28, 0x37, 0x29,
            0x2C, 0x30, 0x31, 0x34, 0x34, 0x34, 0x1F, 0x27, 0x39, 0x3D, 0x38, 0x32,
            0x3C, 0x2E, 0x33, 0x34, 0x32, 0xFF, 0xC0, 0x00, 0x0B, 0x08, 0x00, 0x01,
            0x00, 0x01, 0x01, 0x01, 0x11, 0x00, 0xFF, 0xC4, 0x00, 0x1F, 0x00, 0x00,
            0x01, 0x05, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
            0x09, 0x0A, 0x0B, 0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3F,
            0x00, 0xBF, 0x00, 0xFF, 0xD9
        ])
    }()

    public func playHaptic(_ pattern: HapticPattern) {
        guard connectionState == .connected, capabilities.haptics else { return }
        hapticSink?.play(pattern)
    }

    /// Delivers the next looped sample synchronously. Tests drive the stream
    /// with this; the live mock uses a timer at the sample rate.
    public func pumpOneSample() {
        loop.pump()
    }
}

/// Loops a sample array at a fixed rate with continuous timestamps.
final class MockGlassesMotionSource: MotionSource {
    private let samples: [IMUSample]
    private let sampleRateHz: Double
    private var index = 0
    private var timeOffset = 0.0
    private var onSample: ((IMUSample) -> Void)?
    private var timer: Timer?

    private(set) var isActive = false
    var isAvailable: Bool { !samples.isEmpty }

    init(samples: [IMUSample], sampleRateHz: Double) {
        self.samples = samples
        self.sampleRateHz = sampleRateHz
    }

    func start(_ onSample: @escaping (IMUSample) -> Void) {
        guard !isActive else { return }
        self.onSample = onSample
        isActive = true
        index = 0
        timeOffset = 0
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / sampleRateHz, repeats: true) { [weak self] _ in
            self?.pump()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isActive = false
        onSample = nil
    }

    func pump() {
        guard isActive, !samples.isEmpty, let onSample else { return }
        let s = samples[index]
        let shifted = IMUSample(
            timestamp: s.timestamp + timeOffset, ax: s.ax, ay: s.ay, az: s.az,
            gx: s.gx, gy: s.gy, gz: s.gz, pitchDeg: s.pitchDeg, rollDeg: s.rollDeg
        )
        onSample(shifted)
        index += 1
        if index >= samples.count {
            index = 0
            // Continue time past the end of the loop so the seam is invisible.
            timeOffset = shifted.timestamp + 1.0 / sampleRateHz - samples[0].timestamp
        }
    }
}
