import SwiftUI

/// Calling actions only. Calls open the dialer for confirmation.
struct HelpView: View {
    @ObservedObject var app: CadenceAppModel
    private var caregiverName: String {
        let name = app.settings.caregiverName.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "your caregiver" : name
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: CadenceTheme.tapGap) {
                    VoiceCompanionBar(app: app)

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
                            Text("Your care partner’s contact has not been set up.")
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


                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(CadenceTheme.background.ignoresSafeArea())
            .navigationTitle("Get help")


        }
    }
}
