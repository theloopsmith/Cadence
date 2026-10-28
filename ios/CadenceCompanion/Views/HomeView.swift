import SwiftUI

/// Today: is protection on, what the phone sees, and the labeled demo.
struct HomeView: View {
    @ObservedObject var app: CadenceAppModel
    @State private var beatPulse = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    walkingCard
                    demoCard
                    caregiverCard
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(CadenceTheme.background.ignoresSafeArea())
            .navigationTitle("Today")
        }
    }

    // MARK: - Walking protection

    private var walking: WalkingModel { app.walking }

    private var walkingCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                IconBadge(
                    systemName: walking.isCueing ? "metronome.fill" : "figure.walk",
                    color: walking.isCueing ? CadenceTheme.accent : (walking.isProtectionOn ? CadenceTheme.calm : .secondary),
                    size: 52
                )
                VStack(alignment: .leading, spacing: 4) {
                    Text(walking.headline)
                        .font(.title2.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(walking.detail)
                        .font(.body)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            if walking.isCueing {
                beatBanner
            }

            Toggle(isOn: Binding(
                get: { walking.isProtectionOn },
                set: { enabled in
                    app.settings.protectionEnabled = enabled
                    walking.setProtection(enabled: enabled)
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Protection")
                        .font(.headline)
                    Text("Listens for freezes and hard falls while the phone is with you.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
            .toggleStyle(.switch)
            .tint(CadenceTheme.calm)
            .disabled(walking.isDemoRunning)
            .frame(minHeight: CadenceTheme.minimumTapHeight)
            .accessibilityHint("Turns freeze and fall protection on or off")
        }
        .card()
    }

    private var beatBanner: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(CadenceTheme.accent)
                .frame(width: 14, height: 14)
                .scaleEffect(beatPulse ? 1.25 : 0.85)
                .onAppear {
                    withAnimation(.easeInOut(duration: 0.3).repeatForever(autoreverses: true)) {
                        beatPulse = true
                    }
                }
                .onDisappear { beatPulse = false }
                .accessibilityHidden(true)
            Text("Step with the beat. It stops on its own once you are walking again.")
                .font(.subheadline)
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: CadenceTheme.controlRadius, style: .continuous)
                .fill(CadenceTheme.accent.opacity(0.12))
        )
    }

    // MARK: - Demo

    private var demoCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                StatusPill(text: walking.demoLabel, color: CadenceTheme.caution, filled: true)
                Text("Hear the beat without a real freeze")
                    .font(.headline)
                Spacer(minLength: 0)
            }
            Text("Plays a recorded 16-second walk that freezes and then recovers. Protection pauses while it plays.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if walking.isDemoRunning {
                ProgressView(value: walking.demoProgress)
                    .tint(CadenceTheme.caution)
                Button("Stop demo") { walking.stopFreezeDemo() }
                    .buttonStyle(SecondaryButtonStyle(tint: CadenceTheme.caution))
            } else {
                Button {
                    walking.startFreezeDemo()
                } label: {
                    Label("Play freeze demo", systemImage: "play.fill")
                }
                .buttonStyle(SecondaryButtonStyle(tint: CadenceTheme.caution))
                .disabled(app.fallAlert.isAlertVisible)
            }

            if let summary = walking.lastDemoSummary {
                Text(summary)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .card()
    }

    // MARK: - Caregiver

    private var caregiverCard: some View {
        HStack(spacing: 14) {
            IconBadge(systemName: "person.crop.circle.badge.checkmark", color: CadenceTheme.calm)
            VStack(alignment: .leading, spacing: 3) {
                Text(app.settings.hasCaregiver ? "Caregiver ready" : "Add a caregiver")
                    .font(.headline)
                Text(
                    app.settings.hasCaregiver
                        ? "\(app.settings.caregiverName.isEmpty ? "Your caregiver" : app.settings.caregiverName) will be contacted if you fall and do not answer."
                        : "If you fall and do not answer, Cadence can contact someone you choose."
                )
                .font(.subheadline)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .card(padding: 16)
    }
}
