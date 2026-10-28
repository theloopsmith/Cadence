import CadenceCompanion
import SwiftUI

#if canImport(MWDATCore)
import MWDATCore
#endif

@main
struct CadenceCompanionApp: App {
    init() {
        // Initializes launch-configured .playAndRecord AVAudioSession once at startup
        _ = AudioCueEngine.shared
        #if canImport(MWDATCore)
        do {
            try Wearables.configure()
        } catch {
            // Without the toolkit the app still runs from the iPhone's sensors.
            print("Wearables SDK not configured: \(error)")
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            CadenceRootView(onReady: { app in
                #if canImport(MWDATCore) && canImport(MWDATMotion) && canImport(MWDATCamera)
                app.attachGlasses(DATGlassesDevice())
                #endif
            })
            .onOpenURL { url in
                #if canImport(MWDATCore)
                // The Meta AI app calls back here after registration.
                Task { _ = try? await Wearables.shared.handleUrl(url) }
                #else
                _ = url
                #endif
            }
        }
    }
}
