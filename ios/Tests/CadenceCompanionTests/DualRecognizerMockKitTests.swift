import XCTest
@testable import CadenceCompanion

final class DualRecognizerMockKitTests: XCTestCase {
    func testContradictoryResultsEscalateInEitherArrivalOrder() {
        for localFirst in [true,false] {
            var evidence=DualRecognizerCheckIn()
            if localFirst {
                evidence.record("I'm okay",from:.local); evidence.record("I'm not okay",from:.cloud)
            } else {
                evidence.record("I'm not okay",from:.cloud); evidence.record("I'm okay",from:.local)
            }
            XCTAssertTrue(evidence.distressHeard)
            XCTAssertEqual(evidence.transcriptForResolution,"help")
        }
    }
    func testDistressCannotBeErasedByALaterAffirmativeCorrection() {
        var e=DualRecognizerCheckIn()
        e.record("I can't get up",from:.cloud);e.record("I'm okay",from:.cloud);e.record("I'm okay",from:.local)
        XCTAssertEqual(e.transcriptForResolution,"help")
    }
    func testBothSourcesMustAgreeUnlessCloudIsAbsent() {
        var e=DualRecognizerCheckIn();e.record("I'm OK",from:.local)
        XCTAssertFalse(e.transcriptForResolution.isEmpty)
        e.record("unintelligible speech",from:.cloud)
        XCTAssertTrue(e.transcriptForResolution.isEmpty)
        e.record("I am fine",from:.cloud)
        XCTAssertFalse(e.transcriptForResolution.isEmpty)
    }
    func testCloudAloneCannotCancelAndANewSessionDropsOldEvidence() {
        var e=DualRecognizerCheckIn();e.record("I'm okay",from:.cloud)
        XCTAssertTrue(e.transcriptForResolution.isEmpty)
        e.record("help",from:.local)
        e=DualRecognizerCheckIn();e.record("I am fine",from:.local)
        XCTAssertFalse(e.distressHeard)
        XCTAssertEqual(e.transcriptForResolution,"I am fine")
    }
}
