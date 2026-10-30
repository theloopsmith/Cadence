import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Focused user settings: Voice selection and About information.
struct SettingsView: View {
    @ObservedObject var app: CadenceAppModel
    @ObservedObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var username = ""
    @State private var password = ""
    @State private var server = ""
    @State private var confirmReset = false

    init(app: CadenceAppModel) {
        self.app = app
        self.settings = app.settings
    }

    var body: some View {
        NavigationStack {
            Form {
                accountSection
                voiceSection
                aboutSection
            }
            .onAppear { server = settings.backendBaseURL }
            .onDisappear { password = "" }
            .confirmationDialog("Erase this phone's local profile?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Erase local profile and queued uploads", role: .destructive) { _ = app.resetLocalProfile() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Removes this profile's diary, measurements, recordings, pill photo, setup and pending uploads on the next launch. Server records remain. Close and reopen Cadence to set up another wearer.")
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

    private var accountSection: some View {
        Section {
            Text("One wearer per installation")
            if settings.profile.isBound {
                Text(settings.api.baseURL).font(.footnote)
            } else {
                TextField("Server address", text: $server)
                    .autocorrectionDisabled()
                Button("Use server address") { settings.backendBaseURL = server }
            }
            if app.auth.isSignedIn {
                Text("Signed in as \(app.auth.username ?? "")")
                Button("Sign out") { app.auth.signOut() }
            } else {
                TextField("Phone account username", text: $username).autocorrectionDisabled()
                SecureField("Password", text: $password)
                Button(app.auth.isWorking ? "Signing in…" : "Sign in") {
                    Task {
                        await app.auth.signIn(username: username, password: password)
                        password = ""
                    }
                }.disabled(app.auth.isWorking)
            }
            if let notice = settings.profileNotice { Text(notice).foregroundColor(CadenceTheme.caution) }
            if let error = app.auth.errorMessage { Text(error).foregroundColor(CadenceTheme.caution) }
            if let error = app.profileResetError { Text(error).foregroundColor(CadenceTheme.caution) }
            Button("Erase local profile for a new wearer", role: .destructive) { confirmReset = true }
        } header: { Text("Account and local history") }
        footer: { Text("Signing out pauses uploads and keeps this wearer's offline history. A different account or server requires a local reset. Earlier unassigned files are kept separate and are never adopted into this profile.") }
    }

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
