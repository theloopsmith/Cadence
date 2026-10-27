import SwiftUI

public struct CompanionStatusView: View {
    @State private var fogDetector = FoGDetector()
    @StateObject private var fallAlert = FallAlertCoordinator()
    @StateObject private var motorExam = HomeMotorExamManager()
    @ObservedObject private var scenarioReplayer = IMUScenarioReplayer.shared
    @State private var liveWindow: [IMUSample] = []
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
                        Text("50–100 Hz IMU")
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
        }
    }

    private func triggerSimulatedFoG() {
        // Build a 128-sample window @ 50 Hz (2.56s) dominated by 5.5 Hz freeze band
        var window: [IMUSample] = []
        let fs = 50.0
        for i in 0..<128 {
            let t = Double(i) / fs
            let freezeOsc = 0.70 * sin(2.0 * .pi * 5.5 * t)
            window.append(
                IMUSample(
                    timestamp: t,
                    ax: 0.02,
                    ay: 1.0 + freezeOsc,
                    az: 0.15 * cos(2.0 * .pi * 5.5 * t),
                    gx: 0.1,
                    gy: 0.8,
                    gz: 0.1,
                    pitchDeg: 5.0,
                    rollDeg: 2.0
                )
            )
        }
        let spectral = fogDetector.computeSpectralMetrics(window: window, sampledHz: fs)
        // Arm via upright turn and evaluate 3 consecutive 0.50s hops (1.50s)
        for _ in 0..<3 {
            isFoGActive = fogDetector.evaluateHop(
                locomotorBandPower: max(0.03, spectral.locomotorBandPower),
                freezeBandPower: max(0.18, spectral.freezeBandPower),
                integratedYaw15sDeg: 55.0,
                pitchDeg: 6.0,
                rollDeg: 3.0,
                sitToStandDetected: false,
                isUserSpeaking: false,
                sampledHz: fs
            )
        }
        lastFreezeIndex = max(spectral.freezeIndex, 0.18 / 0.03)
        lastActionBanner = String(
            format: "FoG Detected! Peak FI=%.2f • 100 BPM Woodblock Cue Active",
            lastFreezeIndex
        )
    }

    private func triggerSimulatedFallCheckIn() {
        let detector = fallAlert.detector
        // Stage 1: Free-fall (<0.45g) at t=1.00s
        _ = detector.processIMUSample(
            IMUSample(timestamp: 1.00, ax: 0.1, ay: 0.1, az: 0.1, gx: 0, gy: 0, gz: 0, pitchDeg: 4.0, rollDeg: 2.0)
        )
        // Stage 2: Hard impact (>2.8g, jerk >35g/s) at t=1.10s
        _ = detector.processIMUSample(
            IMUSample(timestamp: 1.10, ax: 0.2, ay: 3.85, az: 0.3, gx: 3.0, gy: 2.0, gz: 1.0, pitchDeg: 25.0, rollDeg: 10.0)
        )
        // Stage 3: Post-impact horizontal stillness (pitch ~76 deg, low dynamic energy) at t=1.80s
        let eventUUID = detector.processIMUSample(
            IMUSample(timestamp: 1.80, ax: 0.98, ay: 0.15, az: 0.05, gx: 0.01, gy: 0.01, gz: 0.01, pitchDeg: 76.0, rollDeg: 4.0),
            latitude: 37.7749,
            longitude: -122.4194,
            horizontalAccuracyM: 6.5
        )
        fallAlert.beginCheckIn(eventUUID: eventUUID ?? UUID().uuidString)
        lastActionBanner = "Stage 3 fall confirmed. Local row saved; 12s voice check-in open."
    }

    private func startKinematicReplay(_ scenario: IMUScenario) {
        liveWindow.removeAll()
        lastActionBanner = "Playing \(scenario.rawValue)..."
        var sampleCount = 0

        scenarioReplayer.playScenario(scenario, sampleRateHz: 50.0, onSample: { sample in
            sampleCount += 1
            liveWindow.append(sample)
            if liveWindow.count > 128 {
                liveWindow.removeFirst()
            }

            switch scenario {
            case .freezeOfGaitWithRecovery:
                if liveWindow.count == 128 && sampleCount % 25 == 0 {
                    let spectral = fogDetector.computeSpectralMetrics(window: liveWindow, sampledHz: 50.0)
                    let active = fogDetector.evaluateHop(
                        locomotorBandPower: spectral.locomotorBandPower,
                        freezeBandPower: spectral.freezeBandPower,
                        integratedYaw15sDeg: 0.0,
                        pitchDeg: sample.pitchDeg,
                        rollDeg: sample.rollDeg,
                        sitToStandDetected: false,
                        isUserSpeaking: false,
                        sampledHz: 50.0
                    )
                    DispatchQueue.main.async {
                        self.isFoGActive = active
                        self.lastFreezeIndex = spectral.freezeIndex
                    }
                }

            case .hardFallWithImpact:
                if let eventUUID = fallAlert.detector.processIMUSample(
                    sample,
                    latitude: 37.7749,
                    longitude: -122.4194,
                    horizontalAccuracyM: 5.0
                ) {
                    DispatchQueue.main.async {
                        self.fallAlert.beginCheckIn(eventUUID: eventUUID)
                        self.lastActionBanner = "Stage 3 fall detected via replay. 12s voice check-in open."
                    }
                }

            case .bedRollSuppression:
                if liveWindow.count == 128 && sampleCount % 25 == 0 {
                    let spectral = fogDetector.computeSpectralMetrics(window: liveWindow, sampledHz: 50.0)
                    _ = fogDetector.evaluateHop(
                        locomotorBandPower: spectral.locomotorBandPower,
                        freezeBandPower: spectral.freezeBandPower,
                        integratedYaw15sDeg: 55.0,
                        pitchDeg: sample.pitchDeg,
                        rollDeg: sample.rollDeg,
                        sitToStandDetected: false,
                        isUserSpeaking: false,
                        sampledHz: 50.0
                    )
                }

            case .sitToStandInitiation:
                break
            }
        }, onCompletion: {
            DispatchQueue.main.async {
                self.lastActionBanner = "Scenario \(scenario.rawValue) finished."
            }
        })
    }
}
