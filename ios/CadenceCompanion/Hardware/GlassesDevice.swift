import Foundation
#if canImport(UIKit)
import UIKit
#endif

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
    var connectionDetails: String? { get }
    func cancelPhotoCapture()
    var onCameraFrame: ((Data) -> Void)? { get set }
    var onCameraPhoto: ((Data) -> Void)? { get set }
    var onCameraError: ((String) -> Void)? { get set }
    func startCameraPreview()
    func stopCameraPreview()
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
    var connectionDetails: String? { nil }
    func cancelPhotoCapture() {}
    var onCameraFrame: ((Data) -> Void)? { get { nil } set {} }
    var onCameraPhoto: ((Data) -> Void)? { get { nil } set {} }
    var onCameraError: ((String) -> Void)? { get { nil } set {} }
    func startCameraPreview() { onCameraError?("Live preview is unavailable on this device.") }
    func stopCameraPreview() {}
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

    public var onCameraFrame: ((Data) -> Void)?
    public var onCameraPhoto: ((Data) -> Void)?
    public var onCameraError: ((String) -> Void)?
    private var previewTimer: Timer?
    public func startCameraPreview() {
        stopCameraPreview()
        guard connectionState == .connected, let frame else { onCameraError?("Mock photo unavailable."); return }
        onCameraFrame?(frame)
        previewTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.onCameraFrame?(frame) }
    }
    public func stopCameraPreview() { previewTimer?.invalidate(); previewTimer = nil }

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
        stopCameraPreview()
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
        #if canImport(UIKit)
        return UIGraphicsImageRenderer(size: CGSize(width: 640, height: 480)).image { context in
            UIColor.darkGray.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 640, height: 480))
            ("MOCK GLASSES CAMERA\nSimulated photo" as NSString).draw(
                in: CGRect(x: 40, y: 180, width: 560, height: 120),
                withAttributes: [.font: UIFont.systemFont(ofSize: 30), .foregroundColor: UIColor.white]
            )
        }.jpegData(compressionQuality: 0.8) ?? Data()
        #else
        return Data("Mock camera frame — not a real photo".utf8)
        #endif
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
