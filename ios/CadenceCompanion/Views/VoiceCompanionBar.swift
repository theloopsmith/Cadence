import SwiftUI

struct VoiceCompanionBar: View {
    @ObservedObject var app: CadenceAppModel
    @ObservedObject private var voice: VoiceCompanion

    var showsSetupHint: Bool
    init(app: CadenceAppModel, showsSetupHint: Bool = true) {
        self.app = app; self.voice = app.companion; self.showsSetupHint = showsSetupHint
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: voice.isEnabled ? "mic.fill" : "mic.slash")
                Text(app.voiceStatusText).font(.subheadline.weight(.semibold))
            }
            if app.isHandingOffToMeta {
                Text("Releasing the glasses microphone…").font(.caption)
            } else if app.isUsingMetaAssistant {
                Text("Use Hey Meta normally. Say “Siri, open Cadence” to return. Cadence camera, voice and walking audio are paused.").font(.caption)
            }
            if let error = app.metaHandoffError { Text(error).font(.footnote).foregroundColor(CadenceTheme.caution) }
            if voice.isEnabled {
                Text(voice.lastReply.isEmpty ? "Tell me what you need help with." : voice.lastReply)
                    .font(.footnote).lineLimit(4)
                Text("Microphone: \(AudioRouteManager.shared.activeInputName). Say “let me use Meta” to switch to Hey Meta.")
                    .font(.caption).foregroundColor(.secondary)
            }
            if let error = app.voicePermissionError { Text(error).font(.footnote).foregroundColor(CadenceTheme.caution) }
            if showsSetupHint, !voice.isEnabled, !app.settings.voiceCompanionEnabled, !app.isUsingMetaAssistant {
                Text("Enable Hands-free voice companion once in Cadence Settings to listen automatically when the app opens.").font(.caption)
            }
        }
        .padding(10)
        .background(CadenceTheme.background)
    }
}
