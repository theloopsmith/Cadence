import SwiftUI

/// Full-screen high-contrast SOS beacon with one-tap caregiver / emergency
/// dialing.
///
/// Once dispatched this keeps flashing and sounding the `.speaker` siren even
/// after the backend's 15-minute Twilio retry cap is exhausted, until a human
/// physically cancels on the device. During the 12-second check-in window the
/// screen stays calm: the wearer is being asked a question, not alarmed.
public struct EmergencySOSView: View {
    /// Flashing is driven by a timer rather than a repeating animation so the
    /// beacon keeps its cadence when the view is recomposed mid-alert.
    private static let flashInterval: TimeInterval = 0.60

    @ObservedObject private var coordinator: FallAlertCoordinator
    @State private var isFlashOn = false
    @State private var secondsRemaining: Int = Int(FallAlertCoordinator.checkInWindowSec)

    private let flashTimer = Timer.publish(
        every: EmergencySOSView.flashInterval, on: .main, in: .common
    ).autoconnect()
    private let countdownTimer = Timer.publish(
        every: 1.0, on: .main, in: .common
    ).autoconnect()

    public init(coordinator: FallAlertCoordinator) {
        self.coordinator = coordinator
    }

    private var isDispatched: Bool { coordinator.isDispatched }

    /// Red and white alternate once dispatched; the check-in screen is a steady
    /// amber so it reads as a question rather than an emergency.
    private var backgroundColor: Color {
        guard isDispatched else { return Color(red: 0.85, green: 0.47, blue: 0.02) }
        return isFlashOn ? .white : Color(red: 0.86, green: 0.08, blue: 0.08)
    }

    private var foregroundColor: Color {
        guard isDispatched else { return .white }
        return isFlashOn ? Color(red: 0.86, green: 0.08, blue: 0.08) : .white
    }

    public var body: some View {
        VStack(spacing: 20) {
            Text(isDispatched ? "EMERGENCY FALL ALERT" : "ARE YOU OK?")
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)
                .foregroundColor(foregroundColor)
                .accessibilityAddTraits(.isHeader)

            Text(statusLine)
                .font(.headline)
                .multilineTextAlignment(.center)
                .foregroundColor(foregroundColor.opacity(0.95))

            Button(action: { coordinator.cancelByUser() }) {
                Text("I'M OKAY — CANCEL ALERT")
                    .font(.title2.bold())
                    .padding()
                    .frame(maxWidth: .infinity, minHeight: 64)
                    .background(foregroundColor)
                    .foregroundColor(backgroundColor)
                    .cornerRadius(14)
            }
            .accessibilityHint("Cancels the fall alert and stops the siren")

            if isDispatched {
                // Shown only after escalation. iOS cannot place a call without
                // the wearer confirming, so these open the dialer pre-filled.
                HStack(spacing: 12) {
                    Button(action: { coordinator.callCaregiver() }) {
                        Label(coordinator.caregiverButtonTitle, systemImage: "phone.fill")
                            .font(.headline)
                            .padding()
                            .frame(maxWidth: .infinity, minHeight: 56)
                            .background(foregroundColor.opacity(0.18))
                            .foregroundColor(foregroundColor)
                            .cornerRadius(12)
                    }
                    Button(action: { coordinator.callEmergencyServices() }) {
                        Label(coordinator.emergencyNumber, systemImage: "cross.case.fill")
                            .font(.headline)
                            .padding()
                            .frame(maxWidth: .infinity, minHeight: 56)
                            .background(foregroundColor.opacity(0.18))
                            .foregroundColor(foregroundColor)
                            .cornerRadius(12)
                    }
                }
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(backgroundColor)
        .animation(.easeInOut(duration: 0.18), value: isFlashOn)
        .onReceive(flashTimer) { _ in
            guard isDispatched else {
                isFlashOn = false
                return
            }
            isFlashOn.toggle()
        }
        .onReceive(countdownTimer) { now in
            guard case let .checkIn(_, deadline) = coordinator.phase else { return }
            secondsRemaining = max(0, Int(deadline.timeIntervalSince(now).rounded(.up)))
        }
        // One announcement rather than a per-flash barrage for VoiceOver users.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            isDispatched
                ? "Emergency fall alert active. Caregiver notified. Siren sounding."
                : "Are you OK? Say I am okay, or tap to cancel."
        )
    }

    private var statusLine: String {
        if isDispatched {
            return "Bystander siren active • Caregiver notified"
        }
        return "Say “I am okay” or tap below • \(secondsRemaining)s"
    }
}
