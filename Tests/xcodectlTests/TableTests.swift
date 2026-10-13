//
// Copyright (c) 2026 Daniel Bauke
//

@testable import xcodectl
import Foundation
import Testing

struct TableTests {
    @Test func `every column but the last is padded to its widest`() {
        #expect(tableLines([["A", "BB", "C"], ["AAA", "B", "CCCC"]]) == [
            "A    BB  C",
            "AAA  B   CCCC",
        ])
    }

    @Test func `empty trailing columns leave no trailing spaces`() {
        #expect(tableLines([["VERSION", "PATH", ""], ["27.0", "", ""]]) == [
            "VERSION  PATH",
            "27.0",
        ])
    }

    /// `list-installed` indents the runtimes under the Xcode that uses them.
    @Test func `a leading indent stays`() {
        #expect(tableLines([["27.0", "27A266a"], ["  iOS 27.0", "24A434"]]) == [
            "27.0        27A266a",
            "  iOS 27.0  24A434",
        ])
    }

    @Test func `no rows give no lines`() {
        #expect(tableLines([]) == [])
    }
}
