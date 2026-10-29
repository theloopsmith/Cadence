import SwiftUI

/// Timing-only meal entry. No photo, nutrient estimate, or medication advice.
public struct MealCheckView: View {
    @ObservedObject var app: CadenceAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var isSaving = false
    @State private var message: String?
    public init(app: CadenceAppModel) { self.app = app }
    public var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Text("Log a meal").font(.title)
                Text("Save the time of your meal alongside your existing routine. No photo or nutrition estimate is needed.")
                if let message { Text(message) }
                Button(isSaving ? "Saving…" : "Log meal now") {
                    isSaving = true
                    Task {
                        do {
                            let result = try await app.settings.api.logMeal(jpeg: Data())
                            app.recordDiary(.mealLogged, detail: "Meal time logged")
                            message = result.spokenResponse
                        } catch { message = "Could not save the meal. Please try again." }
                        isSaving = false
                    }
                }.disabled(isSaving).buttonStyle(.borderedProminent)
                Button("Done") { dismiss() }
            }.padding(24).navigationTitle("Meal diary")
        }
    }
}
