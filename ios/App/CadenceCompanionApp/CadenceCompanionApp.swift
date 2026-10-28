import CadenceCompanion
import SwiftUI

@main
struct CadenceCompanionApp: App {
    init() {
        // Initializes launch-configured .playAndRecord AVAudioSession once at startup
        _ = AudioCueEngine.shared
    }

    var body: some Scene {
        WindowGroup {
            CadenceRootView()
        }
    }
}
