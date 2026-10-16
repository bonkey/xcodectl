//
// Copyright (c) 2026 Daniel Bauke
//

@testable import xcodectl
import Foundation
import Testing

// MARK: - ReleasesTests

struct ReleasesTests {
    /// Every minor of the newest major, the newest release of the major before it, one row per minor.
    @Test func `default listing shows the newest major by minor and the newest of the one before`() {
        #expect(Releases.defaultListing(stableNewest).map(\.display) == ["27.0", "26.6"])
    }

    @Test func `default listing adds the newest prerelease newer than the latest stable`() {
        #expect(Releases.defaultListing(betaNewest).map(\.display) == ["28.0-beta2", "27.1", "27.0", "26.6"])
    }

    /// data.json is ordered by date, and a final can ship after a beta of the next version; the versions
    /// decide which prereleases are newer, not the dates. A patch stands for its minor.
    @Test func `default listing keeps a higher beta released before the newest final`() {
        #expect(
            Releases.defaultListing(finalAfterBeta).map(\.display) ==
                ["27.1", "27.2-beta3", "27.0.1", "26.6"])
    }

    /// An installed Xcode always shows, whether its major is older than the shown ones or it is a
    /// prerelease of a version that has shipped; the final of an installed build stands for it.
    @Test func `default listing adds installed Xcodes`() {
        let installed = ["25E301", "27a9269", "27A9275"]
        #expect(
            Releases.defaultListing(finalAfterBeta, installed: installed).map(\.display) ==
                ["27.1", "27.2-beta3", "27.0.1", "27.1-beta1", "26.6", "25.4"])
        #expect(
            Releases.defaultListing(finalAfterBeta, .stable, installed: installed).map(\.display) ==
                ["27.1", "27.0.1", "26.6", "25.4"])
        #expect(
            Releases.defaultListing(finalAfterBeta, .beta, installed: installed).map(\.display) ==
                ["27.2-beta3", "27.1-rc1", "27.1-beta1"])
    }

    /// A patch of the old major can be released after the new major; the majors decide, not the dates.
    @Test func `default listing keeps the highest major when an older major is newer`() {
        let releases = [makeRelease("26.7", "26G22", (2026, 10, 1))] + stableNewest
        #expect(Releases.defaultListing(releases).map(\.display) == ["26.7", "27.0"])
    }

    @Test func `stable listing drops every prerelease`() {
        #expect(Releases.defaultListing(betaNewest, .stable).map(\.display) == ["27.1", "27.0", "26.6"])
        #expect(Releases.defaultListing(stableNewest, .stable).map(\.display) == ["27.0", "26.6"])
    }

    @Test func `beta listing shows the newest prerelease of each shown minor`() {
        #expect(Releases.defaultListing(stableNewest, .beta).map(\.display) == ["27.0-rc1", "26.5-rc1"])
        #expect(Releases.defaultListing(betaNewest, .beta).map(\.display) == ["28.0-beta2", "27.1-rc1"])
    }

    @Test func `filter narrows search results`() throws {
        let hits = try Releases.search(stableNewest, regex: "^2[67]")
        #expect(Releases.filter(hits, .all).map(\.display) == hits.map(\.display))
        #expect(Releases.filter(hits, .stable).map(\.display) == ["27.0", "26.6", "26.5"])
        #expect(Releases.filter(hits, .beta).map(\.display) == ["27.0-rc1", "26.5-rc1"])
    }

    @Test func `sorted by version orders by number then kind`() {
        let releases = [
            makeRelease("27.1", "27A9275", (2026, 10, 5), kind: .init(rc: 1)),
            makeRelease("27.2", "27B5028f", (2026, 9, 28), kind: .init(beta: 2)),
            makeRelease("27.0.1", "27A300", (2026, 9, 25)),
            makeRelease("27.1", "27A9269", (2026, 9, 18), kind: .init(beta: 1)),
            makeRelease("27.2", "27B5019j", (2026, 9, 16), kind: .init(beta: 1)),
            makeRelease("27", "27A266a", (2026, 9, 14)),
            makeRelease("27.0.0", "27A266a", (2026, 9, 9), kind: .init(rc: 1)),
            makeRelease("27.0", "27A250", (2026, 8, 30), kind: .init(beta: 3)),
            makeRelease("12.0", "12A7208", (2020, 9, 16), kind: .init(gm: true)),
            makeRelease("12.0", "12A7209", (2020, 9, 15), kind: .init(gmSeed: 1)),
        ]
        #expect(Releases.sorted(releases, by: .byVersion).map(\.display) == [
            "27.2-beta2", "27.2-beta1", "27.1-rc1", "27.1-beta1", "27.0.1", "27", "27.0.0-rc1", "27.0-beta3",
            "12.0-gm", "12.0-gmseed1",
        ])
    }

    @Test func `latest beta takes the highest version`() throws {
        let releases = [
            makeRelease("27.1", "27A9275", (2026, 10, 5), kind: .init(rc: 1)),
            makeRelease("27.2", "27B5028f", (2026, 9, 28), kind: .init(beta: 2)),
            makeRelease("27.0", "27A266a", (2026, 9, 14)),
        ]
        #expect(try Query("latest-beta").resolve(in: releases).release.display == "27.2-beta2")
    }

    /// data.json serves a new major's first beta above older finals released after it.
    @Test func `sorted by release date orders by date then version`() {
        let releases = [
            makeRelease("26.6", "17F109", (2026, 6, 8), kind: .init(rc: 1)),
            makeRelease("27.0", "27A5218g", (2026, 6, 8), kind: .init(beta: 1)),
            makeRelease("26.6", "17F113", (2026, 6, 25)),
            makeRelease("26.5", "17F42", (2026, 5, 11)),
        ]
        #expect(
            Releases.sorted(releases, by: .byDate).map(\.display) ==
                ["26.6", "27.0-beta1", "26.6-rc1", "26.5"])
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

    private let finalAfterBeta = [
        makeRelease("27.1", "27A9275", (2026, 10, 15)),
        makeRelease("27.2", "27B5038j", (2026, 10, 14), kind: .init(beta: 3)),
        makeRelease("27.1", "27A9275", (2026, 10, 5), kind: .init(rc: 1)),
        makeRelease("27.2", "27B5028f", (2026, 9, 28), kind: .init(beta: 2)),
        makeRelease("27.0.1", "27A400", (2026, 9, 22)),
        makeRelease("27.1", "27A9269", (2026, 9, 18), kind: .init(beta: 1)),
        makeRelease("27.0", "27A266a", (2026, 9, 14)),
        makeRelease("26.6", "26F71", (2026, 8, 12)),
        makeRelease("25.4", "25E301", (2025, 7, 2)),
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

// MARK: - UpdatesTests

struct UpdatesTests {
    @Test func `beta moves to the newest build of its minor and others stay`() {
        #expect(
            updates([
                makeApp("Xcode-27.1-beta1.app", version: "27.1", build: "27A9269"),
                makeApp("Xcode-27.2-beta1.app", version: "27.2", build: "27B5019j"),
            ]) ==
                ["Xcode-27.2-beta1.app -> 27.2-beta2"])
    }

    @Test func `final moves to the newest final of its minor only`() {
        #expect(
            updates([
                makeApp("Xcode-27.0.app", version: "27.0", build: "27A266a"),
                makeApp("Xcode-26.4.app", version: "26.4", build: "17E192"),
                makeApp("Xcode-26.6.app", version: "26.6", build: "17F113"),
            ]) ==
                ["Xcode-27.0.app -> 27.0.1", "Xcode-26.4.app -> 26.4.1"])
    }

    @Test func `beta of a shipped minor moves to the final`() {
        #expect(
            updates([makeApp("Xcode-27.0-beta1.app", version: "27.0", build: "27A5218g")]) ==
                ["Xcode-27.0-beta1.app -> 27.0.1"])
    }

    @Test func `target already installed or unknown build is skipped`() {
        #expect(
            updates([
                makeApp("Xcode-27.2-beta1.app", version: "27.2", build: "27B5019j"),
                makeApp("Xcode-27.2-beta2.app", version: "27.2", build: "27B5030a"),
                makeApp("Xcode-local.app", version: "27.0", build: "27Z999"),
            ]) ==
                [])
    }

    @Test func `two installs of one minor share one update`() {
        #expect(
            updates([
                makeApp("Xcode-27.0.app", version: "27.0", build: "27A266a"),
                makeApp("Xcode-27.0-beta1.app", version: "27.0", build: "27A5218g"),
            ]) ==
                ["Xcode-27.0.app -> 27.0.1"])
    }

    /// data.json order: newest first.
    private let releases = [
        makeRelease("27.2", "27B5030a", (2026, 9, 28), kind: .init(beta: 2)),
        makeRelease("27.0.1", "27A300", (2026, 9, 25)),
        makeRelease("27.1", "27A9269", (2026, 9, 18), kind: .init(beta: 1)),
        makeRelease("27.2", "27B5019j", (2026, 9, 16), kind: .init(beta: 1)),
        makeRelease("27.0", "27A266a", (2026, 9, 14)),
        makeRelease("27.0", "27A266a", (2026, 9, 9), kind: .init(rc: 1)),
        makeRelease("27.0", "27A5218g", (2026, 6, 9), kind: .init(beta: 1)),
        makeRelease("26.6", "17F113", (2026, 6, 25)),
        makeRelease("26.4.1", "17E202", (2026, 4, 16)),
        makeRelease("26.4", "17E192", (2026, 3, 24)),
    ]

    private func updates(_ installed: [InstalledXcode]) -> [String] {
        Releases.updates(for: installed, in: releases).map { "\($0.from.name) -> \($0.to.display)" }
    }
}
