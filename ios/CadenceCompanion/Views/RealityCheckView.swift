import SwiftUI

/// Look-around view: describes what the camera actually sees, calmly and factually.
/// Uses SAM 3.1 instance lock and Fireworks Llama 3.2 Vision to ground objects
/// (e.g. differentiating a coat on a chair or coat rack in low light from an intruder).
public struct RealityCheckView: View {
    @ObservedObject var app: CadenceAppModel
    @Environment(\.dismiss) private var dismiss

    @State private var question: String = "Is someone standing there, or is it just an object?"
    @State private var isListeningToVoice: Bool = false
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
            .onDisappear {
                requestID = UUID()
                requestTask?.cancel()
                app.glasses.cancelPhotoCapture()
                stopVoiceInput()
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
            if app.glasses.canCapturePhoto {
                GuardedButton(size: .giant, style: .filled(CadenceTheme.accent), action: captureWithGlasses) {
                    Label("Take Photo with Meta Glasses", systemImage: "eyeglasses")
                }
            } else {
                Text(app.glasses.connectionState == .connecting ? "Connecting to Meta glasses…" : "Connect your Meta glasses to take a photo from what you are looking at.")
                Button("Connect Meta glasses") { app.glasses.connect() }
                    .disabled(app.glasses.connectionState == .connecting)
                if let error = app.glasses.connectionError { Text(error).font(.footnote) }
            }
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
            GuardedButton(size: .big, style: .tinted(.secondary), action: {
                if fromGlasses { captureWithGlasses() } else { showCamera = true }
            }) {
                Text("Try Again")
            }
        }
        .card()
    }

    // MARK: - Logic

    private func startVoiceInput() {
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
            if question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                question = "Check the room and tell me what is there."
            }
        }
    }

    private func captureWithGlasses() {
        guard !isChecking else { return }
        stopVoiceInput()
        isChecking = true
        errorMessage = nil
        checkResult = nil
        fromGlasses = true
        photoSource = app.isUsingMockGlasses ? "Mock glasses (simulated)" : "Meta glasses"
        let id = UUID(); requestID = id
        app.glasses.capturePhoto { result in
            guard requestID == id, !app.settings.restartRequired else { return }
            switch result {
            case let .success(jpeg): runRealityCheck(jpeg: jpeg)
            case let .failure(error):
                isChecking = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private func runRealityCheck(jpeg: Data) {
        stopVoiceInput()
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
                app.recordDiary(.environmentCheck, detail: result.spokenResponse)
                AudioCueEngine.shared.speakPrompt(result.spokenResponse, priority: 2)
                Haptics.success()
            } catch {
                guard !Task.isCancelled, requestID == id, !app.settings.restartRequired else { return }
                isChecking = false
                errorMessage = "Could not check this photo: \(error.localizedDescription). Check the server connection in Settings."
            }
        }
    }
}
