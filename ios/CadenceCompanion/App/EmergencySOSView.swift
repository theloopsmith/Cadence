import Combine
import SwiftUI

/// Full-screen check-in after a hard impact, then the beacon if no one answers.
///
/// The question has two enormous answers and a long, visible window. It can
/// be answered by voice ("I'm okay", "help") or by either button at any
/// point. Nobody is contacted until the window closes without an answer.
/// Once contacted, the screen flashes for bystanders and keeps going until
/// someone stops it on the device.
public struct EmergencySOSView: View {
    private static let flashInterval: TimeInterval = 0.60

    @ObservedObject private var coordinator: FallAlertCoordinator
    @State private var isFlashOn = false
    @State private var secondsRemaining: Int = Int(FallAlertCoordinator.checkInWindowSec)
    @State private var windowFraction: Double = 1.0

    private let flashTimer = Timer.publish(every: EmergencySOSView.flashInterval, on: .main, in: .common).autoconnect()
    private let tick = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    public init(coordinator: FallAlertCoordinator) {
        self.coordinator = coordinator
    }

    private var isDispatched: Bool { coordinator.isDispatched }

    private var backgroundColor: Color {
        guard isDispatched else { return CadenceTheme.background }
        return isFlashOn ? .white : CadenceTheme.danger
    }

    private var foregroundColor: Color {
        guard isDispatched else { return .primary }
        return isFlashOn ? CadenceTheme.danger : .white
    }

    public var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            VStack(spacing: 18) {
                Image(systemName: isDispatched ? "phone.arrow.up.right.fill" : "figure.fall")
                    .font(.system(size: 56, weight: .semibold))
                    .foregroundColor(isDispatched ? foregroundColor : CadenceTheme.caution)
                    .accessibilityHidden(true)
                Text(isDispatched ? "Trying to contact caregiver" : "Are you OK?")
                    .font(.system(size: 40, weight: .bold))
                    .multilineTextAlignment(.center)
                    .foregroundColor(foregroundColor)
                    .accessibilityAddTraits(.isHeader)
                Text(statusLine)
                    .font(.title3)
                    .multilineTextAlignment(.center)
                    .foregroundColor(foregroundColor.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
                if !isDispatched {
                    ProgressView(value: windowFraction)
                        .tint(CadenceTheme.caution)
                        .scaleEffect(x: 1, y: 2, anchor: .center)
                        .padding(.horizontal, 8)
                        .accessibilityLabel("Time left to answer")
                        .accessibilityValue("\(secondsRemaining) seconds")
                }
            }
            .padding(.horizontal, 28)
            Spacer()
            answers
                .padding(.horizontal, 20)
                .padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(backgroundColor.ignoresSafeArea())
        .animation(.easeInOut(duration: 0.18), value: isFlashOn)
        .onReceive(flashTimer) { _ in
            guard isDispatched else { isFlashOn = false; return }
            isFlashOn.toggle()
        }
        .onReceive(tick) { now in
            guard case let .checkIn(_, deadline) = coordinator.phase else { return }
            let remaining = max(0, deadline.timeIntervalSince(now))
            secondsRemaining = Int(remaining.rounded(.up))
            windowFraction = remaining / FallAlertCoordinator.checkInWindowSec
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            isDispatched
                ? "Trying to contact caregiver. Siren sounding. Tap I'm OK now to stop."
                : "Are you OK? Say I am okay, or tap I'm OK. Say help, or tap I need help."
        )
    }

    @ViewBuilder
    private var answers: some View {
        if isDispatched {
            VStack(spacing: CadenceTheme.tapGap) {
                HStack(spacing: CadenceTheme.tapGap) {
                    GuardedButton(size: .big, style: .filled(foregroundColor.opacity(0.18)), action: {
                        coordinator.callCaregiver()
                    }) {
                        Label(coordinator.caregiverButtonTitle, systemImage: "phone.fill")
                            .foregroundColor(foregroundColor)
                    }
                    GuardedButton(size: .big, style: .filled(foregroundColor.opacity(0.18)), action: {
                        coordinator.callEmergencyServices()
                    }) {
                        Label(coordinator.emergencyNumber, systemImage: "cross.case.fill")
                            .foregroundColor(foregroundColor)
                    }
                }
                GuardedButton(size: .giant, style: .filled(foregroundColor), action: { coordinator.cancelByUser() }) {
                    Label("I'm OK now — stop", systemImage: "checkmark")
                        .foregroundColor(backgroundColor)
                }
                .accessibilityHint("Stops the siren and queues a cancellation for your caregiver")
            }
        } else {
            VStack(spacing: CadenceTheme.tapGap) {
                GuardedButton(size: .giant, style: .filled(CadenceTheme.calm), action: { coordinator.cancelByUser() }) {
                    Label("I'm OK", systemImage: "checkmark")
                }
                .accessibilityHint("Closes the check-in. No one is contacted.")
                GuardedButton(size: .giant, style: .filled(CadenceTheme.danger), action: {
                    coordinator.escalate(status: "confirmed_waiting_dispatch")
                }) {
                    Label("I need help", systemImage: "phone.fill")
                }
                .accessibilityHint("Saves an alert and tries to contact your caregiver")
            }
        }
    }

    private var statusLine: String {
        if let warning = coordinator.persistenceWarning { return warning }
        if isDispatched {
            return "A loud sound is playing so people nearby can find you. Saved on device; retrying caregiver alert. Use the call buttons if you need help now."
        }
        return "You can say “I'm okay” or “help”, or tap below. Take your time — \(secondsRemaining) seconds left before anyone is contacted."
    }
}
