import Foundation
import CryptoKit

/// One photo of the wearer's own pill, taken by a care partner, shown on the
/// medication card so the right tablet is recognised at a glance.
public struct PillPhotoStore {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public static var `default`: PillPhotoStore {
        PillPhotoStore(directory: DeviceProfile.shared.directory.appendingPathComponent("Medication", isDirectory: true))
    }

    public func forMedication(_ name: String) -> PillPhotoStore {
        let key = SHA256.hash(data: Data(name.utf8)).map { String(format: "%02x", $0) }.joined()
        return PillPhotoStore(directory: directory.appendingPathComponent(key, isDirectory: true))
    }

    public func archiveLegacy() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.moveItem(at: fileURL, to: directory.appendingPathComponent("unassigned-\(UUID().uuidString).jpg"))
    }

    private var fileURL: URL { directory.appendingPathComponent("pill.jpg") }

    public func save(_ jpeg: Data) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try jpeg.write(to: fileURL, options: .atomic)
    }

    public func load() -> Data? {
        try? Data(contentsOf: fileURL)
    }

    public func remove() throws {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }
}
