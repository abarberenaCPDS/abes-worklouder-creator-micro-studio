import XCTest
@testable import CreatorMicroStudioKit

final class HTMLTextTests: XCTestCase {

    func testPlainTextPassesThroughUntouched() {
        XCTAssertEqual(HTMLText.escape("▸ 1  opus"), "▸ 1  opus")
    }

    func testMarkupIsEscaped() {
        XCTAssertEqual(HTMLText.escape("a<b & \"c\">d"), "a&lt;b &amp; &quot;c&quot;&gt;d")
    }

    func testCarriageReturnsAreDropped() {
        XCTAssertEqual(HTMLText.escape("one\r\ntwo"), "one\ntwo")
    }
}
