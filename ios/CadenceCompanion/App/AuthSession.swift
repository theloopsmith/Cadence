import Combine
import Foundation

/// The phone's sign-in. A care partner signs in once with the phone's
/// account; the token lives in the Keychain and every request uses it.
@MainActor
public final class AuthSession: ObservableObject {
    @Published public private(set) var isWorking = false
    @Published public private(set) var errorMessage: String?
    /// The server stopped accepting the token. Events wait on the phone.
    @Published public private(set) var isExpired = false

    private let settings: AppSettings
    private var cancellables: Set<AnyCancellable> = []
    private var generation = UUID()

    public init(settings: AppSettings) {
        self.settings = settings
        // Repaint whenever the token or name changes underneath.
        settings.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    public var username: String? { settings.signedInUsername }

    /// Signed in with an account (not merely running on the development token).
    public var isSignedIn: Bool {
        !settings.deviceToken.isEmpty && settings.signedInUsername != nil && !isExpired
    }

    /// True when events cannot reach the server until someone signs in.
    public var needsSignIn: Bool {
        settings.deviceToken.isEmpty || isExpired
    }

    public func signIn(username rawUsername: String, password: String, serverAddress: String? = nil) async {
        guard !isWorking, !settings.restartRequired, settings.profile.failure == nil else { return }
        let username = rawUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty, !password.isEmpty else {
            errorMessage = "Enter the phone's username and password."
            return
        }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        let generation = self.generation
        let original = settings.api
        let client = CadenceAPIClient(baseURL: serverAddress.map(DeviceProfile.normalize) ?? original.baseURL,
            bearerToken: original.bearerToken, transport: settings.apiTransport)
        do {
            let result = try await client.login(username: username, password: password)
            guard self.generation == generation, !settings.restartRequired,
                  settings.api.baseURL == original.baseURL, settings.deviceToken == original.bearerToken else { return }
            guard result.role == "device_writer" else {
                errorMessage = "That account is for viewing summaries. Use the account made for this phone."
                return
            }
            if client.baseURL != original.baseURL, settings.profile.isBound {
                guard await settings.connectServer(to: client.baseURL, repairLocalhost: true, newToken: result.accessToken,
                    isCurrent: { self.generation == generation }) else {
                    errorMessage = settings.connectionMessage
                    return
                }
            } else if !settings.profile.isBound { settings.backendBaseURL = client.baseURL }
            guard settings.acceptSession(token: result.accessToken, destination: client.baseURL) else {
                errorMessage = settings.profileNotice
                return
            }
            settings.deviceToken = result.accessToken
            settings.signedInUsername = username
            isExpired = false
            // Send anything that waited while signed out.
            Task { await settings.sync.drainPendingEvents() }
        } catch CadenceAPIError.httpStatus(let status) where status == 401 {
            errorMessage = "That username or password didn't match."
        } catch CadenceAPIError.httpStatus(let status) where status == 429 {
            errorMessage = "Too many tries. Please wait a few minutes and try again."
        } catch {
            errorMessage = "Couldn't reach Cadence's server. Check the connection and try again."
        }
    }

    public func signOut() {
        generation = UUID()
        settings.deviceToken = ""
        settings.signedInUsername = nil
        isExpired = false
        errorMessage = nil
    }

    /// Invalidates a pending login without replacing the installation's binding.
    public func cancelPendingSignIn() { generation = UUID() }

    /// The server refused the token (it expired or was revoked).
    public func markExpired() {
        guard !settings.deviceToken.isEmpty else { return }
        isExpired = true
    }
}
