import XCTest
@testable import CadenceCompanion

@MainActor
final class SignInTests: XCTestCase {
    private func make(
        responses: [Data] = [],
        error: Error? = nil,
        defaults: UserDefaults? = nil
    ) -> (AuthSession, AppSettings, InMemoryTokenStore, RecordingJSONTransport) {
        let transport = RecordingJSONTransport()
        transport.responses = responses
        transport.error = error
        let store = InMemoryTokenStore()
        let sync = EventSyncManager(
            databasePath: NSTemporaryDirectory() + "signin-\(UUID().uuidString).sqlite", startPeriodicDrain: false
        )
        let settings = AppSettings(
            defaults: defaults ?? UserDefaults(suiteName: "signin-\(UUID().uuidString)")!,
            sync: sync,
            developerMode: false,
            tokenStore: store,
            defaultToken: ""
        )
        settings.apiTransport = transport
        return (AuthSession(settings: settings), settings, store, transport)
    }

    private func loginBody(role: String) -> Data {
        Data(#"{"access_token":"jwt-abc","token_type":"bearer","expires_in":2592000,"role":"\#(role)"}"#.utf8)
    }

    func testWithNoTokenTheAppAsksForSignIn() {
        let (auth, _, _, _) = make()
        XCTAssertFalse(auth.isSignedIn)
        XCTAssertTrue(auth.needsSignIn)
    }

    func testSigningInStoresTheTokenInTheKeychainAndUsesItEverywhere() async throws {
        let (auth, settings, store, transport) = make(responses: [loginBody(role: "device_writer")])

        await auth.signIn(username: " phone-1 ", password: "device pass phrase long enough")

        XCTAssertTrue(auth.isSignedIn)
        XCTAssertFalse(auth.needsSignIn)
        XCTAssertEqual(auth.username, "phone-1")
        XCTAssertNil(auth.errorMessage)
        XCTAssertEqual(store.read(), "jwt-abc")
        XCTAssertEqual(settings.deviceToken, "jwt-abc")
        XCTAssertEqual(settings.sync.deviceBearerToken, "jwt-abc")

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url.path, "/api/v1/auth/login")
        XCTAssertEqual(request.bearerToken, "", "no old token is sent with a login")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.body!) as? [String: String])
        XCTAssertEqual(body["username"], "phone-1")
    }

    /// A care-team viewing account cannot be used to run the phone.
    func testAViewingAccountIsTurnedAwayPlainly() async {
        let (auth, settings, store, _) = make(responses: [loginBody(role: "clinician_reader")])
        await auth.signIn(username: "dana", password: "correct horse battery staple")
        XCTAssertFalse(auth.isSignedIn)
        XCTAssertNil(store.read())
        XCTAssertEqual(settings.deviceToken, "")
        XCTAssertTrue(auth.errorMessage?.contains("phone") == true)
    }

    func testWrongPasswordAndLockoutHavePlainMessages() async {
        let (wrong, _, _, _) = make(error: CadenceAPIError.httpStatus(401))
        await wrong.signIn(username: "phone-1", password: "nope nope nope")
        XCTAssertEqual(wrong.errorMessage, "That username or password didn't match.")

        let (locked, _, _, _) = make(error: CadenceAPIError.httpStatus(429))
        await locked.signIn(username: "phone-1", password: "nope nope nope")
        XCTAssertEqual(locked.errorMessage, "Too many tries. Please wait a few minutes and try again.")

        let (offline, _, _, _) = make(error: URLError(.notConnectedToInternet))
        await offline.signIn(username: "phone-1", password: "nope nope nope")
        XCTAssertTrue(offline.errorMessage?.contains("reach") == true)
    }

    func testEmptyFieldsAreCaughtBeforeAnyRequest() async {
        let (auth, _, _, transport) = make()
        await auth.signIn(username: "", password: "")
        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertNotNil(auth.errorMessage)
    }

    func testSigningOutClearsTheKeychain() async {
        let (auth, settings, store, _) = make(responses: [loginBody(role: "device_writer")])
        await auth.signIn(username: "phone-1", password: "device pass phrase long enough")
        auth.signOut()
        XCTAssertFalse(auth.isSignedIn)
        XCTAssertNil(store.read())
        XCTAssertEqual(settings.deviceToken, "")
    }

    /// When the server stops accepting the token, the app says so and the
    /// next sign-in clears the notice.
    func testAnExpiredSessionIsShownAndClearedByTheNextSignIn() async {
        let (auth, _, _, transport) = make(responses: [loginBody(role: "device_writer")])
        await auth.signIn(username: "phone-1", password: "device pass phrase long enough")
        auth.markExpired()
        XCTAssertTrue(auth.needsSignIn)
        XCTAssertTrue(auth.isExpired)

        transport.responses = [loginBody(role: "device_writer")]
        await auth.signIn(username: "phone-1", password: "device pass phrase long enough")
        XCTAssertFalse(auth.needsSignIn)
        XCTAssertFalse(auth.isExpired)
    }

    /// A token left in UserDefaults by an older build moves to the Keychain
    /// and is erased from defaults.
    func testAnOldTokenInUserDefaultsMovesToTheKeychain() {
        let defaults = UserDefaults(suiteName: "migrate-\(UUID().uuidString)")!
        defaults.set("old-token", forKey: "cadence.deviceToken")
        let store = InMemoryTokenStore()
        let sync = EventSyncManager(
            databasePath: NSTemporaryDirectory() + "migrate-\(UUID().uuidString).sqlite", startPeriodicDrain: false
        )
        let settings = AppSettings(defaults: defaults, sync: sync, developerMode: false, tokenStore: store, defaultToken: "")
        XCTAssertEqual(settings.deviceToken, "old-token")
        XCTAssertEqual(store.read(), "old-token")
        XCTAssertNil(defaults.string(forKey: "cadence.deviceToken"))
    }
}
