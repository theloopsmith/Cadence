import XCTest
@testable import CadenceCompanion

@MainActor
final class DeveloperToolsTests: XCTestCase {
    private func makeApp(transport: RecordingJSONTransport = RecordingJSONTransport()) -> (CadenceAppModel, RecordingJSONTransport) {
        let suite = "dev-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let sync = EventSyncManager(
            databasePath: NSTemporaryDirectory() + "\(suite).sqlite", startPeriodicDrain: false
        )
        let settings = AppSettings(defaults: defaults, sync: sync, developerMode: false)
        let app = CadenceAppModel(
            settings: settings,
            motion: MotionFeed(),
            fallAlert: FallAlertCoordinator(
                screen: NoopScreenController(), dialer: RecordingPhoneDialer(), sync: sync,
                locationProvider: MockLocationProvider(), speechListener: MockSpeechCheckInListener()
            ),
            location: MockLocationProvider(),
            captureStore: LabeledCaptureStore(directory: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(suite)-cap")),
            diary: DiaryStore(directory: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(suite)-diary")),
            transcripts: MockTranscriptListener(),
            phoneHaptics: RecordingHapticSink(),
            pillPhotos: PillPhotoStore(directory: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(suite)-pill")),
            apiTransport: transport,
            notifications: RecordingNotificationCenter()
        )
        return (app, transport)
    }

    /// Developer mode is a build or launch decision, not something stored in
    /// settings where a care partner would find it.
    func testDeveloperModeComesFromTheBuildNotFromSettings() {
        let (app, _) = makeApp()
        XCTAssertFalse(app.settings.developerModeEnabled)
        let defaults = UserDefaults(suiteName: "dev-flag-\(UUID().uuidString)")!
        let release = AppSettings(defaults: defaults, sync: app.settings.sync, developerMode: false)
        XCTAssertFalse(release.developerModeEnabled)
        let debug = AppSettings(defaults: defaults, sync: app.settings.sync, developerMode: true)
        XCTAssertTrue(debug.developerModeEnabled)
        XCTAssertNil(defaults.object(forKey: "cadence.developerMode"), "nothing persisted")
    }

    /// "Make a dose due now" adds a time in the past half hour so the Taken
    /// button shows, without touching the real schedule's other times.
    func testMakeDoseDueNowShowsTheTakenButton() {
        let (app, _) = makeApp()
        let tools = DeveloperToolsModel(app: app)
        XCTAssertFalse(app.doses.isDoseDue)
        tools.makeDoseDueNow()
        XCTAssertTrue(app.doses.isDoseDue)
        XCTAssertEqual(app.settings.schedule.doseTimes.count, 1)
    }

    func testForcingSimpleModeOverridesThePrediction() {
        let (app, _) = makeApp()
        let tools = DeveloperToolsModel(app: app)
        XCTAssertFalse(app.isSimpleMode)
        tools.setForcedSimpleMode(true)
        XCTAssertTrue(app.isSimpleMode)
        tools.setForcedSimpleMode(false)
        XCTAssertFalse(app.isSimpleMode)
    }

    func testSeedingTheDiaryWritesEveryKindAndClearingRemovesThem() throws {
        let (app, _) = makeApp()
        let tools = DeveloperToolsModel(app: app)
        tools.seedSampleDay()
        let events = try app.diary.events(on: Date())
        let kinds = Set(events.map(\.kind))
        for kind in DiaryEventKind.allCases {
            XCTAssertTrue(kinds.contains(kind), "missing \(kind.rawValue)")
        }
        tools.clearToday()
        XCTAssertEqual(try app.diary.events(on: Date()).count, 0)
    }

    /// A simulated check-in opens the same overlay a real impact would, and
    /// the simulated answers resolve it the same way.
    func testSimulatedCheckInCanBeAnsweredEitherWay() {
        let (app, _) = makeApp()
        let tools = DeveloperToolsModel(app: app)
        tools.openSimulatedCheckIn()
        XCTAssertTrue(app.fallAlert.isAlertVisible)
        tools.simulateSpeech("I'm okay")
        XCTAssertFalse(app.fallAlert.isAlertVisible)
        XCTAssertEqual(app.fallAlert.lastOutcome, "canceled_false_alarm")

        tools.openSimulatedCheckIn()
        tools.simulateSpeech("help me")
        XCTAssertTrue(app.fallAlert.isDispatched)
        tools.standDownAlert()
        XCTAssertFalse(app.fallAlert.isAlertVisible)
        AudioCueEngine.shared.deactivateBystanderSiren()
    }

    func testBackendHealthCheckReportsUpAndDown() async {
        let transport = RecordingJSONTransport()
        transport.responses = [Data(#"{"status":"ok","service":"cadence","version":"1.0.0"}"#.utf8)]
        let (app, _) = makeApp(transport: transport)
        let tools = DeveloperToolsModel(app: app)
        await tools.checkBackend()
        XCTAssertEqual(tools.backendStatus, "Connected · version 1.0.0")

        transport.error = URLError(.cannotConnectToHost)
        await tools.checkBackend()
        XCTAssertTrue(tools.backendStatus.lowercased().contains("not reachable"))
    }

    func testReplayScenarioFeedsTheEngineAndFinishes() async {
        let (app, _) = makeApp()
        let tools = DeveloperToolsModel(app: app)
        tools.replaySampleIntervalNs = 0
        tools.replay(.hardFallWithImpact)
        for _ in 0..<200 {
            if !tools.isReplaying { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(tools.isReplaying)
        XCTAssertTrue(app.fallAlert.isAlertVisible, "the hard fall replay must open a check-in")
        tools.standDownAlert()
        AudioCueEngine.shared.deactivateBystanderSiren()
    }

    func testPendingEventsAreListedAndCanBeDrained() async {
        let transport = RecordingJSONTransport()
        let (app, _) = makeApp(transport: transport)
        let tools = DeveloperToolsModel(app: app)
        tools.makeDoseDueNow()
        app.doses.markTaken()
        tools.refreshQueue()
        XCTAssertEqual(tools.pendingEvents.count, 1)
        XCTAssertTrue(tools.pendingEvents[0].endpoint.contains("/medication/dose"))
    }
}
