import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

enum DeveloperArea: String, CaseIterable, Identifiable {
    case diagnostics = "Connection and status"
    case walking = "Walking replays"
    case calibration = "Motion calibration and recordings"
    case fall = "Safety check-in tests"
    case medication = "Medication tests"
    case camera = "Camera checks"
    case hardware = "Glasses, sound and haptics"
    case diary = "Diary test data"
    case queue = "Offline queue"
    var id: String { rawValue }
}

/// Drives every feature for testing. Visible only when the Developer switch
/// in care-partner setup is on. Nothing here is on the wearer's path.
struct DeveloperView: View {
    @ObservedObject var app: CadenceAppModel
    let area: DeveloperArea
    @StateObject private var tools: DeveloperToolsModel
    @State private var question = "Is someone sitting in that chair?"
    @State private var cameraPurpose: CameraPurpose?
    @State private var forceSimple = false
    @State private var showServerSummary = false

    enum CameraPurpose: Identifiable {
        case environment, meal
        var id: Int { hashValue }
    }

    init(app: CadenceAppModel, area: DeveloperArea) {
        self.area = area
        self.app = app
        _tools = StateObject(wrappedValue: DeveloperToolsModel(app: app))
    }

    var body: some View {
        Form {
            switch area {
            case .diagnostics: statusSection
            case .walking: walkingSection
            case .calibration: TechnicalSetupSections(app: app)
            case .fall: fallSection
            case .medication: medicationSection
            case .camera: cameraSection
            case .hardware: glassesSection; signalsSection
            case .diary: diarySection
            case .queue: queueSection
            }
        }
        .navigationTitle(area.rawValue)
        .onAppear {
            if area == .queue { tools.refreshQueue() }
        }
        .task {
            if area == .diagnostics { await tools.checkBackend() }
        }
        .onDisappear {
            if tools.isReplaying { tools.stopReplay() }
            if forceSimple { tools.setForcedSimpleMode(nil) }
            if area == .calibration { app.recorder.cancel() }
        }
        .sheet(isPresented: $showServerSummary) {
            DaySummaryView(app: app)
        }
        .sheet(item: $cameraPurpose) { purpose in
            CameraPicker(
                onCapture: { jpeg in
                    cameraPurpose = nil
                    Task {
                        switch purpose {
                        case .environment: await tools.runEnvironmentCheck(jpeg: jpeg, question: question)
                        case .meal: await tools.runMealCheck(jpeg: jpeg)
                        }
                    }
                },
                onCancel: { cameraPurpose = nil }
            )
        }
    }

    // MARK: - Status

    private var statusSection: some View {
        Section("Status") {
            row("Backend", tools.backendStatus)
            row("Protection", app.walking.isProtectionOn ? "On · \(app.motion.activeSourceLabel ?? "")" : "Off")
            row("Arming", app.motion.armingMode)
            row("Freeze index", String(format: "%.2f", app.motion.lastFreezeIndex))
            row("Calibration", app.calibration.source.rawValue)
            row("Simple mode", app.isSimpleMode ? "On" : "Off")
            if let message = tools.lastMessage {
                Text(message).font(.footnote).foregroundColor(.secondary)
            }
            Button("Check backend again") { Task { await tools.checkBackend() } }
        }
    }

    // MARK: - Walking

    private var walkingSection: some View {
        Section {
            if tools.isReplaying {
                VStack(alignment: .leading, spacing: 6) {
                    Text(tools.replayName ?? "Replaying").font(.subheadline)
                    ProgressView(value: tools.replayProgress)
                }
                Button("Stop replay", role: .destructive) { tools.stopReplay() }
            } else {
                ForEach(IMUScenario.allCases) { scenario in
                    Button(scenario.rawValue) { tools.replay(scenario) }
                }
            }
            Button(app.walking.isCueing ? "Stop the beat" : "Start the beat (audio only)") {
                if app.walking.isCueing || AudioCueEngine.shared.isMetronomeActive {
                    AudioCueEngine.shared.stopRASMetronome()
                } else {
                    AudioCueEngine.shared.startRASMetronome(bpm: 100)
                }
            }
        } header: {
            Text("Walking · replays through the real detector")
        } footer: {
            Text("Replays pause live protection. The freeze replay should cue and then stop; bed roll and sit-to-stand must not.")
        }
    }

    // MARK: - Fall

    private var fallSection: some View {
        Section {
            Button("Open a check-in (no impact)") { tools.openSimulatedCheckIn() }
                .disabled(app.fallAlert.isAlertVisible)
            Button("Hard fall replay (opens check-in)") { tools.replay(.hardFallWithImpact) }
                .disabled(tools.isReplaying || app.fallAlert.isAlertVisible)
            if app.fallAlert.isAlertVisible {
                Button("Simulate speech: “I'm okay”") { tools.simulateSpeech("I'm okay, just dropped something") }
                Button("Simulate speech: “help”") { tools.simulateSpeech("help me") }
                Button("Simulate silence") { tools.simulateSilence() }
                Button("Stand down", role: .destructive) { tools.standDownAlert() }
            }
            row("Last outcome", app.fallAlert.lastOutcome ?? "—")
            row("Wear state", app.glasses.wearState.rawValue)
        } header: {
            Text("Fall check-in")
        } footer: {
            Text("The check-in runs the real \(Int(FallAlertCoordinator.checkInWindowSec))-second window. Silence escalates and queues a caregiver event; the backend only dials when Twilio is configured.")
        }
    }

    // MARK: - Medication

    private var medicationSection: some View {
        Section {
            Button("Make a dose due now") { tools.makeDoseDueNow() }
            Button("Clear today's logged doses") { tools.clearTodaysDoses() }
            Toggle("Muse Voice Transcribe as second listener", isOn: Binding(
                get: { app.settings.cloudListeningEnabled },
                set: { app.settings.cloudListeningEnabled = $0 }
            ))
            Button("Start voice logging") { app.voiceDose.begin() }
                .disabled(app.voiceDose.state == .listening || app.voiceDose.state == .confirming)
            row("Voice state", "\(app.voiceDose.state)")
            if !app.voiceDose.lastHeard.isEmpty { row("Heard", app.voiceDose.lastHeard) }
            Toggle("Force simple mode", isOn: $forceSimple)
                .onChange(of: forceSimple) { on in tools.setForcedSimpleMode(on ? true : nil) }
        } header: {
            Text("Medication")
        }
    }

    // MARK: - Camera

    private var cameraSection: some View {
        Section {
            TextField("Question", text: $question)
            Button("Look around with Meta glasses") {
                tools.captureFromGlasses { jpeg in
                    guard let jpeg else { return }
                    Task { await tools.runEnvironmentCheck(jpeg: jpeg, question: question) }
                }
            }
            .disabled(!app.glasses.canCapturePhoto || tools.isBusy)
            Button("Use iPhone camera instead") { cameraPurpose = .environment }.disabled(tools.isBusy)
            if let result = tools.lastEnvironmentCheck {
                VStack(alignment: .leading, spacing: 4) {
                    Text(result.spokenResponse).font(.body)
                    Text("Seen: \(result.detectedLabels.isEmpty ? "nothing in the list" : result.detectedLabels.joined(separator: ", ")) · \(result.latencyMs) ms")
                        .font(.footnote).foregroundColor(.secondary)
                }
            }
            Button("Log a meal time") { Task { await tools.runMealCheck(jpeg: Data()) } }
            if tools.lastMeal != nil {
                Text("Meal time logged")
                    .font(.footnote).foregroundColor(.secondary)
            }
            if tools.isBusy { ProgressView() }
        } header: {
            Text("Camera checks")
        } footer: {
            Text("Photos go to the backend for a factual description and are not stored anywhere.")
        }
    }

    // MARK: - Glasses

    private var glassesSection: some View {
        Section("Glasses") {
            Toggle("Use mock glasses", isOn: Binding(
                get: { app.isUsingMockGlasses },
                set: { app.useMockGlasses($0) }
            ))
            if app.glasses.device != nil {
                Button(app.glasses.connectionState == .connected ? "Disconnect" : "Connect") {
                    app.glasses.connectionState == .connected ? app.glasses.disconnect() : app.glasses.connect()
                }
                if let mock = app.glasses.device as? MockGlassesDevice, app.glasses.connectionState == .connected {
                    Picker("Wear state", selection: Binding(
                        get: { app.glasses.wearState },
                        set: { mock.setWearState($0) }
                    )) {
                        Text("Worn").tag(GlassesWearState.worn)
                        Text("Not worn").tag(GlassesWearState.notWorn)
                        Text("Unknown").tag(GlassesWearState.unknown)
                    }
                }
            }
            row("Connection", "\(app.glasses.connectionState)")
            row("Motion source", app.glasses.preferredSourceLabel)
        }
    }

    // MARK: - Signals

    private var signalsSection: some View {
        Section("Sound and touch") {
            Button("Test sound") { AudioCueEngine.shared.playAudioTest() }
            Button(AudioCueEngine.shared.isSirenActive ? "Stop siren" : "Siren (loud)") {
                AudioCueEngine.shared.isSirenActive
                    ? AudioCueEngine.shared.deactivateBystanderSiren()
                    : AudioCueEngine.shared.activateBystanderSiren()
            }
            ForEach(HapticPattern.allCases, id: \.self) { pattern in
                Button("Haptic: \(pattern.rawValue)") { app.haptics.play(pattern) }
            }
        }
    }

    // MARK: - Diary

    private var diarySection: some View {
        Section("Diary") {
            Button("Write a sample day") { tools.seedSampleDay() }
            Button("Server summary (last 24 hours)") { showServerSummary = true }
            Button("Clear today", role: .destructive) { tools.clearToday() }
        }
    }

    // MARK: - Queue

    private var queueSection: some View {
        Section {
            row("Waiting to send", "\(tools.pendingEvents.count)")
            ForEach(tools.pendingEvents, id: \.eventUUID) { event in
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.endpoint).font(.footnote.monospaced())
                    Text("retries: \(event.retryCount)").font(.caption).foregroundColor(.secondary)
                }
            }
            Button("Send now") { Task { await tools.drainQueue() } }
                .disabled(tools.isBusy)
            Button("Refresh") { tools.refreshQueue() }
        } header: {
            Text("Offline queue")
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundColor(.secondary).multilineTextAlignment(.trailing)
        }
    }
}
