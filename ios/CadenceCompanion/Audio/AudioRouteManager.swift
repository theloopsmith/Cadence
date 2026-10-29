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
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        #if targetEnvironment(simulator)
        try? session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker])
        try? session.setActive(true)
        #else
        do {
            let mode: AVAudioSession.Mode = preferVoiceChat ? .voiceChat : .default
            var options: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP]
            #if swift(>=5.9)
            options.insert(.allowBluetoothHFP)
            #endif

            try session.setCategory(.playAndRecord, mode: mode, options: options)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            routeToGlassesIfAvailable()
        } catch {
            print("[AudioRouteManager] Failed to configure audio session: \(error)")
        }
        #endif
        #endif
    }

    /// Automatically sets the connected Bluetooth glasses (HFP/LE) as the preferred audio input.
    public func routeToGlassesIfAvailable() {
        #if os(iOS) && !targetEnvironment(simulator)
        let session = AVAudioSession.sharedInstance()
        let available = session.availableInputs ?? []

        // Prioritize Bluetooth HFP or Bluetooth LE ports (Meta / Ray-Ban glasses)
        if let glassesInput = available.first(where: {
            $0.portType == .bluetoothHFP ||
            $0.portType == .bluetoothLE ||
            $0.portName.localizedCaseInsensitiveContains("Ray-Ban") ||
            $0.portName.localizedCaseInsensitiveContains("Meta")
        }) {
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
        if let current = session.currentRoute.inputs.first {
            let isGlasses = current.portType == .bluetoothHFP ||
                            current.portType == .bluetoothLE ||
                            current.portName.localizedCaseInsensitiveContains("Ray-Ban") ||
                            current.portName.localizedCaseInsensitiveContains("Meta")
            DispatchQueue.main.async {
                self.activeInputName = current.portName
                self.isGlassesMicActive = isGlasses
            }
        }
        #endif
    }
}
