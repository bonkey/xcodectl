//
// Copyright (c) 2026 Daniel Bauke
//

@testable import xcodectl
import Foundation
import Testing

struct TableTests {
    @Test func everyColumnButTheLastIsPaddedToItsWidest() {
        #expect(tableLines([["A", "BB", "C"], ["AAA", "B", "CCCC"]]) == [
            "A    BB  C",
            "AAA  B   CCCC",
        ])
    }

    @Test func emptyTrailingColumnsLeaveNoTrailingSpaces() {
        #expect(tableLines([["VERSION", "PATH", ""], ["27.0", "", ""]]) == [
            "VERSION  PATH",
            "27.0",
        ])
    }

    /// `list-installed` indents the runtimes under the Xcode that uses them.
    @Test func aLeadingIndentStays() {
        #expect(tableLines([["27.0", "27A266a"], ["  iOS 27.0", "24A434"]]) == [
            "27.0        27A266a",
            "  iOS 27.0  24A434",
        ])
    }

    @Test func noRowsGiveNoLines() {
        #expect(tableLines([]) == [])
    }
}
