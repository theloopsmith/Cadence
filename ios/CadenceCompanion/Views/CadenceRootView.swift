import SwiftUI

/// Three tabs and one help button that never moves. Setup lives behind the
/// Help tab for a care partner; the wearer's day is Today and Diary.
public struct CadenceRootView: View {
    @StateObject private var app = CadenceAppModel()
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
        VStack(spacing: 0) {
            TabView(selection: $tab) {
                TodayView(app: app)
                    .tag(Tab.today)
                    .tabItem { Label("Today", systemImage: "sun.max.fill") }
                DiaryView(app: app)
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
            if tab != .help && tab != .developer {
                helpBar
            }
        }
        .onAppear {
            guard !didReady else { return }
            didReady = true
            onReady?(app)
            app.start()
        }
        .modifier(FallOverlay(coordinator: app.fallAlert))
    }

    /// Same place on every screen, in thumb reach. Opens Help; never dials
    /// on its own, so an accidental tap cannot send an alert.
    private var helpBar: some View {
        GuardedButton(size: .giant, style: .filled(CadenceTheme.danger), action: { tab = .help }) {
            Label("I need help", systemImage: "phone.fill")
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background(CadenceTheme.background)
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
