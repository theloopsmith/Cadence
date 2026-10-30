import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Medication name, dose times, and the pill photo. Its own screen, so a
/// care partner can change a time without wading through contacts and
/// glasses. Steppers and preset chips; no sliders.
struct MedicationSetupView: View {
    @ObservedObject var app: CadenceAppModel
    @ObservedObject private var settings: AppSettings
    @State private var showPillCamera = false
    @State private var isCapturing = false
    @State private var photoError: String?
    @State private var photoRequestID = UUID()

    private static let presets = [
        DoseTime(hour: 8, minute: 0), DoseTime(hour: 12, minute: 0),
        DoseTime(hour: 16, minute: 0), DoseTime(hour: 20, minute: 0),
    ]

    init(app: CadenceAppModel) {
        self.app = app
        self.settings = app.settings
    }

    var body: some View {
        NavigationStack {
            Form {
                nameSection
                photoSection
                timesSection
            }
            .navigationTitle("Medication setup")
            .onDisappear { photoRequestID = UUID(); app.glasses.cancelPhotoCapture() }
            .cameraPresentation(
                isPresented: $showPillCamera,
                onCapture: { jpeg in
                    app.setPillPhoto(jpeg)
                    showPillCamera = false
                },
                onCancel: { showPillCamera = false }
            )
        }
    }

    private var nameSection: some View {
        Section {
            TextField("Medication name", text: $settings.schedule.medicationName)
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
                if let data = app.pillPhoto, let image = UIImage(data: data) {
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
                    Text(app.pillPhoto == nil ? "Add a photo of the pill" : "Pill photo")
                        .font(.headline)
                    Text("Shown on the Today card so the right tablet is easy to recognise.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button(isCapturing ? "Taking photo…" : "Take with glasses") {
                    photoError = nil
                    if app.glasses.canCapturePhoto {
                        isCapturing = true
                        let id = UUID(); photoRequestID = id
                        app.glasses.capturePhoto { result in
                            guard photoRequestID == id, !settings.restartRequired else { return }
                            isCapturing = false
                            switch result {
                            case let .success(jpeg):
                                app.setPillPhoto(jpeg)
                            case .failure(let error):
                                photoError = error.localizedDescription
                            }
                        }
                    } else {
                        app.glasses.connect()
                        photoError = "Connect Meta glasses, then try taking the photo again."
                    }
                }
                .disabled(isCapturing)
                .frame(minHeight: CadenceTheme.minimumTapHeight)
            }
            if let photoError { Text(photoError).foregroundColor(CadenceTheme.caution) }
            Button("Use iPhone camera instead") { showPillCamera = true }.disabled(isCapturing)
            if app.pillPhoto != nil {
                Button("Remove pill photo", role: .destructive) { app.setPillPhoto(nil) }
                    .frame(minHeight: CadenceTheme.minimumTapHeight)
            }
        } header: {
            Text("Photo")
        }
    }

    private var timesSection: some View {
        Section {
            if settings.schedule.doseTimes.isEmpty {
                Text("No times yet. Add one below.")
                    .foregroundColor(.secondary)
            }
            ForEach(Array(settings.schedule.doseTimes.enumerated()), id: \.element) { index, time in
                HStack(spacing: 12) {
                    Text(String(format: "%d:%02d", time.hour, time.minute))
                        .font(.title2.weight(.semibold).monospacedDigit())
                        .frame(minWidth: 84, alignment: .leading)
                    Spacer()
                    stepper("−15 min", systemImage: "minus") { adjust(index: index, minutes: -15) }
                    stepper("+15 min", systemImage: "plus") { adjust(index: index, minutes: 15) }
                    Button(role: .destructive) {
                        var times = settings.schedule.doseTimes
                        times.remove(at: index)
                        settings.schedule.doseTimes = times
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
                        .disabled(settings.schedule.doseTimes.contains(preset))
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
        var times = settings.schedule.doseTimes
        guard times.indices.contains(index) else { return }
        var total = times[index].minutesFromMidnight + delta
        total = min(max(total, 0), 23 * 60 + 45)
        times[index] = DoseTime(hour: total / 60, minute: total % 60)
        settings.schedule.doseTimes = times.sorted()
    }

    private func addTime(_ time: DoseTime) {
        var times = settings.schedule.doseTimes
        guard !times.contains(time) else { return }
        times.append(time)
        settings.schedule.doseTimes = times.sorted()
    }
}
