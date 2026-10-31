import SwiftUI

struct VoiceCompanionBar: View {
    @ObservedObject var app: CadenceAppModel
    @ObservedObject private var voice: VoiceCompanion

    init(app: CadenceAppModel) { self.app = app; self.voice = app.companion }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: voice.isEnabled ? "mic.fill" : "mic.slash")
                Text(voice.status).font(.subheadline.weight(.semibold))
                Spacer()
                Button(voice.isEnabled ? "Turn voice off" : "Talk to Cadence") {
                    if voice.isEnabled { voice.stop() }
                    else { Task { await app.enableVoiceCompanion() } }
                }
                .buttonStyle(.bordered)
                .disabled(app.isHandingOffToMeta)
            }
            Button(app.isUsingMetaAssistant ? "Glasses released to Hey Meta" : "Use Hey Meta instead") {
                Task { await app.useMetaAssistant() }
            }
            .disabled(app.fallAlert.isAlertVisible || app.isUsingMetaAssistant || app.isHandingOffToMeta)
            if app.isHandingOffToMeta {
                Text("Releasing the glasses microphone…").font(.caption)
            } else if app.isUsingMetaAssistant {
                Text("Cadence camera and voice are paused. Walking audio is unavailable until you return to Cadence.").font(.caption)
            }
            if let error = app.metaHandoffError { Text(error).font(.footnote).foregroundColor(CadenceTheme.caution) }
            if voice.isEnabled {
                Text(voice.lastReply.isEmpty ? "Tell me what you need help with." : voice.lastReply)
                    .font(.footnote).lineLimit(4)
                Text("Microphone: \(AudioRouteManager.shared.activeInputName). Cadence is using the microphone. Use Hey Meta instead to release it.")
                    .font(.caption).foregroundColor(.secondary)
            }
            if let error = app.voicePermissionError { Text(error).font(.footnote).foregroundColor(CadenceTheme.caution) }
        }
        .padding(10)
        .background(CadenceTheme.background)
    }
}
