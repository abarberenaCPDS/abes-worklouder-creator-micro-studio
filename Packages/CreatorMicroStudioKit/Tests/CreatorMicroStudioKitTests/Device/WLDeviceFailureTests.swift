import XCTest
import IOKit
@testable import CreatorMicroStudioKit

final class WLDeviceFailureTests: XCTestCase {
    func testNotPermittedExplainsInputMonitoring() {
        let failure = WLDevice.Failure.openFailed(kIOReturnNotPermitted)

        XCTAssertTrue(failure.errorDescription?.contains("Input Monitoring") == true)
        XCTAssertTrue(failure.errorDescription?.contains("0xE00002E2") == true)
    }
}
