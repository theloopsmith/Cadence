import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Saved routine first; one explicit edit session and one visible save action.
struct MedicationSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var app: CadenceAppModel
    @ObservedObject private var settings: AppSettings
    @StateObject private var editor: MedicationPlanEditor
    @State private var voiceFlowID = UUID()
    @State private var selectedID: UUID?
    @State private var cameraMedicationID: UUID?
    @State private var automaticVoiceCapture = false
    @State private var showGlassesCamera = false
    @State private var showPillCamera = false
    let isTab: Bool

    init(app: CadenceAppModel, isTab: Bool = false) {
        self.app = app; self.settings = app.settings; self.isTab = isTab
        _editor = StateObject(wrappedValue: MedicationPlanEditor(settings: app.settings,
            loadPhoto: { app.pillPhotos.forMedication($0).load() },
            savePhoto: { data, name in app.setPillPhoto(data, medicationName: name); return app.photoSaveError }))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Your medication routine").font(.largeTitle.weight(.semibold))
                    Text("Keep the names and reminder times from your prescribed plan in one place.")
                        .foregroundColor(.secondary)
                    if let receipt = editor.receipt {
                        Label(receipt, systemImage: "checkmark.circle.fill")
                            .font(.headline).foregroundColor(CadenceTheme.calm).card()
                    }
                    if editor.isEditing { editingContent }
                    else { savedContent }
                    Text("Reminders only. Cadence does not choose a dose or change prescribed timing.")
                        .font(.footnote).foregroundColor(.secondary)
                }.padding(20)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if editor.isEditing {
                    VStack(spacing: 10) {
                        if let error = editor.error { Text(error).foregroundColor(CadenceTheme.caution).font(.subheadline) }
                        GuardedButton(size: .big, style: .filled(CadenceTheme.accent), action: save) {
                            Text("Save routine")
                        }
                        Button("Discard changes") { cancelEditing() }
                            .frame(minHeight: CadenceTheme.minimumTapHeight)
                    }.padding(16).background(CadenceTheme.background)
                }
            }
            .background(CadenceTheme.background.ignoresSafeArea())
            .navigationTitle(isTab ? "My routine" : "Medications")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                if !isTab {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(editor.isEditing ? "Cancel" : "Done") { editor.cancel(); dismiss() }
                    }
                }
            }
            .interactiveDismissDisabled(editor.isEditing)
            .onAppear {
                if editor.isEditing { app.companion.enterFlow(id: voiceFlowID, destination: .medication, step: .medicationSetup) }
                else if !isTab { app.companion.enterFlow(id: voiceFlowID, destination: .medication, step: .medication) }
            }
            .onDisappear {
                if !showGlassesCamera && !showPillCamera { app.companion.leaveFlow(id: voiceFlowID) }
            }
            .onChange(of: app.companion.actionID) { _ in
                guard app.companion.context == .medication else { return }
                switch app.companion.action {
                case .capture:
                    beginEditing()
                    if selectedID == nil { selectedID = editor.items.first?.id }
                    openGlassesCamera(automatic: true)
                case .finish:
                    if editor.isEditing { save() } else if !isTab { dismiss() }
                case .cancel: cancelEditing(); if !isTab { dismiss() }
                default: break
                }
            }
            .sheet(isPresented: $showGlassesCamera, onDismiss: { automaticVoiceCapture = false }) {
                GlassesCameraView(glasses: app.glasses, voice: app.companion, captureWhenReady: automaticVoiceCapture, title: "Medication photo") { stagePhoto($0) }
            }
            .cameraPresentation(isPresented: $showPillCamera, onCapture: { stagePhoto($0); showPillCamera = false }, onCancel: { showPillCamera = false })
        }
    }

    private var savedContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            if settings.medications.isEmpty {
                Text("No medications added yet").font(.title2.weight(.semibold))
                Text("Add a medication, then choose its reminder times.").foregroundColor(.secondary)
            }
            if !settings.medications.isEmpty { Text("Tap a medication to edit its name, reminders or reference photo.").foregroundColor(.secondary) }
            ForEach(settings.medications, id: \.medicationName) { medication in
                Button {
                    beginEditing()
                    selectedID = editor.items.first(where: { $0.name == medication.medicationName })?.id
                } label: {
                    HStack(spacing: 14) {
                        IconBadge(systemName: "pills.fill", color: CadenceTheme.accent, size: 44)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(medication.medicationName).font(.title3.weight(.semibold))
                            Text(timeSummary(medication.doseTimes)).font(.body).foregroundColor(.secondary)
                        }
                        Spacer()
                        Image(systemName: "pencil").foregroundColor(CadenceTheme.accent)
                    }.frame(maxWidth: .infinity, alignment: .leading).card()
                }.buttonStyle(.plain).accessibilityHint("Edit this medication and its reminder times")
            }
            GuardedButton(size: .big, style: .tinted(CadenceTheme.accent), action: addMedication) {
                Label("Add medication", systemImage: "plus")
            }
        }
    }

    private var editingContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Unsaved changes", systemImage: "pencil.circle").foregroundColor(CadenceTheme.caution)
            ForEach(Array(editor.items.enumerated()), id: \.element.id) { index, item in
                VStack(alignment: .leading, spacing: 16) {
                    Button { selectedID = item.id } label: {
                        HStack {
                            Text(item.name.isEmpty ? "New medication" : item.name).font(.headline)
                            Spacer()
                            Image(systemName: selectedID == item.id ? "chevron.up" : "chevron.down")
                        }.frame(minHeight: CadenceTheme.minimumTapHeight)
                    }.buttonStyle(.plain)
                    if selectedID == item.id {
                        TextField("Medication name", text: nameBinding(item.id))
                            .textFieldStyle(.roundedBorder).font(.title3)
                            .accessibilityLabel("Medication name")
                        Text("Reminder times").font(.headline)
                        if item.times.isEmpty { Text("No reminders yet. Add a time below.").foregroundColor(.secondary) }
                        ForEach(Array(item.times.enumerated()), id: \.offset) { timeIndex, time in
                            HStack {
                                DatePicker("Reminder \(timeIndex + 1)", selection: timeBinding(item.id, timeIndex), displayedComponents: .hourAndMinute)
                                Button(role: .destructive) { editor.items[index].times.remove(at: timeIndex) } label: {
                                    Image(systemName: "trash").frame(width: 44, height: 44)
                                }.accessibilityLabel("Remove reminder \(timeIndex + 1)")
                            }
                        }
                        Button { addTime(index) } label: {
                            Label("Add reminder time", systemImage: "plus.circle")
                        }.frame(minHeight: CadenceTheme.minimumTapHeight)
                        photoEditor(index)
                        Button("Remove medication", role: .destructive) {
                            editor.items.remove(at: index); selectedID = editor.items.first?.id
                        }.frame(minHeight: CadenceTheme.minimumTapHeight)
                    }
                }.card()
            }
            GuardedButton(style: .tinted(CadenceTheme.accent), action: addMedication) {
                Label("Add another medication", systemImage: "plus")
            }
        }
    }

    private func photoEditor(_ index: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Reference photo · optional").font(.headline)
            #if canImport(UIKit)
            if let data = editor.items[index].photo, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 160).clipShape(RoundedRectangle(cornerRadius: 12))
            }
            #endif
            Button("Take photo with glasses") { selectedID = editor.items[index].id; openGlassesCamera(automatic: false) }
            Button("Use iPhone camera") { cameraMedicationID = editor.items[index].id; showPillCamera = true }
            if editor.items[index].photo != nil {
                Button("Remove photo", role: .destructive) { editor.items[index].photo = nil; editor.items[index].photoChanged = true }
            }
            Text("The photo stays on this phone and appears on Today.").font(.footnote).foregroundColor(.secondary)
        }
    }

    private func openGlassesCamera(automatic: Bool) {
        guard let index = editor.items.firstIndex(where: { $0.id == selectedID }), !editor.items[index].name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            app.companion.say("Add the medication name first, then take its reference photo."); return
        }
        cameraMedicationID = editor.items[index].id; automaticVoiceCapture = automatic; showGlassesCamera = true
    }
    private func stagePhoto(_ data: Data?) {
        guard let index = editor.items.firstIndex(where: { $0.id == cameraMedicationID }) else { return }
        editor.items[index].photo = data; editor.items[index].photoChanged = true
    }
    private func addMedication() { beginEditing(); editor.add(); selectedID = editor.items.last?.id }
    private func save() {
        if editor.save() {
            selectedID = nil; Haptics.success()
            if isTab { app.companion.leaveFlow(id: voiceFlowID) }
            else { app.companion.updateFlow(id: voiceFlowID, step: .medication) }
            app.companion.say(editor.receipt ?? "Routine saved.")
        }
    }
    private func addTime(_ index: Int) {
        let existing = Set(editor.items[index].times)
        if let next = (0..<24).map({ DoseTime(hour: $0, minute: 0) }).first(where: { $0.hour >= 8 && !existing.contains($0) }) ?? (0..<24).map({ DoseTime(hour: $0, minute: 0) }).first(where: { !existing.contains($0) }) {
            editor.items[index].times.append(next)
        }
    }
    private func beginEditing() {
        editor.begin()
        app.companion.enterFlow(id: voiceFlowID, destination: .medication, step: .medicationSetup)
    }
    private func cancelEditing() {
        editor.cancel(); selectedID = nil
        if isTab { app.companion.leaveFlow(id: voiceFlowID) }
        else { app.companion.updateFlow(id: voiceFlowID, step: .medication) }
    }
    private func nameBinding(_ id: UUID) -> Binding<String> {
        Binding(get: { editor.items.first(where: { $0.id == id })?.name ?? "" }, set: { value in
            if let index = editor.items.firstIndex(where: { $0.id == id }) { editor.items[index].name = value }
        })
    }
    private func timeBinding(_ id: UUID, _ timeIndex: Int) -> Binding<Date> {
        Binding(get: {
            guard let index = editor.items.firstIndex(where: { $0.id == id }), editor.items[index].times.indices.contains(timeIndex) else { return Date() }
            let time = editor.items[index].times[timeIndex]
            return Calendar.current.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: Date()) ?? Date()
        }, set: { date in
            guard let index = editor.items.firstIndex(where: { $0.id == id }), editor.items[index].times.indices.contains(timeIndex) else { return }
            editor.items[index].times[timeIndex] = DoseTime(hour: Calendar.current.component(.hour, from: date), minute: Calendar.current.component(.minute, from: date))
        })
    }
    private func timeSummary(_ times: [DoseTime]) -> String {
        times.isEmpty ? "No reminders set" : times.sorted().map { time in
            let date = Calendar.current.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: Date()) ?? Date()
            return date.formatted(date: .omitted, time: .shortened)
        }.joined(separator: " · ")
    }
}
