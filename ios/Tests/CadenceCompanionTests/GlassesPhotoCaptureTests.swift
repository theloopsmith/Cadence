import XCTest
@testable import CadenceCompanion

private final class HeldPhotoGlasses: GlassesDevice {
    let name = "Meta test device"
    var connectionState: GlassesConnectionState = .connected
    var wearState: GlassesWearState = .worn
    let capabilities = GlassesCapabilities(imu: false, microphone: false, camera: true, audioOutput: true, imuSampleRateHz: nil)
    var onStateChange: ((GlassesDevice) -> Void)?
    let motion: MotionSource = MockGlassesMotionSource(samples: [], sampleRateHz: 50)
    var onCameraFrame: ((Data) -> Void)?
    var onCameraPhoto: ((Data) -> Void)?
    var onCameraError: ((String) -> Void)?
    var previewStarts = 0
    var previewStops = 0
    func startCameraPreview() { previewStarts += 1 }
    func stopCameraPreview() { previewStops += 1 }
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

    func testPreviewStartsAfterConnectionAndFencesCallbacksAfterClosingOrReplacingDevice() async {
        let device = HeldPhotoGlasses()
        device.connectionState = .disconnected
        device.connectsImmediately = false
        let session = session(); session.attach(device)
        session.startCameraPreview()
        XCTAssertEqual(device.previewStarts, 0)
        device.connectionState = .connected; device.onStateChange?(device)
        XCTAssertEqual(device.previewStarts, 1)
        let staleFrame = device.onCameraFrame
        let stalePhoto = device.onCameraPhoto
        let staleError = device.onCameraError
        device.onCameraFrame?(Data("live".utf8))
        await Task.yield(); await Task.yield()
        XCTAssertEqual(session.previewFrame, Data("live".utf8))
        let photoID = session.cameraPhotoID
        device.onCameraPhoto?(Data("physical shutter photo".utf8))
        await Task.yield(); await Task.yield()
        XCTAssertNotEqual(session.cameraPhotoID, photoID)
        XCTAssertEqual(session.cameraPhoto, Data("physical shutter photo".utf8))
        session.stopCameraPreview()
        staleFrame?(Data("late frame".utf8)); stalePhoto?(Data("late photo".utf8)); staleError?("stale error")
        await Task.yield(); await Task.yield()
        XCTAssertNil(session.previewFrame)
        XCTAssertNil(session.cameraPhoto)
        XCTAssertNil(session.cameraError)
        session.attach(HeldPhotoGlasses()); session.startCameraPreview()
        staleFrame?(Data("old device".utf8))
        await Task.yield(); await Task.yield()
        XCTAssertNil(session.previewFrame)
        session.stopCameraPreview()
    }

    func testCaptureDuringPreviewPublishesPhotoOnceWithoutEndingPreview() async {
        let device = HeldPhotoGlasses(); let session = session(); session.attach(device)
        session.startCameraPreview()
        var count = 0
        session.capturePhoto { _ in count += 1 }
        device.requests[0](.success(Data("photo".utf8)))
        let id = session.cameraPhotoID
        XCTAssertEqual(session.cameraPhoto, Data("photo".utf8))
        XCTAssertTrue(session.isPreviewOpen)
        device.requests[0](.success(Data("duplicate".utf8)))
        XCTAssertEqual(session.cameraPhotoID, id)
        XCTAssertEqual(count, 1)
        session.stopCameraPreview()
        XCTAssertNil(device.onCameraFrame)
    }

    func testDisconnectClearsLiveFrameAndMakesFailureVisible() async {
        let device = HeldPhotoGlasses(); let session = session(); session.attach(device)
        session.startCameraPreview()
        device.onCameraFrame?(Data("live".utf8))
        await Task.yield(); await Task.yield()
        device.disconnect()
        XCTAssertNil(session.previewFrame)
        XCTAssertFalse(session.isPreviewOpen)
        XCTAssertTrue(session.cameraError?.contains("disconnected") == true)
    }

    func testFreshVideoFramesClearPriorCameraErrorAndEnableNextCapture() async {
        let device = HeldPhotoGlasses(); let session = session(); session.attach(device)
        session.startCameraPreview()
        device.onCameraError?("Glasses video paused. Check that the glasses are worn and unfolded, then retry.")
        await Task.yield(); await Task.yield()
        XCTAssertEqual(session.cameraError, "Glasses video paused. Check that the glasses are worn and unfolded, then retry.")
        XCTAssertNil(session.previewFrame)

        // Fresh frame arrives once glasses are unfolded or resumed
        device.onCameraFrame?(Data("fresh live frame".utf8))
        await Task.yield(); await Task.yield()
        XCTAssertNil(session.cameraError)
        XCTAssertEqual(session.previewFrame, Data("fresh live frame".utf8))

        // Can capture photo now that preview is restored
        var capturedPhoto: Data?
        session.capturePhoto { result in
            if case .success(let data) = result { capturedPhoto = data }
        }
        XCTAssertTrue(session.isCapturingPhoto)
        XCTAssertEqual(device.requests.count, 1)
        device.requests[0](.success(Data("captured jpeg".utf8)))
        XCTAssertEqual(capturedPhoto, Data("captured jpeg".utf8))
        XCTAssertFalse(session.isCapturingPhoto)
        session.stopCameraPreview()
    }

    func testConsecutivePhotoCapturesSucceedWithoutBreakingPreview() async {
        let device = HeldPhotoGlasses(); let session = session(); session.attach(device)
        session.startCameraPreview()

        // First capture
        var firstPhoto: Data?
        session.capturePhoto { result in
            if case .success(let data) = result { firstPhoto = data }
        }
        XCTAssertEqual(device.requests.count, 1)
        device.requests[0](.success(Data("photo 1".utf8)))
        XCTAssertEqual(firstPhoto, Data("photo 1".utf8))
        XCTAssertFalse(session.isCapturingPhoto)
        XCTAssertTrue(session.isPreviewOpen)

        // Second consecutive capture
        var secondPhoto: Data?
        session.capturePhoto { result in
            if case .success(let data) = result { secondPhoto = data }
        }
        XCTAssertEqual(device.requests.count, 2)
        device.requests[1](.success(Data("photo 2".utf8)))
        XCTAssertEqual(secondPhoto, Data("photo 2".utf8))
        XCTAssertFalse(session.isCapturingPhoto)
        XCTAssertTrue(session.isPreviewOpen)
        session.stopCameraPreview()
    }

    func testMissingOrStaleVideoStopsCameraAndFencesLateFrames() async throws {
        for sendsInitialFrame in [false, true] {
            let device = HeldPhotoGlasses()
            let session = GlassesSessionManager(phoneMotion: device.motion, previewFirstFrameTimeoutSec: 0.01, previewStaleTimeoutSec: 0.01)
            session.attach(device); session.startCameraPreview()
            let lateFrame = device.onCameraFrame
            if sendsInitialFrame { device.onCameraFrame?(Data("first frame".utf8)) }
            try await Task.sleep(nanoseconds: 60_000_000)
            XCTAssertFalse(session.isPreviewOpen)
            XCTAssertNil(session.previewFrame)
            XCTAssertTrue(session.cameraError?.contains("Video stopped") == true)
            lateFrame?(Data("late".utf8))
            await Task.yield(); await Task.yield()
            XCTAssertNil(session.previewFrame)
        }
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
