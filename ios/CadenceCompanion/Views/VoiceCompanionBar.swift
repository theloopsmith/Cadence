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
            Button {
                if voice.isEnabled { voice.stop() }
                else { Task { await app.enableVoiceCompanion(persistPreference: false) } }
            } label: {
                Label(voice.isEnabled ? "Pause listening" : "Talk to Cadence",
                      systemImage: voice.isEnabled ? "pause.circle.fill" : "mic.circle.fill")
                    .frame(maxWidth: .infinity, minHeight: CadenceTheme.minimumTapHeight)
            }
            .buttonStyle(.bordered)
            .disabled(app.isStartingVoice || app.isHandingOffToMeta)
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
                Text("Tap Talk to Cadence when you need help. Hands-free listening is optional in Settings.").font(.caption)
            }
        }
        .padding(compact ? 0 : 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
