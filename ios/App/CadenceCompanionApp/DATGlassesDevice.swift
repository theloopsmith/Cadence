import CadenceCompanion
import Foundation
import UIKit

#if canImport(MWDATCore) && canImport(MWDATMotion) && canImport(MWDATCamera)
import MWDATCamera
import MWDATCore
import MWDATMotion
import MWDATInputs

/// Ray-Ban Meta glasses through the Meta Wearables Device Access Toolkit 1.0.
///
/// Conforms to `GlassesDevice`, so everything downstream (motion → detectors,
/// wear state → fall check-in, camera → environment check) is the code that
/// already runs against the mock. Lives in the app target because the toolkit
/// is iOS-only and the companion package also builds on macOS for tests.
///
/// Capability notes from the 1.0 documentation:
/// - Motion and standalone Photo are **development and beta channel only**.
/// - Motion streams at 5–60 Hz; this adapter asks for 60 Hz.
/// - Haptics are not exposed by the toolkit; `capabilities.haptics` is false.
/// - The SDK uses ExternalAccessory, so distribution is through release
///   channels, not the App Store.
public final class DATGlassesDevice: GlassesDevice {
    public let name: String
    public private(set) var connectionState: GlassesConnectionState = .disconnected
    public private(set) var wearState: GlassesWearState = .unknown
    public private(set) var capabilities = GlassesCapabilities(
        imu: true, microphone: true, camera: true, audioOutput: true, imuSampleRateHz: 60, haptics: false
    )
    public var onStateChange: ((GlassesDevice) -> Void)?
    public var motion: CadenceCompanion.MotionSource { motionSource }

    /// Why the last connect attempt failed, for the Settings screen.
    public private(set) var lastError: String?
    public var connectionError: String? { lastError }
    public private(set) var connectionDetails: String?
    private var errorTask: Task<Void, Never>?
    private var discoveryTask: Task<Void, Never>?
    private var selector: (any DeviceSelector)?

    private var captureTask: Task<Void, Never>?
    private var captureCompletion: ((Result<Data, GlassesError>) -> Void)?
    private var captureID: UUID?
    private var sessionGeneration = UUID()

    private let wearables = Wearables.shared
    private var session: DeviceSession?
    private var sessionTask: Task<Void, Never>?
    private var deviceStateToken: (any AnyListenerToken)?
    private let motionSource: DATMotionSource
    private let activeCaptureTokens = ListenerTokenBag()
    private var activeCamera: Camera?
    public var onCameraFrame: ((Data) -> Void)?
    public var onCameraPhoto: ((Data) -> Void)?
    public var onCameraError: ((String) -> Void)?
    private var previewTask: Task<Void, Never>?
    private var inputTask: Task<Void, Never>?
    private var previewGeneration = UUID()
    private var previewActive = false
    private var lastPreviewAt = Date.distantPast
    private let previewTokens = ListenerTokenBag()


    public init(name: String = "Ray-Ban Meta") {
        self.name = name
        self.motionSource = DATMotionSource()
    }

    // MARK: - Connection

    public func connect() {
        guard connectionState != .connected, connectionState != .connecting else { return }
        if session != nil { disconnect() }
        setConnection(.connecting)
        sessionTask?.cancel()
        discoveryTask?.cancel(); discoveryTask = nil
        errorTask?.cancel(); errorTask = nil
        sessionGeneration = UUID()
        let generation = sessionGeneration
        lastError = nil
        connectionDetails = "Waiting for Meta device discovery…"
        notify()
        sessionTask = Task { @MainActor [weak self] in
            await self?.openSession(generation: generation)
        }
    }

    public func disconnect() {
        sessionGeneration = UUID()
        stopCameraPreview()
        cancelPhotoCapture()
        sessionTask?.cancel()
        sessionTask = nil
        errorTask?.cancel(); errorTask = nil
        discoveryTask?.cancel(); discoveryTask = nil
        selector = nil
        motionSource.stop()
        if let token = deviceStateToken {
            Task { await token.cancel() }
            deviceStateToken = nil
        }
        session?.stop()
        session = nil
        motionSource.bind(session: nil)
        setWear(.unknown)
        setConnection(.disconnected)
    }

    @MainActor
    private func openSession(generation: UUID) async {
        do {
            // Registration is a one-time hand-off to the Meta AI app.
            if !isRegistered() {
                let registration = wearables.registrationStateStream()
                try await wearables.startRegistration()
                for await state in registration {
                    guard !Task.isCancelled, sessionGeneration == generation else { return }
                    if state == .registered { break }
                }
            }
            guard !Task.isCancelled, sessionGeneration == generation else { return }
            updateConnectionDetails()
            discoveryTask = Task { @MainActor [weak self] in
                guard let self else { return }
                for await _ in wearables.devicesStream() {
                    guard !Task.isCancelled, sessionGeneration == generation else { return }
                    updateConnectionDetails()
                }
            }
            // AutoDeviceSelector populates asynchronously. Creating a session
            // immediately can throw noEligibleDevice even for paired glasses.
            let discovery = AutoDeviceSelector(wearables: wearables)
            self.selector = discovery
            let selectedID = try await GlassesDeviceReadiness.waitForDevice(
                current: discovery.activeDevice, updates: discovery.activeDeviceStream()
            )
            guard !Task.isCancelled, sessionGeneration == generation else { return }
            let selected = SpecificDeviceSelector(device: selectedID)
            self.selector = selected
            let session = try wearables.createSession(deviceSelector: selected)
            self.session = session
            let states = session.stateStream()
            let errors = session.errorStream()
            errorTask = Task { @MainActor [weak self] in
                for await error in errors {
                    guard let self, !Task.isCancelled, self.sessionGeneration == generation else { return }
                    self.lastError = self.describeConnectionError(error)
                    self.updateConnectionDetails()
                    self.stopCameraPreview()
                    self.motionSource.bind(session: nil)
                    self.setConnection(.disconnected)
                    session.stop()
                    return
                }
            }
            try session.start()

            for await state in states {
                if Task.isCancelled || sessionGeneration != generation { return }
                switch state {
                case .started:
                    updateConnectionDetails()
                    motionSource.bind(session: session)
                    observeDeviceState(session.device)
                    await MainActor.run {
                        self.setConnection(.connected)
                        AudioRouteManager.shared.routeToGlassesIfAvailable()
                    }
                case .paused:
                    stopCameraPreview()
                    cancelPhotoCapture()
                    motionSource.bind(session: nil)
                    setConnection(.disconnected)
                case .stopped:
                    stopCameraPreview()
                    cancelPhotoCapture()
                    await MainActor.run {
                        self.motionSource.bind(session: nil)
                        self.setWear(.unknown)
                        self.setConnection(.disconnected)
                    }
                    return
                default:
                    break
                }
            }
        } catch {
            guard sessionGeneration == generation, !Task.isCancelled else { return }
            await MainActor.run {
                self.lastError = self.describeConnectionError(error)
                self.updateConnectionDetails()
                self.setConnection(.disconnected)
            }
        }
    }

    private func updateConnectionDetails() {
        let devices = wearables.devices.compactMap { wearables.deviceForIdentifier($0) }
        let status = devices.map { device in
            "\(device.nameOrId()): \(device.linkState), \(device.compatibility().displayString)"
        }.joined(separator: "; ")
        connectionDetails = "Meta app registration: \(isRegistered() ? "ready" : "not ready"). Devices visible to Cadence: \(devices.count)." + (status.isEmpty ? "" : " " + status)
        notify()
    }

    private func describeConnectionError(_ error: Error) -> String {
        if let sdkError = error as? DeviceSessionError {
            switch sdkError {
            case .noEligibleDevice:
                return "Meta has not made an eligible device available to Cadence. Bluetooth pairing alone is not enough. Check Cadence's app connection and Developer Mode in Meta AI, keep the glasses worn and unfolded, then retry."
            case .datAppOnTheGlassesUpdateRequired:
                return "The Meta developer app on your glasses needs an update. Update it in Meta AI, then retry Cadence."
            case .insufficientSDKVersion:
                return "The glasses require a newer Meta SDK. Install an updated Cadence build."
            default: break
            }
        }
        return (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }

    private func isRegistered() -> Bool {
        return wearables.registrationState == .registered
    }

    /// `donState` is device metadata, delivered before and during a session.
    private func observeDeviceState(_ device: Device?) {
        guard let device else { return }
        let generation = sessionGeneration
        deviceStateToken = device.addDeviceStateListener { [weak self] state in
            let worn: GlassesWearState
            switch state.donState {
            case .donned: worn = .worn
            case .doffed: worn = .notWorn
            default: worn = .unknown
            }
            Task { @MainActor in
                guard self?.sessionGeneration == generation else { return }
                self?.setWear(worn)
                self?.updateConnectionDetails()
            }
        }
    }

    private func setConnection(_ state: GlassesConnectionState) {
        connectionState = state
        notify()
    }

    private func setWear(_ state: GlassesWearState) {
        guard wearState != state else { return }
        wearState = state
        notify()
    }

    private func notify() {
        if Thread.isMainThread {
            onStateChange?(self)
        } else {
            DispatchQueue.main.async { self.onStateChange?(self) }
        }
    }

    // MARK: - Camera

    public func startCameraPreview() {
        stopCameraPreview()
        guard connectionState == .connected, let session else {
            onCameraError?("Connect your Meta glasses first."); return
        }
        previewActive = true
        let id = previewGeneration
        previewTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                var status = try await wearables.checkPermissionStatus(.camera)
                if status != .granted { status = try await wearables.requestPermission(.camera) }
                guard !Task.isCancelled, previewGeneration == id else { return }
                guard status == .granted else { onCameraError?(GlassesError.cameraUnavailable.localizedDescription); return }
                guard let camera = try session.addCamera(config: StreamConfiguration(videoCodec: .raw, resolution: .medium, frameRate: 15)) else {
                    onCameraError?("Glasses camera could not start."); return
                }
                activeCamera = camera
                camera.stream.videoFramePublisher.listen { [weak self] frame in
                    Task { @MainActor in
                        guard let self, self.previewGeneration == id, self.previewActive else { return }
                        // Bound image conversions and SwiftUI updates to ten per second.
                        let now = Date()
                        guard now.timeIntervalSince(self.lastPreviewAt) >= 0.1 else { return }
                        self.lastPreviewAt = now
                        if let jpeg = frame.makeUIImage()?.jpegData(compressionQuality: 0.65) { self.onCameraFrame?(jpeg) }
                    }
                }.store(in: previewTokens)
                camera.stream.photoDataPublisher.listen { [weak self] capture in
                    Task { @MainActor in
                        guard let self, self.previewGeneration == id, self.previewActive else { return }
                        guard let jpeg = UIImage(data: capture.data)?.jpegData(compressionQuality: 0.85) else {
                            self.finishCapture(.failure(.captureFailed)); return
                        }
                        if self.captureCompletion != nil { self.finishCapture(.success(jpeg)) }
                        else { self.onCameraPhoto?(jpeg) }
                    }
                }.store(in: previewTokens)
                camera.stream.errorPublisher.listen { [weak self] error in
                    Task { @MainActor in
                        guard let self, self.previewGeneration == id else { return }
                        self.onCameraError?(error.localizedDescription)
                        self.finishCapture(.failure(.captureFailed))
                    }
                }.store(in: previewTokens)
                camera.stream.statePublisher.listen { [weak self] state in
                    Task { @MainActor in
                        guard let self, self.previewGeneration == id else { return }
                        if state == .paused || state == .stopped {
                            self.onCameraError?("Glasses video paused. Check that the glasses are worn and unfolded, then retry.")
                        }
                    }
                }.store(in: previewTokens)
                camera.stream.start()
                // Inputs are optional on some glasses/release channels. The phone shutter remains available.
                if let inputs = try? session.addInputs(configuration: InputsConfiguration(sources: [.captureButton])) {
                    inputTask = Task { @MainActor [weak self] in
                        for await event in inputs.events {
                            guard let self, !Task.isCancelled, self.previewGeneration == id else { return }
                            if case .capture(.shortPress, _, _) = event {
                                self.captureFrame { [weak self] result in
                                    switch result {
                                    case .success(let jpeg): self?.onCameraPhoto?(jpeg)
                                    case .failure(let error): self?.onCameraError?(error.localizedDescription)
                                    }
                                }
                            }
                        }
                    }
                }
            } catch {
                guard !Task.isCancelled, previewGeneration == id else { return }
                onCameraError?(error.localizedDescription)
            }
        }
    }

    public func stopCameraPreview() {
        previewGeneration = UUID()
        previewTask?.cancel(); previewTask = nil
        inputTask?.cancel(); inputTask = nil
        if previewActive {
            cancelPhotoCapture()
            activeCamera?.stream.stop()
            activeCamera?.stop()
            activeCamera = nil
            try? session?.removeInputs()
        }
        previewActive = false
        previewTokens.clear()
    }

    /// One still from the glasses camera via the standalone Photo path.
    public func captureFrame(_ completion: @escaping (Result<Data, GlassesError>) -> Void) {
        guard connectionState == .connected, let session else {
            return completion(.failure(.notConnected))
        }
        guard captureCompletion == nil else { return completion(.failure(.captureInProgress)) }
        if previewActive {
            guard let stream = activeCamera?.stream, stream.state == .streaming else {
                completion(.failure(.cameraUnavailable)); return
            }
            captureCompletion = completion
            let id = UUID(); captureID = id
            guard stream.capturePhoto(format: .jpeg) else { finishCapture(.failure(.captureFailed)); return }
            captureTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { return }
                guard self?.captureID == id else { return }
                self?.finishCapture(.failure(.captureFailed))
            }
            return
        }
        captureCompletion = completion
        let id = UUID(); captureID = id
        let generation = sessionGeneration
        captureTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                var status = try await wearables.checkPermissionStatus(.camera)
                if status != .granted { status = try await wearables.requestPermission(.camera) }
                guard !Task.isCancelled, generation == sessionGeneration, captureID == id else { return }
                guard status == .granted else { return finishCapture(.failure(.cameraUnavailable)) }
                guard let camera = try session.addCamera(config: StreamConfiguration()) else {
                    return finishCapture(.failure(.cameraUnavailable))
                }
                activeCamera = camera
                let photo = camera.photo
                let trigger = OnceFlag()
                photo.photoDataPublisher.listen { [weak self] capture in
                    Task { @MainActor in
                        guard self?.captureID == id else { return }
                        guard let image = UIImage(data: capture.imageData), let jpeg = image.jpegData(compressionQuality: 0.85) else {
                            self?.finishCapture(.failure(.captureFailed))
                            return
                        }
                        self?.finishCapture(.success(jpeg))
                    }
                }.store(in: activeCaptureTokens)
                photo.errorPublisher.listen { [weak self] _ in
                    Task { @MainActor in
                        guard self?.captureID == id else { return }
                        self?.finishCapture(.failure(.captureFailed))
                    }
                }.store(in: activeCaptureTokens)
                photo.statePublisher.listen { [weak self] state in
                    Task { @MainActor in
                        guard self?.captureID == id, state == .started, trigger.claim() else { return }
                        photo.capturePhoto(resolution: .medium, quality: .medium)
                    }
                }.store(in: activeCaptureTokens)
                photo.start()
                do { try await Task.sleep(nanoseconds: 15_000_000_000) }
                catch { return }
                if captureID == id { finishCapture(.failure(.captureFailed)) }
            } catch {
                guard !Task.isCancelled, generation == sessionGeneration, captureID == id else { return }
                finishCapture(.failure(.captureFailed))
            }
        }
    }

    public func cancelPhotoCapture() { finishCapture(.failure(.captureFailed)) }

    private func finishCapture(_ result: Result<Data, GlassesError>) {
        guard let completion = captureCompletion else { return }
        captureCompletion = nil
        captureID = nil
        captureTask?.cancel(); captureTask = nil
        if !previewActive {
            activeCamera?.photo.stop()
            activeCamera?.stop()
            activeCaptureTokens.clear()
            activeCamera = nil
        }
        completion(result)
    }

    public func playHaptic(_ pattern: HapticPattern) {
        // The toolkit exposes no haptic capability; `capabilities.haptics` is false
        // so the router sends these to the phone.
    }
}

/// First caller wins; later callers see false. Safe across the SDK's
/// `@Sendable` listener closures.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

/// Glasses IMU → `IMUSample`, through the same gravity-aligned conversion the
/// phone uses. The toolkit gives total acceleration in m/s² (gravity included)
/// and angular rate in rad/s as `Float`; gravity is separated here with a
/// short low-pass so the detectors see the fields they were calibrated on.
final class DATMotionSource: CadenceCompanion.MotionSource, @unchecked Sendable {
    private(set) var isActive = false
    private weak var session: DeviceSession?
    private var motion: Motion?
    private var sampleTask: Task<Void, Never>?
    private var gravity: (Double, Double, Double)?

    var isAvailable: Bool { session != nil }

    func bind(session: DeviceSession?) {
        self.session = session
        if session == nil { stop() }
    }

    func start(_ onSample: @escaping (IMUSample) -> Void) {
        guard !isActive, let session else { return }
        do {
            guard let motion = try session.addMotion(
                configuration: MotionConfiguration(samplingRate: .hz60)
            ) else { return }
            self.motion = motion
            isActive = true
            gravity = nil
            let samples = motion.samples
            // IMUSample is a plain value; hand it across as its fields.
            let deliver: @Sendable (Double, Double, Double, Double, Double, Double, Double, Double, Double) -> Void = {
                t, ax, ay, az, gx, gy, gz, pitch, roll in
                let imu = IMUSample(
                    timestamp: t, ax: ax, ay: ay, az: az, gx: gx, gy: gy, gz: gz,
                    pitchDeg: pitch, rollDeg: roll
                )
                onSample(imu)
            }
            sampleTask = Task { [weak self] in
                for await sample in samples {
                    guard let self, !Task.isCancelled else { return }
                    if let imu = self.convert(sample) {
                        let (t, ax, ay, az, gx, gy, gz, p, r) = (
                            imu.timestamp, imu.ax, imu.ay, imu.az, imu.gx, imu.gy, imu.gz, imu.pitchDeg, imu.rollDeg
                        )
                        DispatchQueue.main.async { deliver(t, ax, ay, az, gx, gy, gz, p, r) }
                    }
                }
            }
            motion.start()
        } catch {
            isActive = false
        }
    }

    func stop() {
        sampleTask?.cancel()
        sampleTask = nil
        motion?.stop()
        try? session?.removeMotion()
        motion = nil
        isActive = false
    }

    private func convert(_ sample: MotionSample) -> IMUSample? {
        guard let a = sample.accelerometer else { return nil }
        let g0 = 9.80665
        let total = (Double(a.x) / g0, Double(a.y) / g0, Double(a.z) / g0)
        // Low-pass gravity estimate, ~0.5 s time constant at 60 Hz.
        let alpha = 0.033
        if let g = gravity {
            gravity = (
                g.0 + alpha * (total.0 - g.0),
                g.1 + alpha * (total.1 - g.1),
                g.2 + alpha * (total.2 - g.2)
            )
        } else {
            gravity = total
        }
        let g = gravity!
        let user = (total.0 - g.0, total.1 - g.1, total.2 - g.2)
        let rate: (Double, Double, Double) = sample.gyroscope
            .map { (Double($0.x), Double($0.y), Double($0.z)) } ?? (0, 0, 0)

        let (pitch, roll): (Double, Double)
        if let q = sample.orientation {
            // Standard aerospace sequence; the glasses' body axes are a
            // hardware-spike item, see README.
            let (qx, qy, qz, qw) = (Double(q.x), Double(q.y), Double(q.z), Double(q.w))
            let sinp = 2 * (qw * qy - qz * qx)
            pitch = abs(sinp) >= 1 ? (sinp > 0 ? .pi / 2 : -.pi / 2) : asin(sinp)
            roll = atan2(2 * (qw * qx + qy * qz), 1 - 2 * (qx * qx + qy * qy))
        } else {
            // Tilt of the gravity vector from the vertical axis.
            let mag = max(1e-6, sqrt(g.0 * g.0 + g.1 * g.1 + g.2 * g.2))
            pitch = asin(max(-1, min(1, -g.0 / mag)))
            roll = atan2(g.2, g.1)
        }

        return PhoneMotionReading(
            timestamp: Double(sample.timestampNs) / 1_000_000_000,
            userAccelerationG: user,
            gravityG: g,
            rotationRateRadPerSec: rate,
            pitchRad: pitch,
            rollRad: roll
        ).makeIMUSample()
    }
}
#endif
