import SwiftUI

/// Connection setup is optional navigation, never a replacement for the app.
/// Only an explicit reset or unreadable local storage blocks normal access.
enum CadenceLaunchScreen: Equatable {
    case home
    case restart
    case storageFailure(String)

    @MainActor
    init(settings: AppSettings) {
        if settings.restartRequired { self = .restart }
        else if let failure = settings.profile.failure { self = .storageFailure(failure) }
        else { self = .home }
    }
}

/// Settings stays reachable from the tab bar even when voice needs setup.
public struct CadenceRootView: View {
    @StateObject private var app = CadenceAppModel.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab: Tab = .today
    @State private var didReady = false
    private let onReady: ((CadenceAppModel) -> Void)?

    enum Tab: Hashable { case today, medication, settings }

    /// `onReady` runs once with the app model so the host app can attach a
    /// real glasses device, which lives outside this platform-neutral package.
    public init(onReady: ((CadenceAppModel) -> Void)? = nil) {
        self.onReady = onReady
    }

    public var body: some View {
        Group {
            switch CadenceLaunchScreen(settings: app.settings) {
            case .restart:
                VStack(spacing: 16) {
                    Text("Local reset prepared").font(.title2)
                    Text("Close Cadence completely and reopen it. The previous local profile and its queued uploads will be erased before new setup starts. Server records are unchanged.")
                }.padding(24)
            case .storageFailure(let failure):
                VStack(spacing: 16) {
                    Text("Local profile unavailable").font(.title2)
                    Text(failure)
                    Text("Close Cadence and reopen it after resolving the storage problem.")
                }.padding(24)
            case .home:
                mainContent
            }
        }
    }

    private var mainContent: some View {
        TabView(selection: $tab) {
            TodayView(app: app)
                .tag(Tab.today)
                .tabItem { Label("Today", systemImage: "circle.grid.2x2.fill") }
            MedicationSetupView(app: app, isTab: true)
                .tag(Tab.medication)
                .tabItem { Label("My routine", systemImage: "pill.fill") }
            SettingsView(app: app, isTab: true)
                .equatable()
                .tag(Tab.settings)
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }

        }
        .preferredColorScheme(.dark)
        .tint(CadenceTheme.accent)
        .sheet(item: Binding(get: { app.companion.destination }, set: { app.companion.destination = $0 }), onDismiss: {
            if app.companion.destination == nil {
                if app.exam.isRunning { app.exam.cancelExam() }
                app.glasses.stopCameraPreview()
                app.companion.setPaused("Voice measurement", false)
                app.companion.setContext(nil)
            }
        }) { destination in
            Group {
                switch destination {
                case .motor: MotorExamView(app: app)
                case .surroundings: RealityCheckView(app: app)
                case .medication: MedicationSetupView(app: app)
                case .camera: GlassesCameraView(glasses: app.glasses, voice: app.companion)
                case .diary: DiaryView(app: app).modifier(CompanionReadOnlyFlow(voice: app.companion, destination: .diary))
                case .meal: MealCheckView(app: app)
                case .settings: SettingsView(app: app).equatable()
                case .help: HelpView(app: app).modifier(CompanionReadOnlyFlow(voice: app.companion, destination: .help))
                }
            }

            }
        .onChange(of: app.companion.destination) { destination in
            if destination != .motor, app.exam.isRunning {
                app.exam.cancelExam()
                app.companion.setPaused("Voice measurement", false)
            }
        }
        .onChange(of: app.companion.actionID) { _ in
            if tab == .settings, app.companion.destination == nil,
               app.companion.actionContext == .settings,
               [.finish, .cancel].contains(app.companion.action) {
                tab = .today
            }
            if app.companion.action == .cancel, app.companion.actionContext != .camera { app.companion.destination = nil }
            if app.companion.action == .finish,
               app.companion.context == app.companion.destination,
               let context = app.companion.context, [.diary, .settings, .help].contains(context) {
                app.companion.destination = nil
            }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active { AudioCueEngine.shared.refreshVoiceSelection() }
            app.voiceSceneChanged(isActive: phase == .active, isBackground: phase == .background)
        }
        .onAppear {
            guard !didReady else { return }
            didReady = true
            onReady?(app)
            app.start()
        }
        .modifier(FallOverlay(coordinator: app.fallAlert))
    }


}

/// Presents the check-in over everything while one is open.
/// Full-screen on iOS; an overlay on macOS, which has no `fullScreenCover`.
private struct FallOverlay: ViewModifier {
    @ObservedObject var coordinator: FallAlertCoordinator

    func body(content: Content) -> some View {
        #if os(iOS)
        content.fullScreenCover(isPresented: Binding(
            get: { coordinator.isAlertVisible },
            set: { _ in }
        )) {
            EmergencySOSView(coordinator: coordinator)
                .interactiveDismissDisabled(true)
        }
        #else
        ZStack {
            content
            if coordinator.isAlertVisible {
                EmergencySOSView(coordinator: coordinator)
            }
        }
        #endif
    }
}

private struct CompanionReadOnlyFlow: ViewModifier {
    @ObservedObject var voice: VoiceCompanion
    let destination: CompanionDestination
    @State private var id = UUID()
    func body(content: Content) -> some View {
        content.onAppear { voice.enterFlow(id: id, destination: destination, step: .general) }
            .onDisappear { voice.leaveFlow(id: id) }
    }
}
