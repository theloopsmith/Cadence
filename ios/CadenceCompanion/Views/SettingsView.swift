import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct SettingsView: View {
    @ObservedObject var app: CadenceAppModel
    @ObservedObject private var settings: AppSettings

    init(app: CadenceAppModel) {
        self.app = app
        self.settings = app.settings
    }

    var body: some View {
        NavigationStack {
            Form {
                caregiverSection
                aboutSection
            }
            .navigationTitle("Care partner setup")
        }
    }

    // MARK: - Caregiver

    private var caregiverSection: some View {
        Section {
            TextField("Caregiver's name", text: $settings.caregiverName)
            TextField("Caregiver's phone", text: $settings.caregiverPhone)
                #if os(iOS)
                .textContentType(.telephoneNumber)
                .keyboardType(.phonePad)
                #endif
            TextField("Emergency number", text: $settings.emergencyNumber)
                #if os(iOS)
                .keyboardType(.phonePad)
                #endif
        } header: {
            Text("Caregiver")
        } footer: {
            Text("Contacted only if you fall and do not answer the voice check-in.")
        }
    }

    private var aboutSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("Cadence is a daily-living companion, not a medical device.")
                    .font(.subheadline.weight(.semibold))
                Text("It does not diagnose or assess a condition and never suggests changes to medication. Trends in the diary are there to share with your care team.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)
        } header: {
            Text("About")
        }
    }
}
