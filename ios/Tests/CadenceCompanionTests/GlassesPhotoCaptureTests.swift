import XCTest
@testable import CadenceCompanion

private final class HeldPhotoGlasses: GlassesDevice {
    let name = "Meta test device"
    var connectionState: GlassesConnectionState = .connected
    var wearState: GlassesWearState = .worn
    let capabilities = GlassesCapabilities(imu: false, microphone: false, camera: true, audioOutput: true, imuSampleRateHz: nil)
    var onStateChange: ((GlassesDevice) -> Void)?
    let motion: MotionSource = MockGlassesMotionSource(samples: [], sampleRateHz: 50)
    var requests: [(Result<Data, GlassesError>) -> Void] = []
    var cancellations = 0
    var connectsImmediately = true
    func connect() { connectionState = connectsImmediately ? .connected : .connecting; onStateChange?(self) }
    func disconnect() { connectionState = .disconnected; onStateChange?(self) }
    func captureFrame(_ completion: @escaping (Result<Data, GlassesError>) -> Void) { requests.append(completion) }
    func cancelPhotoCapture() { cancellations += 1 }
    func playHaptic(_ pattern: HapticPattern) {}
}

@MainActor
final class GlassesPhotoCaptureTests: XCTestCase {
    private func session(timeout: Double = 20) -> GlassesSessionManager {
        GlassesSessionManager(phoneMotion: MockGlassesMotionSource(samples: [], sampleRateHz: 50), photoTimeoutSec: timeout)
    }

    func testGlassesBytesAreDeliveredOnceAndOverlappingRequestsCannotReplaceThem() throws {
        let device = HeldPhotoGlasses(); let session = session(); session.attach(device)
        var results: [Result<Data, GlassesError>] = []
        session.capturePhoto { results.append($0) }
        XCTAssertTrue(session.isCapturingPhoto)
        var overlapping: GlassesError?
        session.capturePhoto { if case .failure(let error) = $0 { overlapping = error } }
        XCTAssertEqual(overlapping, .captureInProgress)
        XCTAssertEqual(device.requests.count, 1)
        device.requests[0](.success(Data("glasses bytes".utf8)))
        device.requests[0](.failure(.captureFailed))
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(try results[0].get(), Data("glasses bytes".utf8))
        XCTAssertFalse(session.isCapturingPhoto)
    }

    func testReplacementAndDisconnectFenceStaleDeviceCallbacks() {
        let first = HeldPhotoGlasses(); let second = HeldPhotoGlasses(); let session = session()
        session.attach(first)
        let staleState = first.onStateChange
        var firstCount = 0; var secondCount = 0
        session.capturePhoto { _ in firstCount += 1 }
        session.attach(second)
        XCTAssertEqual(firstCount, 1)
        session.capturePhoto { _ in secondCount += 1 }
        first.requests[0](.success(Data("old".utf8)))
        first.connectionState = .disconnected; staleState?(first)
        XCTAssertEqual(session.connectionState, .connected)
        XCTAssertTrue(session.isCapturingPhoto)
        XCTAssertEqual(secondCount, 0)
        session.disconnect()
        XCTAssertEqual(secondCount, 1)
        second.requests[0](.success(Data("too late".utf8)))
        XCTAssertEqual(secondCount, 1)
    }

    func testTimeoutStopsCaptureAndDoesNotAcceptLateOrEmptyPhotos() async {
        let device = HeldPhotoGlasses(); let session = session(timeout: 0.01); session.attach(device)
        let done = expectation(description: "capture times out")
        var count = 0
        session.capturePhoto { result in
            count += 1
            if case .failure(let error) = result { XCTAssertEqual(error, .captureFailed) }
            else { XCTFail("timeout must not produce a photo") }
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 1)
        XCTAssertEqual(device.cancellations, 1)
        device.requests[0](.success(Data("late".utf8)))
        XCTAssertEqual(count, 1)
        var emptyFailed = false
        session.capturePhoto { if case .failure(.captureFailed) = $0 { emptyFailed = true } }
        device.requests[1](.success(Data()))
        XCTAssertTrue(emptyFailed)
    }

    func testLiveMetaMasksWithoutConfidenceDecodeWithoutInventingAValue() throws {
        let body = Data(#"{"event_uuid":"real-photo","sam_verified":true,"living_subject_present":false,"template_id":"observations","spoken_response":"A chair is visible.","verified_masks":[{"label":"chair"},{"label":"coat","confidence":null}],"latency_ms":1200}"#.utf8)
        let result = try JSONDecoder().decode(RealityCheckResult.self, from: body)
        XCTAssertEqual(result.detectedLabels, ["chair", "coat"])
        XCTAssertTrue(result.verifiedMasks.allSatisfy { $0.confidence == nil })
    }

    func testStalledConnectionReturnsAnActionableErrorInsteadOfSpinningForever() async throws {
        let device = HeldPhotoGlasses(); device.connectionState = .disconnected; device.connectsImmediately = false
        let session = GlassesSessionManager(phoneMotion: device.motion, connectionTimeoutSec: 0.01)
        session.attach(device); session.connect()
        XCTAssertEqual(session.connectionState, .connecting)
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(session.connectionState, .disconnected)
        XCTAssertTrue(session.connectionError?.contains("Meta AI app") == true)
    }
}
