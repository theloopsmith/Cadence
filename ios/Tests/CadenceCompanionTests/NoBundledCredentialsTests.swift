import Foundation
import XCTest
@testable import CadenceCompanion

@MainActor
final class NoBundledCredentialsTests: XCTestCase {
    func testProductionDefaultsHaveNoCredential() {
        let queue = EventSyncManager(databasePath: NSTemporaryDirectory()+"no-default-token-\(UUID()).sqlite", startPeriodicDrain: false)
        XCTAssertEqual(queue.deviceBearerToken, "")
        XCTAssertEqual(AppSettings.developmentToken, "")
        let defaults = UserDefaults(suiteName: "no-token-\(UUID())")!
        let settings = AppSettings(defaults: defaults, sync: queue, tokenStore: InMemoryTokenStore())
        XCTAssertEqual(settings.deviceToken, "")
        XCTAssertEqual(HomeMotorExamManager(sync: queue).deviceBearerToken, "")
    }
}
