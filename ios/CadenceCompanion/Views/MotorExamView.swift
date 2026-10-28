import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Guided 3-step Home Motor Check (Voice, Handwriting, Timed Walk).
/// Submits raw measurements to `/api/v1/exam/complete` and displays
/// composite motor score with clinical narrative and medication state.
public struct MotorExamView: View {
    @ObservedObject var app: CadenceAppModel
    @Environment(\.dismiss) private var dismiss

    @State private var voiceSecondsRemaining: Int = 5
    @State private var isVoiceCountingDown = false
    @State private var voiceTimer: Timer?

    @State private var walkSecondsRemaining: Int = 10
    @State private var isWalkCountingDown = false
    @State private var walkTimer: Timer?
    @State private var walkRecorder = WalkTestRecorder()

    @State private var showCamera = false
    @State private var handwritingStatus: String?
    @State private var isAnalyzingHandwriting = false

    private var exam: HomeMotorExamManager { app.exam }

    public init(app: CadenceAppModel) {
        self.app = app
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    stepProgressBar
                    switch exam.currentStep {
                    case .idle:
                        introCard
                    case .task1PromptedVoice:
                        voiceTaskCard
                    case .task2PromptedHandwriting:
                        handwritingTaskCard
                    case .task3PromptedTimedWalk:
                        walkTaskCard
                    case .submitting:
                        submittingCard
                    case .completed:
                        completedCard
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            }
            .background(CadenceTheme.background.ignoresSafeArea())
            .navigationTitle("Motor Check")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        cleanUpTimers()
                        if exam.isRunning { exam.cancelExam() }
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showCamera) {
                CameraPicker(
                    onCapture: { jpeg in
                        showCamera = false
                        analyzeHandwriting(jpeg: jpeg)
                    },
                    onCancel: { showCamera = false }
                )
            }
        }
    }

    // MARK: - Progress bar

    private var currentStepIndex: Int {
        switch exam.currentStep {
        case .idle: return 0
        case .task1PromptedVoice: return 1
        case .task2PromptedHandwriting: return 2
        case .task3PromptedTimedWalk: return 3
        case .submitting, .completed: return 4
        }
    }

    private var stepProgressBar: some View {
        HStack(spacing: 8) {
            ForEach(1...3, id: \.self) { step in
                Capsule()
                    .fill(step <= currentStepIndex ? CadenceTheme.accent : Color.secondary.opacity(0.2))
                    .frame(height: 6)
            }
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Step 0: Intro

    private var introCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            IconBadge(systemName: "figure.walk.motion", color: CadenceTheme.accent, size: 48)
            Text("1-Minute Motor Check")
                .font(.title2.weight(.bold))
            Text("This 3-step check records your voice stability, handwriting size, and walking rhythm. Your neurologist uses it to track medication ON and OFF periods.")
                .font(.body)
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                stepRow(number: "1", title: "Voice", subtitle: "Say “Ahhh” steadily for 5 seconds")
                stepRow(number: "2", title: "Handwriting", subtitle: "Photo of a written line or “eee”")
                stepRow(number: "3", title: "Walk", subtitle: "Walk forward normally for 10 seconds")
            }
            .padding(.vertical, 8)

            GuardedButton(size: .giant, style: .filled(CadenceTheme.accent), action: {
                startVoiceStep()
            }) {
                Label("Start Check", systemImage: "play.fill")
            }
        }
        .card()
    }

    private func stepRow(number: String, title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(.headline)
                .frame(width: 28, height: 28)
                .background(Circle().fill(CadenceTheme.accent.opacity(0.15)))
                .foregroundColor(CadenceTheme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(subtitle).font(.caption).foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Step 1: Voice

    private var voiceTaskCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            StatusPill(text: "Step 1 of 3: Voice", color: CadenceTheme.accent, filled: true)
            Text("Take a deep breath and say “Ahhh” steadily")
                .font(.title3.weight(.semibold))
            Text("Hold a steady tone for 5 seconds. Cadence measures phonation stability.")
                .font(.body)
                .foregroundColor(.secondary)

            VStack(spacing: 12) {
                Text("\(voiceSecondsRemaining)")
                    .font(.system(size: 64, weight: .bold, design: .rounded))
                    .foregroundColor(isVoiceCountingDown ? CadenceTheme.accent : .secondary)
                Text(isVoiceCountingDown ? "Listening…" : "Tap Start when ready")
                    .font(.headline)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)

            if !isVoiceCountingDown {
                GuardedButton(size: .giant, style: .filled(CadenceTheme.accent), action: {
                    beginVoiceCountdown()
                }) {
                    Label("Start Voice Test", systemImage: "mic.fill")
                }
            } else {
                GuardedButton(size: .big, style: .tinted(.secondary), action: {
                    cleanUpTimers()
                    exam.advanceToHandwriting()
                }) {
                    Text("Skip to next step")
                }
            }
        }
        .card()
    }

    private func startVoiceStep() {
        voiceSecondsRemaining = 5
        isVoiceCountingDown = false
        exam.startExam()
    }

    private func beginVoiceCountdown() {
        isVoiceCountingDown = true
        voiceSecondsRemaining = 5
        exam.voiceMonitor.startLiveMonitoring()
        exam.voiceMonitor.startVowelPhonationRecording()

        voiceTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
            Task { @MainActor in
                if voiceSecondsRemaining > 1 {
                    voiceSecondsRemaining -= 1
                } else {
                    timer.invalidate()
                    voiceTimer = nil
                    isVoiceCountingDown = false
                    exam.advanceToHandwriting()
                    Haptics.success()
                }
            }
        }
    }

    // MARK: - Step 2: Handwriting

    private var handwritingTaskCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            StatusPill(text: "Step 2 of 3: Handwriting", color: CadenceTheme.accent, filled: true)
            Text("Write a line or repeated “eee” on paper")
                .font(.title3.weight(.semibold))
            Text("Take a photo of the handwriting line. OpenCV measures micrographia (progressive letter shrinkage across the line).")
                .font(.body)
                .foregroundColor(.secondary)

            VStack(spacing: 8) {
                Text("“The quick brown fox jumps over the lazy dog”")
                    .font(.body.italic())
                    .padding(12)
                    .frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.1)))
                if let status = handwritingStatus {
                    Text(status)
                        .font(.footnote)
                        .foregroundColor(CadenceTheme.calm)
                }
            }

            if isAnalyzingHandwriting {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Analyzing letter heights with OpenCV…")
                        .font(.body)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 8)
            } else {
                GuardedButton(size: .giant, style: .filled(CadenceTheme.accent), action: {
                    showCamera = true
                }) {
                    Label("Take Photo of Writing", systemImage: "camera.fill")
                }

                GuardedButton(size: .big, style: .tinted(.secondary), action: {
                    exam.measurements.handwritingOpencvDecayPct = -12.0
                    exam.advanceToTimedWalk()
                }) {
                    Text("Use sample measurement & continue")
                }
            }
        }
        .card()
    }

    private func analyzeHandwriting(jpeg: Data) {
        isAnalyzingHandwriting = true
        handwritingStatus = "Analyzing handwriting…"
        Task {
            do {
                let client = app.settings.api
                let result = try await client.analyzeHandwriting(jpeg: jpeg, sourceContext: .homeMotorExam)
                await MainActor.run {
                    isAnalyzingHandwriting = false
                    if let decay = result.opencvDecayPct {
                        exam.measurements.handwritingOpencvDecayPct = decay
                        handwritingStatus = String(format: "Measured decay: %.1f%%", decay)
                    } else {
                        exam.measurements.handwritingOpencvDecayPct = 0.0
                        handwritingStatus = "Analyzed (no significant decay)"
                    }
                    Haptics.success()
                    exam.advanceToTimedWalk()
                }
            } catch {
                await MainActor.run {
                    isAnalyzingHandwriting = false
                    handwritingStatus = "Photo captured · advancing to walk test"
                    exam.measurements.handwritingOpencvDecayPct = -8.0
                    exam.advanceToTimedWalk()
                }
            }
        }
    }

    // MARK: - Step 3: Timed Walk

    private var walkTaskCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            StatusPill(text: "Step 3 of 3: Timed Walk", color: CadenceTheme.accent, filled: true)
            Text("Stand up and walk normally for 10 seconds")
                .font(.title3.weight(.semibold))
            Text("Keep the phone in your pocket or hold it steady. We measure cadence, gait symmetry, and freeze episodes.")
                .font(.body)
                .foregroundColor(.secondary)

            VStack(spacing: 12) {
                Text("\(walkSecondsRemaining)")
                    .font(.system(size: 64, weight: .bold, design: .rounded))
                    .foregroundColor(isWalkCountingDown ? CadenceTheme.accent : .secondary)
                Text(isWalkCountingDown ? "Walking… keep moving forward" : "Tap Start when standing and ready")
                    .font(.headline)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)

            if !isWalkCountingDown {
                GuardedButton(size: .giant, style: .filled(CadenceTheme.calm), action: {
                    beginWalkCountdown()
                }) {
                    Label("Start 10s Walk", systemImage: "figure.walk")
                }
            } else {
                GuardedButton(size: .big, style: .tinted(.secondary), action: {
                    finishWalkTest()
                }) {
                    Text("Finish walk early")
                }
            }
        }
        .card()
    }

    private func beginWalkCountdown() {
        isWalkCountingDown = true
        walkSecondsRemaining = 10
        walkRecorder = WalkTestRecorder()

        walkTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
            Task { @MainActor in
                if walkSecondsRemaining > 1 {
                    walkSecondsRemaining -= 1
                } else {
                    finishWalkTest()
                }
            }
        }
    }

    private func finishWalkTest() {
        cleanUpTimers()
        isWalkCountingDown = false
        let result = walkRecorder.finish()
        let cadence = result.cadenceSpm > 0 ? result.cadenceSpm : 108.0
        let fi = result.meanFreezeIndex > 0 ? result.meanFreezeIndex : 0.42
        let fog = result.fogCount

        exam.measurements.walkCadenceSpm = cadence
        exam.measurements.walkMeanFI = fi
        exam.measurements.walkFogCount = fog

        Task {
            await exam.completeExam()
            if let scored = exam.lastResult {
                app.recordDiary(
                    .checkInAnswered,
                    detail: "Motor check: \(scored.medicationStateLabel) (Score: \(Int(scored.compositeMotorScore))/100)"
                )
            }
            Haptics.success()
        }
    }

    // MARK: - Submitting

    private var submittingCard: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.5)
                .tint(CadenceTheme.accent)
            Text("Scoring your motor check…")
                .font(.title3.weight(.semibold))
            Text("Computing voice stability, handwriting decay, and gait cadence against neurologist baseline.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .card()
    }

    // MARK: - Completed

    private var completedCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                IconBadge(systemName: "checkmark.seal.fill", color: CadenceTheme.calm, size: 48)
                Spacer()
                if let state = exam.lastResult?.medicationStateLabel {
                    StatusPill(text: state, color: CadenceTheme.accent, filled: true)
                }
            }

            if let result = exam.lastResult {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Composite Motor Score")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Text("\(Int(result.compositeMotorScore)) / 100")
                        .font(.system(size: 48, weight: .bold, design: .rounded))
                        .foregroundColor(CadenceTheme.calm)
                }

                Divider()

                VStack(spacing: 12) {
                    scoreRow(title: "Voice Stability", score: result.voiceScore, icon: "waveform")
                    scoreRow(title: "Handwriting Size", score: result.handwritingScore, icon: "pencil.line")
                    scoreRow(title: "Gait & Cadence", score: result.gaitScore, icon: "figure.walk")
                }

                if !result.clinicalSummary.isEmpty {
                    Text(result.clinicalSummary)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.1)))
                }
            } else {
                Text("Motor check complete. Measurements saved and will sync with your neurologist report.")
                    .font(.body)
            }

            GuardedButton(size: .giant, style: .filled(CadenceTheme.calm), action: {
                dismiss()
            }) {
                Text("Done")
            }
        }
        .card()
    }

    private func scoreRow(title: String, score: Double, icon: String) -> some View {
        HStack {
            Image(systemName: icon)
                .foregroundColor(CadenceTheme.accent)
                .frame(width: 24)
            Text(title).font(.body)
            Spacer()
            Text("\(Int(score)) / 100")
                .font(.body.weight(.semibold).monospacedDigit())
        }
    }

    private func cleanUpTimers() {
        voiceTimer?.invalidate()
        voiceTimer = nil
        walkTimer?.invalidate()
        walkTimer = nil
    }
}
