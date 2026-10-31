import XCTest
@testable import CadenceCompanion

final class AudioInputOwnershipTests: XCTestCase {
    func testInputIsOnlyNeededWhileAtLeastOneOwnerIsActive() {
        var ownership = AudioInputOwnership()
        XCTAssertFalse(ownership.requiresInput)
        ownership.acquire(.companion)
        ownership.acquire(.transcript)
        XCTAssertTrue(ownership.requiresInput)
        ownership.release(.transcript)
        XCTAssertTrue(ownership.requiresInput)
        ownership.release(.companion)
        XCTAssertFalse(ownership.requiresInput)
    }

    func testEmergencyAndMotorInputAreNotReleasedWithCompanion() {
        var ownership = AudioInputOwnership()
        ownership.acquire(.companion)
        ownership.acquire(.checkIn)
        ownership.acquire(.motorVoice)
        ownership.release(.companion)
        XCTAssertTrue(ownership.requiresInput)
        ownership.release(.checkIn)
        XCTAssertTrue(ownership.requiresInput)
        ownership.release(.motorVoice)
        XCTAssertFalse(ownership.requiresInput)
    }
}
