import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

extension Color {
    fileprivate static var appBackground: Color {
        #if canImport(UIKit)
        return Color(uiColor: .systemGroupedBackground)
        #else
        return Color.secondary.opacity(0.06)
        #endif
    }

    fileprivate static var cardBackground: Color {
        #if canImport(UIKit)
        return Color(uiColor: .secondarySystemGroupedBackground)
        #else
        return Color.secondary.opacity(0.12)
        #endif
    }
}

public struct CompanionStatusView: View {
    @State private var fogDetector = FoGDetector()
    @StateObject private var fallAlert = FallAlertCoordinator()
    @StateObject private var motorExam = HomeMotorExamManager()
    @StateObject private var motionFeed = MotionFeed()
    @ObservedObject private var scenarioReplayer = IMUScenarioReplayer.shared
    @State private var lastFreezeIndex: Double = 0.0
    @State private var isFoGActive: Bool = false
    @State private var lastActionBanner: String = "Ready — All 7 edge pipelines active"
    @State private var isMetronomePulsing: Bool = false

    public init() {}

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // 1. Meta Glasses Hardware Card
                    glassesConnectionCard

                    // 2. Live Edge DSP & Metronome Hero Card
                    liveDSPHeroCard

                    // 3. Audio & Haptics Quick Verification Pill
                    audioQuickTestCard

                    // 4. Interactive Scenarios Hub
                    interactiveScenariosSection

                    // 5. Guided Motor Exam Active View
                    if let step = motorExam.currentPrompt {
                        motorExamCard(step: step)
                    }

                    // 6. Emergency Fall Overlay View
                    if fallAlert.isAlertVisible {
                        EmergencySOSView(coordinator: fallAlert)
                            .frame(height: 340)
                            .cornerRadius(20)
                            .shadow(color: .red.opacity(0.3), radius: 10, y: 4)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(Color.appBackground)
            .navigationTitle("Cadence")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 6) {
                        Image(systemName: "waveform.path.ecg")
                            .foregroundColor(.blue)
                        Text("Cadence")
                            .font(.headline.weight(.bold))
                        Text("• Companion")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
                #endif
                ToolbarItem(placement: .automatic) {
                    Button(action: {
                        AudioCueEngine.shared.playAudioTest()
                        lastActionBanner = "Audio test played: 100 BPM clicks + speech prompt"
                    }) {
                        Label("Test Sound", systemImage: "speaker.wave.2.fill")
                            .font(.caption.bold())
                    }
                }
            }
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
        .onChange(of: motionFeed.isFoGActive) {
            isFoGActive = $0
            if isFoGActive {
                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                    isMetronomePulsing = true
                }
            } else {
                isMetronomePulsing = false
            }
        }
    }

    // MARK: - Subviews

    /// Top Glasses & Telemetry Status Card
    private var glassesConnectionCard: some View {
        VStack(spacing: 10) {
            HStack(alignment: .center) {
                Image(systemName: "eyeglasses")
                    .font(.title2)
                    .foregroundColor(.blue)
                    .frame(width: 36, height: 36)
                    .background(Color.blue.opacity(0.12))
                    .clipShape(Circle())

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("Meta Gen 3 AI Glasses")
                            .font(.subheadline.bold())
                        Circle()
                            .fill(GlassesSessionManager.shared.isConnected ? Color.green : Color.orange)
                            .frame(width: 8, height: 8)
                    }
                    Text("Wear State: \(GlassesSessionManager.shared.wearState.rawValue.capitalized) • Bluetooth Low-Latency")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(motionFeed.isRunning ? "100 Hz Phone" : "50–100 Hz IMU")
                        .font(.caption2.bold())
                        .foregroundColor(.blue)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.blue.opacity(0.12))
                        .cornerRadius(6)
                    Text("< 50ms Edge DSP")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            Divider()

            HStack {
                Image(systemName: "info.circle.fill")
                    .font(.caption)
                    .foregroundColor(.blue)
                Text(lastActionBanner)
                    .font(.caption.weight(.medium))
                    .foregroundColor(.primary)
                    .lineLimit(2)
                Spacer()
            }
        }
        .padding(14)
        .background(Color.cardBackground)
        .cornerRadius(16)
        .shadow(color: Color.black.opacity(0.04), radius: 6, y: 2)
    }

    private func computeMeterWidth(totalWidth: CGFloat) -> CGFloat {
        let clamped = min(max(lastFreezeIndex, 0.0), 4.0)
        let ratio = CGFloat(clamped / 4.0)
        return min(totalWidth, max(4.0, totalWidth * ratio))
    }

    private var meterColor: Color {
        if isFoGActive { return .red }
        if lastFreezeIndex > 1.2 { return .orange }
        return .blue
    }

    /// Live Edge DSP Telemetry Hero Card
    private var liveDSPHeroCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("REAL-TIME EDGE DSP")
                        .font(.caption2.weight(.heavy))
                        .foregroundColor(isFoGActive ? .red : .blue)
                        .tracking(1.0)
                    Text("Locomotor & Freeze Band")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                Spacer()

                // Arming Mode Pill
                HStack(spacing: 4) {
                    Circle()
                        .fill(isFoGActive ? Color.red : Color.green)
                        .frame(width: 6, height: 6)
                    Text(fogDetector.armingMode.rawValue.uppercased())
                        .font(.caption2.weight(.bold))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(isFoGActive ? Color.red.opacity(0.15) : Color.green.opacity(0.15))
                .foregroundColor(isFoGActive ? .red : .green)
                .cornerRadius(12)
            }

            // Metronome State & Freeze Index Meter
            HStack(spacing: 16) {
                // Freeze Index Metric
                VStack(alignment: .leading, spacing: 4) {
                    Text("Freeze Index (FI)")
                        .font(.caption.weight(.medium))
                        .foregroundColor(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(String(format: "%.2f", lastFreezeIndex))
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                            .foregroundColor(isFoGActive ? .red : (lastFreezeIndex > 1.2 ? .orange : .primary))
                        Text(lastFreezeIndex > 2.0 ? "FREEZE" : "NORMAL")
                            .font(.caption2.bold())
                            .foregroundColor(isFoGActive ? .red : .secondary)
                    }

                    // Progress Bar
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.secondary.opacity(0.2))
                                .frame(height: 6)
                            Capsule()
                                .fill(meterColor)
                                .frame(width: computeMeterWidth(totalWidth: geo.size.width), height: 6)
                        }
                    }
                    .frame(height: 6)
                }
                .frame(maxWidth: .infinity)

                Divider()
                    .frame(height: 50)

                // Metronome Cadence Visual
                VStack(spacing: 6) {
                    ZStack {
                        Circle()
                            .stroke(isFoGActive ? Color.red.opacity(0.3) : Color.secondary.opacity(0.2), lineWidth: 4)
                            .frame(width: 44, height: 44)

                        if isFoGActive {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 32, height: 32)
                                .scaleEffect(isMetronomePulsing ? 1.2 : 0.9)
                            Image(systemName: "metronome.fill")
                                .font(.caption.bold())
                                .foregroundColor(.white)
                        } else {
                            Image(systemName: "metronome")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }

                    Text(isFoGActive ? "100 BPM CUE" : "RAS Standby")
                        .font(.caption2.bold())
                        .foregroundColor(isFoGActive ? .red : .secondary)
                }
                .frame(width: 90)
            }

            if isFoGActive {
                HStack {
                    Image(systemName: "speaker.wave.3.fill")
                        .foregroundColor(.red)
                    Text("Acoustic cueing active: Woodblock clicks at 1.67 Hz entraining gait.")
                        .font(.caption)
                        .foregroundColor(.red)
                    Spacer()
                    Button(action: {
                        AudioCueEngine.shared.stopRASMetronome()
                        isFoGActive = false
                    }) {
                        Text("Stop")
                            .font(.caption2.bold())
                            .foregroundColor(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Color.red)
                            .cornerRadius(6)
                    }
                }
                .padding(8)
                .background(Color.red.opacity(0.10))
                .cornerRadius(8)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(isFoGActive ? Color.red.opacity(0.4) : Color.clear, lineWidth: 2)
                )
        )
        .shadow(color: isFoGActive ? Color.red.opacity(0.12) : Color.black.opacity(0.04), radius: 8, y: 2)
    }

    /// Audio Verification Button Card
    private var audioQuickTestCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.circle.fill")
                .font(.title2)
                .foregroundColor(.indigo)

            VStack(alignment: .leading, spacing: 2) {
                Text("Sound & Speech Synthesis")
                    .font(.footnote.bold())
                Text("Tap to test volume, woodblock click, and voice prompt.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button(action: {
                AudioCueEngine.shared.playAudioTest()
                lastActionBanner = "Audio test played: 100 BPM clicks + speech"
            }) {
                Text("Play Tone")
                    .font(.caption.bold())
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.indigo)
                    .foregroundColor(.white)
                    .cornerRadius(8)
            }
        }
        .padding(12)
        .background(Color.indigo.opacity(0.08))
        .cornerRadius(12)
    }

    /// Interactive Parkinson's Clinical Scenarios
    private var interactiveScenariosSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("CLINICAL DEMO SCENARIOS")
                .font(.caption2.weight(.heavy))
                .foregroundColor(.secondary)
                .tracking(1.0)
                .padding(.horizontal, 4)

            // Replayer Progress Card if active
            if scenarioReplayer.isPlaying, let scenario = scenarioReplayer.activeScenario {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("Replaying: \(scenario.rawValue)")
                            .font(.caption.bold())
                            .foregroundColor(.blue)
                        Spacer()
                        Text("\(Int(scenarioReplayer.progress * 100))%")
                            .font(.caption.monospacedDigit().bold())
                    }
                    ProgressView(value: scenarioReplayer.progress)
                        .tint(.blue)

                    Button(action: {
                        scenarioReplayer.stop()
                        AudioCueEngine.shared.stopRASMetronome()
                        lastActionBanner = "Scenario playback canceled."
                    }) {
                        Text("Stop Playback")
                            .font(.caption.bold())
                            .foregroundColor(.red)
                    }
                }
                .padding(12)
                .background(Color.blue.opacity(0.08))
                .cornerRadius(12)
            }

            // Scenario 1: Freezing of Gait
            scenarioCard(
                icon: "metronome.fill",
                iconColor: .purple,
                title: "1. Freezing of Gait (FoG) & Metronome",
                description: "5.5 Hz leg trembling triggers 100 BPM acoustic cue to break freeze.",
                primaryButtonTitle: "▶ Run 16s FoG Replay",
                primaryAction: { startKinematicReplay(.freezeOfGaitWithRecovery) },
                secondaryButtonTitle: "Instant FoG Burst",
                secondaryAction: triggerSimulatedFoG,
                isDisabled: scenarioReplayer.isPlaying
            )

            // Scenario 2: Emergency Fall
            fallScenarioCard

            // Scenario 3: Guided 3-Step Motor Exam
            scenarioCard(
                icon: "waveform.path.ecg",
                iconColor: .indigo,
                title: "3. Guided Home Motor Exam",
                description: "Voice phonation (σ_dB) • Micrographia writing • 10m Timed Walk.",
                primaryButtonTitle: "▶ Run Guided 3-Step Exam",
                primaryAction: {
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
                },
                secondaryButtonTitle: nil,
                secondaryAction: nil,
                isDisabled: motorExam.isRunning || scenarioReplayer.isPlaying
            )

            // Scenario 4: Live Motion Stream Toggle
            HStack(spacing: 12) {
                Image(systemName: "iphone.radiowaves.left.and.right")
                    .font(.title3)
                    .foregroundColor(motionFeed.isRunning ? .green : .secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text("iPhone CoreMotion Stream (100 Hz)")
                        .font(.footnote.bold())
                    Text(motionFeed.isRunning ? "Streaming live phone kinematics to DSP" : "Fallback when glasses are off")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button(action: togglePhoneMotion) {
                    Text(motionFeed.isRunning ? "Stop" : "Start")
                        .font(.caption.bold())
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(motionFeed.isRunning ? Color.orange : Color.green)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                }
                .disabled(scenarioReplayer.isPlaying)
            }
            .padding(14)
            .background(Color.cardBackground)
            .cornerRadius(14)
        }
    }

    /// Fall Protection Interactive Card
    private var fallScenarioCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "figure.fall")
                    .font(.title3)
                    .foregroundColor(.red)
                    .frame(width: 32, height: 32)
                    .background(Color.red.opacity(0.12))
                    .clipShape(Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text("2. Hard Fall Detection & SOS")
                        .font(.footnote.bold())
                    Text("Free-fall + 3.8g impact triggers 12s voice check-in.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

            // Primary replay button
            Button(action: { startKinematicReplay(.hardFallWithImpact) }) {
                HStack {
                    Spacer()
                    Image(systemName: "play.circle.fill")
                    Text("▶ Run 4s Hard Fall Replay")
                        .font(.caption.bold())
                    Spacer()
                }
                .padding(.vertical, 9)
                .background(Color.red)
                .foregroundColor(.white)
                .cornerRadius(8)
            }
            .disabled(scenarioReplayer.isPlaying)

            // Voice Check-In Response Buttons
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
                    lastActionBanner = "Spoken check-in: “I'm okay” canceled alert (\(status))"
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.shield.fill")
                        Text("Say: “I'm okay”")
                    }
                    .font(.caption2.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(Color.green.opacity(0.12))
                    .foregroundColor(.green)
                    .cornerRadius(8)
                }

                Button(action: {
                    let status = fallAlert.resolveFromSpeech(
                        transcript: nil,
                        maxVocalLevelDbfs: -52.0,
                        hardwareWearStateWorn: true,
                        preImpactWearRmsG: 0.08,
                        preImpactRespPower: 2.0e-5,
                        preImpactPitchDeg: 8.0
                    )
                    lastActionBanner = "Silent timeout escalated: siren + Twilio dispatch"
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "speaker.wave.3.fill")
                        Text("Silent Timeout")
                    }
                    .font(.caption2.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(Color.red.opacity(0.12))
                    .foregroundColor(.red)
                    .cornerRadius(8)
                }
            }
        }
        .padding(14)
        .background(Color.cardBackground)
        .cornerRadius(14)
        .shadow(color: Color.black.opacity(0.03), radius: 4, y: 2)
    }

    private func scenarioCard(
        icon: String,
        iconColor: Color,
        title: String,
        description: String,
        primaryButtonTitle: String,
        primaryAction: @escaping () -> Void,
        secondaryButtonTitle: String?,
        secondaryAction: (() -> Void)?,
        isDisabled: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundColor(iconColor)
                    .frame(width: 32, height: 32)
                    .background(iconColor.opacity(0.12))
                    .clipShape(Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.footnote.bold())
                    Text(description)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

            HStack(spacing: 8) {
                Button(action: primaryAction) {
                    Text(primaryButtonTitle)
                        .font(.caption.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(iconColor)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                }
                .disabled(isDisabled)

                if let secTitle = secondaryButtonTitle, let secAction = secondaryAction {
                    Button(action: secAction) {
                        Text(secTitle)
                            .font(.caption2.bold())
                            .padding(.horizontal, 10)
                            .padding(.vertical, 9)
                            .background(Color.secondary.opacity(0.12))
                            .foregroundColor(.primary)
                            .cornerRadius(8)
                    }
                    .disabled(isDisabled)
                }
            }
        }
        .padding(14)
        .background(Color.cardBackground)
        .cornerRadius(14)
        .shadow(color: Color.black.opacity(0.03), radius: 4, y: 2)
    }

    private func motorExamCard(step: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "stethoscope")
                    .foregroundColor(.indigo)
                Text("Active Motor Exam")
                    .font(.subheadline.bold())
                    .foregroundColor(.indigo)
                Spacer()
            }
            Text(step)
                .font(.footnote)
                .foregroundColor(.primary)
            if let result = motorExam.lastResultSummary {
                Text(result)
                    .font(.caption.bold())
                    .foregroundColor(.indigo)
            }
        }
        .padding(14)
        .background(Color.indigo.opacity(0.10))
        .cornerRadius(14)
    }

    // MARK: - Actions & Triggers

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

    private func triggerSimulatedFoG() {
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
            format: "FoG Triggered! Peak FI=%.2f • 100 BPM Woodblock Cue Active",
            lastFreezeIndex
        )
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
