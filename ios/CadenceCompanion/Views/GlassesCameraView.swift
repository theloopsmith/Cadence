import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Shared, foreground-only camera for pill references and photo checks.
struct GlassesCameraView: View {
    @ObservedObject var glasses: GlassesSessionManager
    @ObservedObject var voice: VoiceCompanion
    var captureWhenReady = false
    var title = "Glasses camera"
    var onUsePhoto: ((Data) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var attemptedAutomaticCapture = false
    @State private var voiceFlowID = UUID()
    @State private var captured: Data?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                #if canImport(UIKit)
                if let data = captured ?? glasses.previewFrame, let image = UIImage(data: data) {
                    Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: .infinity)
                        .accessibilityLabel(captured == nil ? "Live glasses video" : "Captured glasses photo")
                } else {
                    Spacer()
                    Image(systemName: "eyeglasses").font(.largeTitle)
                    Text(glasses.connectionState == .connecting ? "Connecting to glasses…" : "Waiting for glasses video…")
                    Spacer()
                }
                #else
                Text("Glasses video is available in the iPhone app.")
                #endif
                if let details = glasses.connectionDetails { Text(details).font(.caption).foregroundColor(.secondary) }
                if let message = error ?? glasses.cameraError ?? glasses.connectionError {
                    Text(message).foregroundColor(CadenceTheme.caution)
                    Button("Retry camera") { captured = nil; error = nil; glasses.startCameraPreview() }
                }
                if glasses.device is MockGlassesDevice {
                    Text("Mock image — this is not live glasses video.").font(.footnote)
                }
                if let captured {
                    Button(onUsePhoto == nil ? "Done" : "Use this photo") {
                        glasses.stopCameraPreview()
                        onUsePhoto?(captured)
                        dismiss()
                    }.buttonStyle(.borderedProminent)
                    Button("Retake") { self.captured = nil; error = nil }
                } else {
                    Text("Look through your glasses. Tap Capture here, or press the glasses shutter if supported. Photos taken outside this camera session are not imported automatically.")
                        .font(.footnote).foregroundColor(.secondary)
                    Button(glasses.isCapturingPhoto ? "Capturing…" : "Capture photo") {
                        error = nil
                        glasses.capturePhoto { result in
                            if case .failure(let failure) = result { error = failure.localizedDescription }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(glasses.previewFrame == nil || glasses.isCapturingPhoto || glasses.cameraError != nil)
                }
            }
            .padding()
            .navigationTitle(title)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .onAppear {
                voice.enterFlow(id: voiceFlowID, destination: .camera, step: captured == nil ? .cameraPreview : .photoReview)
                glasses.startCameraPreview()
            }
            .onDisappear { glasses.stopCameraPreview(); voice.leaveFlow(id: voiceFlowID) }
            .onChange(of: voice.actionID) { _ in
                guard voice.context == .camera else { return }
                switch voice.action {
                case .capture, .start:
                    glasses.capturePhoto { result in
                        if case .failure(let failure) = result { error = failure.localizedDescription; voice.say(failure.localizedDescription) }
                    }
                case .usePhoto, .finish:
                    guard let captured else { voice.say("Take a photo first. Say capture when you're ready."); return }
                    glasses.stopCameraPreview(); onUsePhoto?(captured); dismiss()
                case .retry: captured = nil; error = nil; glasses.startCameraPreview()
                case .retake: captured = nil; error = nil; voice.say("Let's try another photo. Say capture when you're ready.")
                case .cancel: dismiss()
                default: break
                }
            }
            .onChange(of: glasses.previewFrame) { frame in
                if captureWhenReady, !attemptedAutomaticCapture, frame != nil, captured == nil {
                    attemptedAutomaticCapture = true
                    glasses.capturePhoto { result in
                        if case .failure(let failure) = result { error = failure.localizedDescription; voice.say(failure.localizedDescription) }
                    }
                }
            }
            .onChange(of: captured) { data in
                voice.updateFlow(id: voiceFlowID, step: data == nil ? .cameraPreview : .photoReview)
            }
            .onChange(of: glasses.cameraPhotoID) { _ in
                captured = glasses.cameraPhoto
                if captured != nil { voice.say("I've got the photo. Say use this photo, or retake.") }
            }
            .onChange(of: glasses.cameraError) { message in if let message { voice.say(message) } }
            .onChange(of: scenePhase) { phase in
                if phase != .active { glasses.stopCameraPreview() }
                else if captured == nil { glasses.startCameraPreview() }
            }
        }
    }
}
