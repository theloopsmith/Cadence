import XCTest
@testable import CadenceCompanion

@MainActor
final class GlassesDeviceReadinessTests: XCTestCase {
    func testAppDeclaresMetaDiscoveryAndCameraTransports() throws {
        let iosRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: iosRoot.appendingPathComponent("App/Info.plist"))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let modes = Set(try XCTUnwrap(plist["UIBackgroundModes"] as? [String]))
        XCTAssertTrue(modes.isSuperset(of: ["bluetooth-central", "bluetooth-peripheral", "external-accessory"]))
        let protocols = try XCTUnwrap(plist["UISupportedExternalAccessoryProtocols"] as? [String])
        XCTAssertTrue(protocols.contains("com.meta.ar.wearable"))
        let services = try XCTUnwrap(plist["NSBonjourServices"] as? [String])
        XCTAssertTrue(services.contains("_bonjour._tcp"))
        XCTAssertFalse((plist["NSBluetoothAlwaysUsageDescription"] as? String ?? "").isEmpty)
        let config = try XCTUnwrap(plist["MWDAT"] as? [String: Any])
        XCTAssertEqual(config["TeamID"] as? String, "$(DEVELOPMENT_TEAM)")
    }

    func testSessionCreationWaitsThroughEmptyDiscoveryUntilDeviceArrives() async throws {
        let updates = AsyncStream<String?>.makeStream()
        var sessionDevice: String?
        let start = Task {
            sessionDevice = try await GlassesDeviceReadiness.waitForDevice(current: nil, updates: updates.stream)
        }
        updates.continuation.yield(nil)
        updates.continuation.yield("")
        await Task.yield()
        XCTAssertNil(sessionDevice, "A nil selector must not reach session creation")
        updates.continuation.yield("paired-glasses")
        try await start.value
        XCTAssertEqual(sessionDevice, "paired-glasses")
        updates.continuation.finish()
    }

    func testAlreadyDiscoveredDeviceDoesNotWaitForAnotherUpdate() async throws {
        let updates = AsyncStream<String?> { _ in }
        let device = try await GlassesDeviceReadiness.waitForDevice(current: "ready-glasses", updates: updates)
        XCTAssertEqual(device, "ready-glasses")
    }

    func testCancelledDiscoveryCannotCreateSessionFromLateDevice() async {
        let updates = AsyncStream<String?>.makeStream()
        let start = Task { try await GlassesDeviceReadiness.waitForDevice(current: nil, updates: updates.stream) }
        start.cancel()
        updates.continuation.yield("late-device")
        do { _ = try await start.value; XCTFail("Cancelled connection must not create a session") }
        catch is CancellationError {}
        catch { XCTFail("Expected cancellation, got \(error)") }
        updates.continuation.finish()
    }

    func testDiscoveryEndingWithoutDeviceFailsWithoutStartingSession() async {
        let updates = AsyncStream<String?> { $0.yield(nil); $0.finish() }
        do { _ = try await GlassesDeviceReadiness.waitForDevice(current: nil, updates: updates); XCTFail("Missing device") }
        catch let error as GlassesError { XCTAssertEqual(error, .notConnected) }
        catch { XCTFail("Unexpected error: \(error)") }
    }
}
