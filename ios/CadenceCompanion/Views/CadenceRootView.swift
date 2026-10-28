import SwiftUI

/// The app's entry view: a two-tab shell with the fall check-in overlaid
/// full screen whenever one is open.
public struct CadenceRootView: View {
    @StateObject private var app = CadenceAppModel()

    public init() {}

    public var body: some View {
        TabView {
            HomeView(app: app)
                .tabItem { Label("Today", systemImage: "figure.walk") }
            SettingsView(app: app)
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .tint(CadenceTheme.accent)
        .onAppear { app.start() }
        .modifier(FallOverlay(coordinator: app.fallAlert))
    }
}

/// Presents the SOS screen over everything while a check-in or alert is open.
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
