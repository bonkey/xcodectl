//
// Copyright (c) 2026 Daniel Bauke
//

@testable import xcodectl
import XCTest

final class ReleaseRowsTests: XCTestCase {
    func testOneInstalledAppFillsOneRow() {
        let rows = releaseRows([finalRelease, candidate], installed: [app], active: nil)
        XCTAssertEqual(rows.map(\.last), ["STATUS", "installed", ""])
    }

    func testTheActiveAppIsMarkedActive() {
        let rows = releaseRows([finalRelease, candidate], installed: [app], active: app.path.path)
        XCTAssertEqual(rows.map(\.last), ["STATUS", "* active", ""])
    }

    func testNothingInstalledLeavesEveryStatusEmpty() {
        let rows = releaseRows([finalRelease, candidate], installed: [], active: nil)
        XCTAssertEqual(rows.map(\.last), ["STATUS", "", ""])
    }

    func testARowWithoutAMatchingBuildStaysEmpty() {
        let older = makeRelease("26.6", "26F71", (2026, 8, 12))
        let rows = releaseRows([finalRelease, older], installed: [app], active: nil)
        XCTAssertEqual(rows.map(\.last), ["STATUS", "installed", ""])
    }

    /// A release candidate and its final release carry the same build.
    private let finalRelease = makeRelease("27.0", "27A266a", (2026, 9, 14))
    private let candidate = makeRelease("27.0", "27A266a", (2026, 9, 9), kind: .init(rc: 1))
    private let app = makeApp("Xcode-27.0.0-release.candidate.app", version: "27.0", build: "27A266a")
}
