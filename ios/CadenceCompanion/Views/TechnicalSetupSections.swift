import SwiftUI

/// Freeze-sensing calibration, labeled motion recording, and the server
/// connection. Technical setup that lives on the Developer tab, not with
/// the care partner's contacts.
struct TechnicalSetupSections: View {
    @ObservedObject var app: CadenceAppModel
    @ObservedObject private var settings: AppSettings
    @State private var recordingLabel: GaitLabel = .walking
    @State private var showSensitivity = false
    @State private var deviceKey = ""
    @State private var serverAddress: String

    init(app: CadenceAppModel) {
        self.app = app
        self.settings = app.settings
        _serverAddress = State(initialValue: app.settings.backendBaseURL)
    }

    var body: some View {
        calibrationSection
        recordingSection
        backendSection
    }

    // MARK: - Calibration

    var calibration: FoGCalibrationController { app.calibration }

    var calibrationSection: some View {
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

    var recorder: LabeledCaptureRecorder { app.recorder }

    var recordingSection: some View {
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

    var backendSection: some View {
        Section {
            TextField("Server address", text: $serverAddress)
                #if os(iOS)
                .textContentType(.URL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                #endif
                .autocorrectionDisabled()
            SecureField("New device key", text: $deviceKey)
            Button("Apply connection") {
                settings.backendBaseURL = serverAddress
                if settings.api.baseURL == DeviceProfile.normalize(serverAddress) {
                    settings.deviceToken = deviceKey
                }
                deviceKey = ""
            }
            if let notice = settings.profileNotice { Text(notice).foregroundColor(CadenceTheme.caution) }
        } header: {
            Text("Connection")
        } footer: {
            Text("Events are saved on the phone first and sent when a connection is available. On an iPhone, localhost points to the phone itself: run scripts/run_phone_backend.py on the Mac and use the .local address it prints; the phone account's username and password are written to .local/phone-login.txt there.")
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
