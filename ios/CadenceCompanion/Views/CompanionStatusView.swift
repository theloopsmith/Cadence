import SwiftUI

public struct CompanionStatusView: View {
    @State private var fogDetector = FoGDetector()
    @StateObject private var fallAlert = FallAlertCoordinator()
    @StateObject private var motorExam = HomeMotorExamManager()
    @StateObject private var motionFeed = MotionFeed()
    @ObservedObject private var scenarioReplayer = IMUScenarioReplayer.shared
    @State private var lastFreezeIndex: Double = 0.0
    @State private var isFoGActive: Bool = false
    @State private var lastActionBanner: String = "Ready — All 7 Pipelines Active"

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header Status Card
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Circle()
                            .fill(GlassesSessionManager.shared.isConnected ? Color.green : Color.orange)
                            .frame(width: 10, height: 10)
                        Text("Meta Gen 3 AI Glasses • \(GlassesSessionManager.shared.wearState.rawValue.uppercased())")
                            .font(.headline)
                        Spacer()
                        Text(motionFeed.isRunning ? "iPhone 100 Hz" : "50–100 Hz IMU")
                            .font(.caption.monospaced())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.blue.opacity(0.15))
                            .cornerRadius(6)
                    }
                    Text("Audio Session: .playAndRecord (.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(lastActionBanner)
                        .font(.footnote.weight(.semibold))
                        .foregroundColor(.blue)
                        .padding(.top, 2)
                }
                .padding()
                .background(Color.secondary.opacity(0.10))
                .cornerRadius(12)

                // Live DSP Telemetry Card
                VStack(alignment: .leading, spacing: 10) {
                    Text("Live Edge DSP Telemetry")
                        .font(.headline)
                    HStack {
                        VStack(alignment: .leading) {
                            Text("Freeze Index (FI)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(String(format: "%.2f", lastFreezeIndex))
                                .font(.title2.bold())
                                .foregroundColor(isFoGActive ? .red : .primary)
                        }
                        Spacer()
                        VStack(alignment: .leading) {
                            Text("RAS Metronome")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(isFoGActive ? "ACTIVE (100 BPM)" : "Standby")
                                .font(.subheadline.bold())
                                .foregroundColor(isFoGActive ? .green : .secondary)
                        }
                        Spacer()
                        VStack(alignment: .leading) {
                            Text("Arming Mode")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(fogDetector.armingMode.rawValue)
                                .font(.subheadline.bold())
                        }
                    }
                }
                .padding()
                .background(Color.secondary.opacity(0.10))
                .cornerRadius(12)

                // Interactive Hackathon Demo Scenario Replay Controls
                VStack(alignment: .leading, spacing: 10) {
                    Text("Interactive Demo Scenarios & 50 Hz Replay")
                        .font(.headline)

                    Button(action: togglePhoneMotion) {
                        Label(
                            motionFeed.isRunning
                                ? "Stop iPhone Motion (CoreMotion fallback)"
                                : "Start iPhone Motion (CoreMotion fallback)",
                            systemImage: motionFeed.isRunning ? "stop.circle.fill" : "iphone"
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(motionFeed.isRunning ? .orange : .green)
                    .disabled(scenarioReplayer.isPlaying || (!motionFeed.sourceIsAvailable && !motionFeed.isRunning))

                    if scenarioReplayer.isPlaying, let scenario = scenarioReplayer.activeScenario {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                ProgressView()
                                    .padding(.trailing, 4)
                                Text("Replaying: \(scenario.rawValue)")
                                    .font(.caption.bold())
                                    .foregroundColor(.blue)
                                Spacer()
                                Text("\(Int(scenarioReplayer.progress * 100))%")
                                    .font(.caption.monospacedDigit())
                            }
                            ProgressView(value: scenarioReplayer.progress)
                                .tint(.blue)

                            Button(action: {
                                scenarioReplayer.stop()
                                AudioCueEngine.shared.stopRASMetronome()
                                lastActionBanner = "Scenario playback canceled."
                            }) {
                                Text("Stop Kinematic Playback")
                                    .font(.caption.bold())
                                    .foregroundColor(.red)
                            }
                            .padding(.top, 2)
                        }
                        .padding()
                        .background(Color.blue.opacity(0.08))
                        .cornerRadius(8)
                    }

                    // 1. FoG Kinematic Replay
                    Button(action: {
                        startKinematicReplay(.freezeOfGaitWithRecovery)
                    }) {
                        Label("▶ Live Replay: FoG Walk -> Freeze -> RAS Cue -> Recovery", systemImage: "play.circle.fill")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(scenarioReplayer.isPlaying)

                    // 2. Hard Fall Kinematic Replay
                    Button(action: {
                        startKinematicReplay(.hardFallWithImpact)
                    }) {
                        Label("▶ Live Replay: Hard Fall (Impact + Stillness -> 12s SOS)", systemImage: "play.circle.fill")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(scenarioReplayer.isPlaying)

                    // 3. Bed Roll False-Alarm Suppression Replay
                    Button(action: {
                        startKinematicReplay(.bedRollSuppression)
                    }) {
                        Label("▶ Live Replay: Bed Roll (Pitch >65° Disarmed Guard)", systemImage: "bed.double.fill")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                    .disabled(scenarioReplayer.isPlaying)

                    // Instant Fall Check-In Simulators
                    HStack(spacing: 8) {
                        Button(action: {
                            let status = fallAlert.resolveFromSpeech(
                                transcript: "I'm okay, just dropped my keys",
                                maxVocalLevelDbfs: -22.0,
                                hardwareWearStateWorn: true,
                                preImpactWearRmsG: 0.08,
                                preImpactRespPower: 2.0e-5,
                                preImpactPitchDeg: 8.0
                            )
                            lastActionBanner = "Spoken check-in resolved: \(status)"
                        }) {
                            Label("“I'm okay” (cancel)", systemImage: "checkmark.shield.fill")
                                .font(.caption.bold())
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)

                        Button(action: {
                            let status = fallAlert.resolveFromSpeech(
                                transcript: nil,
                                maxVocalLevelDbfs: -52.0,
                                hardwareWearStateWorn: true,
                                preImpactWearRmsG: 0.08,
                                preImpactRespPower: 2.0e-5,
                                preImpactPitchDeg: 8.0
                            )
                            lastActionBanner = "Silent timeout escalated: \(status)"
                        }) {
                            Label("Timeout (siren)", systemImage: "speaker.wave.3.fill")
                                .font(.caption.bold())
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                    }

                    // Guided Motor Exam
                    Button(action: {
                        Task {
                            var m = HomeMotorExamMeasurements()
                            m.voiceMeanDbfs = -26.5
                            m.voiceStabilityDb = 2.9
                            m.handwritingOpencvDecayPct = -22.0
                            m.handwritingSamDecayPct = -20.5
                            m.walkCadenceSpm = 88.0
                            m.walkMeanFI = 1.65
                            m.walkFogCount = 0
                            let summary = await motorExam.runDemoExam(measurements: m)
                            lastActionBanner = summary
                        }
                    }) {
                        Label("3. Run Guided 3-Step Home Motor Exam (Voice -> Line -> Walk)", systemImage: "waveform.path.ecg")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.indigo)
                    .disabled(motorExam.isRunning || scenarioReplayer.isPlaying)
                }
                .padding()
                .background(Color.secondary.opacity(0.10))
                .cornerRadius(12)

                if let step = motorExam.currentPrompt {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Guided Home Motor Exam")
                            .font(.headline)
                        Text(step)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        if let result = motorExam.lastResultSummary {
                            Text(result)
                                .font(.footnote.weight(.semibold))
                                .foregroundColor(.indigo)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(Color.indigo.opacity(0.10))
                    .cornerRadius(12)
                }

                if fallAlert.isAlertVisible {
                    EmergencySOSView(coordinator: fallAlert)
                        .frame(height: 320)
                        .cornerRadius(16)
                }
            }
            .padding()
        }
        .onAppear {
            AudioCueEngine.shared.configureLaunchAudioSession()
            LiveLocationProvider.shared.requestAuthorization()
            motionFeed.attach(fogDetector: fogDetector, fallDetector: fallAlert.detector)
        }
        .onChange(of: motionFeed.fallEventUUID) { uuid in
            guard let uuid else { return }
            fallAlert.beginCheckIn(eventUUID: uuid)
            lastActionBanner = "Fall detected. 12s voice check-in open."
        }
        .onChange(of: motionFeed.lastFreezeIndex) { lastFreezeIndex = $0 }
        .onChange(of: motionFeed.isFoGActive) { isFoGActive = $0 }
    }

    private func togglePhoneMotion() {
        motionFeed.attach(fogDetector: fogDetector, fallDetector: fallAlert.detector)
        let running = motionFeed.togglePhone {
            guard let loc = LiveLocationProvider.shared.currentLocation else { return nil }
            return (loc.latitude, loc.longitude, loc.horizontalAccuracyM)
        }
        lastActionBanner = running
            ? "Listening to iPhone motion at 100 Hz."
            : motionFeed.status
    }

    private func startKinematicReplay(_ scenario: IMUScenario) {
        motionFeed.stopPhone()
        motionFeed.attach(fogDetector: fogDetector, fallDetector: fallAlert.detector)
        motionFeed.beginSegment()
        lastActionBanner = "Playing \(scenario.rawValue)..."

        scenarioReplayer.playScenario(scenario, sampleRateHz: 50.0, onSample: { sample in
            _ = motionFeed.ingest(
                sample,
                latitude: 37.7749,
                longitude: -122.4194,
                horizontalAccuracyM: 5.0
            )
        }, onCompletion: {
            DispatchQueue.main.async {
                self.lastActionBanner = "Scenario \(scenario.rawValue) finished."
            }
        })
    }
}

/// Owns the phone motion source and the shared sample engine. Published fields
/// are what the SwiftUI view renders; the engine itself has no UI.
@MainActor
private final class MotionFeed: ObservableObject {
    @Published var isRunning = false
    @Published var lastFreezeIndex = 0.0
    @Published var isFoGActive = false
    @Published var fallEventUUID: String?
    @Published var status = "Phone motion idle"

    private let source = PhoneMotionSource()
    private var engine: LiveEdgeEngine?

    var sourceIsAvailable: Bool { source.isAvailable }

    func attach(fogDetector: FoGDetector, fallDetector: FallDetector) {
        if engine == nil {
            engine = LiveEdgeEngine(fogDetector: fogDetector, fallDetector: fallDetector)
        }
    }

    func beginSegment() {
        engine?.beginSegment()
    }

    @discardableResult
    func ingest(
        _ sample: IMUSample,
        latitude: Double? = nil,
        longitude: Double? = nil,
        horizontalAccuracyM: Double? = nil
    ) -> LiveEdgeUpdate? {
        guard let engine else { return nil }
        let update = engine.ingest(
            sample,
            latitude: latitude,
            longitude: longitude,
            horizontalAccuracyM: horizontalAccuracyM
        )
        apply(update)
        return update
    }

    /// Returns whether the phone stream is running after the toggle.
    @discardableResult
    func togglePhone(
        location: @escaping () -> (latitude: Double, longitude: Double, accuracy: Double)?
    ) -> Bool {
        if source.isActive {
            stopPhone()
            return false
        }
        guard engine != nil else {
            status = "Motion engine is not ready."
            return false
        }
        source.start { [weak self] sample in
            guard let self else { return }
            let loc = location()
            _ = self.ingest(
                sample,
                latitude: loc?.latitude,
                longitude: loc?.longitude,
                horizontalAccuracyM: loc?.accuracy
            )
        }
        isRunning = source.isActive
        status = isRunning
            ? "Listening to iPhone motion at 100 Hz."
            : "iPhone motion is not available on this device."
        return isRunning
    }

    func stopPhone() {
        source.stop()
        isRunning = false
        status = "Phone motion stopped."
    }

    private func apply(_ update: LiveEdgeUpdate) {
        if let freezeIndex = update.freezeIndex { lastFreezeIndex = freezeIndex }
        if let fogActive = update.fogActive { isFoGActive = fogActive }
        if let uuid = update.fallEventUUID { fallEventUUID = uuid }
    }
}
