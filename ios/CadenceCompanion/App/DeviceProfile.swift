import Foundation

/// One wearer and destination per installation. Credentials may refresh, but
/// changing the wearer requires an explicit erase and a fresh app launch.
public final class DeviceProfile {
    public static let shared: DeviceProfile = {
        if NSClassFromString("XCTestCase") != nil {
            return DeviceProfile(root: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("shared-profile-\(UUID())"))
        }
        return .default
    }()
    private struct Manifest: Codable {
        var id = UUID().uuidString
        var owner: String?
        var destination: String?
        var resetPending = false
        var allowDevelopmentDefault = true
        var erasedProfiles: [String]?
    }
    public let root: URL
    private var manifest: Manifest
    public private(set) var failure: String?
    public var id: String { manifest.id }
    public var directory: URL { root.appendingPathComponent(manifest.id, isDirectory: true) }
    public var allowsDevelopmentDefault: Bool { manifest.allowDevelopmentDefault }
    public var isBound: Bool { manifest.owner != nil }
    public var resetPending: Bool { manifest.resetPending }
    public var erasedProfileIDs: [String] { manifest.erasedProfiles ?? [] }
    private var manifestURL: URL { root.appendingPathComponent("profile.json") }

    public static var `default`: DeviceProfile {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return DeviceProfile(root: docs.appendingPathComponent("CadenceDevice", isDirectory: true))
    }

    public init(root: URL) {
        self.root = root
        self.manifest = Manifest()
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: manifestURL.path) {
                manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
                // Never use an on-disk identifier as an unchecked filesystem path.
                guard UUID(uuidString: manifest.id) != nil,
                      (manifest.owner == nil) == (manifest.destination == nil),
                      manifest.owner?.isEmpty != true, manifest.destination?.isEmpty != true
                else { throw CocoaError(.fileReadCorruptFile) }
            } else { try persist() }
            if manifest.resetPending { try finishReset() }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch { failure = "This phone's local profile could not be opened safely. Retry after checking storage. No history has been assigned to a new account." }
    }

    public static func normalize(_ destination: String) -> String {
        var result = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        while result.hasSuffix("/") { result.removeLast() }
        return result
    }

    /// JWT claims identify a local routing partition only. Server authorization
    /// still verifies signatures and roles independently.
    public func accept(token: String, destination: String) throws -> Bool {
        guard failure == nil, !manifest.resetPending else { return false }
        let destination = Self.normalize(destination)
        guard let url = URLComponents(string: destination),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host?.isEmpty == false, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else { return false }
        if let bound = manifest.destination, bound != destination { return false }
        guard let owner = EventSyncManager.owner(for: token) else { return true }
        if let bound = manifest.owner { return bound == owner }
        var next = manifest
        next.owner = owner; next.destination = destination
        next.allowDevelopmentDefault = false
        try persist(next)
        manifest = next
        return true
    }

    public func beginReset() throws {
        var next = manifest; next.resetPending = true
        try persist(next); manifest = next
    }

    /// Called at the next launch, before any producer or queue is created.
    private func finishReset() throws {
        let retiredID = manifest.id
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        var next = Manifest(); next.allowDevelopmentDefault = false
        next.erasedProfiles = (manifest.erasedProfiles ?? []) + [retiredID]
        try persist(next); manifest = next
    }

    private func persist(_ value: Manifest? = nil) throws {
        try JSONEncoder().encode(value ?? manifest).write(to: manifestURL, options: .atomic)
    }
}
