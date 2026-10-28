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

    public private(set) var device: GlassesDevice?
    private let phoneMotion: MotionSource

    public init(phoneMotion: MotionSource) {
        self.phoneMotion = phoneMotion
    }

    /// Attaches a device and mirrors its state. Replaces any previous device.
    public func attach(_ device: GlassesDevice) {
        self.device?.onStateChange = nil
        self.device?.disconnect()
        self.device = device
        device.onStateChange = { [weak self] device in
            guard let self else { return }
            if Thread.isMainThread {
                self.mirror(device)
            } else {
                DispatchQueue.main.async { self.mirror(device) }
            }
        }
        mirror(device)
    }

    public func detach() {
        device?.onStateChange = nil
        device?.disconnect()
        device = nil
        connectionState = .notPaired
        wearState = .unknown
        deviceName = nil
        capabilities = nil
    }

    public func connect() {
        device?.connect()
    }

    public func disconnect() {
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

    private func mirror(_ device: GlassesDevice) {
        connectionState = device.connectionState
        wearState = device.wearState
        deviceName = device.name
        capabilities = device.capabilities
    }
}
