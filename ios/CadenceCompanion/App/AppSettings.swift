import Combine
import Foundation

/// User-editable configuration, persisted in `UserDefaults` and pushed into
/// the subsystems that need it whenever a value changes.
@MainActor
public final class AppSettings: ObservableObject {
    private enum Key {
        static let backendBaseURL = "cadence.backendBaseURL"
        static let deviceToken = "cadence.deviceToken"
        static let caregiverName = "cadence.caregiverName"
        static let caregiverPhone = "cadence.caregiverPhone"
        static let emergencyNumber = "cadence.emergencyNumber"
        static let protectionEnabled = "cadence.protectionEnabled"
    }

    @Published public var backendBaseURL: String {
        didSet { defaults.set(backendBaseURL, forKey: Key.backendBaseURL); apply() }
    }
    @Published public var deviceToken: String {
        didSet { defaults.set(deviceToken, forKey: Key.deviceToken); apply() }
    }
    @Published public var caregiverName: String {
        didSet { defaults.set(caregiverName, forKey: Key.caregiverName) }
    }
    @Published public var caregiverPhone: String {
        didSet { defaults.set(caregiverPhone, forKey: Key.caregiverPhone); apply() }
    }
    @Published public var emergencyNumber: String {
        didSet { defaults.set(emergencyNumber, forKey: Key.emergencyNumber); apply() }
    }
    /// Whether the wearer wants motion protection to start with the app.
    @Published public var protectionEnabled: Bool {
        didSet { defaults.set(protectionEnabled, forKey: Key.protectionEnabled) }
    }

    private let defaults: UserDefaults
    private let sync: EventSyncManager
    private weak var fallAlert: FallAlertCoordinator?
    private weak var exam: HomeMotorExamManager?

    public init(
        defaults: UserDefaults = .standard,
        sync: EventSyncManager = .shared
    ) {
        self.defaults = defaults
        self.sync = sync
        backendBaseURL = defaults.string(forKey: Key.backendBaseURL) ?? "http://localhost:8000"
        deviceToken = defaults.string(forKey: Key.deviceToken) ?? "cadence-dev-device-writer-token-2026"
        caregiverName = defaults.string(forKey: Key.caregiverName) ?? ""
        caregiverPhone = defaults.string(forKey: Key.caregiverPhone) ?? ""
        emergencyNumber = defaults.string(forKey: Key.emergencyNumber) ?? "911"
        protectionEnabled = defaults.object(forKey: Key.protectionEnabled) as? Bool ?? true
        apply()
    }

    /// Connects the coordinators that read caregiver and backend details.
    public func bind(fallAlert: FallAlertCoordinator, exam: HomeMotorExamManager) {
        self.fallAlert = fallAlert
        self.exam = exam
        apply()
    }

    public var api: CadenceAPIClient {
        CadenceAPIClient(baseURL: trimmedBaseURL, bearerToken: deviceToken)
    }

    public var hasCaregiver: Bool {
        !caregiverPhone.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var trimmedBaseURL: String {
        var url = backendBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while url.hasSuffix("/") { url.removeLast() }
        return url
    }

    private func apply() {
        sync.backendBaseURL = trimmedBaseURL
        sync.deviceBearerToken = deviceToken
        exam?.backendBaseURL = trimmedBaseURL
        exam?.deviceBearerToken = deviceToken
        fallAlert?.caregiverPhoneNumber = hasCaregiver ? caregiverPhone : nil
        fallAlert?.emergencyNumber = emergencyNumber.isEmpty ? "911" : emergencyNumber
    }
}
