import SwiftUI

/// Call the caregiver, call emergency services, and the door to care-partner
/// setup. Calls open the dialer so a stray tap never places one unseen.
struct HelpView: View {
    @ObservedObject var app: CadenceAppModel
    enum Setup: Identifiable {
        case medication, carePartner
        var id: Int { hashValue }
    }

    @State private var pendingSetup: Setup?

    private var caregiverName: String {
        let name = app.settings.caregiverName.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "your caregiver" : name
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: CadenceTheme.tapGap) {
                    Text("Tap a button. Your phone will show the number so you can confirm the call.")
                        .font(.body)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if app.settings.hasCaregiver {
                        GuardedButton(size: .giant, style: .filled(CadenceTheme.calm), action: {
                            app.fallAlert.callCaregiver()
                        }) {
                            Label("Call \(caregiverName)", systemImage: "phone.fill")
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("No caregiver added yet")
                                .font(.headline)
                            Text("A care partner can add a number in setup below.")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        .card()
                    }

                    GuardedButton(size: .giant, style: .filled(CadenceTheme.danger), action: {
                        app.fallAlert.callEmergencyServices()
                    }) {
                        Label("Call \(app.settings.emergencyNumber)", systemImage: "cross.case.fill")
                    }

                    Spacer(minLength: 32)

                    GuardedButton(size: .big, style: .tinted(.secondary), action: { pendingSetup = .medication }) {
                        Label("Medication setup", systemImage: "pills.fill")
                    }
                    GuardedButton(size: .big, style: .tinted(.secondary), action: { pendingSetup = .carePartner }) {
                        Label("Settings", systemImage: "gearshape.fill")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(CadenceTheme.background.ignoresSafeArea())
            .navigationTitle("Help")
            .confirmationDialog(
                pendingSetup == .medication ? "Open medication setup?" : "Open settings?",
                isPresented: Binding(get: { pendingSetup != nil }, set: { if !$0 { pendingSetup = nil } }),
                titleVisibility: .visible
            ) {
                Button("Open") {
                    app.companion.destination = pendingSetup == .medication ? .medication : .settings
                    pendingSetup = nil
                }
                Button("Not now", role: .cancel) { pendingSetup = nil }
            } message: {
                Text(
                    pendingSetup == .medication
                        ? "Medication name, dose times, and the pill photo."
                        : "Voice, glasses, server connection, and contacts."
                )
            }

        }
    }
}
