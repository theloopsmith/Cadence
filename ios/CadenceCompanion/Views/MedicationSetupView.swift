import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Medication name, dose times, and the pill photo. Its own screen, so a
/// care partner can change a time without wading through contacts and
/// glasses. Steppers and preset chips; no sliders.
struct MedicationSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var voiceFlowID = UUID()
    @State private var draft: [MedicationSchedule] = []
    @State private var selected = 0
    @State private var loaded = false
    @State private var saveError: String?
    @State private var saveSuccessMessage: String?
    @State private var newTime = Date()
    @State private var draftPhotos: [String: Data] = [:]
    @State private var loadedPhotos: [String: Data] = [:]
    @State private var removedPhotos: Set<String> = []
    @ObservedObject var app: CadenceAppModel
    @ObservedObject private var settings: AppSettings
    @State private var automaticVoiceCapture = false
    @State private var showGlassesCamera = false
    @State private var showPillCamera = false
    let isTab: Bool

    private static let presets = [
        DoseTime(hour: 8, minute: 0), DoseTime(hour: 12, minute: 0),
        DoseTime(hour: 16, minute: 0), DoseTime(hour: 20, minute: 0),
    ]

    init(app: CadenceAppModel, isTab: Bool = false) {
        self.app = app
        self.settings = app.settings
        self.isTab = isTab
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Your medications") {
                    ForEach(Array(draft.enumerated()), id: \.offset) { index, medication in
                        Button {
                            selected = index
                        } label: {
                            HStack {
                                Text(medication.medicationName.isEmpty ? "New medication" : medication.medicationName)
                                Spacer()
                                if selected == index { Image(systemName: "checkmark") }
                            }
                        }
                    }
                    Button("Add medication") {
                        draft.append(MedicationSchedule(medicationName: "", doseTimes: []))
                        selected = draft.count - 1
                    }
                }
                if draft.indices.contains(selected) {
                    nameSection
                    photoSection.disabled(draft[selected].medicationName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    timesSection
                    Button("Remove this medication", role: .destructive) {
                        draft.remove(at: selected)
                        selected = max(0, min(selected, draft.count - 1))
                    }
                }
                if let saveSuccessMessage {
                    Text(saveSuccessMessage)
                        .foregroundColor(CadenceTheme.calm)
                        .font(.subheadline.weight(.semibold))
                }
                if let saveError { Text(saveError).foregroundColor(CadenceTheme.caution) }
                Button("Save medications") { save() }.buttonStyle(PrimaryButtonStyle())
            }
            .navigationTitle(isTab ? "Medication" : "Medication setup")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .onDisappear {
                if !isTab { app.companion.leaveFlow(id: voiceFlowID) }
            }
            .onAppear {
                draft = settings.medications
                for medication in draft {
                    loadedPhotos[medication.medicationName] = medication.medicationName == settings.schedule.medicationName ? app.pillPhoto : app.pillPhotos.forMedication(medication.medicationName).load()
                }
                loaded = true
                saveSuccessMessage = nil
                saveError = nil
                if !isTab {
                    app.companion.enterFlow(id: voiceFlowID, destination: .medication, step: .medication)
                }
            }
            .onChange(of: app.companion.actionID) { _ in
                guard app.companion.context == .medication else { return }
                if app.companion.action == .capture {
                    if draft.indices.contains(selected), !draft[selected].medicationName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        automaticVoiceCapture = true; showGlassesCamera = true
                    } else { app.companion.say("Add the medication's name first so I can keep its photo with the right medication.") }
                }
                if app.companion.action == .finish { save() }
                if app.companion.action == .cancel { dismiss() }
            }
            .interactiveDismissDisabled()
            .toolbar {
                if !isTab {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() } }
            }
            .sheet(isPresented: $showGlassesCamera) {
                GlassesCameraView(glasses: app.glasses, voice: app.companion, captureWhenReady: automaticVoiceCapture, title: "Medication photo") { jpeg in
                    stagePhoto(jpeg)
                }
            }
            .cameraPresentation(
                isPresented: $showPillCamera,
                onCapture: { jpeg in
                    stagePhoto(jpeg)
                    showPillCamera = false
                },
                onCancel: { showPillCamera = false }
            )
        }
    }

    private var currentPhoto: Data? {
        guard draft.indices.contains(selected) else { return nil }
        let name = draft[selected].medicationName
        return draftPhotos[name] ?? (removedPhotos.contains(name) ? nil : loadedPhotos[name])
    }

    private func stagePhoto(_ data: Data?) {
        guard draft.indices.contains(selected) else { return }
        let name = draft[selected].medicationName
        draftPhotos[name] = data
        if data == nil { removedPhotos.insert(name) } else { removedPhotos.remove(name) }
    }

    private func save() {
        saveError = nil
        saveSuccessMessage = nil
        do {
            try settings.saveMedicationPlan(draft)
            for medication in draft {
                let name = medication.medicationName
                if draftPhotos[name] != nil || removedPhotos.contains(name) {
                    app.setPillPhoto(draftPhotos[name], medicationName: name.trimmingCharacters(in: .whitespacesAndNewlines))
                    if let error = app.photoSaveError { saveError = "Medication times are saved. " + error; return }
                }
            }
            saveSuccessMessage = "Medication schedule saved."
            Haptics.success()
            if !isTab { dismiss() }
        } catch { saveError = error.localizedDescription }
    }

    private var nameSection: some View {
        Section {
            TextField("Medication name", text: $draft[selected].medicationName)
                .frame(minHeight: CadenceTheme.minimumTapHeight)
        } header: {
            Text("Medication")
        } footer: {
            Text("Reminders only. Cadence never suggests changing a dose or its timing; use the times the prescriber gave.")
        }
    }

    private var photoSection: some View {
        Section {
            HStack(spacing: 14) {
                #if canImport(UIKit)
                if let data = currentPhoto, let image = UIImage(data: data) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: CadenceTheme.controlRadius, style: .continuous))
                } else {
                    IconBadge(systemName: "pills.fill", color: .secondary, size: 56)
                }
                #endif
                VStack(alignment: .leading, spacing: 2) {
                    Text(currentPhoto == nil ? "Add a photo of the pill" : "Pill photo")
                        .font(.headline)
                    Text("Shown on the Today card so the right tablet is easy to recognise.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button("Open glasses camera") { showGlassesCamera = true }
                .frame(minHeight: CadenceTheme.minimumTapHeight)
            }
            Button("Use iPhone camera instead") { showPillCamera = true }
            if currentPhoto != nil {
                Button("Remove pill photo", role: .destructive) { stagePhoto(nil) }
                    .frame(minHeight: CadenceTheme.minimumTapHeight)
            }
        } header: {
            Text("Photo")
        }
    }

    private var timesSection: some View {
        Section {
            if draft[selected].doseTimes.isEmpty {
                Text("No times yet. Add one below.")
                    .foregroundColor(.secondary)
            }
            ForEach(Array(draft[selected].doseTimes.enumerated()), id: \.element) { index, time in
                HStack(spacing: 12) {
                    Text(String(format: "%d:%02d", time.hour, time.minute))
                        .font(.title2.weight(.semibold).monospacedDigit())
                        .frame(minWidth: 84, alignment: .leading)
                    Spacer()
                    stepper("−15 min", systemImage: "minus") { adjust(index: index, minutes: -15) }
                    stepper("+15 min", systemImage: "plus") { adjust(index: index, minutes: 15) }
                    Button(role: .destructive) {
                        var times = draft[selected].doseTimes
                        times.remove(at: index)
                        draft[selected].doseTimes = times
                    } label: {
                        Image(systemName: "trash")
                            .frame(width: CadenceTheme.minimumTapHeight, height: CadenceTheme.minimumTapHeight)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remove \(time.hour):\(String(format: "%02d", time.minute))")
                }
                .frame(minHeight: CadenceTheme.minimumTapHeight)
            }

            VStack(alignment: .leading, spacing: 10) {
                DatePicker("Reminder time", selection: $newTime, displayedComponents: .hourAndMinute)
                Button("Add selected time") {
                    let calendar = Calendar.current
                    addTime(DoseTime(hour: calendar.component(.hour, from: newTime), minute: calendar.component(.minute, from: newTime)))
                }
                Text("Add a time")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                HStack(spacing: 10) {
                    ForEach(Self.presets, id: \.self) { preset in
                        Button(String(format: "%d:%02d", preset.hour, preset.minute)) {
                            addTime(preset)
                        }
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: CadenceTheme.minimumTapHeight)
                        .buttonStyle(.bordered)
                        .tint(CadenceTheme.accent)
                        .disabled(draft[selected].doseTimes.contains(preset))
                    }
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("Dose times")
        } footer: {
            Text("Use the plus and minus buttons to move a time in 15-minute steps.")
        }
    }

    private func stepper(_ label: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.headline)
                .frame(width: CadenceTheme.minimumTapHeight, height: CadenceTheme.minimumTapHeight)
        }
        .buttonStyle(.bordered)
        .tint(CadenceTheme.accent)
        .accessibilityLabel(label)
    }

    private func adjust(index: Int, minutes delta: Int) {
        var times = draft[selected].doseTimes
        guard times.indices.contains(index) else { return }
        var total = times[index].minutesFromMidnight + delta
        total = min(max(total, 0), 23 * 60 + 45)
        times[index] = DoseTime(hour: total / 60, minute: total % 60)
        draft[selected].doseTimes = times.sorted()
    }

    private func addTime(_ time: DoseTime) {
        var times = draft[selected].doseTimes
        guard !times.contains(time) else { return }
        times.append(time)
        draft[selected].doseTimes = times.sorted()
    }
}
