import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Walking support is the first action. Device diagnostics expand separately;
/// the help footer is inset into this scroll view so it cannot cover its content.
struct TodayView: View {
    @ObservedObject var app: CadenceAppModel
    @State private var showDeviceDetails = false

    @ObservedObject private var audioRoute = AudioRouteManager.shared
    @ObservedObject private var audio = AudioCueEngine.shared

    private var walking: WalkingModel { app.walking }
    private var doses: DoseLogModel { app.doses }
    private var voice: VoiceDoseAssistant { app.voiceDose }
    private var simple: Bool { app.isSimpleMode }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: CadenceTheme.tapGap) {
                    homeHeader
                    protectionCard
                        .card(padding: 20)
                    if !simple {
                        checksCard
                    } else {
                        simpleChecksCard
                    }
                    SectionHeader(title: "Your routine")
                    medicationCard
                    VoiceCompanionBar(app: app, compact: true)
                        .card(padding: 20)

                    if app.isUsingMockGlasses {
                        InlineNotice(text: "Mock kit: sensor inputs are simulated. This does not verify physical glasses or audio routing.", color: CadenceTheme.caution, systemName: "testtube.2")
                    }
                    if app.auth.needsSignIn {
                        Button { app.companion.destination = .settings } label: {
                            HStack(spacing: 14) {
                                Image(systemName: "arrow.triangle.2.circlepath").foregroundColor(CadenceTheme.accent)
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Connect your diary").font(.headline).foregroundColor(.primary)
                                    Text(app.settings.profile.isBound
                                        ? "Your diary works offline. Open Settings to sign in and sync."
                                        : "Set up your server in Settings. Earlier offline records stay on this phone.")
                                        .font(.subheadline).foregroundColor(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right").foregroundColor(.secondary)
                            }.frame(minHeight: CadenceTheme.bigTapHeight).card(padding: 20)
                        }.buttonStyle(.plain)
                    }
                    if let warning = app.persistenceWarning {
                        InlineNotice(text: warning, color: CadenceTheme.danger, systemName: "exclamationmark.triangle.fill")
                    }
                    if let warning = app.diaryWarning {
                        InlineNotice(text: warning, color: CadenceTheme.caution, systemName: "book.closed.fill")
                    }
                    if let notice = app.syncNotice {
                        InlineNotice(text: notice, color: CadenceTheme.caution, systemName: "arrow.triangle.2.circlepath")
                    }
                    if let error = doses.saveError { Text(error).foregroundColor(CadenceTheme.caution) }
                    deviceDetails
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 24)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { helpBar }
            .background(CadenceTheme.background.ignoresSafeArea())
            #if os(iOS)
            .toolbar(.hidden, for: .navigationBar)
            #endif


        }
    }

    private var homeHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform.path.ecg").foregroundColor(CadenceTheme.accent)
            Text("Cadence").font(.title3.weight(.semibold))
            Spacer()
            Text("TODAY").font(.caption.weight(.medium)).tracking(1.5).foregroundColor(.secondary)
        }
        .accessibilityAddTraits(.isHeader)
    }

    /// Inset at the scroll view itself, inside NavigationStack. SwiftUI reserves
    /// its full height so the last expanded row can scroll above it and the tab bar.
    private var helpBar: some View {
        GuardedButton(size: .big, style: .tinted(CadenceTheme.danger), action: { app.companion.destination = .help }) {
            Label("I need help", systemImage: "hand.raised.fill")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(CadenceTheme.background)
        .accessibilityHint("Opens help without placing a call")
    }

    private var deviceDetails: some View {
        DisclosureGroup(isExpanded: $showDeviceDetails) {
            VStack(alignment: .leading, spacing: CadenceTheme.tapGap) {
                glassesCard
                Text("Audio output: \(audioRoute.activeOutputName)")
                    .font(.footnote).foregroundColor(.secondary)
                Text("Microphone: \(audioRoute.activeInputName)")
                    .font(.footnote).foregroundColor(.secondary)
                GuardedButton(style: .tinted(CadenceTheme.accent), action: { app.companion.destination = .camera }) {
                    Label("Glasses camera", systemImage: "video")
                }
            }.padding(.top, 20)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text("Glasses & audio").font(.headline).foregroundColor(.primary)
                Text(glassesSubtitle).font(.subheadline).foregroundColor(.secondary)
            }
            .padding(.vertical, 8)
        }
        .card(padding: 20)
    }

    // MARK: - Protection & Status

    private var isGlassesConnected: Bool {
        app.glasses.connectionState == .connected
    }

    private var statusColor: Color {
        if walking.isCueing { return CadenceTheme.accent }
        return walking.isProtectionOn ? CadenceTheme.calm : .secondary
    }

    private var protectionCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Walking support")
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text("Rhythmic cues when walking gets difficult.")
                .font(.subheadline).foregroundColor(.secondary)
            StatusBadge(
                systemImage: walking.isCueing ? "metronome.fill" : (walking.isProtectionOn ? "shield.fill" : "shield.slash"),
                word: walking.headline,
                color: statusColor
            )
            GuardedButton(size: .big, style: .filled(CadenceTheme.accent), action: {
                if walking.isProtectionRequested || walking.isDemoRunning || walking.isCueing {
                    app.settings.protectionEnabled = false
                    walking.stopWalkingAudio()
                } else {
                    app.settings.protectionEnabled = true
                    walking.setProtection(enabled: true)
                }
            }) {
                Label(walking.isDemoRunning ? "Stop walking demo" : walking.isProtectionRequested ? "Turn walking support off" : "Turn walking support on",
                      systemImage: walking.isProtectionRequested || walking.isDemoRunning ? "stop.fill" : "shield")
            }
            .accessibilityHint("Controls walking cues. An active fall check-in stays active.")

            Text(walking.detail)
                .font(.body)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if walking.isProtectionOn, !walking.sourceSentence.isEmpty {
                Text(walking.sourceSentence).font(.footnote).foregroundColor(.secondary)
            }
            if walking.isProtectionRequested && !walking.isProtectionOn {
                InlineNotice(text: walking.protectionProblem ?? audio.audioProblem ?? "Walking support needs attention.",
                             color: CadenceTheme.caution, systemName: "exclamationmark.triangle")
                GuardedButton(size: .big, style: .tinted(CadenceTheme.caution), action: {
                    walking.retryAudio()
                    walking.setProtection(enabled: true)
                }) { Label("Retry walking support", systemImage: "arrow.clockwise") }
                .disabled(audio.isInterrupted)
            }
        }
    }

    // MARK: - Glasses

    private var glassesSubtitle: String {
        switch app.glasses.connectionState {
        case .connected:
            let micLabel = audioRoute.isGlassesMicActive ? "Glasses Mic" : audioRoute.activeInputName
            return "Connected · microphone: \(micLabel)"
        case .connecting:
            return "Connecting to glasses…"
        case .disconnected, .notPaired:
            return "Connect the camera and audio; available phone motion is the fallback."
        }
    }

    private var glassesCard: some View {
        HStack(spacing: 12) {
            IconBadge(
                systemName: "eyeglasses",
                color: app.glasses.connectionState == .connected ? CadenceTheme.calm : CadenceTheme.accent,
                size: 36
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(app.glasses.connectionState == .connected ? (app.glasses.deviceName ?? "Meta Glasses Connected") : "Meta glasses")
                    .font(.headline)
                Text(glassesSubtitle)
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            Spacer()
            if app.glasses.connectionState == .connecting {
                ProgressView().tint(CadenceTheme.accent)
            } else if app.glasses.connectionState == .connected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(CadenceTheme.calm)
            } else {
                Button {
                    app.glasses.connect()
                } label: {
                    Text("Connect")
                        .font(.title3.weight(.semibold))
                        .foregroundColor(CadenceTheme.accent)
                        .padding(.horizontal, 18)
                        .frame(minHeight: CadenceTheme.bigTapHeight)
                        .background(
                            Capsule().fill(CadenceTheme.accent.opacity(0.14))
                        )
                        .contentShape(Capsule())
                }
            }
        }
    }

    // MARK: - Medication

    @ViewBuilder
    private var pillImage: some View {
        #if canImport(UIKit)
        if let data = app.pillPhoto, let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: CadenceTheme.controlRadius, style: .continuous))
                .accessibilityLabel("Photo of your \(doses.schedule.medicationName)")
        } else {
            IconBadge(systemName: "pills.fill", color: doses.isDoseDue ? CadenceTheme.accent : .secondary, size: 52)
        }
        #else
        IconBadge(systemName: "pills.fill", color: doses.isDoseDue ? CadenceTheme.accent : .secondary, size: 52)
        #endif
    }

    private var voiceLine: String? {
        switch voice.state {
        case .idle, .done, .cancelled: return nil
        case .listening: return "Listening… say “taken” when you have had it."
        case .confirming: return "Heard you. Say “yes” to log it, or “no”."
        }
    }

    private var medicationCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            if app.settings.medications.count > 1 {
                Picker("Medication", selection: Binding(get: { app.settings.schedule.medicationName }, set: { app.settings.selectMedication(named: $0) })) {
                    ForEach(app.settings.medications, id: \.medicationName) { medication in
                        Text(medication.medicationName).tag(medication.medicationName)
                    }
                }
            }
            Button("Edit routine") { app.companion.destination = .medication }
            HStack(spacing: 14) {
                pillImage
                VStack(alignment: .leading, spacing: 4) {
                    Text(doses.headline)
                        .font(.title2.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(doses.detail)
                        .font(.body)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            if let voiceLine {
                HStack(spacing: 10) {
                    Image(systemName: "waveform")
                        .foregroundColor(CadenceTheme.accent)
                        .accessibilityHidden(true)
                    Text(voiceLine)
                        .font(.body)
                    Spacer(minLength: 0)
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: CadenceTheme.controlRadius, style: .continuous)
                        .fill(CadenceTheme.accent.opacity(0.12))
                )
                GuardedButton(size: .big, style: .tinted(.secondary), action: { voice.cancel() }) {
                    Text("Stop listening")
                }
            } else if doses.isDoseDue {
                GuardedButton(size: .giant, style: .filled(CadenceTheme.calm), action: {
                    if doses.markTaken() { Haptics.success() }
                }) {
                    Label("Taken", systemImage: "checkmark")
                }
                .accessibilityHint("Logs this dose as taken. You can undo afterwards.")
                if app.companion.isEnabled {
                    Text("Or say “I took my medication.”")
                        .font(.subheadline).foregroundColor(.secondary)
                } else {
                    GuardedButton(size: .big, style: .tinted(CadenceTheme.accent), action: { voice.begin() }) {
                        Label("Say it instead", systemImage: "mic.fill")
                    }
                    .accessibilityHint("Cadence asks whether you have taken it and reads your answer back")
                }
            } else if doses.canUndo {
                GuardedButton(size: .big, style: .tinted(CadenceTheme.accent), action: { doses.undo() }) {
                    Label("Undo — I haven't taken it yet", systemImage: "arrow.uturn.backward")
                }
            }
        }
        .card()
    }

    // MARK: - Quick Checks

    private var checksCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("A little help, when you need it")
                .font(.headline)
                .foregroundColor(.secondary)

            VStack(spacing: 8) {
                actionRow(
                    title: "Daily check",
                    subtitle: "Voice, handwriting and a short walk",
                    icon: "figure.walk.motion",
                    tint: CadenceTheme.accent
                ) {
                    app.companion.destination = .motor
                }

                Divider().padding(.vertical, 2)

                actionRow(
                    title: "Check my surroundings",
                    subtitle: "Take a photo to help identify what’s around you",
                    icon: "eye.fill",
                    tint: CadenceTheme.calm
                ) {
                    app.companion.destination = .surroundings
                }

                Divider().padding(.vertical, 2)

                actionRow(
                    title: "Save a meal time",
                    subtitle: "Save a meal time in your routine diary",
                    icon: "fork.knife",
                    tint: CadenceTheme.caution
                ) {
                    app.companion.destination = .meal
                }

                Divider().padding(.vertical, 2)
                actionRow(title: "Your diary", subtitle: "Return to what you recorded", icon: "book.closed", tint: CadenceTheme.accent) {
                    app.companion.destination = .diary
                }

            }
        }
        .card()
    }

    private var simpleChecksCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Check with Cadence")
                .font(.headline)
                .foregroundColor(.secondary)

            actionRow(
                title: "Daily check",
                subtitle: "Voice, handwriting & walk",
                icon: "figure.walk.motion",
                tint: CadenceTheme.accent
            ) {
                app.companion.destination = .motor
            }

            Divider().padding(.vertical, 2)

            actionRow(
                title: "Check my surroundings",
                subtitle: "Take a photo to help identify what’s around you",
                icon: "eye.fill",
                tint: CadenceTheme.calm
            ) {
                app.companion.destination = .surroundings
            }
            Divider().padding(.vertical, 2)
            actionRow(title: "Your diary", subtitle: "Your saved moments", icon: "book.closed", tint: CadenceTheme.accent) {
                app.companion.destination = .diary
            }
        }
        .card()
    }

    private func actionRow(
        title: String,
        subtitle: String,
        icon: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                IconBadge(systemName: icon, color: tint, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body.weight(.semibold))
                        .foregroundColor(.primary)
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(Color.secondary.opacity(0.6))
            }
            .contentShape(Rectangle())
            .frame(minHeight: CadenceTheme.bigTapHeight)
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }
}
