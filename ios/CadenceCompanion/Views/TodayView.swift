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

    private var walking: WalkingModel { app.walking }
    private var doses: DoseLogModel { app.doses }
    private var voice: VoiceDoseAssistant { app.voiceDose }
    private var simple: Bool { app.isSimpleMode }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: CadenceTheme.tapGap) {
                    if app.auth.needsSignIn {
                        InlineNotice(
                            text: "Cadence is keeping today's events on this phone until it's signed in. You can sign in anytime in Settings.",
                            color: CadenceTheme.accent,
                            systemName: "info.circle.fill"
                        )
                    }
                    statusCard
                    glassesCard
                    medicationCard
                    if !simple {
                        checksCard
                        protectionCard
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

    // MARK: - Status

    private var statusColor: Color {
        if walking.isCueing { return CadenceTheme.accent }
        return walking.isProtectionOn ? CadenceTheme.calm : .secondary
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            StatusBadge(
                systemImage: walking.isCueing ? "metronome.fill" : (walking.isProtectionOn ? "shield.fill" : "shield.slash"),
                word: walking.headline,
                color: statusColor
            )
            Text(walking.detail)
                .font(simple ? .title3 : .body)
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
            if walking.isProtectionOn, !walking.sourceSentence.isEmpty, !simple {
                Text(walking.sourceSentence)
                    .font(.footnote)
                    .foregroundColor(.secondary)
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
                Text(app.glasses.connectionState == .connected ? "60 Hz IMU · Open-Ear Audio Active" : "Tap to connect for head motion & cues")
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

    // MARK: - Protection

    private var protectionCard: some View {
        SwitchCard(
            title: "Protection",
            detail: "Listens for freezes and hard falls while the phone or glasses are with you.",
            isOn: walking.isProtectionOn,
            onColor: CadenceTheme.calm
        ) {
            let next = !walking.isProtectionOn
            app.settings.protectionEnabled = next
            walking.setProtection(enabled: next)
        }
        .disabled(walking.isDemoRunning)
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
                    title: "Check Meal for Protein",
                    subtitle: "Avoid Levodopa absorption delay",
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
