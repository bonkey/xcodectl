//
// Copyright (c) 2026 Daniel Bauke
//

@testable import xcodectl
import XCTest

final class ReleasesTests: XCTestCase {
    func testDefaultListingShowsTheTwoLatestStableMajorsWithoutOldPrereleases() {
        XCTAssertEqual(Releases.defaultListing(stableNewest).map(\.display), ["27.0", "26.6", "26.5"])
    }

    func testDefaultListingAddsPrereleasesNewerThanTheLatestStable() {
        XCTAssertEqual(
            Releases.defaultListing(betaNewest).map(\.display),
            ["28.0-beta2", "28.0-beta1", "27.1", "27.0", "26.6"])
    }

    /// A patch of the old major can be released after the new major; the majors decide, not the dates.
    func testDefaultListingKeepsTheHighestMajorWhenAnOlderMajorIsNewer() {
        let releases = [makeRelease("26.7", "26G22", (2026, 10, 1))] + stableNewest
        XCTAssertEqual(Releases.defaultListing(releases).map(\.display), ["26.7", "27.0", "26.6", "26.5"])
    }

    func testStableListingDropsEveryPrerelease() {
        XCTAssertEqual(Releases.defaultListing(betaNewest, .stable).map(\.display), ["27.1", "27.0", "26.6"])
        XCTAssertEqual(Releases.defaultListing(stableNewest, .stable).map(\.display), ["27.0", "26.6", "26.5"])
    }

    func testBetaListingShowsOnlyPrereleasesOfTheShownMajors() {
        XCTAssertEqual(Releases.defaultListing(stableNewest, .beta).map(\.display), ["27.0-rc1", "26.5-rc1"])
        XCTAssertEqual(
            Releases.defaultListing(betaNewest, .beta).map(\.display),
            ["28.0-beta2", "28.0-beta1", "27.1-rc1"])
    }

    func testFilterNarrowsSearchResults() throws {
        let hits = try Releases.search(stableNewest, regex: "^2[67]")
        XCTAssertEqual(Releases.filter(hits, .all).map(\.display), hits.map(\.display))
        XCTAssertEqual(Releases.filter(hits, .stable).map(\.display), ["27.0", "26.6", "26.5"])
        XCTAssertEqual(Releases.filter(hits, .beta).map(\.display), ["27.0-rc1", "26.5-rc1"])
    }

    /// data.json order: newest first.
    private let stableNewest = [
        makeRelease("27.0", "27A266a", (2026, 9, 14)),
        makeRelease("27.0", "27A266a", (2026, 9, 9), kind: .init(rc: 1)),
        makeRelease("26.6", "26F71", (2026, 8, 12)),
        makeRelease("26.5", "26E62", (2026, 6, 30)),
        makeRelease("26.5", "26E62", (2026, 6, 23), kind: .init(rc: 1)),
        makeRelease("25.4", "25E301", (2025, 7, 2)),
        makeRelease("25.4", "25E299", (2025, 6, 25), kind: .init(rc: 1)),
    ]

    private let betaNewest = [
        makeRelease("28.0", "28A5240c", (2026, 6, 23), kind: .init(beta: 2)),
        makeRelease("28.0", "28A5228b", (2026, 6, 9), kind: .init(beta: 1)),
        makeRelease("27.1", "27B48", (2026, 5, 20)),
        makeRelease("27.1", "27B47", (2026, 5, 13), kind: .init(rc: 1)),
        makeRelease("27.0", "27A266a", (2026, 9, 14)),
        makeRelease("26.6", "26F71", (2026, 8, 12)),
        makeRelease("25.4", "25E301", (2025, 7, 2)),
    ]
}
