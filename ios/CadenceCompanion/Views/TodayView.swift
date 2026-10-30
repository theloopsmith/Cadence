import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// The home screen: how the day is going, the next dose with one big Taken,
/// and a protection switch card. In a predicted off period it drops to the
/// two things that matter and makes them bigger.
struct TodayView: View {
    @ObservedObject var app: CadenceAppModel

    @State private var showMotorCheck = false
    @State private var showRealityCheck = false
    @State private var showMealCheck = false
    @State private var showSettings = false
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
                    if app.isUsingMockGlasses {
                        InlineNotice(text: "Mock kit: sensor inputs are simulated. This does not verify physical glasses or audio routing.", color: CadenceTheme.caution, systemName: "testtube.2")
                    }
                    if app.auth.needsSignIn {
                        InlineNotice(
                            text: app.settings.profile.isBound
                                ? "Your diary works offline. Sign in through Settings when you want to sync this wearer's events."
                                : "You can use Cadence now. Connect your server in Settings to enable online checks. Events recorded before account setup stay on this phone.",
                            color: CadenceTheme.accent,
                            systemName: "info.circle.fill"
                        )
                        Button("Set up connection") { showSettings = true }
                            .buttonStyle(.bordered)
                    }
                    if app.settings.sync.quarantinedCount() > 0 {
                        InlineNotice(text: "Older events with an unknown account are held on this phone and will not be sent under a new sign-in.", color: CadenceTheme.caution, systemName: "person.crop.circle.badge.exclamationmark")
                    }
                    if let warning = app.persistenceWarning {
                        InlineNotice(text: warning, color: CadenceTheme.danger, systemName: "exclamationmark.triangle.fill")
                    }
                    protectionCard
                    if !isGlassesConnected {
                        glassesCard
                    }
                    medicationCard
                    if !simple {
                        checksCard
                    } else {
                        // In simple mode, offer the motor check directly
                        simpleChecksCard
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 96)
            }
            .background(CadenceTheme.background.ignoresSafeArea())
            .navigationTitle(simple ? "Right now" : "Today")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(CadenceTheme.accent)
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(app: app)
            }
            .sheet(isPresented: $showMotorCheck) {
                MotorExamView(app: app)
            }
            .sheet(isPresented: $showRealityCheck) {
                RealityCheckView(app: app)
            }
            .sheet(isPresented: $showMealCheck) {
                MealCheckView(app: app)
            }
        }
    }

    // MARK: - Protection & Status

    private var isGlassesConnected: Bool {
        app.glasses.connectionState == .connected
    }

    private var glassesDisplayName: String {
        if let name = app.glasses.deviceName, !name.isEmpty {
            return name
        }
        if audioRoute.isGlassesMicActive {
            return audioRoute.activeInputName.isEmpty ? "Meta Glasses" : audioRoute.activeInputName
        }
        return "Meta Gen 3 AI Glasses"
    }

    private var statusColor: Color {
        if walking.isCueing { return CadenceTheme.accent }
        return walking.isProtectionOn ? CadenceTheme.calm : .secondary
    }

    private var protectionCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                StatusBadge(
                    systemImage: walking.isCueing ? "metronome.fill" : (walking.isProtectionOn ? "shield.fill" : "shield.slash"),
                    word: walking.headline,
                    color: statusColor
                )
                Spacer()
                Button {
                    let next = !walking.isProtectionRequested
                    app.settings.protectionEnabled = next
                    walking.setProtection(enabled: next)
                    Haptics.tap()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: walking.isProtectionRequested ? "checkmark.circle.fill" : "circle")
                        Text(walking.isProtectionRequested ? "Turn Off" : "Turn On")
                            .fontWeight(.semibold)
                    }
                    .font(.subheadline)
                    .foregroundColor(walking.isProtectionOn ? CadenceTheme.calm : .secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        Capsule().fill(walking.isProtectionOn ? CadenceTheme.calm.opacity(0.14) : Color.secondary.opacity(0.12))
                    )
                }
                .disabled(walking.isDemoRunning)
                .accessibilityLabel(walking.isProtectionRequested ? "Turn protection off" : "Turn protection on")
            }

            Text(walking.detail)
                .font(simple ? .title3 : .body)
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Audio output: \(audioRoute.activeOutputName) · Microphone: \(audioRoute.activeInputName)")
                .font(.footnote)
                .foregroundColor(.secondary)

            if !audio.isAudioAvailable || (walking.isProtectionRequested && app.motion.health == .healthy && !walking.isProtectionOn) {
                InlineNotice(text: audio.audioProblem ?? walking.protectionProblem ?? "Audio cues are unavailable.", color: CadenceTheme.caution, systemName: "speaker.slash.fill")
                Button("Retry audio") { walking.retryAudio() }
                    .disabled(audio.isInterrupted)
            }
            if walking.isProtectionRequested, app.motion.health == .stale {
                Button("Retry protection") { walking.setProtection(enabled: true) }
            }
            if walking.isProtectionRequested || walking.isDemoRunning || walking.isCueing {
                GuardedButton(size: .big, style: .tinted(.secondary), action: {
                    app.settings.protectionEnabled = false
                    walking.stopWalkingAudio()
                }) {
                    Label("Stop walking cues", systemImage: "stop.fill")
                }
                .accessibilityHint("Stops walking protection and its speech. An active fall alert stays active.")
            }

            if walking.isProtectionOn, !walking.sourceSentence.isEmpty, !simple {
                Text(walking.sourceSentence)
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }

            if isGlassesConnected {
                HStack(spacing: 6) {
                    Image(systemName: "eyeglasses")
                        .foregroundColor(CadenceTheme.calm)
                    Text("\(glassesDisplayName) · \(audioRoute.isGlassesMicActive ? "Glasses Mic" : "Glasses") Active")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }

            if simple {
                Text("Things are kept simple for now. Everything else is a tab away.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
        .card()
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
            return "Tap to connect for head motion, mic & cues"
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
                Text(app.glasses.connectionState == .connected ? (app.glasses.deviceName ?? "Meta Glasses Connected") : "Meta Gen 3 AI Glasses")
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
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(CadenceTheme.accent)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(
                            Capsule().fill(CadenceTheme.accent.opacity(0.14))
                        )
                }
            }
        }
        .card(padding: 14)
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
                    doses.markTaken()
                    Haptics.success()
                }) {
                    Label("Taken", systemImage: "checkmark")
                }
                .accessibilityHint("Logs this dose as taken. You can undo afterwards.")
                GuardedButton(size: .big, style: .tinted(CadenceTheme.accent), action: { voice.begin() }) {
                    Label("Say it instead", systemImage: "mic.fill")
                }
                .accessibilityHint("Cadence asks whether you have taken it and reads your answer back")
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
            Text("Quick Checks")
                .font(.headline)
                .foregroundColor(.secondary)

            VStack(spacing: 8) {
                actionRow(
                    title: "1-Minute Motor Check",
                    subtitle: "Voice stability, handwriting size & walk rhythm",
                    icon: "figure.walk.motion",
                    tint: CadenceTheme.accent
                ) {
                    showMotorCheck = true
                }

                Divider().padding(.vertical, 2)

                actionRow(
                    title: "Check Surroundings",
                    subtitle: "Vision AI reality check for shadows or objects",
                    icon: "eye.fill",
                    tint: CadenceTheme.calm
                ) {
                    showRealityCheck = true
                }

                Divider().padding(.vertical, 2)

                actionRow(
                    title: "Log a Meal",
                    subtitle: "Save a meal time in your routine diary",
                    icon: "fork.knife",
                    tint: CadenceTheme.caution
                ) {
                    showMealCheck = true
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
                title: "1-Minute Motor Check",
                subtitle: "Voice, handwriting & walk",
                icon: "figure.walk.motion",
                tint: CadenceTheme.accent
            ) {
                showMotorCheck = true
            }

            Divider().padding(.vertical, 2)

            actionRow(
                title: "Check Surroundings",
                subtitle: "See what is in the room",
                icon: "eye.fill",
                tint: CadenceTheme.calm
            ) {
                showRealityCheck = true
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
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }
}
