//
// Copyright (c) 2026 Daniel Bauke
//

@testable import xcodectl
import Foundation
import Testing

struct ReleaseRowsTests {
    @Test func `one installed app fills one row`() {
        let rows = releaseRows([finalRelease, candidate], installed: [app], active: nil)
        #expect(rows.map(\.last) == ["STATUS", "installed", ""])
    }

    @Test func `the active app is marked active`() {
        let rows = releaseRows([finalRelease, candidate], installed: [app], active: app.path.path)
        #expect(rows.map(\.last) == ["STATUS", "* active", ""])
    }

    @Test func `nothing installed leaves every status empty`() {
        let rows = releaseRows([finalRelease, candidate], installed: [], active: nil)
        #expect(rows.map(\.last) == ["STATUS", "", ""])
    }

    @Test func `a row without a matching build stays empty`() {
        let older = makeRelease("26.6", "26F71", (2026, 8, 12))
        let rows = releaseRows([finalRelease, older], installed: [app], active: nil)
        #expect(rows.map(\.last) == ["STATUS", "installed", ""])
    }

    /// A release candidate and its final release carry the same build.
    private let finalRelease = makeRelease("27.0", "27A266a", (2026, 9, 14))
    private let candidate = makeRelease("27.0", "27A266a", (2026, 9, 9), kind: .init(rc: 1))
    private let app = makeApp("Xcode-27.0.0-release.candidate.app", version: "27.0", build: "27A266a")
}
