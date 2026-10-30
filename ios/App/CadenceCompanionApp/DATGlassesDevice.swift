import CadenceCompanion
import Foundation
import UIKit

#if canImport(MWDATCore) && canImport(MWDATMotion) && canImport(MWDATCamera)
import MWDATCamera
import MWDATCore
import MWDATMotion

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
        sessionGeneration = UUID()
        let generation = sessionGeneration
        lastError = nil
        sessionTask = Task { @MainActor [weak self] in
            await self?.openSession(generation: generation)
        }
    }

    public func disconnect() {
        sessionGeneration = UUID()
        cancelPhotoCapture()
        sessionTask?.cancel()
        sessionTask = nil
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
                try await wearables.startRegistration()
            }
            guard !Task.isCancelled, sessionGeneration == generation else { return }
            let selector = AutoDeviceSelector(wearables: wearables)
            let session = try wearables.createSession(deviceSelector: selector)
            self.session = session
            let states = session.stateStream()
            try session.start()

            for await state in states {
                if Task.isCancelled || sessionGeneration != generation { return }
                switch state {
                case .started:
                    motionSource.bind(session: session)
                    observeDeviceState(session.device)
                    await MainActor.run {
                        self.setConnection(.connected)
                        AudioRouteManager.shared.routeToGlassesIfAvailable()
                    }
                case .paused:
                    cancelPhotoCapture()
                    motionSource.bind(session: nil)
                    setConnection(.disconnected)
                case .stopped:
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
                self.lastError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                self.setConnection(.disconnected)
            }
        }
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

    /// One still from the glasses camera via the standalone Photo path.
    public func captureFrame(_ completion: @escaping (Result<Data, GlassesError>) -> Void) {
        guard connectionState == .connected, let session else {
            return completion(.failure(.notConnected))
        }
        guard captureCompletion == nil else { return completion(.failure(.captureInProgress)) }
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
        activeCamera?.photo.stop()
        activeCamera?.stop()
        activeCaptureTokens.clear()
        activeCamera = nil
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
