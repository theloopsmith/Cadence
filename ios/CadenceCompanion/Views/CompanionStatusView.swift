import SwiftUI

public struct CompanionStatusView: View {
    @StateObject private var sessionManager = GlassesSessionManager()
    @StateObject private var sensorStream = SensorStreamManager()
    @StateObject private var fogDetector = FoGDetector()
    @StateObject private var fallDetector = FallDetector()
    @StateObject private var voiceMonitor = VoiceMonitor()
    @StateObject private var motorExam = HomeMotorExamManager()

    @State private var lastActionBanner: String = "Ready — All 7 Pipelines Active"

    public init() {}

    public var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Header Status Card
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Circle()
                                .fill(sessionManager.isConnected ? Color.green : Color.orange)
                                .frame(width: 10, height: 10)
                            Text("Meta Gen 3 AI Glasses • \(sessionManager.wearState.rawValue.uppercased())")
                                .font(.headline)
                            Spacer()
                            Text("100 Hz IMU")
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
                    .background(Color(.secondarySystemBackground))
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
                                Text(String(format: "%.2f", fogDetector.currentFreezeIndex))
                                    .font(.title2.bold())
                                    .foregroundColor(fogDetector.isFoGActive ? .red : .primary)
                            }
                            Spacer()
                            VStack(alignment: .leading) {
                                Text("RAS Metronome")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text(fogDetector.isFoGActive ? "ACTIVE (100 BPM)" : "Standby")
                                    .font(.subheadline.bold())
                                    .foregroundColor(fogDetector.isFoGActive ? .green : .secondary)
                            }
                            Spacer()
                            VStack(alignment: .leading) {
                                Text("Fall Stage")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text("\(fallDetector.stage)")
                                    .font(.subheadline.bold())
                            }
                        }
                    }
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(12)

                    // Interactive Hackathon Demo Scenario Replay Controls
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Interactive Demo Scenario Replay")
                            .font(.headline)

                        Button(action: triggerSimulatedFoG) {
                            Label("1. Simulate Freeze of Gait (5.5 Hz Tremor Burst -> RAS Cue)", systemImage: "metronome.fill")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.borderedProminent)

                        Button(action: triggerSimulatedFallCheckIn) {
                            Label("2. Simulate Hard Fall (3.8g Impact + 78° Posture -> 12s Check-In)", systemImage: "exclamationmark.triangle.fill")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)

                        Button(action: {
                            fallDetector.handleCheckInTranscript("I'm okay, just dropped my keys")
                            lastActionBanner = "Fall Check-In Canceled via 'I'm okay'"
                        }) {
                            Label("   ↳ Resolve Fall Check-In ('I'm okay')", systemImage: "checkmark.shield.fill")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.bordered)

                        Button(action: {
                            motorExam.startExam()
                            lastActionBanner = "Guided 3-Step Home Motor Exam Started (Step 1: Voice)"
                        }) {
                            Label("3. Start Guided 3-Step Home Motor Exam (Voice -> Writing -> Walk)", systemImage: "waveform.path.ecg")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.indigo)
                    }
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(12)

                    if fallDetector.stage == .stage3CheckInActive || fallDetector.stage == .escalatedEmergency {
                        EmergencySOSView(
                            patientName: "Arthur Pendelton",
                            onCancelFalseAlarm: {
                                fallDetector.handleCheckInTranscript("I'm okay")
                                lastActionBanner = "SOS Canceled by Patient"
                            }
                        )
                        .frame(height: 300)
                        .cornerRadius(16)
                    }
                }
                .padding()
            }
            .navigationTitle("Cadence Companion")
            .onAppear {
                sessionManager.connect()
                AudioCueEngine.shared.configureLaunchSession()
            }
        }
    }

    private func triggerSimulatedFoG() {
        fogDetector.notifyVoluntaryWalkingDetected(at: 0.0)
        // Feed 3 consecutive 0.50s hops (450 samples @ 100 Hz) dominated by 5.5 Hz freeze band
        for i in 0..<450 {
            let t = Double(i) / 100.0
            let freezeOsc = 0.65 * sin(2.0 * .pi * 5.5 * t)
            let sample = IMUSample(
                timestamp: t,
                ax: 0.05,
                ay: 0.98 + freezeOsc,
                az: 0.05,
                gx: 0.1,
                gy: 0.85,
                gz: 0.1
            )
            fogDetector.ingestSample(sample, isUserSpeaking: false)
        }
        lastActionBanner = String(
            format: "FoG Detected! Peak FI=%.2f • 100 BPM Woodblock Cue Active",
            fogDetector.currentFreezeIndex
        )
    }

    private func triggerSimulatedFallCheckIn() {
        // Pre-populate 3.0s of worn physiological motion so wear_rms_g >= 0.015g
        for i in 0..<300 {
            let t = Double(i) / 100.0
            fallDetector.ingestSample(
                IMUSample(
                    timestamp: t,
                    ax: 0.05 * sin(2.0 * .pi * 1.8 * t),
                    ay: 1.0 + 0.08 * cos(2.0 * .pi * 1.8 * t),
                    az: 0.04,
                    gx: 0.1,
                    gy: 0.2,
                    gz: 0.1
                ),
                wearState: .worn
            )
        }
        // Stage 1: Free-fall (0.2g) + Stage 2: Impact (3.8g) at t=3.10s
        fallDetector.ingestSample(
            IMUSample(timestamp: 3.05, ax: 0.1, ay: 0.1, az: 0.1, gx: 0, gy: 0, gz: 0),
            wearState: .worn
        )
        fallDetector.ingestSample(
            IMUSample(timestamp: 3.12, ax: 0.2, ay: 3.75, az: 0.4, gx: 2.5, gy: 1.8, gz: 1.2),
            wearState: .worn
        )
        // Stage 3: Post-impact horizontal stillness (pitch ~78 deg, low variance) from t=3.65s..5.80s
        for i in 365...585 {
            let t = Double(i) / 100.0
            fallDetector.ingestSample(
                IMUSample(timestamp: t, ax: 0.98, ay: 0.18, az: 0.05, gx: 0.01, gy: 0.01, gz: 0.01),
                wearState: .worn
            )
        }
        lastActionBanner = "Stage 3 Fall Confirmed! P0 SQLite Saved & 12s Voice Check-In Started"
    }
}
