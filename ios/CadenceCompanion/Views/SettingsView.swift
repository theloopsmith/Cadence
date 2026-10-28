import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct SettingsView: View {
    @ObservedObject var app: CadenceAppModel
    @ObservedObject private var settings: AppSettings
    @State private var recordingLabel: GaitLabel = .walking
    @State private var showSensitivity = false

    init(app: CadenceAppModel) {
        self.app = app
        self.settings = app.settings
    }

    var body: some View {
        NavigationStack {
            Form {
                caregiverSection
                glassesSection
                calibrationSection
                recordingSection
                backendSection
                demoToolsSection
                aboutSection
            }
            .navigationTitle("Care partner setup")
        }
    }

    // MARK: - Caregiver

    private var caregiverSection: some View {
        Section {
            TextField("Caregiver's name", text: $settings.caregiverName)
            TextField("Caregiver's phone", text: $settings.caregiverPhone)
                #if os(iOS)
                .textContentType(.telephoneNumber)
                .keyboardType(.phonePad)
                #endif
            TextField("Emergency number", text: $settings.emergencyNumber)
                #if os(iOS)
                .keyboardType(.phonePad)
                #endif
        } header: {
            Text("Caregiver")
        } footer: {
            Text("Contacted only if you fall and do not answer the voice check-in.")
        }
    }

    // MARK: - Glasses

    private var glassesSection: some View {
        Section {
            if app.glasses.device == nil || app.isUsingMockGlasses {
                InlineNotice(
                    text: "Real glasses connect through the Meta AI app in Developer Mode. A mock pair can stand in so every glasses path can be tried without hardware.",
                    color: CadenceTheme.accent,
                    systemName: "info.circle.fill"
                )
            } else {
                HStack {
                    Text(app.glasses.deviceName ?? "Glasses")
                    Spacer()
                    Button(app.glasses.connectionState == .connected ? "Disconnect" : "Connect") {
                        app.glasses.connectionState == .connected ? app.glasses.disconnect() : app.glasses.connect()
                    }
                    .frame(minHeight: CadenceTheme.minimumTapHeight)
                }
                Text("Motion and photo capture from the glasses are development and beta channel features of the toolkit; the iPhone's sensors are used whenever the glasses are not connected.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            Toggle(isOn: Binding(
                get: { app.isUsingMockGlasses },
                set: { app.useMockGlasses($0) }
            )) {
                HStack {
                    Text("Use mock glasses")
                    StatusPill(text: "Mock", color: CadenceTheme.caution)
                }
            }
            .frame(minHeight: CadenceTheme.minimumTapHeight)

            if app.isUsingMockGlasses, let device = app.glasses.device as? MockGlassesDevice {
                HStack {
                    Text("Connection")
                    Spacer()
                    Button(app.glasses.connectionState == .connected ? "Disconnect" : "Connect") {
                        app.glasses.connectionState == .connected ? device.disconnect() : device.connect()
                    }
                    .frame(minHeight: CadenceTheme.minimumTapHeight)
                }
                if app.glasses.connectionState == .connected {
                    Picker("Wear state", selection: Binding(
                        get: { app.glasses.wearState },
                        set: { device.setWearState($0) }
                    )) {
                        Text("Worn").tag(GlassesWearState.worn)
                        Text("Not worn").tag(GlassesWearState.notWorn)
                        Text("Unknown").tag(GlassesWearState.unknown)
                    }
                }
            }
        } header: {
            Text("Glasses")
        } footer: {
            Text("With glasses connected, motion comes from the glasses and the fall check-in knows whether they are being worn. Otherwise the iPhone is used.")
        }
    }

    // MARK: - Calibration

    private var calibration: FoGCalibrationController { app.calibration }

    private var calibrationSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("Freeze sensing is tuned from")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Text(calibration.sourceDescription)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)

            if let problem = calibration.problem {
                InlineNotice(text: problem)
            }

            DisclosureGroup("Sensitivity details", isExpanded: $showSensitivity) {
                thresholdRow("Freeze trigger", calibration.thresholds.freezeIndexTrigger, "%.2f")
                thresholdRow("Walking resumed below", calibration.thresholds.recoveryFreezeIndex, "%.2f")
                thresholdRow("Walking floor", calibration.thresholds.locomotorArmingPower, "%.4f g²")
                thresholdRow("Stillness floor", calibration.thresholds.dynamicEnergyFloor, "%.5f g²")
                if let report = calibration.report {
                    ForEach(report.trapMargins.sorted { $0.key.rawValue < $1.key.rawValue }, id: \.key) { label, margin in
                        HStack {
                            Text("\(plain(label)) margin")
                            Spacer()
                            Text(String(format: "%.2f", margin))
                                .foregroundColor(margin > 0 ? CadenceTheme.calm : CadenceTheme.danger)
                                .monospacedDigit()
                        }
                    }
                }
            }

            Button("Re-tune now") { calibration.recalibrate() }
                .frame(minHeight: CadenceTheme.minimumTapHeight)
        } header: {
            Text("Freeze sensing")
        } footer: {
            Text("Every number comes from labeled motion clips, never from a fixed guess. Your own recordings replace the built-in reference once you have walking, a freeze, and sitting still.")
        }
    }

    private func thresholdRow(_ title: String, _ value: Double, _ format: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(String(format: format, value))
                .foregroundColor(.secondary)
                .monospacedDigit()
        }
    }

    // MARK: - Recording

    private var recorder: LabeledCaptureRecorder { app.recorder }

    private var recordingSection: some View {
        Section {
            if !app.motion.isRunning {
                InlineNotice(
                    text: "Turn on protection on the Today screen first. Recording uses the same motion sensors.",
                    color: CadenceTheme.accent,
                    systemName: "info.circle.fill"
                )
            }

            Picker("What you are doing", selection: $recordingLabel) {
                ForEach(GaitLabel.allCases, id: \.self) { label in
                    Text(plain(label)).tag(label)
                }
            }
            .disabled(recorder.isRecording)

            if recorder.isRecording {
                HStack {
                    Circle().fill(CadenceTheme.danger).frame(width: 10, height: 10)
                        .accessibilityHidden(true)
                    Text("Recording \(plain(recorder.label ?? recordingLabel).lowercased())")
                    Spacer()
                    Text(String(format: "%.0f s", recorder.elapsedSec))
                        .monospacedDigit()
                        .foregroundColor(.secondary)
                }
                Button("Stop and save") {
                    recorder.stopAndSave()
                    calibration.recalibrate()
                }
                .buttonStyle(PrimaryButtonStyle(tint: CadenceTheme.danger))
                Button("Discard") { recorder.cancel() }
                    .frame(minHeight: CadenceTheme.minimumTapHeight)
            } else {
                Button {
                    recorder.start(label: recordingLabel)
                } label: {
                    Label("Start recording", systemImage: "record.circle")
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(!app.motion.isRunning)
            }

            if !calibration.recordedCaptures.isEmpty {
                ForEach(calibration.recordedCaptures) { capture in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(plain(capture.label))
                            Text(String(format: "%.0f s · %@", capture.durationSec, capture.recordedAt.formatted(date: .abbreviated, time: .shortened)))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            calibration.deleteRecording(id: capture.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .frame(minWidth: CadenceTheme.minimumTapHeight, minHeight: CadenceTheme.minimumTapHeight)
                        .accessibilityLabel("Delete \(plain(capture.label)) recording")
                    }
                }
            }
        } header: {
            Text("Record your own motion")
        } footer: {
            Text("Keep the phone in a trouser pocket. Record at least ten seconds of steady walking, a freeze if one happens, and sitting still.")
        }
    }

    // MARK: - Backend

    private var backendSection: some View {
        Section {
            TextField("Server address", text: $settings.backendBaseURL)
                #if os(iOS)
                .textContentType(.URL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                #endif
                .autocorrectionDisabled()
            SecureField("Device key", text: $settings.deviceToken)
        } header: {
            Text("Connection")
        } footer: {
            Text("Events are saved on the phone first and sent when a connection is available.")
        }
    }

    // MARK: - Demo tools

    private var demoToolsSection: some View {
        Section {

            Button {
                AudioCueEngine.shared.playAudioTest()
            } label: {
                Label("Test sound", systemImage: "speaker.wave.2.fill")
            }
            .frame(minHeight: CadenceTheme.minimumTapHeight)

            Button {
                app.walking.startFreezeDemo()
            } label: {
                HStack {
                    Label("Freeze demo", systemImage: "metronome")
                    Spacer()
                    StatusPill(text: "Demo", color: CadenceTheme.caution)
                }
            }
            .disabled(app.walking.isDemoRunning || app.fallAlert.isAlertVisible)
            .frame(minHeight: CadenceTheme.minimumTapHeight)
        } header: {
            Text("Demo tools")
        } footer: {
            Text("Demos play recorded motion through the real detector. They never contact anyone.")
        }
    }

    private var aboutSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("Cadence is a daily-living companion, not a medical device.")
                    .font(.subheadline.weight(.semibold))
                Text("It does not diagnose or assess a condition and never suggests changes to medication. Trends in the diary are there to share with your care team.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)
        } header: {
            Text("About")
        }
    }

    private func plain(_ label: GaitLabel) -> String {
        switch label {
        case .walking: return "Walking"
        case .freeze: return "Freeze"
        case .still: return "Sitting still"
        case .turnUpright: return "Turning"
        case .sitToStand: return "Standing up"
        case .bedRoll: return "Rolling in bed"
        }
    }
}
