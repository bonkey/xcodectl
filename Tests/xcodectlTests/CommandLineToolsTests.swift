//
// Copyright (c) 2026 Daniel Bauke
//

@testable import xcodectl
import XCTest

final class CommandLineToolsTests: XCTestCase {
    func testVersionIsTheReleaseMajorMinor() {
        XCTAssertEqual(Installer.commandLineToolsVersion(for: makeRelease("26.6", "17G1", (2026, 6, 1))), "26.6")
        XCTAssertEqual(Installer.commandLineToolsVersion(for: makeRelease("27", "27A266a", (2026, 9, 1))), "27.0")
        XCTAssertEqual(Installer.commandLineToolsVersion(for: makeRelease("26.0.1", "17A400", (2025, 10, 1))), "26.0")
    }

    func testUpgradesWhenNothingIsInstalled() {
        XCTAssertTrue(Installer.isCommandLineToolsUpgrade(installed: nil, wanted: "26.1"))
    }

    func testUpgradesToANewerVersion() {
        XCTAssertTrue(Installer.isCommandLineToolsUpgrade(installed: "26.1", wanted: "26.2"))
        XCTAssertTrue(Installer.isCommandLineToolsUpgrade(installed: "26.6", wanted: "27.0"))
        XCTAssertTrue(Installer.isCommandLineToolsUpgrade(installed: "16.4", wanted: "26.0"))
    }

    /// Installing an older Xcode side by side must leave newer Command Line Tools alone.
    func testNeverDowngradesOrReinstalls() {
        XCTAssertFalse(Installer.isCommandLineToolsUpgrade(installed: "26.2", wanted: "26.2"))
        XCTAssertFalse(Installer.isCommandLineToolsUpgrade(installed: "26.2", wanted: "16.4"))
        XCTAssertFalse(Installer.isCommandLineToolsUpgrade(installed: "26.10", wanted: "26.9"))
    }
}
