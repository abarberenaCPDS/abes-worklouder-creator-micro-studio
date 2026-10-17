import XCTest

class LiveIntegrationTestCase: XCTestCase {
    func requireLiveIntegrationOptIn() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["CREATOR_MICRO_STUDIO_LIVE_TESTS"] == "1",
            "Set CREATOR_MICRO_STUDIO_LIVE_TESTS=1 to run tests against real services or hardware."
        )
    }
}
