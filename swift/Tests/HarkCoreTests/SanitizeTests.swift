import XCTest
@testable import HarkCore

final class SanitizeTests: XCTestCase {
    func testCollapsesNewlinesToSingleSpace() {
        XCTAssertEqual(Sanitize.sanitize("hello\nworld"), "hello world")
        XCTAssertEqual(Sanitize.sanitize("two  spaces"), "two spaces")
    }
    func testReplacesControlChars() {
        // C0 controls (0x00-0x08, 0x0B, 0x0C, 0x0E-0x1F) → space.
        let raw = "a\u{07}b\u{08}c"
        XCTAssertEqual(Sanitize.sanitize(raw), "a b c")
    }
    func testReplacesC1AndLineSeparators() {
        XCTAssertEqual(Sanitize.sanitize("a\u{009B}b"), "a b")   // CSI (ESC [)
        XCTAssertEqual(Sanitize.sanitize("a\u{2028}b"), "a b")   // line separator
    }
    func testTrims() {
        XCTAssertEqual(Sanitize.sanitize("  padded  "), "padded")
    }
    func testHostileEscapeSequenceNeutralised() {
        // A full CSI sequence must never survive as a control sequence.
        XCTAssertEqual(Sanitize.sanitize("ok\u{001B}[31mred"), "ok [31mred")
    }
    func testEmptyStaysEmpty() {
        XCTAssertEqual(Sanitize.sanitize(""), "")
    }
}
