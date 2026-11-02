import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Photo-assisted diary entry. Only the timestamp is shared; no food analysis.
public struct MealCheckView: View {
    @State private var voiceFlowID = UUID()
    @ObservedObject var app: CadenceAppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: MealLogModel
    @State private var mealTime = Date()
    @State private var note = ""
    @State private var photo: Data?
    @State private var showGlassesCamera = false
    @State private var showPhoneCamera = false
    @State private var automaticCapture = false
    @State private var introduced = false
    @State private var needsPhotoPrompt = false
    public init(app: CadenceAppModel) {
        self.app = app
        _model = StateObject(wrappedValue: MealLogModel(diary: app.diary, sync: app.settings.sync))
    }
    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(model.savedEvent == nil ? "Remember this meal" : "Meal saved")
                        .font(.largeTitle.weight(.semibold))
                    if let event = model.savedEvent {
                        VStack(alignment: .leading, spacing: 14) {
                            Label(event.at.formatted(date: .abbreviated, time: .shortened), systemImage: "checkmark.circle.fill")
                                .font(.title3).foregroundColor(CadenceTheme.calm)
                            photoPreview
                            if !event.detail.isEmpty { Text(event.detail) }
                            Text(model.message ?? "Saved on this phone.").foregroundColor(.secondary)
                            if model.sharingNeedsRetry { Button("Retry sharing meal time") { model.retrySharing() } }
                        }.card()
                        GuardedButton(style: .tinted(CadenceTheme.accent), action: newMeal) { Text("Log another meal") }
                        GuardedButton(style: .filled(CadenceTheme.accent), action: { dismiss() }) { Text("Done") }
                    } else {
                        Text("Take an optional photo to help you remember, then save the meal time. You can also log without a photo.")
                            .foregroundColor(.secondary)
                        VStack(alignment: .leading, spacing: 16) {
                            photoPreview
                            GuardedButton(style: .tinted(CadenceTheme.accent), action: { automaticCapture = false; showGlassesCamera = true }) {
                                Label(photo == nil ? "Take meal photo" : "Retake photo", systemImage: "eyeglasses")
                            }
                            Button("Use iPhone camera") { showPhoneCamera = true }
                            if photo != nil { Button("Remove photo", role: .destructive) { photo = nil } }
                            Text("Photo and note stay on this phone. Only the meal time is shared.")
                                .font(.footnote).foregroundColor(.secondary)
                        }.card()
                        VStack(alignment: .leading, spacing: 16) {
                            DatePicker("Meal time", selection: $mealTime, in: ...Date(), displayedComponents: [.date, .hourAndMinute])
                            TextField("Optional note, such as breakfast", text: $note).textFieldStyle(.roundedBorder)
                        }.card()
                        if let error = model.error { Text(error).foregroundColor(CadenceTheme.caution) }
                        GuardedButton(size: .big, style: .filled(CadenceTheme.accent), action: saveMeal) {
                            Text(photo == nil ? "Log meal without photo" : "Save meal and photo")
                        }
                    }
                    Text("A meal diary, not food recognition or nutrition/medication advice.")
                        .font(.footnote).foregroundColor(.secondary)
                }.padding(20)
            }
            .background(CadenceTheme.background.ignoresSafeArea())
            .navigationTitle("Meal diary")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .onAppear {
                app.companion.enterFlow(id: voiceFlowID, destination: .meal, step: model.savedEvent == nil ? .meal : .mealSaved)
                model.recoverPendingSharing()
                if !introduced {
                    introduced = true
                    app.companion.say("Would you like a meal photo? Say take a photo, or ready to log without a photo.")
                }
            }
            .onDisappear { if !showGlassesCamera && !showPhoneCamera { app.companion.leaveFlow(id: voiceFlowID) } }
            .onChange(of: app.companion.actionID) { _ in
                guard app.companion.context == .meal else { return }
                switch app.companion.action {
                case .capture, .retake: if model.savedEvent == nil { automaticCapture = true; showGlassesCamera = true }
                case .start: saveMeal()
                case .retry: if model.savedEvent != nil { newMeal() } else { saveMeal() }
                case .finish, .cancel: dismiss()
                default: break
                }
            }
            .sheet(isPresented: $showGlassesCamera, onDismiss: { automaticCapture = false; photoPrompt() }) {
                GlassesCameraView(glasses: app.glasses, voice: app.companion, captureWhenReady: automaticCapture, title: "Meal photo") { acceptPhoto($0) }
            }
            .cameraPresentation(isPresented: $showPhoneCamera, onCapture: { acceptPhoto($0); showPhoneCamera = false }, onCancel: { showPhoneCamera = false }, onDismiss: { photoPrompt() })
        }
    }
    private var photoPreview: some View {
        Group {
            #if canImport(UIKit)
            if let photo, let image = UIImage(data: photo) {
                Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 280).clipShape(RoundedRectangle(cornerRadius: 14))
                    .accessibilityLabel("Your reviewed meal photo")
            }
            #endif
        }
    }
    private func acceptPhoto(_ data: Data) {
        photo = data; needsPhotoPrompt = true
    }
    private func photoPrompt() {
        guard needsPhotoPrompt else { return }; needsPhotoPrompt = false
        app.companion.say("Photo ready. Say ready to save the meal time and keep this photo on your phone, or retake for another photo.")
    }
    private func saveMeal() {
        guard !app.settings.restartRequired, model.savedEvent == nil else { return }
        if model.save(at: mealTime, note: note, photo: photo) {
            app.diaryChanged(); Haptics.success()
            app.companion.updateFlow(id: voiceFlowID, step: .mealSaved)
            app.companion.say("Meal saved at " + mealTime.formatted(date: .omitted, time: .shortened) + ". " + (model.message ?? "") + " Say another meal or done.")
        } else if let error = model.error { app.companion.say(error) }
    }
    private func newMeal() {
        model.newMeal(); photo = nil; note = ""; mealTime = Date()
        app.companion.updateFlow(id: voiceFlowID, step: .meal)
        app.companion.say("Take an optional meal photo, or say ready to save without a photo.")
    }
}
