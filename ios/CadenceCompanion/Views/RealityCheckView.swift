import SwiftUI

/// Look-around view: describes what the camera actually sees, calmly and factually.
/// Uses SAM 3.1 instance lock and Fireworks Llama 3.2 Vision to ground objects
/// (e.g. differentiating a coat on a chair or coat rack in low light from an intruder).
public struct RealityCheckView: View {
    @ObservedObject var app: CadenceAppModel
    @Environment(\.dismiss) private var dismiss

    @State private var voiceFlowID = UUID()
    @State private var question: String = "Is someone standing there, or is it just an object?"
    @State private var isListeningToVoice: Bool = false
    @State private var showSignIn = false
    @State private var retryPhoto: Data?
    @State private var retryProfileID: String?
    @State private var automaticVoiceCapture = false
    @State private var showGlassesCamera = false
    @State private var showCamera: Bool = false
    @State private var isChecking: Bool = false
    @State private var checkResult: RealityCheckResult?
    @State private var errorMessage: String?
    @State private var requestID = UUID()
    @State private var requestTask: Task<Void, Never>?
    @State private var fromGlasses = true
    @State private var photoSource: String?

    private let sampleQuestions = [
        "Is someone standing there, or is it just an object?",
        "Is that a person on the chair or just clothes?",
        "Is there an animal or pet in the room?",
        "Check the room and tell me what is there.",
    ]

    public init(app: CadenceAppModel) {
        self.app = app
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    headerCard
                    questionCard
                    actionsCard
                    if isChecking {
                        loadingCard
                    } else if let result = checkResult {
                        resultCard(result)
                    } else if let error = errorMessage {
                        errorCard(error)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 64)
            }
            .background(CadenceTheme.background.ignoresSafeArea())
            .navigationTitle("Check Surroundings")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        stopVoiceInput()
                        dismiss()
                    }
                }
            }
            .onAppear {
                app.companion.enterFlow(id: voiceFlowID, destination: .surroundings, step: isChecking ? .analyzing : .surroundings)
                if app.companion.isEnabled, !app.companion.lastHeard.isEmpty { question = app.companion.lastHeard }
            }
            .onChange(of: isChecking) { active in app.companion.updateFlow(id: voiceFlowID, step: active ? .analyzing : .surroundings) }
            .onChange(of: app.companion.actionID) { _ in
                guard app.companion.context == .surroundings else { return }
                switch app.companion.action {
                case .capture: automaticVoiceCapture = true; showGlassesCamera = true
                case .start, .retry:
                    if let retryPhoto { runRealityCheck(jpeg: retryPhoto) }
                    else { automaticVoiceCapture = true; showGlassesCamera = true }
                case .settings: showSignIn = true
                case .cancel, .finish: dismiss()
                default: break
                }
            }
            .onDisappear {
                if showGlassesCamera || showCamera || showSignIn { return }
                app.companion.leaveFlow(id: voiceFlowID)
                requestID = UUID()
                requestTask?.cancel()
                app.glasses.cancelPhotoCapture()
                stopVoiceInput()
            }
            .sheet(isPresented: $showSignIn) { SettingsView(app: app) }
            .sheet(isPresented: $showGlassesCamera, onDismiss: {
                automaticVoiceCapture = false
            }) {
                GlassesCameraView(glasses: app.glasses, voice: app.companion, captureWhenReady: automaticVoiceCapture) { jpeg in
                    fromGlasses = true
                    photoSource = app.isUsingMockGlasses ? "Mock glasses (simulated)" : "Meta glasses"
                    runRealityCheck(jpeg: jpeg)
                }
            }
            .cameraPresentation(
                isPresented: $showCamera,
                onCapture: { jpeg in
                    showCamera = false
                    fromGlasses = false
                    photoSource = "iPhone camera"
                    runRealityCheck(jpeg: jpeg)
                },
                onCancel: { showCamera = false }
            )
        }
    }

    // MARK: - Header

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            IconBadge(systemName: "eye.fill", color: CadenceTheme.accent, size: 48)
            Text("Describe Surroundings")
                .font(.title2.weight(.bold))
            Text("Cadence describes objects it can identify in a photo when you ask. It cannot verify the whole scene or confirm that an area is safe.")
                .font(.body)
                .foregroundColor(.secondary)
        }
        .card()
    }

    // MARK: - Question selector

    private var questionCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("What would you like to check?")
                .font(.headline)

            // Voice input prompt
            if isListeningToVoice {
                HStack(spacing: 12) {
                    Image(systemName: "waveform")
                        .foregroundColor(CadenceTheme.accent)
                        .font(.title2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Listening… speak what you see or ask")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(question.isEmpty ? "“Is someone standing there?”" : question)
                            .font(.body.weight(.medium))
                            .foregroundColor(.primary)
                    }
                    Spacer()
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(CadenceTheme.accent.opacity(0.12))
                )

                GuardedButton(size: .big, style: .filled(CadenceTheme.accent), action: {
                    stopVoiceInput()
                }) {
                    Label("Done Speaking", systemImage: "checkmark")
                }
            } else {
                GuardedButton(size: .big, style: .tinted(CadenceTheme.accent), action: {
                    startVoiceInput()
                }) {
                    Label("Speak Question with Microphone", systemImage: "mic.fill")
                }
            }

            Divider().padding(.vertical, 2)

            Text("Or choose a common question:")
                .font(.footnote)
                .foregroundColor(.secondary)

            ForEach(sampleQuestions, id: \.self) { q in
                Button {
                    stopVoiceInput()
                    question = q
                } label: {
                    HStack {
                        Text(q)
                            .font(.subheadline)
                            .foregroundColor(.primary)
                            .multilineTextAlignment(.leading)
                        Spacer()
                        if question == q {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(CadenceTheme.accent)
                        }
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(question == q ? CadenceTheme.accent.opacity(0.12) : Color.secondary.opacity(0.08))
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .card()
    }

    // MARK: - Actions

    private var actionsCard: some View {
        VStack(spacing: 12) {
            GuardedButton(size: .giant, style: .filled(CadenceTheme.accent), action: { showGlassesCamera = true }) {
                Label("Open glasses camera", systemImage: "eyeglasses")
            }
            Text("The camera screen connects Cadence to your glasses and shows live video before you capture.")
                .font(.footnote).foregroundColor(.secondary)
            if let error = app.glasses.connectionError { Text(error).font(.footnote) }
            if let details = app.glasses.connectionDetails { Text(details).font(.caption).foregroundColor(.secondary) }
            Button("Use iPhone camera instead") {
                stopVoiceInput()
                fromGlasses = false
                showCamera = true
            }.font(.footnote)
            if let photoSource { Text("Photo source: \(photoSource)").font(.footnote).foregroundColor(.secondary) }
        }
        .disabled(isChecking)
        .card()
    }

    // MARK: - Loading

    private var loadingCard: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.4)
                .tint(CadenceTheme.accent)
            Text("Looking at the scene…")
                .font(.headline)
            Text("Identifying objects in this photo with Meta models.")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .card()
    }

    // MARK: - Result

    private func resultCard(_ result: RealityCheckResult) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                StatusPill(
                    text: result.detectedLabels.isEmpty ? "No clear objects" : "Photo observations",
                    color: result.livingSubjectPresent ? CadenceTheme.caution : CadenceTheme.calm,
                    filled: true
                )
                Spacer()
                Text("\(result.latencyMs) ms")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Text(result.spokenResponse)
                .font(.title3.weight(.medium))
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)

            if !result.detectedLabels.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Objects identified:")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)
                    Text(result.detectedLabels.joined(separator: ", "))
                        .font(.body)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
            }

            HStack(spacing: 12) {
                GuardedButton(size: .big, style: .tinted(CadenceTheme.accent), action: {
                    AudioCueEngine.shared.speakPrompt(result.spokenResponse, priority: 2)
                }) {
                    Label("Read Aloud", systemImage: "speaker.wave.2.fill")
                }

                GuardedButton(size: .big, style: .filled(CadenceTheme.calm), action: {
                    dismiss()
                }) {
                    Text("Done")
                }
            }
        }
        .card()
    }

    private func errorCard(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            StatusPill(text: "Check failed", color: CadenceTheme.danger, filled: true)
            Text(error)
                .font(.body)
                .foregroundColor(.secondary)
            if app.auth.needsSignIn {
                Button("Sign in to check this photo") { showSignIn = true }
                    .buttonStyle(.borderedProminent)
            } else if let jpeg = retryPhoto, retryProfileID == app.settings.profile.id {
                Button("Retry this photo") { runRealityCheck(jpeg: jpeg) }
                    .buttonStyle(.borderedProminent)
            }
            Button("Take another photo") {
                if fromGlasses { captureWithGlasses() } else { showCamera = true }
            }

        }
        .card()
    }

    // MARK: - Logic

    private func startVoiceInput() {
        app.companion.setPaused("Question dictation", true)
        isListeningToVoice = true
        question = ""
        app.transcripts.startListening { text in
            Task { @MainActor in
                self.question = text
            }
        }
    }

    private func stopVoiceInput() {
        if isListeningToVoice {
            isListeningToVoice = false
            app.transcripts.stopListening()
            app.companion.setPaused("Question dictation", false)
            if question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                question = "Check the room and tell me what is there."
            }
        }
    }

    private func captureWithGlasses() {
        guard !isChecking else { return }
        stopVoiceInput()
        errorMessage = nil
        automaticVoiceCapture = false
        showGlassesCamera = true
    }

    private func runRealityCheck(jpeg: Data) {
        stopVoiceInput()
        retryPhoto = jpeg
        retryProfileID = app.settings.profile.id
        guard !app.auth.needsSignIn else {
            errorMessage = "Sign in to your Cadence server to check this photo. Say settings to open sign-in. The photo is kept only while this screen stays open."
            app.companion.say(errorMessage ?? "Sign in to continue.")
            return
        }
        isChecking = true
        errorMessage = nil
        checkResult = nil
        let id = UUID(); requestID = id
        let client = app.settings.api
        let profileID = app.settings.profile.id
        requestTask?.cancel()
        requestTask = Task { @MainActor in
            do {
                let result = try await client.realityCheck(question: question, jpeg: jpeg)
                guard !Task.isCancelled, requestID == id, !app.settings.restartRequired,
                      app.settings.profile.id == profileID, app.settings.deviceToken == client.bearerToken,
                      app.settings.api.baseURL == client.baseURL else { return }
                isChecking = false
                checkResult = result
                retryPhoto = nil
                app.recordDiary(.environmentCheck, detail: result.spokenResponse)
                AudioCueEngine.shared.speakPrompt(result.spokenResponse, priority: 2)
                Haptics.success()
            } catch {
                guard !Task.isCancelled, requestID == id, !app.settings.restartRequired,
                      app.settings.profile.id == profileID, app.settings.deviceToken == client.bearerToken,
                      app.settings.api.baseURL == client.baseURL else { return }
                isChecking = false
                errorMessage = "Could not check this photo: \(error.localizedDescription). Say settings to open the server connection, or retry to try this photo again."
                app.companion.say(errorMessage ?? "The check could not finish.")
            }
        }
    }
}
