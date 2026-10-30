import XCTest
@testable import CadenceCompanion

private final class HeldProfileUpload: EventTransport {
    let started: XCTestExpectation
    var reply: CheckedContinuation<DeliveryOutcome, Never>?
    init(_ started: XCTestExpectation) { self.started = started }
    func send(endpoint: String, jsonData: Data, bearerToken: String) async -> DeliveryOutcome {
        await withCheckedContinuation { reply = $0; started.fulfill() }
    }
}

private final class HeldProfileLogin: JSONTransporting {
    let started: XCTestExpectation
    var reply: CheckedContinuation<Data, Never>?
    init(_ started: XCTestExpectation) { self.started = started }
    func send(_ request: URLRequest, bearerToken: String) async throws -> Data {
        await withCheckedContinuation { reply = $0; started.fulfill() }
    }
}

private final class HeldProfileNotifications: DoseNotificationCentering {
    let started: XCTestExpectation
    var reply: CheckedContinuation<Bool, Never>?
    var added: [DoseReminderRequest] = []
    init(_ started: XCTestExpectation) { self.started = started }
    func requestAuthorization() async -> Bool {
        await withCheckedContinuation { reply = $0; started.fulfill() }
    }
    func add(_ request: DoseReminderRequest) { added.append(request) }
    func removePending(withIdentifiers ids: [String]) {}
    func removeAllPending() { added.removeAll() }
}

@MainActor
final class DeviceProfileTests: XCTestCase {
    private func root() -> URL { URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("profile-check-\(UUID())") }
    private func token(_ sub: String = "phone-a", pid: String = "wearer-a", issued: Int = 1) -> String {
        let body = try! JSONSerialization.data(withJSONObject: ["sub":sub,"pid":pid,"iat":issued])
        return "header." + body.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") + ".signature"
    }
    private func settings(_ profile: DeviceProfile, defaults: UserDefaults? = nil, store: InMemoryTokenStore = InMemoryTokenStore()) -> AppSettings {
        AppSettings(defaults: defaults ?? UserDefaults(suiteName: "profile-defaults-\(UUID())")!,
            sync: EventSyncManager(databasePath: profile.directory.appendingPathComponent("queue.sqlite").path, startPeriodicDrain: false),
            developerMode: false, tokenStore: store, defaultToken: "", profile: profile)
    }

    func testBindingSurvivesRelaunchAndAllowsOnlySameIdentityAndDestination() throws {
        let root = root(); let profile = DeviceProfile(root: root)
        for invalid in ["", "file:///private/tmp", "https://user:secret@example.test", "https://example.test/?token=secret"] {
            XCTAssertFalse(try profile.accept(token: token(), destination: invalid))
            XCTAssertFalse(profile.isBound)
        }
        XCTAssertTrue(try profile.accept(token: token(), destination: " https://example.test/ "))
        let next = DeviceProfile(root: root)
        XCTAssertEqual(next.id, profile.id)
        XCTAssertTrue(try next.accept(token: token(issued: 2), destination: "https://example.test"))
        XCTAssertTrue(try next.accept(token: "", destination: "https://example.test"))
        XCTAssertFalse(try next.accept(token: token("phone-b"), destination: "https://example.test"))
        XCTAssertFalse(try next.accept(token: token(pid: "wearer-b"), destination: "https://example.test"))
        XCTAssertFalse(try next.accept(token: token(), destination: "https://other.test"))
        XCTAssertFalse(try next.accept(token: "", destination: "https://other.test"))
    }

    func testDirectCredentialEditsCannotMoveExistingHistoryOrQueue() throws {
        let profile = DeviceProfile(root: root()); let app = settings(profile)
        app.backendBaseURL = "https://example.test"
        app.deviceToken = token()
        app.summaryName = "Wearer A"
        _ = app.sync.saveLocalImmediate(eventUUID: "a-event", endpoint: "/fixture", payload: ["owner":"a"])
        app.deviceToken = token("phone-b")
        XCTAssertEqual(app.deviceToken, token())
        app.backendBaseURL = "https://other.test"
        XCTAssertEqual(app.api.baseURL, "https://example.test")
        XCTAssertEqual(app.summaryName, "Wearer A")
        XCTAssertNotNil(app.profileNotice)
        XCTAssertEqual(app.sync.dueEvents().map(\.eventUUID), ["a-event"])
    }

    func testSignOutDoesNotReactivateDevelopmentCredentialsAfterRelaunch() {
        let profile = DeviceProfile(root: root())
        let defaults = UserDefaults(suiteName: "profile-logout-\(UUID())")!
        let store = InMemoryTokenStore()
        let queue = EventSyncManager(databasePath: profile.directory.appendingPathComponent("queue.sqlite").path, startPeriodicDrain: false)
        let app = AppSettings(defaults: defaults, sync: queue, tokenStore: store, defaultToken: "fixture-development-key", profile: profile)
        XCTAssertEqual(app.deviceToken, "fixture-development-key")
        app.deviceToken = ""
        let next = AppSettings(defaults: defaults, sync: queue, tokenStore: store, defaultToken: "fixture-development-key", profile: DeviceProfile(root: profile.root))
        XCTAssertEqual(next.deviceToken, "")
        XCTAssertTrue(next.profile.isBound)
    }

    func testResetResumesBeforeOpeningNewStoresAndDoesNotReviveOldCredentials() throws {
        let profile = DeviceProfile(root: root())
        let defaults = UserDefaults(suiteName: "reset-defaults-\(UUID())")!
        let store = InMemoryTokenStore()
        let old = settings(profile, defaults: defaults, store: store)
        old.backendBaseURL = "https://example.test"; old.deviceToken = token()
        old.summaryName = "Wearer A"; old.caregiverPhone = "fixture-a"
        try Data("private history".utf8).write(to: profile.directory.appendingPathComponent("history.json"))
        _ = old.sync.saveLocalImmediate(eventUUID: "old-dose", endpoint: "/fixture", payload: ["dose":1])
        XCTAssertTrue(try old.prepareLocalReset())
        XCTAssertTrue(old.restartRequired)
        XCTAssertFalse(try profile.accept(token: token("phone-b"), destination: "https://example.test"))
        XCTAssertThrowsError(try old.sync.saveLocalImmediate(eventUUID: "late", endpoint: "/fixture", payload: [:]).get())
        store.write(token()) // crash before keychain clear, or a failed clear
        let next = DeviceProfile(root: profile.root)
        XCTAssertNotEqual(next.id, profile.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: profile.directory.path))
        let fresh = settings(next, defaults: defaults, store: store)
        XCTAssertEqual(fresh.deviceToken, "")
        XCTAssertEqual(fresh.summaryName, "")
        XCTAssertEqual(fresh.caregiverPhone, "")
        XCTAssertTrue(fresh.schedule.isEmpty)
        XCTAssertTrue(fresh.sync.dueEvents().isEmpty)
        fresh.backendBaseURL = "https://other.test"; fresh.deviceToken = token("phone-b", pid: "wearer-b")
        XCTAssertEqual(fresh.deviceToken, token("phone-b", pid: "wearer-b"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: next.directory.appendingPathComponent("history.json").path))
    }

    func testLegacyPreferencesAndFilesAreNotSilentlyAdopted() throws {
        let defaults = UserDefaults(suiteName: "legacy-profile-\(UUID())")!
        defaults.set("Unassigned wearer", forKey: "cadence.summaryName")
        defaults.set("legacy-contact", forKey: "cadence.caregiverPhone")
        let profile = DeviceProfile(root: root()); let app = settings(profile, defaults: defaults)
        XCTAssertEqual(app.summaryName, "")
        XCTAssertEqual(app.caregiverPhone, "")
        XCTAssertNotEqual(DiaryStore.default.directory, profile.directory.appendingPathComponent("Diary"))
        app.summaryName = "Assigned wearer"
        let reopened = settings(DeviceProfile(root: profile.root), defaults: defaults)
        XCTAssertEqual(reopened.summaryName, "Assigned wearer")
        XCTAssertEqual(defaults.string(forKey: "cadence.summaryName"), "Unassigned wearer")
    }

    func testCorruptManifestAndFailedBindingWritesFailClosed() throws {
        let profile = DeviceProfile(root: root())
        let manifest = profile.root.appendingPathComponent("profile.json")
        try Data("corrupt".utf8).write(to: manifest)
        let broken = DeviceProfile(root: profile.root)
        XCTAssertNotNil(broken.failure)
        XCTAssertFalse(try broken.accept(token: token(), destination: "https://example.test"))
        XCTAssertEqual(try String(contentsOf: manifest, encoding: .utf8), "corrupt")
        try FileManager.default.removeItem(at: manifest)
        try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: false)
        XCTAssertThrowsError(try profile.accept(token: token(), destination: "https://example.test"))
        XCTAssertFalse(profile.isBound)
    }

    func testResetWaitsForInflightUploadAndThenPermanentlySuspendsOldProducers() async throws {
        let started = expectation(description: "upload started")
        let transport = HeldProfileUpload(started)
        let queue = EventSyncManager(transport: transport, databasePath: root().path+".sqlite", startPeriodicDrain: false)
        queue.configureSession(baseURL: "https://example.test", bearerToken: token(), replaceTransport: false)
        _ = queue.saveLocalImmediate(eventUUID: "inflight", endpoint: "/fixture", payload: [:])
        let upload = Task { await queue.drainPendingEvents() }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertFalse(queue.suspendForLocalReset())
        transport.reply?.resume(returning: .delivered)
        _ = await upload.value
        XCTAssertTrue(queue.suspendForLocalReset())
        queue.configureSession(baseURL: "https://other.test", bearerToken: token("other"), replaceTransport: false)
        XCTAssertThrowsError(try queue.saveLocalImmediate(eventUUID: "stale-producer", endpoint: "/fixture", payload: [:]).get())
        let result = await queue.drainPendingEvents()
        XCTAssertEqual(result.delivered, 0)
    }

    func testSignOutFencesAnInflightLoginResponse() async throws {
        let app = settings(DeviceProfile(root: root()))
        let started = expectation(description: "login started")
        let transport = HeldProfileLogin(started); app.apiTransport = transport
        let auth = AuthSession(settings: app)
        let login = Task { await auth.signIn(username: "phone-a", password: "test password") }
        await fulfillment(of: [started], timeout: 2)
        auth.signOut()
        let body = try JSONSerialization.data(withJSONObject: ["access_token":token(),"token_type":"bearer","expires_in":100,"role":"device_writer"])
        transport.reply?.resume(returning: body)
        await login.value
        XCTAssertFalse(auth.isSignedIn)
        XCTAssertEqual(app.deviceToken, "")
        XCTAssertFalse(app.profile.isBound)
    }

    func testSignOutRetainsOnlySameWearerHistoryAndOtherAccountLoginIsRejected() async throws {
        let app = settings(DeviceProfile(root: root()))
        let transport = RecordingJSONTransport(); app.apiTransport = transport
        func body(_ jwt: String) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["access_token":jwt,"token_type":"bearer","expires_in":100,"role":"device_writer"])
        }
        transport.responses = [try body(token()), try body(token("phone-b")), try body(token(issued: 2))]
        let auth = AuthSession(settings: app)
        await auth.signIn(username: "phone-a", password: "fixture password")
        app.summaryName = "Wearer A"
        auth.signOut()
        XCTAssertEqual(app.summaryName, "Wearer A")
        XCTAssertTrue(app.profile.isBound)
        await auth.signIn(username: "phone-b", password: "fixture password")
        XCTAssertFalse(auth.isSignedIn)
        XCTAssertNotNil(auth.errorMessage)
        XCTAssertEqual(app.deviceToken, "")
        await auth.signIn(username: "phone-a", password: "fixture password")
        XCTAssertTrue(auth.isSignedIn)
        XCTAssertEqual(app.summaryName, "Wearer A")
    }

    func testFailedResetMarkerKeepsBindingAndRestoresQueueWithoutClaimingErasure() throws {
        let profile = DeviceProfile(root: root()); let app = settings(profile)
        app.deviceToken = token()
        let manifest = profile.root.appendingPathComponent("profile.json")
        try FileManager.default.removeItem(at: manifest)
        try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: false)
        XCTAssertThrowsError(try app.prepareLocalReset())
        XCTAssertFalse(app.restartRequired)
        XCTAssertFalse(profile.resetPending)
        XCTAssertEqual(app.sync.deviceBearerToken, token())
        XCTAssertNoThrow(try app.sync.saveLocalImmediate(eventUUID: "after-failed-reset", endpoint: "/fixture", payload: [:]).get())
    }

    func testLateNotificationPermissionCannotRestoreRemindersAfterReset() async {
        let started = expectation(description: "permission requested")
        let center = HeldProfileNotifications(started)
        let reminders = DoseReminderScheduler(center: center)
        let schedule = MedicationSchedule(medicationName: "Fixture", doseTimes: [DoseTime(hour: 9, minute: 0)])
        let scheduling = Task { await reminders.sync(schedule) }
        await fulfillment(of: [started], timeout: 2)
        reminders.suspendForLocalReset()
        center.reply?.resume(returning: true)
        await scheduling.value
        XCTAssertTrue(center.added.isEmpty)
        XCTAssertEqual(reminders.status, .none)
    }
}
