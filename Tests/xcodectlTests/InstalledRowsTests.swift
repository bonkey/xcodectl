//
// Copyright (c) 2026 Daniel Bauke
//

@testable import xcodectl
import Foundation
import Testing

struct InstalledRowsTests {
    @Test func `an Xcode row carries its size and path`() {
        let rows = installedRows([(app, 3_583_873_024, [])], active: nil)
        #expect(rows == [
            ["VERSION", "BUILD", "SIZE", "PATH", ""],
            ["27.0", "27A266a", "3.3 GB", "/Applications/Xcode-27.0.app", ""],
        ])
    }

    @Test func `the active Xcode is marked active`() {
        let rows = installedRows([(app, 0, []), (beta, 0, [])], active: beta.path.path)
        #expect(rows.map(\.last) == ["", "", "* active"])
    }

    @Test func `runtimes follow the Xcode that uses them`() throws {
        let runtimes = try SimCtl.parse(makeSimctlOutput([
            ("A", "com.apple.platform.iphonesimulator", "27.0", "24A434", "Ready", 8_067_000_161, "/a.asset/AssetData"),
        ]))
        let rows = installedRows([(app, 0, runtimes), (beta, 0, [])], active: nil)
        #expect(rows.map(\.first) == ["VERSION", "27.0", "  iOS 27.0", "27.1"])
        #expect(rows[2] == ["  iOS 27.0", "24A434", "7.5 GB", "", ""])
    }

    @Test func `an Xcode still being sized shows the placeholder`() {
        let rows = installedRows([(app, nil, [])], active: nil, unknownSize: "…")
        #expect(rows[1] == ["27.0", "27A266a", "…", "/Applications/Xcode-27.0.app", ""])
    }

    /// `--no-size` skips the Xcode bundles; runtime sizes come from simctl for free.
    @Test func `an unsized Xcode leaves its size empty but keeps runtime sizes`() throws {
        let runtimes = try SimCtl.parse(makeSimctlOutput([
            ("A", "com.apple.platform.iphonesimulator", "27.0", "24A434", "Ready", 8_067_000_161, "/a.asset/AssetData"),
        ]))
        let rows = installedRows([(app, nil, runtimes)], active: nil)
        #expect(rows.map { $0[2] } == ["SIZE", "", "7.5 GB"])
    }

    private let app = makeApp("Xcode-27.0.app", version: "27.0", build: "27A266a")
    private let beta = makeApp("Xcode-27.1-beta1.app", version: "27.1", build: "27A5001a")
}
