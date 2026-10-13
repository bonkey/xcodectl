//
// Copyright (c) 2026 Daniel Bauke
//

@testable import xcodectl
import Foundation
import Testing

struct CommandLineToolsTests {
    @Test func `version is the release major minor`() {
        #expect(Installer.commandLineToolsVersion(for: makeRelease("26.6", "17G1", (2026, 6, 1))) == "26.6")
        #expect(Installer.commandLineToolsVersion(for: makeRelease("27", "27A266a", (2026, 9, 1))) == "27.0")
        #expect(Installer.commandLineToolsVersion(for: makeRelease("26.0.1", "17A400", (2025, 10, 1))) == "26.0")
    }

    @Test func `upgrades when nothing is installed`() {
        #expect(Installer.isCommandLineToolsUpgrade(installed: nil, wanted: "26.1"))
    }

    @Test func `upgrades to a newer version`() {
        #expect(Installer.isCommandLineToolsUpgrade(installed: "26.1", wanted: "26.2"))
        #expect(Installer.isCommandLineToolsUpgrade(installed: "26.6", wanted: "27.0"))
        #expect(Installer.isCommandLineToolsUpgrade(installed: "16.4", wanted: "26.0"))
    }

    /// Installing an older Xcode side by side must leave newer Command Line Tools alone.
    @Test func `never downgrades or reinstalls`() {
        #expect(!Installer.isCommandLineToolsUpgrade(installed: "26.2", wanted: "26.2"))
        #expect(!Installer.isCommandLineToolsUpgrade(installed: "26.2", wanted: "16.4"))
        #expect(!Installer.isCommandLineToolsUpgrade(installed: "26.10", wanted: "26.9"))
    }
}
