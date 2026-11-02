import XCTest
@testable import CadenceCompanion

@MainActor
final class MealAndMedicationFlowTests: XCTestCase {
    private func sync() -> EventSyncManager {
        let sync = EventSyncManager(databasePath: NSTemporaryDirectory()+"meals-\(UUID()).sqlite", startPeriodicDrain: false)
        sync.configureSession(baseURL: "https://demo.test", bearerToken: "fixture-owner-token")
        return sync
    }
    private func diary() -> DiaryStore {
        DiaryStore(directory: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("meal-diary-\(UUID())"))
    }
    func testMealPhotoAndNoteStayLocalWhileTimestampIsDurablyQueued() throws {
        let sync = sync(), diary = diary(), now = Date()
        let model = MealLogModel(diary: diary, sync: sync)
        XCTAssertTrue(model.save(at: now, note: "Breakfast", photo: Data([1,2,3])))
        let event = try XCTUnwrap(model.savedEvent)
        XCTAssertEqual(try diary.events(on: now).count,1)
        XCTAssertEqual(MealPhotoStore(diary: diary).load(id: event.id),Data([1,2,3]))
        let queued = try XCTUnwrap(sync.peekNext())
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(queued.payloadJSON.utf8)) as? [String:Any])
        XCTAssertEqual(Set(payload.keys),["event_uuid","timestamp_utc"])
        XCTAssertEqual(queued.endpoint,"/api/v1/meals/log")
        XCTAssertFalse(model.save(at: now, note: "duplicate", photo: nil))
        XCTAssertEqual(try diary.events(on: now).count,1)
    }
    func testFailedDiaryWriteHasNoSuccessReceiptAndNoQueuedMeal() throws {
        let sync = sync(), diary = diary()
        try Data("blocked".utf8).write(to: diary.directory)
        let model = MealLogModel(diary: diary,sync: sync)
        XCTAssertFalse(model.save(at: Date(), note: "", photo: nil))
        XCTAssertNil(model.savedEvent); XCTAssertNotNil(model.error)
        XCTAssertEqual(sync.pendingCount(),0)
    }
    func testCrashGapRecoveryAndWipeBoundaryDoNotCreateDuplicateOrStaleMeals() throws {
        let sync = sync(), diary = diary(), now = Date()
        var event = DiaryEvent(kind:.mealLogged,at:now,detail:"local receipt")
        event.mealSharing = MealSharingContext(owner:try XCTUnwrap(EventSyncManager.owner(for: sync.deviceBearerToken)), destination:sync.backendBaseURL,generation:0)
        try diary.append(event)
        let model = MealLogModel(diary:diary,sync:sync)
        model.recoverPendingSharing(); model.recoverPendingSharing()
        XCTAssertEqual(sync.pendingCount(),1)
        XCTAssertTrue(sync.observeDataGeneration(1,bearerToken:sync.deviceBearerToken,baseURL:sync.backendBaseURL))
        model.recoverPendingSharing()
        XCTAssertEqual(sync.pendingCount(),0)
    }
    func testMealSharingStorageFailureCanRetryWithoutDuplicatingDiary() throws {
        let diary = diary()
        let blocked = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("blocked-queue-\(UUID())")
        try Data([1]).write(to: blocked)
        let sync = EventSyncManager(databasePath: blocked.appendingPathComponent("queue.sqlite").path, startPeriodicDrain: false)
        sync.configureSession(baseURL: "https://demo.test", bearerToken: "fixture-owner-token")
        let model = MealLogModel(diary: diary, sync: sync)
        XCTAssertTrue(model.save(at: Date(), note: "", photo: nil))
        XCTAssertTrue(model.sharingNeedsRetry)
        try FileManager.default.removeItem(at: blocked)
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        model.retrySharing()
        XCTAssertFalse(model.sharingNeedsRetry)
        XCTAssertEqual(sync.pendingCount(), 1)
        XCTAssertEqual(try diary.events(on: Date()).count, 1)
    }
    func testReopenedMealModelCannotAdoptAnotherAccountsJournal() throws {
        let sync = sync(), diary = diary()
        XCTAssertTrue(MealLogModel(diary: diary, sync: sync).save(at: Date(), note: "", photo: nil))
        sync.configureSession(baseURL: sync.backendBaseURL, bearerToken: "another-owner")
        MealLogModel(diary: diary, sync: sync).recoverPendingSharing()
        XCTAssertNil(sync.peekNext())
        XCTAssertEqual(sync.pendingCount(), 1)
    }
    func testChangedAccountCannotReceiveMealOrItsRecovery() throws {
        let sync = sync(), diary = diary()
        let model = MealLogModel(diary:diary,sync:sync)
        sync.configureSession(baseURL:sync.backendBaseURL,bearerToken:"other-owner")
        XCTAssertFalse(model.save(at:Date(),note:"",photo:nil))
        model.recoverPendingSharing()
        XCTAssertEqual(sync.pendingCount(),0)
    }
    func testMedicationEditorPreservesDraftAcrossCameraAndShowsSavedSummary() throws {
        let sync = sync()
        let defaults = UserDefaults(suiteName:"editor-\(UUID())")!
        let settings = AppSettings(defaults:defaults,sync:sync,defaultToken:"fixture")
        try settings.saveMedicationPlan([MedicationSchedule(medicationName:"A",doseTimes:[DoseTime(hour:8,minute:0)])])
        let editor = MedicationPlanEditor(settings:settings,loadPhoto:{_ in nil},savePhoto:{_,_ in nil})
        editor.begin(); editor.items[0].name = "Changed A"
        let firstID = editor.items[0].id
        editor.add(); editor.items[1].name = "B"; editor.items[1].times = [DoseTime(hour:12,minute:0)]
        editor.begin() // camera parent reappearance must not reload settings
        XCTAssertEqual(editor.items[0].id, firstID)
        XCTAssertEqual(editor.items[0].name,"Changed A")
        XCTAssertEqual(editor.items.count,2)
        XCTAssertTrue(editor.save()); XCTAssertFalse(editor.isEditing)
        XCTAssertEqual(settings.medications.map(\.medicationName),["Changed A","B"])
        XCTAssertEqual(editor.receipt,"Saved 2 medications with 2 reminders.")
    }
    func testPhotoFailureNeverDismissesMedicationEditorAsFullySaved() throws {
        let settings = AppSettings(defaults:UserDefaults(suiteName:"editor-\(UUID())")!,sync:sync(),defaultToken:"fixture")
        let editor = MedicationPlanEditor(settings:settings,loadPhoto:{_ in nil},savePhoto:{_,_ in "Photo storage failed."})
        editor.add(); editor.items[editor.items.count-1].name = "New"
        editor.items[editor.items.count-1].photo = Data([1]); editor.items[editor.items.count-1].photoChanged = true
        // Discard any default empty setup row, retaining this explicit draft.
        editor.items = [editor.items.last!]
        XCTAssertFalse(editor.save()); XCTAssertTrue(editor.isEditing)
        XCTAssertNil(editor.receipt); XCTAssertTrue(editor.error?.contains("times are saved") == true)
    }
    func testInvalidMedicationNamesKeepDraftAndCannotClaimSuccess() {
        let settings = AppSettings(defaults:UserDefaults(suiteName:"editor-\(UUID())")!,sync:sync(),defaultToken:"fixture")
        let editor = MedicationPlanEditor(settings:settings,loadPhoto:{_ in nil},savePhoto:{_,_ in nil})
        editor.add()
        XCTAssertFalse(editor.save()); XCTAssertTrue(editor.isEditing); XCTAssertNil(editor.receipt)
    }
    func testMedicationSetupVoiceCommandsStayInTheEditor() {
        XCTAssertEqual(CompanionStep.medicationSetup.resolve("save routine"),.finish)
        XCTAssertEqual(CompanionStep.medicationSetup.resolve("discard changes"),.cancel)
        XCTAssertNil(CompanionStep.medicationSetup.resolve("yes"))
    }
    func testSavedMealVoiceContextCannotRepeatAnUnintendedSave() {
        XCTAssertEqual(CompanionStep.mealSaved.resolve("another meal"),.retry)
        XCTAssertNil(CompanionStep.mealSaved.resolve("yes"))
    }
    func testRealityStatusDecodesOldResponsesAndDistinguishesServiceFailure() throws {
        let json = """
        {"event_uuid":"fixture", "sam_verified":false,"living_subject_present":false,"chosen_inanimate_label":null,
         "template_id":"UNVERIFIED_LIGHTING_FALLBACK","spoken_response":"Retry the image service","verified_masks":[],"latency_ms":20,"analysis_status":"unavailable"}
        """
        let result = try JSONDecoder().decode(RealityCheckResult.self,from:Data(json.utf8))
        XCTAssertEqual(result.statusTitle,"Photo check unavailable")
        var duplicates = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        duplicates["verified_masks"] = [["label":"pillow"],["label":"pillow"],["label":"sofa"]]
        XCTAssertEqual(try JSONDecoder().decode(RealityCheckResult.self, from: JSONSerialization.data(withJSONObject: duplicates)).detectedLabels, ["pillow","sofa"])
        let old = json.replacingOccurrences(of:",\"analysis_status\":\"unavailable\"",with:"")
        XCTAssertNoThrow(try JSONDecoder().decode(RealityCheckResult.self,from:Data(old.utf8)))
    }
}

private final class PhotoBudgetURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var budgets: [TimeInterval] = []
    static func reset() { lock.lock(); budgets = []; lock.unlock() }
    static func captured() -> [TimeInterval] { lock.lock(); defer { lock.unlock() }; return budgets }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "cadence-budget.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.budgets.append(request.timeoutInterval); Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class PhotoRequestBudgetTests: XCTestCase {
    func testPhotoUploadAllowsServerProcessingAndNetworkTimeWithoutSlowingHealthChecks() async throws {
        PhotoBudgetURLProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PhotoBudgetURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let transport = URLSessionJSONTransport(timeoutSec: 8, session: session)
        _ = try await transport.send(URLRequest(url: URL(string:"https://cadence-budget.invalid/api/v1/reality-check")!),bearerToken:"fixture")
        _ = try await transport.send(URLRequest(url: URL(string:"https://cadence-budget.invalid/health")!),bearerToken:"")
        XCTAssertEqual(PhotoBudgetURLProtocol.captured(),[20,8])
    }
}
