import SwiftUI
import AVFoundation
#if canImport(UIKit)
import UIKit
#endif

/// Guided 3-step motor check (voice, handwriting, timed walk). Shows the raw
/// measurements and how they compare with the previous check. No scores.
public struct MotorExamView: View {
    @ObservedObject var app: CadenceAppModel
    @ObservedObject private var exam: HomeMotorExamManager
    @Environment(\.dismiss) private var dismiss

    @Environment(\.scenePhase) private var scenePhase
    @State private var hasEntered = false
    @State private var measurementID = UUID()
    @State private var narrationID = UUID()
    @State private var narrationTask: Task<Void, Never>?
    @State private var measurementTask: Task<Void, Never>?
    @State private var analysisTask: Task<Void, Never>?
    @State private var isPreparingMeasurement = false
    @State private var voiceFlowID = UUID()
    @State private var voiceSecondsRemaining: Int = 5
    @State private var isVoiceCountingDown = false
    @State private var voiceTimer: Timer?
    @State private var voiceErrorMessage: String?

    @State private var walkSecondsRemaining: Int = 10
    @State private var isWalkCountingDown = false
    @State private var walkTimer: Timer?
    @State private var walkRecorder = WalkTestRecorder()
    @State private var walkSinkToken: UUID?
    @State private var startedMotionForWalk = false
    @State private var walkErrorMessage: String?

    @State private var automaticVoiceCapture = false
    @State private var showGlassesCamera = false
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
            .onAppear {
                app.companion.enterFlow(id: voiceFlowID, destination: .motor, step: voiceStep)
                if !hasEntered { hasEntered = true; announceStep() }
            }
            .onChange(of: isVoiceCountingDown) { _ in app.companion.updateFlow(id: voiceFlowID, step: voiceStep) }
            .onChange(of: isWalkCountingDown) { _ in app.companion.updateFlow(id: voiceFlowID, step: voiceStep) }
            .onChange(of: isAnalyzingHandwriting) { _ in app.companion.updateFlow(id: voiceFlowID, step: voiceStep) }
            .onChange(of: app.companion.actionID) { _ in handleVoiceAction() }
            .onChange(of: exam.currentStep) { step in
                app.companion.updateFlow(id: voiceFlowID, step: voiceStep)
                app.companion.setPaused("Voice measurement", false)
                announceStep()
            }
            .onChange(of: scenePhase) { phase in
                if phase == .background {
                    cleanUpTimers()
                    voiceErrorMessage = "The check paused while Cadence was in the background. Start this step again, or skip."
                    walkErrorMessage = voiceErrorMessage
                }
            }
            .onDisappear {
                // Presenting a handwriting camera must not cancel its parent exam.
                guard !showGlassesCamera, !showCamera else { return }
                app.glasses.cancelPhotoCapture(); cleanUpTimers()
                if exam.isRunning { exam.cancelExam() }
                app.companion.leaveFlow(id: voiceFlowID)
                app.companion.setPaused("Voice measurement", false)
            }
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
            .sheet(isPresented: $showGlassesCamera) {
                GlassesCameraView(glasses: app.glasses, voice: app.companion, captureWhenReady: automaticVoiceCapture, title: "Handwriting photo") { jpeg in
                    analyzeHandwriting(jpeg: jpeg)
                }
            }
            .cameraPresentation(
                isPresented: $showCamera,
                onCapture: { jpeg in
                    showCamera = false
                    analyzeHandwriting(jpeg: jpeg)
                },
                onCancel: { showCamera = false }
            )
        }
    }

    // MARK: - Progress bar

    private var voiceStep: CompanionStep {
        switch exam.currentStep {
        case .idle: return .motorIntro
        case .task1PromptedVoice: return isVoiceCountingDown ? .motorRecording : .motorVoiceReady
        case .task2PromptedHandwriting: return isAnalyzingHandwriting ? .analyzing : .handwriting
        case .task3PromptedTimedWalk: return isWalkCountingDown ? .walking : .walkReady
        case .submitting: return .analyzing
        case .completed: return .completed
        }
    }

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
            Text("Guided Motor Check")
                .font(.title2.weight(.bold))
            Text("Three short tasks: your voice, your handwriting, and a short walk. Cadence keeps the measurements in your diary so you can share how they change over time with your care team.")
                .font(.body)
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                stepRow(number: "1", title: "Voice", subtitle: "Say “Ahhh” steadily for 5 seconds")
                stepRow(number: "2", title: "Handwriting", subtitle: "Write a sentence, then photograph it")
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
            Text("Use a comfortable breath and say “Ahhh” steadily")
                .font(.title3.weight(.semibold))
            Text("Hold a steady tone for 5 seconds. Cadence notes how loud and how steady it is.")
                .font(.body)
                .foregroundColor(.secondary)

            if let error = voiceErrorMessage {
                InlineNotice(text: error, color: CadenceTheme.caution, systemName: "exclamationmark.triangle.fill")
            }

            VStack(spacing: 12) {
                Text("\(voiceSecondsRemaining)")
                    .font(.system(size: 64, weight: .bold, design: .rounded))
                    .foregroundColor(isVoiceCountingDown ? CadenceTheme.accent : .secondary)
                Text(isPreparingMeasurement ? "Preparing… wait for the spoken cue" : (isVoiceCountingDown ? "Listening…" : "Say ready, or tap Start"))
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
                Button("Skip voice this time") {
                    cleanUpTimers()
                    voiceErrorMessage = nil
                    exam.skipVoice()
                }
            } else {
                GuardedButton(size: .big, style: .tinted(.secondary), action: {
                    cleanUpTimers()
                    voiceErrorMessage = nil
                    exam.skipVoice()
                }) {
                    Text("Skip voice this time")
                }
            }
        }
        .card()
    }

    private func handleVoiceAction() {
        guard app.companion.actionContext == .motor else { return }
        let action = app.companion.action
        if action == .repeatPrompt { announceStep(); return }
        if action == .cancel { cleanUpTimers(); exam.cancelExam(); dismiss(); return }
        switch (exam.currentStep, action) {
        case (.idle, .start):
            startVoiceStep()

        case (.task1PromptedVoice, .start): if !isVoiceCountingDown { beginVoiceCountdown() }
        case (.task1PromptedVoice, .skip):
            cleanUpTimers()
            voiceErrorMessage = nil
            exam.skipVoice()
        case (.task2PromptedHandwriting, .capture), (.task2PromptedHandwriting, .start), (.task2PromptedHandwriting, .retry): automaticVoiceCapture = true; showGlassesCamera = true
        case (.task2PromptedHandwriting, .skip): analysisTask?.cancel(); isAnalyzingHandwriting = false; exam.skipHandwriting()
        case (.task3PromptedTimedWalk, .start): if !isWalkCountingDown { beginWalkCountdown() }
        case (.task3PromptedTimedWalk, .skip):
            cleanUpTimers()
            walkErrorMessage = nil
            exam.skipTimedWalk()
            saveExam()
        case (.task3PromptedTimedWalk, .finish): if isWalkCountingDown { finishWalkTest() }
        case (.completed, .finish): dismiss()
        default: app.companion.say("You can say ready, skip this step, or cancel.")
        }
    }

    private func startVoiceStep() {
        voiceSecondsRemaining = 5
        isVoiceCountingDown = false
        voiceErrorMessage = nil
        handwritingStatus = nil
        isAnalyzingHandwriting = false
        exam.startExam()
    }

    private func beginVoiceCountdown() {
        voiceErrorMessage = nil
        isVoiceCountingDown = true
        voiceSecondsRemaining = 5
        let startingSession = exam.examSessionID
        narrationID = UUID()
        let previousNarration = narrationTask
        previousNarration?.cancel()
        measurementTask?.cancel()
        isPreparingMeasurement = true
        let operation = UUID(); measurementID = operation
        measurementTask = Task { @MainActor in
            await previousNarration?.value
            guard !Task.isCancelled else { return }
            await app.companion.releaseMicrophone(for: "Voice measurement")
            app.companion.setPaused("Motor narration", false)
            let permitted = await AVCaptureDevice.requestAccess(for: .audio)
            guard measurementID == operation, exam.examSessionID == startingSession else { return }
            guard !Task.isCancelled, permitted else {
                isVoiceCountingDown = false; isPreparingMeasurement = false
                voiceErrorMessage = "Microphone access is required. Allow it in iPhone Settings, or skip voice."
                app.companion.setPaused("Voice measurement", false)
                return
            }
            exam.voiceMonitor.startLiveMonitoring()
            guard exam.voiceMonitor.isMonitoring else {
                isVoiceCountingDown = false; isPreparingMeasurement = false
                voiceErrorMessage = "The microphone could not start. Check the audio connection, retry, or skip."
                app.companion.setPaused("Voice measurement", false)
                return
            }
            // Settle the input route before the cue. The tap is live, but
            // phonation samples are not collected until narration is finished.
            do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
            guard measurementID == operation, !Task.isCancelled else { return }
            let spoken = await AudioCueEngine.shared.narrateMotorInstruction("Hold a steady ah after I say begin. Begin.")
            guard measurementID == operation, exam.examSessionID == startingSession else { return }
            guard !Task.isCancelled, spoken else {
                exam.voiceMonitor.stopLiveMonitoring()
                isVoiceCountingDown = false; isPreparingMeasurement = false
                voiceErrorMessage = "The start cue was interrupted. Start voice again when ready, or skip."
                app.companion.setPaused("Voice measurement", false)
                return
            }
            guard exam.examSessionID == startingSession, exam.currentStep == .task1PromptedVoice else {
                app.companion.setPaused("Voice measurement", false); return
            }
            isPreparingMeasurement = false
            exam.voiceMonitor.startVowelPhonationRecording()
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            let session = exam.examSessionID

            voiceTimer = Timer(timeInterval: 0.1, repeats: true) { timer in
                Task { @MainActor in
                    guard exam.examSessionID == session, exam.currentStep == .task1PromptedVoice else { timer.invalidate(); return }
                    if ProcessInfo.processInfo.systemUptime < deadline {
                        voiceSecondsRemaining = max(1, Int(ceil(deadline - ProcessInfo.processInfo.systemUptime)))
                    } else {
                        timer.invalidate()
                        voiceTimer = nil
                        isVoiceCountingDown = false
                        voiceErrorMessage = nil
                        if exam.finishVoiceMeasurement() {
                            Haptics.success()
                        } else {
                            voiceErrorMessage = "There was not enough steady voice to measure. Try a comfortable ah again, or skip this step."
                            app.companion.setPaused("Voice measurement", false)
                            app.companion.say(voiceErrorMessage!)
                        }
                    }
                }
            }
            if let voiceTimer { RunLoop.main.add(voiceTimer, forMode: .common) }
        }
    }

    // MARK: - Step 2: Handwriting

    private var handwritingTaskCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            StatusPill(text: "Step 2 of 3: Handwriting", color: CadenceTheme.accent, filled: true)
            Text("Write the sentence on paper")
                .font(.title3.weight(.semibold))
            Text("Take a photo of the line. Cadence measures whether the letters change size from start to end.")
                .font(.body)
                .foregroundColor(.secondary)

            VStack(spacing: 8) {
                Text("“\(MotorExamGuidance.writingSentence)”")
                    .font(.body.italic())
                    .padding(12)
                    .frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.1)))
                if let status = handwritingStatus {
                    InlineNotice(text: status)
                }
            }

            Button("Hear the sentence slowly again") { announceStep() }
                .disabled(isAnalyzingHandwriting)

            if isAnalyzingHandwriting {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Measuring the letters…")
                        .font(.body)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 8)
            } else {
                if app.glasses.canCapturePhoto {
                    GuardedButton(size: .giant, style: .filled(CadenceTheme.accent), action: {
                        narrationTask?.cancel()
                        automaticVoiceCapture = false
                        showGlassesCamera = true
                    }) {
                        Label("Open glasses camera", systemImage: "eyeglasses")
                    }

                    Button("Or use phone camera") {
                        narrationTask?.cancel()
                        showCamera = true
                    }
                    .font(.footnote)
                    .foregroundColor(.secondary)
                } else {
                    GuardedButton(size: .giant, style: .filled(CadenceTheme.accent), action: {
                        app.glasses.connect()
                        handwritingStatus = "Connect Meta glasses, then take a photo of your writing."
                    }) {
                        Label("Connect Meta Glasses", systemImage: "eyeglasses")
                    }
                }

                if !app.glasses.canCapturePhoto {
                    Button("Use iPhone camera instead") { narrationTask?.cancel(); showCamera = true }
                }
                GuardedButton(size: .big, style: .tinted(.secondary), action: {
                    exam.skipHandwriting()
                }) {
                    Text("Skip handwriting this time")
                }
            }
        }
        .card()
    }

    private func analyzeHandwriting(jpeg: Data) {
        guard exam.currentStep == .task2PromptedHandwriting else { return }
        let session = exam.examSessionID
        isAnalyzingHandwriting = true
        handwritingStatus = nil
        analysisTask?.cancel()
        analysisTask = Task {
            do {
                let result = try await app.settings.api.analyzeHandwriting(jpeg: jpeg, sourceContext: .homeMotorExam)
                await MainActor.run {
                    guard !Task.isCancelled, exam.examSessionID == session, exam.currentStep == .task2PromptedHandwriting else { return }
                    isAnalyzingHandwriting = false
                    if result.measured, let decay = result.opencvDecayPct {
                        exam.measurements.handwritingOpencvDecayPct = decay
                        exam.measurements.handwritingSamDecayPct = result.sam31DecayPct
                        exam.measurements.handwritingMeasured = true
                        Haptics.success()
                        exam.advanceToTimedWalk()
                    } else {
                        // Stay on this step: an unreadable photo is not a result.
                        handwritingStatus = "Couldn't read enough of the line. Try another photo with the whole line in view, or skip."
                        app.companion.say(handwritingStatus!)
                    }
                }
            } catch {
                await MainActor.run {
                    guard !Task.isCancelled, exam.examSessionID == session, exam.currentStep == .task2PromptedHandwriting else { return }
                    isAnalyzingHandwriting = false
                    handwritingStatus = "Couldn't reach Cadence to measure the photo. Try again, or skip this step."
                    app.companion.say(handwritingStatus!)
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

            if let error = walkErrorMessage {
                InlineNotice(text: error, color: CadenceTheme.caution, systemName: "exclamationmark.triangle.fill")
            }

            VStack(spacing: 12) {
                Text("\(walkSecondsRemaining)")
                    .font(.system(size: 64, weight: .bold, design: .rounded))
                    .foregroundColor(isWalkCountingDown ? CadenceTheme.accent : .secondary)
                Text(isPreparingMeasurement ? "Preparing… wait for the spoken cue" : (isWalkCountingDown ? "Walking… stop if uncomfortable" : "Say ready, or tap Start when ready"))
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
                Button("Skip walk and save") {
                    cleanUpTimers()
                    walkErrorMessage = nil
                    exam.skipTimedWalk()
                    saveExam()
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
        walkErrorMessage = nil
        isWalkCountingDown = true
        walkSecondsRemaining = 10
        narrationID = UUID()
        let previousNarration = narrationTask
        previousNarration?.cancel()
        measurementTask?.cancel()
        isPreparingMeasurement = true
        let startingSession = exam.examSessionID
        let operation = UUID(); measurementID = operation
        measurementTask = Task { @MainActor in
            await previousNarration?.value
            guard !Task.isCancelled else { return }
            await app.companion.releaseMicrophone(for: "Motor narration")
            let spoken = await AudioCueEngine.shared.narrateMotorInstruction("Walk at your usual comfortable pace for ten seconds. Begin.")
            guard measurementID == operation else { return }
            app.companion.setPaused("Motor narration", false)
            isPreparingMeasurement = false
            guard !Task.isCancelled, spoken, exam.examSessionID == startingSession,
                  exam.currentStep == .task3PromptedTimedWalk else {
                isWalkCountingDown = false
                walkErrorMessage = "The start cue was interrupted. Start walking again when ready, or skip."
                return
            }
            let recorder = WalkTestRecorder()
            walkRecorder = recorder
            if !app.motion.isRunning {
                app.walking.setProtection(enabled: true)
                startedMotionForWalk = app.motion.isRunning
            }
            guard app.motion.isRunning else {
                isWalkCountingDown = false
                walkErrorMessage = "Motion recording could not start. Check motion permissions, retry, or skip walking."
                return
            }
            walkSinkToken = app.motion.addSink { sample in recorder.ingest(sample) }

            let session = exam.examSessionID
            let deadline = ProcessInfo.processInfo.systemUptime + 10
            walkTimer = Timer(timeInterval: 0.1, repeats: true) { timer in
                Task { @MainActor in
                    guard exam.examSessionID == session, exam.currentStep == .task3PromptedTimedWalk else { timer.invalidate(); return }
                    if ProcessInfo.processInfo.systemUptime < deadline {
                        walkSecondsRemaining = max(1, Int(ceil(deadline - ProcessInfo.processInfo.systemUptime)))
                    } else {
                        finishWalkTest()
                    }
                }
            }
            if let walkTimer { RunLoop.main.add(walkTimer, forMode: .common) }
        }
    }

    private func finishWalkTest() {
        cleanUpTimers()
        isWalkCountingDown = false
        stopWalkRecording()
        walkErrorMessage = nil
        let result = walkRecorder.finish()
        // A sparse/interrupted stream is not a zero-valued walking result.
        let measured = walkRecorder.hasUsableRecording
        exam.measurements.walkCadenceSpm = measured ? result.cadenceSpm : 0
        exam.measurements.walkMeanFI = measured ? result.meanFreezeIndex : 0
        exam.measurements.walkFogCount = measured ? result.fogCount : 0
        exam.measurements.walkMeasured = measured

        guard measured else {
            walkErrorMessage = "There was not enough continuous motion data to measure this walk. Try again if comfortable, or skip and save."
            announceStep()
            return
        }
        saveExam()
    }

    private func saveExam() {
        let session = exam.examSessionID
        Task {
            await exam.completeExam()
            guard exam.examSessionID == session, exam.currentStep == .completed else { return }
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

            if let warning = exam.historyPersistenceWarning { InlineNotice(text: warning, color: CadenceTheme.caution, systemName: "exclamationmark.triangle.fill") }
            Text(exam.lastResultSummary ?? "No result was saved. Please try again.")
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

    private func announceStep() {
        guard !isAnalyzingHandwriting else { return }
        let previousNarration = narrationTask
        previousNarration?.cancel()
        let id = UUID(); narrationID = id
        let session = exam.examSessionID
        let step = exam.currentStep
        narrationTask = Task { @MainActor in
            await previousNarration?.value
            guard !Task.isCancelled, narrationID == id else { return }
            await app.companion.releaseMicrophone(for: "Motor narration")
            defer { if narrationID == id { app.companion.setPaused("Motor narration", false) } }
            let audio = AudioCueEngine.shared
            switch step {
            case .idle:
                _ = await audio.narrateMotorInstruction("This check has three tasks: voice, handwriting, and walking. You can skip any task. Say start when ready.")
            case .task1PromptedVoice:
                _ = await audio.narrateMotorInstruction(MotorExamGuidance.voiceReady)
            case .task2PromptedHandwriting:
                guard await audio.narrateMotorInstruction(MotorExamGuidance.writingIntro) else { return }
                for chunk in MotorExamGuidance.writingChunks {
                    guard !Task.isCancelled, exam.examSessionID == session, exam.currentStep == step,
                          await audio.narrateMotorInstruction(chunk, slowly: true) else { return }
                    do { try await Task.sleep(nanoseconds: 6_000_000_000) } catch { return }
                }
                _ = await audio.narrateMotorInstruction(MotorExamGuidance.writingFinish)
            case .task3PromptedTimedWalk:
                _ = await audio.narrateMotorInstruction(MotorExamGuidance.walkReady)
            case .completed:
                _ = await audio.narrateMotorInstruction((exam.lastResultSummary ?? "Your check is finished.") + " Say done to close.")
            case .submitting: break
            }
        }
    }

    private func cleanUpTimers() {
        measurementID = UUID()
        narrationID = UUID()
        narrationTask?.cancel(); measurementTask?.cancel(); analysisTask?.cancel()
        AudioCueEngine.shared.cancelNonEmergencySpeech()
        isPreparingMeasurement = false
        _ = exam.voiceMonitor.stopVowelPhonationRecording()
        exam.voiceMonitor.stopLiveMonitoring()
        app.companion.setPaused("Motor narration", false)
        isAnalyzingHandwriting = false
        voiceTimer?.invalidate()
        voiceTimer = nil
        isVoiceCountingDown = false
        walkTimer?.invalidate()
        walkTimer = nil
        isWalkCountingDown = false
        stopWalkRecording()
        app.companion.setPaused("Voice measurement", false)
    }
}
