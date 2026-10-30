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

/// Three tabs and one help button that never moves. Setup lives behind the
/// Help tab for a care partner; the wearer's day is Today and Diary.
public struct CadenceRootView: View {
    @StateObject private var app = CadenceAppModel.shared
    @State private var tab: Tab = .today
    @State private var didReady = false
    private let onReady: ((CadenceAppModel) -> Void)?

    enum Tab: Hashable { case today, diary, help, developer }

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
                .safeAreaInset(edge: .bottom) { helpBar }
                .tag(Tab.today)
                .tabItem { Label("Today", systemImage: "sun.max.fill") }
            DiaryView(app: app)
                .safeAreaInset(edge: .bottom) { helpBar }
                .tag(Tab.diary)
                .tabItem { Label("Diary", systemImage: "book.fill") }
            HelpView(app: app)
                .tag(Tab.help)
                .tabItem { Label("Help", systemImage: "phone.fill") }
            if app.settings.developerModeEnabled {
                DeveloperView(app: app)
                    .tag(Tab.developer)
                    .tabItem { Label("Developer", systemImage: "wrench.and.screwdriver.fill") }
            }
        }
        .tint(CadenceTheme.accent)
        .onAppear {
            guard !didReady else { return }
            didReady = true
            onReady?(app)
            app.start()
        }
        .modifier(FallOverlay(coordinator: app.fallAlert))
    }

    /// Sits just above the tab bar on Today and Diary, in thumb reach. Opens
    /// Help; never dials on its own, so an accidental tap cannot send an alert.
    private var helpBar: some View {
        GuardedButton(size: .giant, style: .filled(CadenceTheme.danger), action: { tab = .help }) {
            Label("I need help", systemImage: "phone.fill")
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(CadenceTheme.background.opacity(0.97))
        .accessibilityHint("Opens the help screen with your caregiver's number")
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
