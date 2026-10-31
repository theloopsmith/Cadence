import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Focused user settings: Voice selection and About information.
struct SettingsView: View {
    @ObservedObject var app: CadenceAppModel
    @ObservedObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @StateObject private var discovery = BackendDiscovery()
    @ObservedObject private var glasses: GlassesSessionManager
    @State private var showGlassesCamera = false
    @State private var voiceFlowID = UUID()
    @State private var username = ""
    @State private var password = ""
    @State private var server = ""
    @State private var confirmReset = false
    @State private var confirmServerRepair = false

    init(app: CadenceAppModel) {
        self.app = app
        self.settings = app.settings
        self.glasses = app.glasses
    }

    var body: some View {
        NavigationStack {
            Form {
                Section { VoiceCompanionBar(app: app) }
                contactsSection
                accountSection
                glassesSection
                voiceSection
                aboutSection
            }
            .onAppear {
                server = settings.backendBaseURL
                app.companion.enterFlow(id: voiceFlowID, destination: .settings, step: .settings)
            }
            .onChange(of: app.companion.actionID) { _ in
                if app.companion.context == .settings, app.companion.action == .finish { dismiss() }
            }
            .onDisappear {
                password = ""; discovery.stop()
                app.companion.leaveFlow(id: voiceFlowID)
            }
            .sheet(isPresented: $showGlassesCamera) { GlassesCameraView(glasses: glasses, voice: app.companion) }
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

    // MARK: - Contacts

    /// The people Cadence offers to call. These feed the Help tab, the SOS
    /// screen and the voice companion; nothing here changes server routing.
    private var contactsSection: some View {
        Section {
            TextField("Care partner's name", text: $settings.caregiverName)
                .frame(minHeight: CadenceTheme.bigTapHeight)
            TextField("Care partner's phone number", text: $settings.caregiverPhone)
                .frame(minHeight: CadenceTheme.bigTapHeight)
                #if os(iOS)
                .keyboardType(.phonePad)
                .textContentType(.telephoneNumber)
                #endif
            TextField("Emergency number (default 911)", text: $settings.emergencyNumber)
                .frame(minHeight: CadenceTheme.bigTapHeight)
                #if os(iOS)
                .keyboardType(.phonePad)
                #endif
            TextField("Name on shared summaries (optional)", text: $settings.summaryName)
                .frame(minHeight: CadenceTheme.bigTapHeight)
        } header: {
            Text("People to call")
        } footer: {
            Text("The Help tab and the fall screen offer one-tap calls to these numbers. Automatic caregiver alerts are set up on the server, not here.")
        }
    }

    // MARK: - Account

    private var accountSection: some View {
        Section {
            Text("1. Start the Cadence server on the Mac and keep it running.")
            Text("2. Keep both devices on the same Wi-Fi, then find the Mac below.")
            Button("Find my Mac server") { discovery.start() }
            ForEach(discovery.servers) { found in
                Button {
                    server = found.address
                    discovery.stop()
                } label: {
                    VStack(alignment: .leading) {
                        Text("Use \(found.name)")
                        Text(found.address).font(.caption)
                    }
                }
            }
            if !discovery.message.isEmpty { Text(discovery.message).font(.footnote) }
            Text("3. Enter the phone account's username and password, then tap Sign in. The person who set up the server has them.")

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
                Text("This phone is still pointed at itself. Choose the Mac above, then tap Connect. Your history on this phone is kept.")
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
            Text(glasses.canCapturePhoto ? "Connected — glasses camera ready" : "Glasses camera not connected")
            Button("Open live glasses camera") { showGlassesCamera = true }
            Button("Connect Meta glasses") { app.glasses.connect() }
                .disabled(glasses.connectionState == .connecting)
            if let details = glasses.connectionDetails { Text(details).font(.caption).foregroundColor(.secondary) }
            if let error = glasses.connectionError { Text(error).foregroundColor(CadenceTheme.caution) }
            if app.isUsingMockGlasses { Text("Mock glasses: photos and sensors are simulated.") }
        } header: { Text("Photo source") }
        footer: { Text("Pair in the Meta AI app and allow camera access. Photo actions use the glasses; the iPhone camera is an explicit alternative.") }
    }

    private var voiceSection: some View {
        let installed = VoiceCandidate.installed
        let choices = Array(VoiceSelection.choices(from: installed).prefix(8))
        let current = VoiceSelection.best(from: installed, preferred: settings.preferredVoiceIdentifier)
        return Section {
            Button("Automatically use the best installed voice") {
                settings.preferredVoiceIdentifier = nil
                AudioCueEngine.shared.refreshVoiceSelection()
            }
            if let current { Text("Current voice: \(current.name) · \(current.quality.word)").font(.footnote) }
            Text("Speech uses the iPhone's built-in voice. No third-party speech-generation model is called.").font(.footnote)
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
