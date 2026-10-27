import SwiftUI

@main
public struct CadenceApp: App {
    public init() {
        // Initializes launch-configured .playAndRecord AVAudioSession once at startup
        _ = AudioCueEngine.shared
    }

    public var body: some Scene {
        WindowGroup {
            CompanionStatusView()
        }
    }
}
