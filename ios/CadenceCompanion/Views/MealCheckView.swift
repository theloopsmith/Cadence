import SwiftUI

/// Meal & Levodopa Protein Conflict Checker (Pipeline 3).
/// Analyzes meal photos with SAM 3.1 plate segmentation and Fireworks Llama 3.2 Vision.
/// Detects protein content that competes with Levodopa across the LAT1 blood-brain barrier.
public struct MealCheckView: View {
    @ObservedObject var app: CadenceAppModel
    @Environment(\.dismiss) private var dismiss

    @State private var showCamera: Bool = false
    @State private var isAnalyzing: Bool = false
    @State private var mealResult: MealProteinResult?
    @State private var errorMessage: String?

    public init(app: CadenceAppModel) {
        self.app = app
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    infoCard
                    actionCard
                    if isAnalyzing {
                        loadingCard
                    } else if let result = mealResult {
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
            .navigationTitle("Meal & Medication Check")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .cameraPresentation(
                isPresented: $showCamera,
                onCapture: { jpeg in
                    showCamera = false
                    analyzeMeal(jpeg: jpeg)
                },
                onCancel: { showCamera = false }
            )
        }
    }

    // MARK: - Info

    private var infoCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            IconBadge(systemName: "fork.knife", color: CadenceTheme.accent, size: 48)
            Text("Meals and protein")
                .font(.title2.weight(.bold))
            Text("Some people notice that protein-rich meals close to a Levodopa dose matter for them. Cadence can estimate the protein on your plate and note meals near a dose in your diary, to talk over with your care team.")
                .font(.body)
                .foregroundColor(.secondary)

            HStack(spacing: 12) {
                Image(systemName: "clock.badge.exclamationmark")
                    .foregroundColor(CadenceTheme.accent)
                Text("Next dose: \(app.doses.detail)")
                    .font(.subheadline.weight(.semibold))
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(CadenceTheme.accent.opacity(0.1)))
        }
        .card()
    }

    // MARK: - Action

    private var actionCard: some View {
        VStack(spacing: 12) {
            if app.glasses.connectionState == .connected {
                GuardedButton(size: .giant, style: .filled(CadenceTheme.accent), action: {
                    captureWithGlasses()
                }) {
                    Label("Take Photo with Glasses", systemImage: "eyeglasses")
                }

                Button("Or use phone camera") {
                    showCamera = true
                }
                .font(.footnote)
                .foregroundColor(.secondary)
            } else {
                GuardedButton(size: .giant, style: .filled(CadenceTheme.accent), action: {
                    showCamera = true
                }) {
                    Label("Take Photo of Plate", systemImage: "camera.fill")
                }
            }
        }
        .card()
    }

    // MARK: - Loading

    private var loadingCard: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.4)
                .tint(CadenceTheme.accent)
            Text("Analyzing plate…")
                .font(.headline)
            Text("Estimating the protein on your plate.")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .card()
    }

    // MARK: - Result

    private func resultCard(_ result: MealProteinResult) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                StatusPill(
                    text: result.conflictDetected ? "Close to a dose" : "Meal noted",
                    color: result.conflictDetected ? CadenceTheme.caution : CadenceTheme.calm,
                    filled: true
                )
                Spacer()
                if result.plateDetected {
                    Text("Plate found")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(String(format: "About %.0f g protein", result.estimatedProteinGrams))
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundColor(result.conflictDetected ? CadenceTheme.caution : CadenceTheme.calm)
                Text(result.spokenResponse)
                    .font(.body)
                    .foregroundColor(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !result.items.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("What Cadence saw:")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)
                    ForEach(result.items, id: \.label) { item in
                        HStack {
                            Text(item.label.capitalized)
                            Spacer()
                            Text(String(format: "~%.0f g", item.estimatedGrams))
                                .foregroundColor(.secondary)
                                .monospacedDigit()
                        }
                        .font(.subheadline)
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
            }

            if result.conflictDetected {
                Text("This meal is close to your Levodopa time and is noted in your diary. Questions about meals and your medication are best answered by your care team.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(CadenceTheme.caution.opacity(0.12)))
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
            StatusPill(text: "Analysis failed", color: CadenceTheme.danger, filled: true)
            Text(error)
                .font(.body)
                .foregroundColor(.secondary)
            GuardedButton(size: .big, style: .tinted(.secondary), action: { showCamera = true }) {
                Text("Try Again")
            }
        }
        .card()
    }

    // MARK: - Logic

    private func captureWithGlasses() {
        isAnalyzing = true
        errorMessage = nil
        mealResult = nil

        app.glasses.capturePhoto { result in
            switch result {
            case let .success(jpeg):
                self.analyzeMeal(jpeg: jpeg)
            case let .failure(error):
                self.isAnalyzing = false
                self.errorMessage = "Glasses camera: \(error.localizedDescription)"
            }
        }
    }

    private func analyzeMeal(jpeg: Data) {
        isAnalyzing = true
        errorMessage = nil
        mealResult = nil

        Task {
            do {
                let client = app.settings.api
                let result = try await client.logMeal(jpeg: jpeg)
                await MainActor.run {
                    self.isAnalyzing = false
                    self.mealResult = result
                    app.recordDiary(
                        .mealLogged,
                        detail: String(format: "%.0f g protein%@", result.estimatedProteinGrams, result.conflictDetected ? " (Conflict with dose)" : "")
                    )
                    AudioCueEngine.shared.speakPrompt(result.spokenResponse, priority: 2)
                    Haptics.success()
                }
            } catch {
                await MainActor.run {
                    self.isAnalyzing = false
                    self.errorMessage = "Could not analyze meal: \(error.localizedDescription)"
                }
            }
        }
    }
}
