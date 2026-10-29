import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Focused user settings: Voice selection and About information.
struct SettingsView: View {
    @ObservedObject var app: CadenceAppModel
    @ObservedObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    init(app: CadenceAppModel) {
        self.app = app
        self.settings = app.settings
    }

    var body: some View {
        NavigationStack {
            Form {
                voiceSection
                aboutSection
            }
            .navigationTitle("Settings")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: - Voice

    private var voiceSection: some View {
        let installed = VoiceCandidate.installed
        let choices = Array(VoiceSelection.choices(from: installed).prefix(8))
        let current = VoiceSelection.best(from: installed, preferred: settings.preferredVoiceIdentifier)
        return Section {
            ForEach(choices) { voice in
                Button {
                    settings.preferredVoiceIdentifier = voice.identifier
                    AudioCueEngine.shared.speakSample(voiceIdentifier: voice.identifier)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(voice.name).foregroundColor(.primary)
                            Text("\(voice.quality.word) · \(voice.language)")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        if voice.identifier == current?.identifier {
                            Image(systemName: "checkmark").foregroundColor(CadenceTheme.accent)
                        }
                    }
                }
                .frame(minHeight: CadenceTheme.minimumTapHeight)
                .accessibilityAddTraits(voice.identifier == current?.identifier ? .isSelected : [])
            }
            if VoiceSelection.betterVoiceAvailableToDownload(installed: installed) {
                InlineNotice(
                    text: "For a more natural voice, download one for free: Settings, Accessibility, Spoken Content, Voices, English. Pick one marked Enhanced or Premium, then choose it here.",
                    color: CadenceTheme.accent,
                    systemName: "arrow.down.circle.fill"
                )
            }
        } header: {
            Text("Voice & Audio Cues")
        } footer: {
            Text("Tap a voice to test it. Cadence uses this voice for rhythmic gait prompts, fall safety check-ins, and reminders.")
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("Cadence is a daily-living companion, not a medical device.")
                    .font(.subheadline.weight(.semibold))
                Text("It does not judge how you are doing and never suggests changes to medication. The diary is there to share with your care team.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)
        } header: {
            Text("About")
        }
    }
}
