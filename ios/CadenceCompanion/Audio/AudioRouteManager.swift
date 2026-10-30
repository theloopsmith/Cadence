import Combine
import Foundation
#if os(iOS)
import AVFoundation
#endif

/// Coordinates audio routing between iPhone and Meta Gen 3 AI Glasses.
/// Ensures that when Bluetooth glasses are connected, the glasses' microphone
/// is selected as the preferred audio input port rather than the iPhone's microphone.
public final class AudioRouteManager: ObservableObject {
    public static let shared = AudioRouteManager()

    @Published public private(set) var activeInputName: String = "iPhone"
    @Published public private(set) var isGlassesMicActive: Bool = false

    @Published public private(set) var activeOutputName: String = "No audio output"

    public static func isGlassesName(_ name: String) -> Bool {
        name.localizedCaseInsensitiveContains("Ray-Ban") || name.localizedCaseInsensitiveContains("RayBan") || name.localizedCaseInsensitiveContains("Meta")
    }

    private init() {
        #if os(iOS)
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.routeToGlassesIfAvailable()
        }
        #endif
    }

    /// Prepares AVAudioSession with .playAndRecord and two-way Bluetooth support,
    /// explicitly using .voiceChat mode so iOS does not disable Bluetooth microphones.
    public func configureAudioSession(preferVoiceChat: Bool = true) {
        AudioCueEngine.shared.configureLaunchAudioSession(preferVoiceChat: preferVoiceChat)
    }

    /// Automatically sets the connected Bluetooth glasses (HFP/LE) as the preferred audio input.
    public func routeToGlassesIfAvailable() {
        #if os(iOS) && !targetEnvironment(simulator)
        let session = AVAudioSession.sharedInstance()
        let available = session.availableInputs ?? []

        // Ordinary Bluetooth earphones must not be classified or selected as glasses.
        if let glassesInput = available.first(where: {
            Self.isGlassesName($0.portName)
        }), session.preferredInput?.uid != glassesInput.uid {
            do {
                try session.setPreferredInput(glassesInput)
                print("[AudioRouteManager] Selected glasses microphone: \(glassesInput.portName)")
            } catch {
                print("[AudioRouteManager] setPreferredInput failed: \(error)")
            }
        }

        updateCurrentInput()
        #endif
    }

    /// Queries the currently active input port on the hardware route.
    public func updateCurrentInput() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        let current = session.currentRoute.inputs.first
        let output = session.currentRoute.outputs.map(\.portName).joined(separator: ", ")
        self.activeInputName = current?.portName ?? "No microphone"
        self.isGlassesMicActive = current.map { Self.isGlassesName($0.portName) } ?? false
        self.activeOutputName = output.isEmpty ? "No audio output" : output
        #endif
    }
}
