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
    @Published public private(set) var connectionDetails: String?
    @Published public private(set) var isCapturingPhoto = false

    @Published public private(set) var previewFrame: Data?
    @Published public private(set) var cameraPhoto: Data?
    @Published public private(set) var cameraPhotoID = UUID()
    @Published public private(set) var cameraError: String?
    @Published public private(set) var isPreviewOpen = false
    private var previewID = UUID()
    private var lastFrameAt: Date?
    private var previewStarted = false
    private var previewTimeout: Task<Void, Never>?

    public private(set) var device: GlassesDevice?
    private let phoneMotion: MotionSource
    private let previewFirstFrameTimeoutSec: Double
    private let previewStaleTimeoutSec: Double
    private let photoTimeoutSec: Double
    private let connectionTimeoutSec: Double
    private var connectionTimeout: Task<Void, Never>?
    private var photoRequestID: UUID?
    private var photoCompletion: ((Result<Data, GlassesError>) -> Void)?
    private var photoTimeout: Task<Void, Never>?

    public init(phoneMotion: MotionSource, photoTimeoutSec: Double = 20, connectionTimeoutSec: Double = 30, previewFirstFrameTimeoutSec: Double = 20, previewStaleTimeoutSec: Double = 8) {
        self.previewFirstFrameTimeoutSec = previewFirstFrameTimeoutSec
        self.previewStaleTimeoutSec = previewStaleTimeoutSec
        self.phoneMotion = phoneMotion
        self.photoTimeoutSec = photoTimeoutSec
        self.connectionTimeoutSec = connectionTimeoutSec
    }

    /// Attaches a device and mirrors its state. Replaces any previous device.
    public func attach(_ device: GlassesDevice) {
        connectionTimeout?.cancel()
        stopCameraPreview()
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
        stopCameraPreview()
        cancelPhotoCapture()
        device?.onStateChange = nil
        device?.disconnect()
        device = nil
        connectionState = .notPaired
        wearState = .unknown
        deviceName = nil
        capabilities = nil
        connectionError = nil
        connectionDetails = nil
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
            connectionError = "Cadence could not start a glasses session in time. Bluetooth pairing alone does not grant app access. In the Meta AI app, check Cadence under app connections and Developer Mode; keep the glasses worn and unfolded, then retry."
        }
    }

    public func disconnect() {
        connectionTimeout?.cancel()
        stopCameraPreview()
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

    /// The camera belongs to the visible camera screen, never a background observer.
    public func startCameraPreview() {
        stopCameraPreview()
        isPreviewOpen = true
        cameraError = nil
        cameraPhoto = nil
        if connectionState == .connected { beginPreview() }
        else { connect() }
    }

    private func beginPreview() {
        guard isPreviewOpen, !previewStarted, let device else { return }
        previewStarted = true
        let id = previewID
        device.onCameraFrame = { [weak self] data in
            DispatchQueue.main.async {
                guard let self, self.isPreviewOpen, self.previewID == id, !data.isEmpty else { return }
                self.lastFrameAt = Date()
                self.previewFrame = data
            }
        }
        device.onCameraPhoto = { [weak self] data in
            DispatchQueue.main.async {
                guard let self, self.isPreviewOpen, self.previewID == id else { return }
                self.publishPhoto(data)
            }
        }
        device.onCameraError = { [weak self] error in
            DispatchQueue.main.async {
                guard let self, self.isPreviewOpen, self.previewID == id else { return }
                self.cameraError = error
                self.previewFrame = nil
            }
        }
        let openedAt = Date()
        let tick = UInt64(min(1, max(0.001, min(previewFirstFrameTimeoutSec, previewStaleTimeoutSec))) * 1_000_000_000)
        previewTimeout = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: tick) } catch { return }
                guard let self, self.previewID == id, self.isPreviewOpen else { return }
                let stale = self.lastFrameAt.map { Date().timeIntervalSince($0) > self.previewStaleTimeoutSec }
                    ?? (Date().timeIntervalSince(openedAt) > self.previewFirstFrameTimeoutSec)
                if stale {
                    self.stopCameraPreview()
                    self.cameraError = "Video stopped arriving. Check Developer Mode and camera permission in Meta AI, then retry."
                    return
                }
            }
        }
        device.startCameraPreview()
    }

    public func stopCameraPreview() {
        previewID = UUID()
        isPreviewOpen = false
        previewStarted = false
        lastFrameAt = nil
        previewTimeout?.cancel(); previewTimeout = nil
        cancelPhotoCapture()
        device?.onCameraFrame = nil
        device?.onCameraPhoto = nil
        device?.onCameraError = nil
        device?.stopCameraPreview()
        previewFrame = nil
        cameraPhoto = nil
    }

    private func publishPhoto(_ data: Data) {
        guard !data.isEmpty else { return }
        cameraPhoto = data
        cameraPhotoID = UUID()
    }

    private func finishPhoto(id: UUID, result: Result<Data, GlassesError>) {
        guard photoRequestID == id else { return }
        photoTimeout?.cancel(); photoTimeout = nil
        let completion = photoCompletion
        photoCompletion = nil; photoRequestID = nil; isCapturingPhoto = false
        if case .success(let data) = result, data.isEmpty { completion?(.failure(.captureFailed)) }
        else {
            if case .success(let data) = result, isPreviewOpen { publishPhoto(data) }
            completion?(result)
        }
    }

    private func mirror(_ device: GlassesDevice) {
        connectionState = device.connectionState
        wearState = device.wearState
        deviceName = device.name
        capabilities = device.capabilities
        connectionError = device.connectionError
        connectionDetails = device.connectionDetails
        if connectionState != .connecting { connectionTimeout?.cancel(); connectionTimeout = nil }
        if connectionState == .connected { beginPreview() }
        else {
            cancelPhotoCapture()
            if previewStarted {
                stopCameraPreview()
                cameraError = "Glasses disconnected. Reopen the camera to reconnect."
            }
        }
    }
}
