//
// Copyright (c) 2026 Daniel Bauke
//

@testable import xcodectl
import XCTest

final class TableTests: XCTestCase {
    func testEveryColumnButTheLastIsPaddedToItsWidest() {
        XCTAssertEqual(tableLines([["A", "BB", "C"], ["AAA", "B", "CCCC"]]), [
            "A    BB  C",
            "AAA  B   CCCC",
        ])
    }

    func testEmptyTrailingColumnsLeaveNoTrailingSpaces() {
        XCTAssertEqual(tableLines([["VERSION", "PATH", ""], ["27.0", "", ""]]), [
            "VERSION  PATH",
            "27.0",
        ])
    }

    /// `list-installed` indents the runtimes under the Xcode that uses them.
    func testALeadingIndentStays() {
        XCTAssertEqual(tableLines([["27.0", "27A266a"], ["  iOS 27.0", "24A434"]]), [
            "27.0        27A266a",
            "  iOS 27.0  24A434",
        ])
    }

    func testNoRowsGiveNoLines() {
        XCTAssertEqual(tableLines([]), [])
    }
}
