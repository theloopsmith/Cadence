import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Guided 3-step motor check (voice, handwriting, timed walk). Shows the raw
/// measurements and how they compare with the previous check. No scores.
public struct MotorExamView: View {
    @ObservedObject var app: CadenceAppModel
    @ObservedObject private var exam: HomeMotorExamManager
    @Environment(\.dismiss) private var dismiss

    @State private var voiceSecondsRemaining: Int = 5
    @State private var isVoiceCountingDown = false
    @State private var voiceTimer: Timer?

    @State private var walkSecondsRemaining: Int = 10
    @State private var isWalkCountingDown = false
    @State private var walkTimer: Timer?
    @State private var walkRecorder = WalkTestRecorder()
    @State private var walkSinkToken: UUID?
    @State private var startedMotionForWalk = false

    @State private var showCamera = false
    @State private var handwritingStatus: String?
    @State private var isAnalyzingHandwriting = false

    public init(app: CadenceAppModel) {
        self.app = app
        self._exam = ObservedObject(wrappedValue: app.exam)
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
                .padding(.top, 16)
                .padding(.bottom, 64)
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
            Text("Three short tasks: your voice, your handwriting, and a short walk. Cadence keeps the measurements in your diary so you can share how they change over time with your care team.")
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
            Text("Hold a steady tone for 5 seconds. Cadence notes how loud and how steady it is.")
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
            Text("Take a photo of the line. Cadence measures whether the letters change size from start to end.")
                .font(.body)
                .foregroundColor(.secondary)

            VStack(spacing: 8) {
                Text("“The quick brown fox jumps over the lazy dog”")
                    .font(.body.italic())
                    .padding(12)
                    .frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.1)))
                if let status = handwritingStatus {
                    InlineNotice(text: status)
                }
            }

            if isAnalyzingHandwriting {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Measuring the letters…")
                        .font(.body)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 8)
            } else {
                if app.glasses.connectionState == .connected {
                    GuardedButton(size: .giant, style: .filled(CadenceTheme.accent), action: {
                        captureHandwritingWithGlasses()
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
                        Label("Take Photo of Writing", systemImage: "camera.fill")
                    }
                }

                GuardedButton(size: .big, style: .tinted(.secondary), action: {
                    exam.measurements.handwritingMeasured = false
                    exam.advanceToTimedWalk()
                }) {
                    Text("Skip handwriting this time")
                }
            }
        }
        .card()
    }

    private func captureHandwritingWithGlasses() {
        isAnalyzingHandwriting = true
        handwritingStatus = nil
        app.glasses.capturePhoto { result in
            switch result {
            case let .success(jpeg):
                self.analyzeHandwriting(jpeg: jpeg)
            case let .failure(error):
                self.isAnalyzingHandwriting = false
                self.handwritingStatus = "Glasses camera: \(error.localizedDescription)"
            }
        }
    }

    private func analyzeHandwriting(jpeg: Data) {
        isAnalyzingHandwriting = true
        handwritingStatus = nil
        Task {
            do {
                let result = try await app.settings.api.analyzeHandwriting(jpeg: jpeg, sourceContext: .homeMotorExam)
                await MainActor.run {
                    isAnalyzingHandwriting = false
                    if result.measured, let decay = result.opencvDecayPct {
                        exam.measurements.handwritingOpencvDecayPct = decay
                        exam.measurements.handwritingMeasured = true
                        Haptics.success()
                        exam.advanceToTimedWalk()
                    } else {
                        // Stay on this step: an unreadable photo is not a result.
                        handwritingStatus = "Couldn't read enough of the line. Try another photo with the whole line in view, or skip."
                    }
                }
            } catch {
                await MainActor.run {
                    isAnalyzingHandwriting = false
                    handwritingStatus = "Couldn't reach Cadence to measure the photo. Try again, or skip this step."
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
            Text("Keep the phone in a pocket. Cadence counts your steps and notes any pauses.")
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
        let recorder = WalkTestRecorder()
        walkRecorder = recorder
        if !app.motion.isRunning {
            app.walking.setProtection(enabled: true)
            startedMotionForWalk = app.motion.isRunning
        }
        walkSinkToken = app.motion.addSink { sample in recorder.ingest(sample) }

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
        stopWalkRecording()
        let result = walkRecorder.finish()
        // Fewer than three seconds or no steps counted is not a measurement.
        let measured = result.durationSec >= 3.0 && result.stepCount > 0
        exam.measurements.walkCadenceSpm = measured ? result.cadenceSpm : 0
        exam.measurements.walkMeanFI = measured ? result.meanFreezeIndex : 0
        exam.measurements.walkFogCount = measured ? result.fogCount : 0
        exam.measurements.walkMeasured = measured

        Task {
            await exam.completeExam()
            if let record = exam.lastRecord {
                app.recordDiary(.motorCheck, detail: TaskMetricsSummary.diaryDetail(record))
            }
            Haptics.success()
        }
    }

    private func stopWalkRecording() {
        if let token = walkSinkToken {
            app.motion.removeSink(token)
            walkSinkToken = nil
        }
        if startedMotionForWalk {
            app.walking.setProtection(enabled: false)
            startedMotionForWalk = false
        }
    }

    // MARK: - Submitting

    private var submittingCard: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.5)
                .tint(CadenceTheme.accent)
            Text("Saving your motor check…")
                .font(.title3.weight(.semibold))
            Text("This only takes a moment.")
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
            IconBadge(systemName: "checkmark.seal.fill", color: CadenceTheme.calm, size: 48)
            Text("Motor check done")
                .font(.title2.weight(.bold))

            if let record = exam.lastRecord {
                VStack(spacing: 14) {
                    ForEach(TaskMetricsSummary.lines(current: record, previous: exam.previousRecord), id: \.title) { line in
                        metricRow(line)
                    }
                }
            }

            Text(exam.lastResult == nil
                 ? "Saved on your phone. It will be sent when you're back online."
                 : "Saved in your diary to share with your care team. These are measurements, not a judgement of how you are doing.")
                .font(.footnote)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            GuardedButton(size: .giant, style: .filled(CadenceTheme.calm), action: {
                dismiss()
            }) {
                Text("Done")
            }
        }
        .card()
    }

    private func metricRow(_ line: TaskMetricsSummary.Line) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: line.systemImage)
                .foregroundColor(CadenceTheme.accent)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(line.title).font(.subheadline).foregroundColor(.secondary)
                Text(line.value).font(.body.weight(.semibold))
                if let comparison = line.comparison {
                    Text(comparison).font(.footnote).foregroundColor(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private func cleanUpTimers() {
        voiceTimer?.invalidate()
        voiceTimer = nil
        walkTimer?.invalidate()
        walkTimer = nil
        stopWalkRecording()
    }
}
