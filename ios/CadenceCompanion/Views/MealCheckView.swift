import SwiftUI

/// Timing-only meal entry. No photo, nutrient estimate, or medication advice.
public struct MealCheckView: View {
    @State private var voiceFlowID = UUID()
    @ObservedObject var app: CadenceAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var isSaving = false
    @State private var message: String?
    public init(app: CadenceAppModel) { self.app = app }
    public var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Text("Log a meal").font(.title)
                Text("Save the time of your meal alongside your existing routine. No photo or nutrition estimate is needed. Say ready to record the meal time.")
                if let message { Text(message) }
                Button(isSaving ? "Saving…" : "Log meal now", action: saveMeal)
                    .disabled(isSaving).buttonStyle(.borderedProminent)
                Button("Done") { dismiss() }
            }.padding(24).navigationTitle("Meal diary")
            .onDisappear { app.companion.leaveFlow(id: voiceFlowID) }
            .onAppear { app.companion.enterFlow(id: voiceFlowID, destination: .meal, step: .meal) }
            .onChange(of: app.companion.actionID) { _ in
                guard app.companion.context == .meal else { return }
                if app.companion.action == .start { saveMeal() }
                if app.companion.action == .finish || app.companion.action == .cancel { dismiss() }
            }
        }
    }
    private func saveMeal() {
        guard !isSaving else { return }
        isSaving = true
        let client = app.settings.api
        Task { @MainActor in
            do {
                let result = try await client.logMeal(jpeg: Data())
                guard app.settings.deviceToken == client.bearerToken, app.settings.api.baseURL == client.baseURL,
                      !app.settings.restartRequired else { isSaving = false; return }
                app.recordDiary(.mealLogged, detail: "Meal time logged")
                message = result.spokenResponse
            } catch { message = "Could not save the meal. \(error.localizedDescription)" }
            isSaving = false
            if let message { app.companion.say(message) }
        }
    }
}
