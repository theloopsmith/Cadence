import Foundation
import Security

/// Where the phone keeps its sign-in token.
public protocol TokenStoring: AnyObject {
    func read() -> String?
    /// Stores `token`, or deletes it when nil or empty.
    func write(_ token: String?)
}

/// The iOS Keychain. Readable after the first unlock following a restart, so
/// the offline queue can still send a fall with the phone locked in a pocket.
/// Never synced to iCloud and never restored to a different device.
public final class KeychainTokenStore: TokenStoring {
    private let service: String
    private let account: String

    public init(service: String = "com.theloopsmith.cadence", account: String = "device-sign-in") {
        self.service = service
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func read() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let token = String(data: data, encoding: .utf8),
              !token.isEmpty else { return nil }
        return token
    }

    public func write(_ token: String?) {
        SecItemDelete(baseQuery as CFDictionary)
        guard let token, !token.isEmpty, let data = token.data(using: .utf8) else { return }
        var item = baseQuery
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }
}

/// For tests and previews.
public final class InMemoryTokenStore: TokenStoring {
    private var token: String?
    public init(token: String? = nil) { self.token = token }
    public func read() -> String? { token }
    public func write(_ token: String?) { self.token = (token?.isEmpty ?? true) ? nil : token }
}
