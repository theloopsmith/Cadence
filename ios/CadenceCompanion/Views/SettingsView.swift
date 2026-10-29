import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct SettingsView: View {
    @ObservedObject var app: CadenceAppModel
    @ObservedObject private var settings: AppSettings
    @ObservedObject private var auth: AuthSession
    @State private var username = ""
    @State private var password = ""
    @State private var confirmSignOut = false

    init(app: CadenceAppModel) {
        self.app = app
        self.settings = app.settings
        self.auth = app.auth
    }

    var body: some View {
        NavigationStack {
            Form {
                signInSection
                serverSection
                glassesSection
                Section {
                    TextField("Name on summaries (optional)", text: $settings.summaryName)
                        .frame(minHeight: CadenceTheme.minimumTapHeight)
                } header: {
                    Text("Shared summaries")
                } footer: {
                    Text("Printed at the top of summaries shared from the Diary.")
                }
                caregiverSection
                voiceSection
                aboutSection
            }
            .navigationTitle("Care partner setup")
            .confirmationDialog("Sign this phone out?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("Sign out", role: .destructive) { auth.signOut() }
                Button("Keep signed in", role: .cancel) {}
            } message: {
                Text("Events will stay on the phone until someone signs in again.")
            }
        }
    }

    // MARK: - Sign-in

    private var signInSection: some View {
        Section {
            if auth.isSignedIn, let name = auth.username {
                HStack {
                    Label("Signed in as \(name)", systemImage: "checkmark.shield.fill")
                        .foregroundColor(CadenceTheme.calm)
                    Spacer()
                }
                .frame(minHeight: CadenceTheme.minimumTapHeight)
                Button("Sign out", role: .destructive) { confirmSignOut = true }
                    .frame(minHeight: CadenceTheme.minimumTapHeight)
            } else {
                if auth.isExpired {
                    InlineNotice(text: "The phone needs to sign in again. Nothing is lost; events are waiting on the phone.")
                }
                TextField("Username", text: $username)
                    .textContentType(.username)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                    .frame(minHeight: CadenceTheme.minimumTapHeight)
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .frame(minHeight: CadenceTheme.minimumTapHeight)
                if let message = auth.errorMessage {
                    Text(message).font(.footnote).foregroundColor(CadenceTheme.danger)
                }
                Button {
                    Task {
                        await auth.signIn(username: username, password: password)
                        if auth.isSignedIn { password = "" }
                    }
                } label: {
                    if auth.isWorking { ProgressView() } else { Text("Sign in") }
                }
                .frame(minHeight: CadenceTheme.minimumTapHeight)
                .disabled(auth.isWorking)
            }
        } header: {
            Text("Phone sign-in")
        } footer: {
            Text("Use the account made for this phone. The password is not stored; the phone keeps a sign-in key in its secure storage.")
        }
    }

    // MARK: - Server Connection

    private var serverSection: some View {
        Section {
            TextField("Server address", text: $settings.backendBaseURL)
                #if os(iOS)
                .textContentType(.URL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                #endif
                .autocorrectionDisabled()
                .frame(minHeight: CadenceTheme.minimumTapHeight)
        } header: {
            Text("Backend server")
        } footer: {
            Text("For local Wi-Fi testing, use your Mac's IP (e.g. http://192.168.86.206:8000).")
        }
    }

    // MARK: - Meta AI Glasses

    private var glassesSection: some View {
        Section {
            HStack(spacing: 12) {
                IconBadge(
                    systemName: "eyeglasses",
                    color: app.glasses.connectionState == .connected ? CadenceTheme.calm : .secondary,
                    size: 36
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.glasses.deviceName ?? "Meta Gen 3 AI Glasses")
                        .font(.headline)
                    Text(glassesStatusText)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                Spacer()
                if app.glasses.connectionState == .connecting {
                    ProgressView().tint(CadenceTheme.accent)
                } else if app.glasses.connectionState == .connected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(CadenceTheme.calm)
                }
            }
            .frame(minHeight: CadenceTheme.minimumTapHeight)

            if app.glasses.connectionState == .connected {
                HStack {
                    Text("Wear State")
                    Spacer()
                    Text(app.glasses.wearState.rawValue.capitalized)
                        .foregroundColor(.secondary)
                }
                HStack {
                    Text("Motion Stream")
                    Spacer()
                    Text("60 Hz IMU (Active)")
                        .foregroundColor(CadenceTheme.calm)
                }
                Button("Disconnect Glasses", role: .destructive) {
                    app.glasses.disconnect()
                }
                .frame(minHeight: CadenceTheme.minimumTapHeight)
            } else {
                Button {
                    app.glasses.connect()
                } label: {
                    HStack {
                        Text(app.glasses.connectionState == .connecting ? "Connecting to Meta Glasses…" : "Connect Meta Glasses")
                            .font(.headline)
                        Spacer()
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                }
                .disabled(app.glasses.connectionState == .connecting)
                .frame(minHeight: CadenceTheme.minimumTapHeight)

                Toggle(
                    "Simulate Meta Glasses (Mock)",
                    isOn: Binding(
                        get: { app.isUsingMockGlasses },
                        set: { app.useMockGlasses($0) }
                    )
                )
                .frame(minHeight: CadenceTheme.minimumTapHeight)
            }
        } header: {
            Text("Meta AI Glasses")
        } footer: {
            Text("Streams 60 Hz head motion for Freeze of Gait detection, triggers open-ear audio cueing, and provides ground-level vision checks.")
        }
    }

    private var glassesStatusText: String {
        switch app.glasses.connectionState {
        case .connected:
            return "Connected · " + (app.glasses.wearState == .worn ? "Worn on head" : "Not worn")
        case .connecting:
            return "Connecting through Meta Wearables SDK…"
        case .disconnected:
            return "Disconnected"
        case .notPaired:
            return "Not paired yet"
        }
    }

    // MARK: - Caregiver

    private var caregiverSection: some View {
        Section {
            TextField("Caregiver's name", text: $settings.caregiverName)
            TextField("Caregiver's phone", text: $settings.caregiverPhone)
                #if os(iOS)
                .textContentType(.telephoneNumber)
                .keyboardType(.phonePad)
                #endif
            TextField("Emergency number", text: $settings.emergencyNumber)
                #if os(iOS)
                .keyboardType(.phonePad)
                #endif
        } header: {
            Text("Caregiver")
        } footer: {
            Text("Contacted only if you fall and do not answer the voice check-in.")
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
            Text("Voice")
        } footer: {
            Text("Tap a voice to hear it and use it for all of Cadence's spoken prompts.")
        }
    }

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
