import Combine
import Foundation

/// User-editable configuration, persisted in `UserDefaults` and pushed into
/// the subsystems that need it whenever a value changes.
@MainActor
public final class AppSettings: ObservableObject {
    public let profile: DeviceProfile
    @Published public private(set) var profileNotice: String?
    @Published public private(set) var restartRequired = false
    @Published public private(set) var isConnecting = false
    @Published public private(set) var connectionMessage: String?
    private var changingCredentials = false
    private enum Key {
        static let backendBaseURL = "cadence.backendBaseURL"
        /// Read once to move an older build's token into the Keychain, then erased.
        static let legacyDeviceToken = "cadence.deviceToken"
        static let signedInUsername = "cadence.signedInUsername"
        static let summaryName = "cadence.summaryName"
        static let preferredVoice = "cadence.preferredVoice"
        static let cloudListening = "cadence.cloudListening"
        static let caregiverName = "cadence.caregiverName"
        static let caregiverPhone = "cadence.caregiverPhone"
        static let emergencyNumber = "cadence.emergencyNumber"
        static let protectionEnabled = "cadence.protectionEnabled"
        static let schedule = "cadence.medicationSchedule"
    }

    /// Explicit testing tools, hidden behind the Settings toggle by default.
    @Published public var developerModeEnabled: Bool {
        didSet { defaults.set(developerModeEnabled, forKey: scoped("developerModeEnabled")) }
    }

    public nonisolated static var defaultDeveloperMode: Bool {
        if ProcessInfo.processInfo.arguments.contains("-cadence-developer") { return true }
        if ProcessInfo.processInfo.environment["CADENCE_DEVELOPER"] == "1" { return true }
        return false
    }

    /// Dose times set up by a care partner. Reminders only.
    @Published public private(set) var medications: [MedicationSchedule] = []
    private var updatingMedicationPlan = false
    @Published public var schedule: MedicationSchedule {
        didSet {
            if let data = try? JSONEncoder().encode(schedule) {
                defaults.set(data, forKey: scoped(Key.schedule))
            }
            if !updatingMedicationPlan {
                var plan = medications
                if plan.isEmpty { plan = [schedule] } else { plan[0] = schedule }
                medications = plan
                if let data = try? JSONEncoder().encode(plan) { defaults.set(data, forKey: scoped("medications")) }
            }
        }
    }

    @Published public var backendBaseURL: String {
        didSet {
            guard !changingCredentials else { return }
            guard acceptSession(token: deviceToken, destination: backendBaseURL) else {
                changingCredentials = true; backendBaseURL = oldValue; changingCredentials = false; return
            }
            defaults.set(backendBaseURL, forKey: Key.backendBaseURL); apply()
        }
    }
    /// The sign-in token, kept in the Keychain and never in UserDefaults.
    @Published public var deviceToken: String {
        didSet {
            guard !changingCredentials else { return }
            guard acceptSession(token: deviceToken, destination: backendBaseURL) else {
                changingCredentials = true; deviceToken = oldValue; changingCredentials = false; return
            }
            tokenStore.write(deviceToken); apply()
        }
    }
    /// Who the phone is signed in as, for display only.
    @Published public var signedInUsername: String? {
        didSet { defaults.set(signedInUsername, forKey: scoped(Key.signedInUsername)) }
    }

    /// The shared development token, available in debug builds so the app
    /// works against a local server before anyone signs in.
    public nonisolated static var developmentToken: String {
        #if DEBUG
        return "cadence-dev-device-writer-token-2026"
        #else
        return ""
        #endif
    }

    /// Server address baked into the build (`CadenceServerURL` in Info.plist),
    /// or the local development server.
    public nonisolated static var bundledServerURL: String {
        let configured = (Bundle.main.object(forInfoDictionaryKey: "CadenceServerURL") as? String)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return configured.isEmpty || configured.hasPrefix("$(") ? "http://localhost:8000" : configured
    }
    /// The voice prompts are spoken in. Nil picks the most natural installed.
    @Published public var preferredVoiceIdentifier: String? {
        didSet { defaults.set(preferredVoiceIdentifier, forKey: scoped(Key.preferredVoice)); apply() }
    }
    @Published public var voiceCompanionEnabled: Bool {
        didSet { defaults.set(voiceCompanionEnabled, forKey: scoped("voiceCompanionEnabled")) }
    }

    /// Muse Voice Transcribe listens alongside the on-device recognizer when online.
    @Published public var cloudListeningEnabled: Bool {
        didSet { defaults.set(cloudListeningEnabled, forKey: scoped(Key.cloudListening)) }
    }

    /// The name printed at the top of shared summaries. Optional.
    @Published public var summaryName: String {
        didSet { defaults.set(summaryName, forKey: scoped(Key.summaryName)) }
    }
    @Published public var caregiverName: String {
        didSet { defaults.set(caregiverName, forKey: scoped(Key.caregiverName)) }
    }
    @Published public var caregiverPhone: String {
        didSet { defaults.set(caregiverPhone, forKey: scoped(Key.caregiverPhone)); apply() }
    }
    @Published public var emergencyNumber: String {
        didSet { defaults.set(emergencyNumber, forKey: scoped(Key.emergencyNumber)); apply() }
    }
    /// Whether the wearer wants motion protection to start with the app.
    @Published public var protectionEnabled: Bool {
        didSet { defaults.set(protectionEnabled, forKey: scoped(Key.protectionEnabled)) }
    }

    private let defaults: UserDefaults
    private let tokenStore: TokenStoring
    /// The offline queue every event goes through.
    public let sync: EventSyncManager
    private weak var fallAlert: FallAlertCoordinator?
    private weak var exam: HomeMotorExamManager?

    public init(
        defaults: UserDefaults = .standard,
        sync: EventSyncManager = .shared,
        developerMode: Bool = AppSettings.defaultDeveloperMode,
        tokenStore: TokenStoring? = nil,
        defaultToken: String = AppSettings.developmentToken,
        profile: DeviceProfile? = nil
    ) {
        let profile = profile ?? (NSClassFromString("XCTestCase") != nil
            ? DeviceProfile(root: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("profile-\(UUID())")) : .shared)
        self.profile = profile
        let localKey: (String) -> String = { "cadence.profile.\(profile.id).\($0)" }
        let store = tokenStore ?? (NSClassFromString("XCTestCase") != nil ? InMemoryTokenStore() : KeychainTokenStore())
        self.defaults = defaults
        self.tokenStore = store
        self.sync = sync
        self.developerModeEnabled = defaults.object(forKey: localKey("developerModeEnabled")) as? Bool ?? developerMode
        backendBaseURL = defaults.string(forKey: Key.backendBaseURL) ?? AppSettings.bundledServerURL
        if let legacy = defaults.string(forKey: Key.legacyDeviceToken), store.read() == nil {
            store.write(legacy)
        }
        defaults.removeObject(forKey: Key.legacyDeviceToken)
        let requiresFreshLogin = !profile.isBound && !profile.allowsDevelopmentDefault
        if requiresFreshLogin { store.write("") }
        for retiredID in profile.erasedProfileIDs {
            for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("cadence.profile.\(retiredID).") {
                defaults.removeObject(forKey: key)
            }
        }
        deviceToken = requiresFreshLogin ? "" : (store.read() ?? (profile.allowsDevelopmentDefault ? defaultToken : ""))
        signedInUsername = defaults.string(forKey: localKey(Key.signedInUsername))
        summaryName = defaults.string(forKey: localKey(Key.summaryName)) ?? ""
        preferredVoiceIdentifier = defaults.string(forKey: localKey(Key.preferredVoice))
        // Upgrade the old button-driven setup once. Afterwards, an explicit
        // voice-off choice made in the new setup still survives reopening.
        let automaticVoiceKey = localKey("automaticVoiceStartupV1")
        if !defaults.bool(forKey: automaticVoiceKey) {
            voiceCompanionEnabled = true
            defaults.set(true, forKey: localKey("voiceCompanionEnabled"))
            defaults.set(true, forKey: automaticVoiceKey)
        } else {
            voiceCompanionEnabled = defaults.object(forKey: localKey("voiceCompanionEnabled")) as? Bool ?? true
        }
        cloudListeningEnabled = defaults.object(forKey: localKey(Key.cloudListening)) as? Bool ?? true
        caregiverName = defaults.string(forKey: localKey(Key.caregiverName)) ?? ""
        caregiverPhone = defaults.string(forKey: localKey(Key.caregiverPhone)) ?? ""
        emergencyNumber = defaults.string(forKey: localKey(Key.emergencyNumber)) ?? "911"
        protectionEnabled = defaults.object(forKey: localKey(Key.protectionEnabled)) as? Bool ?? true
        if let data = defaults.data(forKey: localKey(Key.schedule)),
           let saved = try? JSONDecoder().decode(MedicationSchedule.self, from: data) {
            schedule = saved
        } else {
            schedule = MedicationSchedule(medicationName: "", doseTimes: [])
        }
        if let data = defaults.data(forKey: localKey("medications")),
           let plan = try? JSONDecoder().decode([MedicationSchedule].self, from: data) {
            medications = plan
            schedule = plan.first ?? MedicationSchedule(medicationName: "", doseTimes: [])
        } else { medications = schedule.isEmpty && schedule.medicationName.isEmpty ? [] : [schedule] }
        if let move = profile.pendingServerMove {
            do {
                try sync.relocateDestination(from: move.from, to: move.to, owner: move.owner)
                try profile.finishServerMove()
                changingCredentials = true; backendBaseURL = move.to; changingCredentials = false
                defaults.set(move.to, forKey: Key.backendBaseURL)
            } catch { connectionMessage = "The server address repair is pending. Finish any upload, then close and reopen Cadence to retry." }
        }
        if !acceptSession(token: deviceToken, destination: backendBaseURL) {
            changingCredentials = true; deviceToken = ""; changingCredentials = false
        } else { store.write(deviceToken) }
        apply()
    }

    /// Connects the coordinators that read caregiver and backend details.
    public func bind(fallAlert: FallAlertCoordinator, exam: HomeMotorExamManager) {
        self.fallAlert = fallAlert
        self.exam = exam
        apply()
    }

    /// Swapped by tests so no request leaves the process.
    public var onUnauthorized: (() -> Void)?
    public var apiTransport: JSONTransporting = URLSessionJSONTransport()

    public var api: CadenceAPIClient {
        let token = deviceToken; let base = trimmedBaseURL
        return CadenceAPIClient(baseURL: base, bearerToken: token, transport: apiTransport,
            dataGeneration: sync.currentDataGeneration,
            onDataGenerationChanged: { [weak sync] generation in
                sync?.observeDataGeneration(generation, bearerToken: token, baseURL: base)
            }, onUnauthorized: { [weak self] in
                self?.handleUnauthorized(token: token, baseURL: base)
            })
    }

    private func handleUnauthorized(token: String, baseURL: String) {
        guard !restartRequired, deviceToken == token, trimmedBaseURL == baseURL else { return }
        onUnauthorized?()
    }

    public var hasCaregiver: Bool {
        !caregiverPhone.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var trimmedBaseURL: String {
        var url = backendBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while url.hasSuffix("/") { url.removeLast() }
        return url
    }

    public func saveMedicationPlan(_ plan: [MedicationSchedule]) throws {
        let normalized = plan.map { MedicationSchedule(medicationName: $0.medicationName.trimmingCharacters(in: .whitespacesAndNewlines), doseTimes: Array(Set($0.doseTimes)).sorted(), calendar: $0.calendar) }
        guard normalized.allSatisfy({ !$0.medicationName.isEmpty && $0.doseTimes.allSatisfy { (0..<24).contains($0.hour) && (0..<60).contains($0.minute) } }),
              Set(normalized.map { $0.medicationName.lowercased() }).count == normalized.count else {
            throw NSError(domain: "MedicationPlan", code: 1, userInfo: [NSLocalizedDescriptionKey: "Give each medication a different name and valid reminder times."])
        }
        let data = try JSONEncoder().encode(normalized)
        defaults.set(data, forKey: scoped("medications"))
        updatingMedicationPlan = true
        medications = normalized
        schedule = normalized.first ?? MedicationSchedule(medicationName: "", doseTimes: [])
        updatingMedicationPlan = false
    }

    public func selectMedication(named name: String) {
        guard let chosen = medications.first(where: { $0.medicationName == name }) else { return }
        try? saveMedicationPlan([chosen] + medications.filter { $0.medicationName != name })
    }

    private func scoped(_ key: String) -> String { "cadence.profile.\(profile.id).\(key)" }

    @discardableResult
    public func connectServer(to address: String, repairLocalhost: Bool = false, newToken: String? = nil, isCurrent: () -> Bool = { true }) async -> Bool {
        guard !isConnecting, !restartRequired, fallAlert?.isAlertVisible != true else { return false }
        let oldToken = deviceToken; let oldURL = api.baseURL
        let token = newToken ?? oldToken
        let target = DeviceProfile.normalize(address)
        guard !token.isEmpty else { connectionMessage = "Sign in with this phone's account to verify the server."; return false }
        isConnecting = true; connectionMessage = "Connecting…"
        defer { isConnecting = false }
        do {
            let client = CadenceAPIClient(baseURL: target, bearerToken: token, transport: apiTransport)
            let info = try await client.connectionInfo()
            guard isCurrent(), !Task.isCancelled, deviceToken == oldToken, api.baseURL == oldURL,
                  !restartRequired, fallAlert?.isAlertVisible != true else { return false }
            guard !sync.isUploading else { connectionMessage = "An event upload is in progress. Wait for it to finish, then connect again."; return false }
            if let generation = info.dataGeneration, generation < sync.currentDataGeneration {
                connectionMessage = "This server has an older erase history. Use the original server or restore its current database before syncing."
                return false
            }
            guard try profile.stageServerMove(to: target, info: info, token: token, repairLocalhost: repairLocalhost) else {
                connectionMessage = "This is a different server or account. Use the original Cadence server; changing wearer still requires a local reset."
                return false
            }
            if let move = profile.pendingServerMove {
                try sync.relocateDestination(from: move.from, to: move.to, owner: move.owner)
                try profile.finishServerMove()
            }
            changingCredentials = true
            backendBaseURL = target; deviceToken = token
            changingCredentials = false
            defaults.set(target, forKey: Key.backendBaseURL); tokenStore.write(token)
            apply()
            if let generation = info.dataGeneration {
                guard sync.observeDataGeneration(generation, bearerToken: token, baseURL: target) else {
                    connectionMessage = "Server connected, but its data version could not be saved. Check phone storage before syncing."
                    return false
                }
            }
            profileNotice = nil
            connectionMessage = "Connected to Cadence. This phone's queued records are preserved."
            return true
        } catch {
            if profile.pendingServerMove != nil {
                connectionMessage = "Address repair saved but not complete. Wait for uploads to finish, then close and reopen Cadence."
            } else if DeviceProfile.isLoopback(target) {
                connectionMessage = "On an iPhone, localhost is the iPhone itself. Enter your Mac's .local address from the phone-server script."
            } else {
                connectionMessage = "Could not connect: \(error.localizedDescription). Start the Mac backend, keep both devices on the same Wi-Fi, and allow Local Network access for Cadence."
            }
            return false
        }
    }

    @discardableResult
    public func acceptSession(token: String, destination: String) -> Bool {
        do {
            guard !restartRequired, try profile.accept(token: token, destination: destination) else {
                profileNotice = profile.failure ?? "This installation belongs to one wearer and server. Use the same account, or erase this phone's local profile in Settings before changing wearer or server."
                return false
            }
            profileNotice = nil
            return true
        } catch {
            profileNotice = "The account binding could not be saved. Check phone storage and try again."
            return false
        }
    }

    /// The durable marker makes interrupted erasure resume before producers
    /// start at the next launch. Credentials cannot repopulate the old queue.
    public func prepareLocalReset() throws -> Bool {
        guard sync.suspendForLocalReset() else { return false }
        do { try profile.beginReset() }
        catch {
            sync.resumeAfterFailedLocalReset(baseURL: trimmedBaseURL, token: deviceToken)
            throw error
        }
        restartRequired = true
        changingCredentials = true
        deviceToken = ""; signedInUsername = nil
        tokenStore.write("")
        changingCredentials = false
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("cadence.profile.\(profile.id).") {
            defaults.removeObject(forKey: key)
        }
        return true
    }

    private func apply() {
        AudioCueEngine.shared.preferredVoiceIdentifier = preferredVoiceIdentifier
        sync.configureSession(baseURL: trimmedBaseURL, bearerToken: deviceToken)
        exam?.backendBaseURL = trimmedBaseURL
        exam?.deviceBearerToken = deviceToken
        fallAlert?.caregiverPhoneNumber = hasCaregiver ? caregiverPhone : nil
        fallAlert?.emergencyNumber = emergencyNumber.isEmpty ? "911" : emergencyNumber
    }
}
