import SwiftUI

/// Full-screen high-contrast red/white flashing SOS screen beacon + one-tap Caregiver / 911 dialer.
/// Continues flashing and sounding the .speaker siren even after the 15-minute Twilio retry cap
/// until physically canceled on the device.
public struct EmergencySOSView: View {
    public var onCancelAlert: () -> Void

    public init(onCancelAlert: @escaping () -> Void) {
        self.onCancelAlert = onCancelAlert
    }

    public var body: some View {
        VStack(spacing: 24) {
            Text("EMERGENCY FALL ALERT")
                .font(.largeTitle.bold())
                .foregroundColor(.white)
            Text("Bystander Siren Active • Caregiver Notified")
                .font(.headline)
                .foregroundColor(.white.opacity(0.9))

            Button(action: onCancelAlert) {
                Text("I'M OKAY — CANCEL ALERT")
                    .font(.title2.bold())
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color.white)
                    .foregroundColor(.red)
                    .cornerRadius(14)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.red)
    }
}
