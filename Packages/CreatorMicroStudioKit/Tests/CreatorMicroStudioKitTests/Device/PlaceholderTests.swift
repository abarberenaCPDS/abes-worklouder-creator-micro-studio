import XCTest
@testable import CreatorMicroStudioKit

final class PlaceholderTests: XCTestCase {
    func testPadGeometry() {
        XCTAssertEqual(Pad.rows.flatMap { $0 }.count, Pad.keyCount)
        // Reading order: the top row is wired right to left.
        XCTAssertEqual(Pad.agentKeyIDs, [1, 0, 2, 3, 4, 5])
        XCTAssertEqual(Pad.displayRows.flatMap { $0 }.sorted(), Pad.rows.flatMap { $0 }.sorted())
        XCTAssertEqual(Pad.physicalDisplayRows, [
            [.dial, .key(1), .key(0), .joystick],
            [.key(2), .key(3), .key(4), .key(5)],
            [.key(6), .key(7), .key(8), .key(9)],
            [.caseMark, .key(10), .key(11), .key(12)],
        ])
    }
}
