import SwiftUI

struct VoiceCompanionBar: View {
    @ObservedObject var app: CadenceAppModel
    @ObservedObject private var voice: VoiceCompanion

    var compact: Bool
    var showsSetupHint: Bool
    init(app: CadenceAppModel, showsSetupHint: Bool = true, compact: Bool = false) {
        self.app = app; self.voice = app.companion; self.showsSetupHint = showsSetupHint; self.compact = compact
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: voice.isEnabled ? "waveform" : "mic.slash")
                    .foregroundColor(CadenceTheme.accent)
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
                    .font(compact ? .body : .footnote).lineLimit(4)
                if !compact {
                    Text("Microphone: \(AudioRouteManager.shared.activeInputName). Say “let me use Meta” to switch to Hey Meta.")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            if let error = app.voicePermissionError { Text(error).font(.footnote).foregroundColor(CadenceTheme.caution) }
            if showsSetupHint, !voice.isEnabled, !app.settings.voiceCompanionEnabled, !app.isUsingMetaAssistant {
                Text("Enable Hands-free voice companion once in Cadence Settings to listen automatically when the app opens.").font(.caption)
            }
        }
        .padding(compact ? 0 : 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
