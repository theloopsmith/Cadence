import Combine
import Foundation

/// Owns whichever glasses are attached and decides where motion comes from.
///
/// With connected glasses that expose an IMU, the glasses stream feeds the
/// detectors; otherwise the iPhone does. The fall check-in reads wear state
/// from here. No toolkit API is referenced; the real adapter plugs in as a
/// `GlassesDevice`.
///
/// Used from the main thread: devices report state changes there, and the
/// published properties drive SwiftUI.
public final class GlassesSessionManager: ObservableObject, WearStateProviding {
    @Published public private(set) var connectionState: GlassesConnectionState = .notPaired
    @Published public private(set) var wearState: GlassesWearState = .unknown
    @Published public private(set) var deviceName: String?
    @Published public private(set) var capabilities: GlassesCapabilities?
    @Published public private(set) var connectionError: String?
    @Published public private(set) var isCapturingPhoto = false

    public private(set) var device: GlassesDevice?
    private let phoneMotion: MotionSource
    private let photoTimeoutSec: Double
    private let connectionTimeoutSec: Double
    private var connectionTimeout: Task<Void, Never>?
    private var photoRequestID: UUID?
    private var photoCompletion: ((Result<Data, GlassesError>) -> Void)?
    private var photoTimeout: Task<Void, Never>?

    public init(phoneMotion: MotionSource, photoTimeoutSec: Double = 20, connectionTimeoutSec: Double = 30) {
        self.phoneMotion = phoneMotion
        self.photoTimeoutSec = photoTimeoutSec
        self.connectionTimeoutSec = connectionTimeoutSec
    }

    /// Attaches a device and mirrors its state. Replaces any previous device.
    public func attach(_ device: GlassesDevice) {
        connectionTimeout?.cancel()
        cancelPhotoCapture()
        self.device?.onStateChange = nil
        self.device?.disconnect()
        self.device = device
        device.onStateChange = { [weak self] device in
            guard let self else { return }
            if Thread.isMainThread {
                guard self.device === device else { return }
                self.mirror(device)
            } else {
                DispatchQueue.main.async {
                    guard self.device === device else { return }
                    self.mirror(device)
                }
            }
        }
        mirror(device)
    }

    public func detach() {
        connectionTimeout?.cancel()
        cancelPhotoCapture()
        device?.onStateChange = nil
        device?.disconnect()
        device = nil
        connectionState = .notPaired
        wearState = .unknown
        deviceName = nil
        capabilities = nil
        connectionError = nil
    }

    public func connect() {
        guard let device else {
            connectionError = "Meta glasses are unavailable in this build. Use the Cadence iPhone app with your paired glasses."
            return
        }
        connectionError = nil
        connectionTimeout?.cancel()
        device.connect()
        guard connectionState == .connecting else { return }
        connectionTimeout = Task { @MainActor [weak self, weak device] in
            guard let self else { return }
            do { try await Task.sleep(nanoseconds: UInt64(max(0.001, connectionTimeoutSec) * 1_000_000_000)) }
            catch { return }
            guard let device, self.device === device, connectionState == .connecting else { return }
            device.disconnect()
            connectionError = "Connection timed out. Open the Meta AI app, check that your glasses are connected, then try again."
        }
    }

    public func disconnect() {
        connectionTimeout?.cancel()
        cancelPhotoCapture()
        device?.disconnect()
    }

    /// Glasses motion when connected with an IMU; the phone otherwise.
    public var preferredMotionSource: MotionSource {
        if let device, device.connectionState == .connected, device.capabilities.imu,
           device.motion.isAvailable {
            return device.motion
        }
        return phoneMotion
    }

    public var preferredSourceLabel: String {
        if let device, preferredMotionSource === device.motion {
            return device.name
        }
        return "iPhone"
    }

    /// Hardware wear state, or nil when nothing can report it.
    public var isWorn: Bool? {
        guard device != nil, connectionState == .connected else { return nil }
        switch wearState {
        case .worn: return true
        case .notWorn: return false
        case .unknown: return nil
        }
    }

    /// Whether connected glasses can capture a photo.
    public var canCapturePhoto: Bool {
        device != nil && connectionState == .connected && (capabilities?.camera ?? false)
    }

    /// Captures a photo using the connected glasses device.
    /// Delivers the result to `completion` on the main thread.
    public func capturePhoto(completion: @escaping (Result<Data, GlassesError>) -> Void) {
        guard !isCapturingPhoto else { completion(.failure(.captureInProgress)); return }
        guard let device, connectionState == .connected else {
            DispatchQueue.main.async { completion(.failure(.notConnected)) }
            return
        }
        guard capabilities?.camera ?? false else {
            DispatchQueue.main.async { completion(.failure(.cameraUnavailable)) }
            return
        }
        let id = UUID()
        photoRequestID = id
        photoCompletion = completion
        isCapturingPhoto = true
        photoTimeout = Task { @MainActor [weak self] in
            guard let self else { return }
            do { try await Task.sleep(nanoseconds: UInt64(max(0.001, self.photoTimeoutSec) * 1_000_000_000)) }
            catch { return }
            guard self.photoRequestID == id else { return }
            self.device?.cancelPhotoCapture()
            self.finishPhoto(id: id, result: .failure(.captureFailed))
        }
        device.captureFrame { [weak self] result in
            if Thread.isMainThread {
                self?.finishPhoto(id: id, result: result)
            } else {
                DispatchQueue.main.async { self?.finishPhoto(id: id, result: result) }
            }
        }
    }

    public func cancelPhotoCapture() {
        guard let id = photoRequestID else { return }
        device?.cancelPhotoCapture()
        finishPhoto(id: id, result: .failure(.captureFailed))
    }

    private func finishPhoto(id: UUID, result: Result<Data, GlassesError>) {
        guard photoRequestID == id else { return }
        photoTimeout?.cancel(); photoTimeout = nil
        let completion = photoCompletion
        photoCompletion = nil; photoRequestID = nil; isCapturingPhoto = false
        if case .success(let data) = result, data.isEmpty { completion?(.failure(.captureFailed)) }
        else { completion?(result) }
    }

    private func mirror(_ device: GlassesDevice) {
        connectionState = device.connectionState
        wearState = device.wearState
        deviceName = device.name
        capabilities = device.capabilities
        connectionError = device.connectionError
        if connectionState != .connecting { connectionTimeout?.cancel(); connectionTimeout = nil }
        if connectionState != .connected { cancelPhotoCapture() }
    }
}
