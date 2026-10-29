import XCTest
@testable import CadenceCompanion

@MainActor
final class MockKitRecoveryFlowTests: XCTestCase {
    func testMockGlassesFallContradictorySpeechCancelAndQueueRelaunch() {
        let path=NSTemporaryDirectory()+"mock-kit-recovery-\(UUID().uuidString).sqlite"
        let q=EventSyncManager(transport:StubTransport(),databasePath:path,startPeriodicDrain:false)
        let listener=MockSpeechCheckInListener()
        let coordinator=FallAlertCoordinator(sync:q,locationProvider:MockLocationProvider(),speechListener:listener)
        let samples=[
            IMUSample(timestamp:1,ax:0.1,ay:0.1,az:0.1,gx:0,gy:0,gz:0,pitchDeg:4,rollDeg:2),
            IMUSample(timestamp:1.1,ax:0.2,ay:3.85,az:0.3,gx:3,gy:2,gz:1,pitchDeg:25,rollDeg:10),
            IMUSample(timestamp:1.8,ax:0.98,ay:0.15,az:0.05,gx:0.01,gy:0.01,gz:0.01,pitchDeg:76,rollDeg:4)
        ]
        let device=MockGlassesDevice(name:"Cadence Mock Kit",loopSamples:samples)
        device.connect()
        device.motion.start { sample in
            if let event=coordinator.detector.processIMUSample(sample) { coordinator.beginCheckIn(eventUUID:event) }
        }
        for _ in samples { device.pumpOneSample() }
        XCTAssertTrue(coordinator.isAlertVisible)
        listener.simulateUtterance("I'm okay",source:.local)
        XCTAssertFalse(coordinator.isDispatched)
        listener.simulateUtterance("I'm not okay",source:.cloud)
        XCTAssertTrue(coordinator.isDispatched)
        coordinator.cancelByUser();device.disconnect()
        XCTAssertFalse(coordinator.isAlertVisible)
        let reopened=EventSyncManager(transport:StubTransport(),databasePath:path,startPeriodicDrain:false)
        XCTAssertEqual(reopened.pendingCount(),2)
        XCTAssertTrue(reopened.dueEvents().contains{$0.endpoint.hasSuffix("/cancel")})
    }
}

extension MockKitRecoveryFlowTests {
    func testPersistenceFailureIsVisibleAndManualCallingRemainsAvailable() throws {
        let path=NSTemporaryDirectory()+"unwritable-mock-kit-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath:path,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(atPath:path) }
        let queue=EventSyncManager(transport:StubTransport(),databasePath:path,startPeriodicDrain:false)
        let dialer=RecordingPhoneDialer()
        let c=FallAlertCoordinator(dialer:dialer,sync:queue,locationProvider:MockLocationProvider(),speechListener:MockSpeechCheckInListener())
        c.beginCheckIn(eventUUID:"unsaved-fall")
        c.escalate()
        XCTAssertEqual(c.lastOutcome,"local_persistence_failed")
        XCTAssertNotNil(c.persistenceWarning)
        XCTAssertEqual(queue.volatileEventCount,1)
        c.caregiverPhoneNumber="+15550001111"
        c.callCaregiver()
        XCTAssertEqual(dialer.dialedNumbers,["+15550001111"])
        c.cancelByUser()
    }
}
