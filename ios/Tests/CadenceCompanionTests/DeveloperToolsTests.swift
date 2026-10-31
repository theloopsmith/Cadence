import XCTest
@testable import CadenceCompanion

@MainActor
final class DeveloperToolsTests: XCTestCase {
    func testLegacyMedicationMigratesAndMultipleMedicationPlanSurvivesReload() throws {
        let suite = "medications-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let profile = DeviceProfile(root: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(suite))
        let sync = EventSyncManager(databasePath: NSTemporaryDirectory() + "\(suite).sqlite", startPeriodicDrain: false)
        let original = MedicationSchedule(medicationName: "First", doseTimes: [DoseTime(hour: 8, minute: 10)])
        defaults.set(try JSONEncoder().encode(original), forKey: "cadence.profile.\(profile.id).cadence.medicationSchedule")
        let settings = AppSettings(defaults: defaults, sync: sync, profile: profile)
        XCTAssertEqual(settings.medications, [original])
        try settings.saveMedicationPlan([original, MedicationSchedule(medicationName: "Second", doseTimes: [DoseTime(hour: 9, minute: 5)])])
        settings.selectMedication(named: "Second")
        let reopened = AppSettings(defaults: defaults, sync: sync, profile: profile)
        XCTAssertEqual(reopened.medications.count, 2)
        XCTAssertEqual(reopened.schedule.medicationName, "Second")
        XCTAssertEqual(reopened.medications.last, original)
    }
    func testMultipleMedicationsKeepDoseHistoryAndPhotosSeparate() throws {
        let (app, _) = makeApp()
        let time = DoseTime(hour: 8, minute: 0)
        try app.settings.saveMedicationPlan([
            MedicationSchedule(medicationName: "First medication", doseTimes: [time]),
            MedicationSchedule(medicationName: "Second medication", doseTimes: [time])
        ])
        app.setPillPhoto(Data("first photo".utf8))
        app.setPillPhoto(Data("second photo".utf8), medicationName: "Second medication")
        XCTAssertEqual(app.pillPhoto, Data("first photo".utf8))
        XCTAssertTrue(app.doses.markTaken())
        XCTAssertEqual(app.doses.takenToday.count, 1)
        app.settings.selectMedication(named: "Second medication")
        XCTAssertEqual(app.doses.takenToday.count, 0)
        XCTAssertEqual(app.pillPhoto, Data("second photo".utf8))
        XCTAssertFalse(app.doses.canUndo)
        app.setPillPhoto(Data("second photo".utf8))
        XCTAssertTrue(app.doses.markTaken())
        app.settings.selectMedication(named: "First medication")
        XCTAssertEqual(app.doses.takenToday.count, 1)
        XCTAssertEqual(app.pillPhoto, Data("first photo".utf8))
        XCTAssertEqual(app.settings.medications.count, 2)
    }

    func testMedicationPlanRejectsAmbiguousNamesWithoutChangingSavedPlan() throws {
        let (app, _) = makeApp()
        let original = MedicationSchedule(medicationName: "First", doseTimes: [DoseTime(hour: 8, minute: 0)])
        try app.settings.saveMedicationPlan([original])
        XCTAssertThrowsError(try app.settings.saveMedicationPlan([original, MedicationSchedule(medicationName: " first ", doseTimes: [])]))
        XCTAssertEqual(app.settings.medications, [original])
    }
    func testVoiceDefaultsToAutomaticButExplicitOffSurvivesReload() {
        let suite = "voice-setup-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let profile = DeviceProfile(root: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(suite))
        let sync = EventSyncManager(databasePath: NSTemporaryDirectory() + "\(suite).sqlite", startPeriodicDrain: false)
        // An installed phone may still carry false from the old startup flow.
        defaults.set(false, forKey: "cadence.profile.\(profile.id).voiceCompanionEnabled")
        let first = AppSettings(defaults: defaults, sync: sync, profile: profile)
        XCTAssertTrue(first.voiceCompanionEnabled)
        first.voiceCompanionEnabled = false
        let reopened = AppSettings(defaults: defaults, sync: sync, profile: profile)
        XCTAssertFalse(reopened.voiceCompanionEnabled)
        reopened.voiceCompanionEnabled = true
        XCTAssertTrue(AppSettings(defaults: defaults, sync: sync, profile: profile).voiceCompanionEnabled)
    }

    func testVoiceStatusExplainsSetupInsteadOfGenericOff() {
        let (app, _) = makeApp()
        XCTAssertTrue(app.settings.voiceCompanionEnabled)
        XCTAssertNotEqual(app.voiceStatusText, "Voice companion is off")
        app.companion.stop()
        XCTAssertEqual(app.voiceStatusText, "Voice is turned off in Settings")
    }

    func testVoiceStatusKeepsTheActualPauseReason() {
        let (app, _) = makeApp()
        app.companion.setPaused("Safety check-in", true)
        app.companion.start()
        XCTAssertEqual(app.voiceStatusText, "Voice paused: Safety check-in")
        app.companion.stop()
    }
    func testWalkingSwitchesCalibrationWithGlassesAndPhoneFallback() throws {
        let (app, _) = makeApp()
        defer { app.walking.setProtection(enabled: false) }
        for var clip in LabeledCaptureLibrary.referenceCaptures() {
            clip.source = .phoneRecording
            try app.calibration.store.save(clip)
        }
        app.calibration.recalibrate(for: .phoneRecording)
        XCTAssertEqual(app.calibration.source, .phoneRecording)
        let glasses = MockGlassesDevice(name: "Calibration test glasses", loopSamples: LabeledCaptureLibrary.referenceCaptures()[0].samples)
        app.glasses.attach(glasses)
        app.glasses.connect()
        app.walking.setProtection(enabled: true)
        XCTAssertEqual(app.motion.activeCaptureSource, .glassesRecording)
        XCTAssertEqual(app.calibration.targetSource, .glassesRecording)
        XCTAssertEqual(app.calibration.source, .syntheticReference)
        app.glasses.disconnect()
        XCTAssertEqual(app.calibration.targetSource, .phoneRecording)
        XCTAssertEqual(app.calibration.source, .phoneRecording)
    }
    private func makeApp(transport: RecordingJSONTransport = RecordingJSONTransport(), defaultToken: String = AppSettings.developmentToken) -> (CadenceAppModel, RecordingJSONTransport) {
        let suite = "dev-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let sync = EventSyncManager(
            databasePath: NSTemporaryDirectory() + "\(suite).sqlite", startPeriodicDrain: false
        )
        let settings = AppSettings(defaults: defaults, sync: sync, developerMode: false, defaultToken: defaultToken)
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

    func testFallCheckInPreemptsHeyMetaAudioHandoff() async {
        let (app, _) = makeApp()
        await app.useMetaAssistant()
        XCTAssertTrue(app.isUsingMetaAssistant)
        app.fallAlert.beginCheckIn(eventUUID: UUID().uuidString)
        XCTAssertFalse(app.isUsingMetaAssistant)
        app.fallAlert.cancelByUser()
    }

    func testHeyMetaHandoffKeepsHandsFreeSetupWhileVoiceOffDisablesIt() async {
        let (app, _) = makeApp()
        app.settings.voiceCompanionEnabled = true
        await app.useMetaAssistant()
        XCTAssertTrue(app.isUsingMetaAssistant)
        XCTAssertTrue(app.settings.voiceCompanionEnabled)
        app.companion.stop()
        XCTAssertFalse(app.settings.voiceCompanionEnabled)
        AudioCueEngine.shared.retryAudio()
    }

    func testMedicationPhotoWriteFailureRetainsPreviousPhotoAndRetriesOriginalBytes() throws {
        let (app, _) = makeApp()
        let original = Data("original photo".utf8)
        let replacement = Data("new glasses photo".utf8)
        app.setPillPhoto(original)
        XCTAssertEqual(app.pillPhoto, original)
        let directory = app.pillPhotos.directory
        try FileManager.default.removeItem(at: directory)
        try Data("blocked path".utf8).write(to: directory)
        app.setPillPhoto(replacement)
        XCTAssertEqual(app.pillPhoto, original)
        XCTAssertNotNil(app.photoSaveError)
        try FileManager.default.removeItem(at: directory)
        app.retryPillPhotoSave()
        XCTAssertNil(app.photoSaveError)
        XCTAssertEqual(app.pillPhoto, replacement)
        XCTAssertEqual(app.pillPhotos.forMedication(app.settings.schedule.medicationName).load(), replacement)
        app.retryPillPhotoSave()
        XCTAssertEqual(app.pillPhotos.forMedication(app.settings.schedule.medicationName).load(), replacement)
    }

    func testAnalysis401RequiresSignInWithoutErasingProfileOrPendingHistory() async {
        let (app, transport) = makeApp(defaultToken: "")
        app.settings.deviceToken = "rejected-device-token"
        let profile = app.settings.profile.id
        _ = app.settings.sync.saveLocalImmediate(eventUUID: "keep-my-event", endpoint: "/fixture", payload: [:])
        let before = app.settings.sync.pendingCount()
        transport.error = CadenceAPIError.httpStatus(401)
        _ = try? await app.settings.api.realityCheck(question: "Check", jpeg: Data([1]))
        XCTAssertTrue(app.auth.isExpired)
        XCTAssertTrue(app.auth.needsSignIn)
        XCTAssertEqual(app.settings.profile.id, profile)
        XCTAssertEqual(app.settings.sync.pendingCount(), before)
        XCTAssertEqual(app.settings.deviceToken, "rejected-device-token")
    }

    func testLate401FromOldTokenCannotExpireARefreshedSession() async throws {
        let (app, transport) = makeApp(defaultToken: "")
        let body = Data(#"{"sub":"phone","pid":"wearer","role":"device_writer"}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        app.settings.deviceToken = "header.\(body).old-signature"
        let old = app.settings.api
        let refreshed = "header.\(body).new-signature"
        app.settings.deviceToken = refreshed
        XCTAssertEqual(app.settings.deviceToken, refreshed)
        transport.error = CadenceAPIError.httpStatus(401)
        _ = try? await old.realityCheck(question: "Check", jpeg: Data([1]))
        XCTAssertFalse(app.auth.isExpired)
    }

    func testDeveloperTogglePersistsPerProfileAndCanOverrideLaunchDefault() {
        let (app, _) = makeApp()
        let suite = "dev-flag-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let profile = app.settings.profile
        let initial = AppSettings(defaults: defaults, sync: app.settings.sync, developerMode: false, profile: profile)
        XCTAssertFalse(initial.developerModeEnabled)
        initial.developerModeEnabled = true
        let reopened = AppSettings(defaults: defaults, sync: app.settings.sync, developerMode: false, profile: profile)
        XCTAssertTrue(reopened.developerModeEnabled)
        reopened.developerModeEnabled = false
        XCTAssertFalse(AppSettings(defaults: defaults, sync: app.settings.sync, developerMode: true, profile: profile).developerModeEnabled)
        let otherProfile = DeviceProfile(root: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString))
        XCTAssertFalse(AppSettings(defaults: defaults, sync: app.settings.sync, developerMode: false, profile: otherProfile).developerModeEnabled)
    }

    func testLaunchKeepsHomeAvailableBeforeSetupAfterOfflineLoginAndAfterSignOut() async {
        let (app, transport) = makeApp(defaultToken: "")
        XCTAssertFalse(app.settings.profile.isBound)
        XCTAssertEqual(CadenceLaunchScreen(settings: app.settings), .home)
        transport.error = URLError(.notConnectedToInternet)
        await app.auth.signIn(username: "phone", password: "fixture password")
        XCTAssertNotNil(app.auth.errorMessage)
        XCTAssertEqual(CadenceLaunchScreen(settings: app.settings), .home)
        app.settings.deviceToken = "fixture-device-key"
        XCTAssertTrue(app.settings.profile.isBound)
        XCTAssertEqual(CadenceLaunchScreen(settings: app.settings), .home)
        app.auth.signOut()
        XCTAssertEqual(CadenceLaunchScreen(settings: app.settings), .home)
    }

    func testDeliveryPollingRecordsDistinctEvidenceOnceAndRejectsOtherSessions() async throws {
        let (app, transport) = makeApp(defaultToken: "")
        // Start with no token so the automatic poller cannot consume test responses.
        app.settings.deviceToken = ""
        app.fallAlert.beginCheckIn(eventUUID: "poll-incident")
        app.fallAlert.escalate()
        app.settings.backendBaseURL = "http://example.test/"
        app.settings.deviceToken = "report-test-token"
        let client = app.settings.api
        let accepted = Data(#"{"event_uuid":"poll-incident","contact_state":"provider_accepted","provider_accepted":true,"caregiver_acknowledged":false,"simulated":false}"#.utf8)
        let ack = Data(#"{"event_uuid":"poll-incident","contact_state":"acknowledged","provider_accepted":true,"caregiver_acknowledged":true,"simulated":false}"#.utf8)
        transport.responses = [accepted, accepted, ack, ack]
        for _ in 0..<4 { _ = await app.refreshDelivery(eventUUID: "poll-incident", client: client) }
        let events = try app.diary.events(on: Date())
        XCTAssertEqual(events.filter { $0.kind == .alertAccepted }.count, 1)
        XCTAssertEqual(events.filter { $0.kind == .caregiverAcknowledged }.count, 1)
        XCTAssertEqual(app.fallAlert.contactState, "acknowledged")
        XCTAssertTrue(events.filter { $0.kind == .alertAccepted || $0.kind == .caregiverAcknowledged }.allSatisfy { $0.incidentID == "poll-incident" })
        let before = transport.requests.count
        // A different account is rejected by single-wearer provisioning;
        // signing out still invalidates a captured poll client.
        app.settings.deviceToken = "different-session"
        XCTAssertEqual(app.settings.deviceToken, client.bearerToken)
        app.settings.deviceToken = ""
        let owned = await app.refreshDelivery(eventUUID: "poll-incident", client: client)
        XCTAssertFalse(owned)
        XCTAssertEqual(transport.requests.count, before)
        app.fallAlert.cancelByUser()
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

    func testLocalResetCannotCancelAnActiveHelpAlertAndBlocksOldProducers() throws {
        let (app, _) = makeApp()
        app.fallAlert.beginCheckIn(eventUUID: "reset-guard")
        XCTAssertFalse(app.resetLocalProfile())
        XCTAssertFalse(app.settings.restartRequired)
        XCTAssertTrue(app.fallAlert.isAlertVisible)
        app.fallAlert.cancelByUser()
        XCTAssertTrue(app.resetLocalProfile())
        XCTAssertTrue(app.settings.restartRequired)
        XCTAssertEqual(CadenceLaunchScreen(settings: app.settings), .restart)
        XCTAssertFalse(app.motion.isRunning)
        let before = try app.diary.events(on: Date()).count
        app.recordDiary(.doseTaken, detail: "late callback")
        app.setPillPhoto(Data("late photo".utf8))
        XCTAssertEqual(try app.diary.events(on: Date()).count, before)
        XCTAssertNil(app.pillPhoto)
        XCTAssertThrowsError(try app.settings.sync.saveLocalImmediate(eventUUID: "late", endpoint: "/fixture", payload: [:]).get())
    }

    func testSeedingTheDiaryWritesEveryKindAndClearingRemovesThem() throws {
        let (app, _) = makeApp()
        let tools = DeveloperToolsModel(app: app)
        tools.seedSampleDay()
        let events = try app.diary.events(on: Date())
        let kinds = Set(events.map(\.kind))
        // Delivery evidence must come from the server, never from sample data.
        XCTAssertFalse(kinds.contains(.alertAccepted))
        XCTAssertFalse(kinds.contains(.caregiverAcknowledged))
        for kind in DiaryEventKind.allCases where kind != .alertAccepted && kind != .caregiverAcknowledged {
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
