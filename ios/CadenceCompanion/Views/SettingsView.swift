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
    @State private var confirmServerRepair = false

    init(app: CadenceAppModel) {
        self.app = app
        self.settings = app.settings
    }

    var body: some View {
        NavigationStack {
            Form {
                accountSection
                glassesSection
                voiceSection
                aboutSection
            }
            .onAppear { server = settings.backendBaseURL }
            .onDisappear { password = "" }
            .confirmationDialog("Use this Mac development server?", isPresented: $confirmServerRepair, titleVisibility: .visible) {
                Button("Connect and preserve this phone's records") {
                    Task { await settings.connectServer(to: server, repairLocalhost: true) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This repairs the existing localhost connection. Queued records will be sent to the Mac address you entered. Existing records on the old server stay there. Use only your own Cadence server.")
            }
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
            TextField("Mac server address", text: $server)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                #endif
            if !settings.profile.isBound {
                Button("Use server address") { settings.backendBaseURL = server }
            } else {
                Button(settings.isConnecting ? "Connecting…" : "Connect to this Cadence server") {
                    if DeviceProfile.isLoopback(settings.api.baseURL), DeviceProfile.normalize(server) != settings.api.baseURL {
                        confirmServerRepair = true
                    } else { Task { await settings.connectServer(to: server) } }
                }.disabled(settings.isConnecting || app.fallAlert.isAlertVisible)
            }
            if DeviceProfile.isLoopback(settings.api.baseURL) {
                Text("On an iPhone, localhost points to the phone. Run scripts/run_phone_backend.py on your Mac and enter the .local address it prints. For an existing localhost profile, Connect repairs the address for the same Mac server without erasing your history.")
                    .font(.footnote)
            }
            if let message = settings.connectionMessage { Text(message).font(.footnote) }
            if app.auth.isSignedIn {
                Text("Signed in as \(app.auth.username ?? "")")
                Button("Sign out") { app.auth.signOut() }
            } else {
                TextField("Phone account username", text: $username).autocorrectionDisabled()
                SecureField("Password", text: $password)
                Button(app.auth.isWorking ? "Signing in…" : "Sign in") {
                    Task {
                        await app.auth.signIn(username: username, password: password, serverAddress: server)
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

    private var glassesSection: some View {
        Section {
            Text(app.glasses.deviceName ?? "Meta glasses")
            Text(app.glasses.canCapturePhoto ? "Connected — glasses camera ready" : "Glasses camera not connected")
            Button("Connect Meta glasses") { app.glasses.connect() }
                .disabled(app.glasses.connectionState == .connecting)
            if let error = app.glasses.connectionError { Text(error).foregroundColor(CadenceTheme.caution) }
            if app.isUsingMockGlasses { Text("Mock glasses: photos and sensors are simulated.") }
        } header: { Text("Photo source") }
        footer: { Text("Pair in the Meta AI app and allow camera access. Photo actions use the glasses; the iPhone camera is an explicit alternative.") }
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
