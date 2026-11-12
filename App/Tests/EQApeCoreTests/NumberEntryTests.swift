import Foundation
import XCTest
@testable import EQApeCore

final class NumberEntryTests: XCTestCase {
    /// Regression (found by the UI-test suite, 2026-11-12): Return committed the typed value, the field then showed
    /// the old value (the view had not updated yet), and the focus change that Return causes committed that old value
    /// again, silently undoing the edit.
    func testReturnThenFocusLossKeepsTheTypedValue() {
        let e = NumberEntry(digits: 1, locale: Locale(identifier: "en_US"))
        let submit = e.commit(text: "250", current: 120)
        XCTAssertEqual(submit.value, 250)
        XCTAssertEqual(submit.text, "250")
        // focus loss before the view has updated (current still 120): must not write 120 back
        let blurStale = e.commit(text: submit.text, current: 120)
        XCTAssertNotEqual(blurStale.value, 120)
        // focus loss after the update: nothing to commit
        let blur = e.commit(text: submit.text, current: 250)
        XCTAssertNil(blur.value)
        XCTAssertEqual(blur.text, "250")
    }

    func testParsingAndInvalidText() {
        let fi = NumberEntry(digits: 2, locale: Locale(identifier: "fi_FI"))
        let us = NumberEntry(digits: 2, locale: Locale(identifier: "en_US"))
        XCTAssertEqual(fi.parse("-4,5"), -4.5)
        XCTAssertEqual(fi.parse("-4.5"), -4.5)
        XCTAssertEqual(us.parse("-4.5"), -4.5)
        XCTAssertEqual(us.parse("4,5"), 4.5, "a comma is a decimal separator, never grouping")
        XCTAssertNil(us.parse("abc"))
        XCTAssertNil(us.parse("  "))
        let bad = us.commit(text: "abc", current: 4)
        XCTAssertNil(bad.value)
        XCTAssertEqual(bad.text, "4")
        XCTAssertEqual(fi.format(10.8), "10,8")
        XCTAssertEqual(us.format(1234.5), "1234.5")
    }
}
