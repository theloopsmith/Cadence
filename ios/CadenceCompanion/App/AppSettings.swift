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
        static let schedule = "cadence.medicationSchedule"
    }

    /// Shows the Developer tab. Not a user setting: on in debug builds, and
    /// on in any build launched with `-cadence-developer`, so testers get it
    /// from Xcode or a scheme without anything appearing in setup.
    @Published public var developerModeEnabled: Bool

    public nonisolated static var defaultDeveloperMode: Bool {
        if ProcessInfo.processInfo.arguments.contains("-cadence-developer") { return true }
        if ProcessInfo.processInfo.environment["CADENCE_DEVELOPER"] == "1" { return true }
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    /// Dose times set up by a care partner. Reminders only.
    @Published public var schedule: MedicationSchedule {
        didSet {
            if let data = try? JSONEncoder().encode(schedule) {
                defaults.set(data, forKey: Key.schedule)
            }
        }
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
    /// The offline queue every event goes through.
    public let sync: EventSyncManager
    private weak var fallAlert: FallAlertCoordinator?
    private weak var exam: HomeMotorExamManager?

    public init(
        defaults: UserDefaults = .standard,
        sync: EventSyncManager = .shared,
        developerMode: Bool = AppSettings.defaultDeveloperMode
    ) {
        self.defaults = defaults
        self.sync = sync
        self.developerModeEnabled = developerMode
        backendBaseURL = defaults.string(forKey: Key.backendBaseURL) ?? "http://localhost:8000"
        deviceToken = defaults.string(forKey: Key.deviceToken) ?? "cadence-dev-device-writer-token-2026"
        caregiverName = defaults.string(forKey: Key.caregiverName) ?? ""
        caregiverPhone = defaults.string(forKey: Key.caregiverPhone) ?? ""
        emergencyNumber = defaults.string(forKey: Key.emergencyNumber) ?? "911"
        protectionEnabled = defaults.object(forKey: Key.protectionEnabled) as? Bool ?? true
        if let data = defaults.data(forKey: Key.schedule),
           let saved = try? JSONDecoder().decode(MedicationSchedule.self, from: data) {
            schedule = saved
        } else {
            schedule = MedicationSchedule(medicationName: "Levodopa", doseTimes: [])
        }
        apply()
    }

    /// Connects the coordinators that read caregiver and backend details.
    public func bind(fallAlert: FallAlertCoordinator, exam: HomeMotorExamManager) {
        self.fallAlert = fallAlert
        self.exam = exam
        apply()
    }

    /// Swapped by tests so no request leaves the process.
    public var apiTransport: JSONTransporting = URLSessionJSONTransport()

    public var api: CadenceAPIClient {
        CadenceAPIClient(baseURL: trimmedBaseURL, bearerToken: deviceToken, transport: apiTransport)
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
