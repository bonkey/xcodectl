//
// Copyright (c) 2026 Daniel Bauke
//

@testable import xcodectl
import XCTest

final class InstalledRowsTests: XCTestCase {
    func testAnXcodeRowCarriesItsSizeAndPath() {
        let rows = installedRows([(app, 3_583_873_024, [])], active: nil)
        XCTAssertEqual(rows, [
            ["VERSION", "BUILD", "SIZE", "PATH", ""],
            ["27.0", "27A266a", "3.3 GB", "/Applications/Xcode-27.0.app", ""],
        ])
    }

    func testTheActiveXcodeIsMarkedActive() {
        let rows = installedRows([(app, 0, []), (beta, 0, [])], active: beta.path.path)
        XCTAssertEqual(rows.map(\.last), ["", "", "* active"])
    }

    func testRuntimesFollowTheXcodeThatUsesThem() throws {
        let runtimes = try SimCtl.parse(makeSimctlOutput([
            ("A", "com.apple.platform.iphonesimulator", "27.0", "24A434", "Ready", 8_067_000_161, "/a.asset/AssetData"),
        ]))
        let rows = installedRows([(app, 0, runtimes), (beta, 0, [])], active: nil)
        XCTAssertEqual(rows.map(\.first), ["VERSION", "27.0", "  iOS 27.0", "27.1"])
        XCTAssertEqual(rows[2], ["  iOS 27.0", "24A434", "7.5 GB", "", ""])
    }

    private let app = makeApp("Xcode-27.0.app", version: "27.0", build: "27A266a")
    private let beta = makeApp("Xcode-27.1-beta1.app", version: "27.1", build: "27A5001a")
}
