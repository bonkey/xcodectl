//
// Copyright (c) 2026 Daniel Bauke
//

@testable import xcodectl
import Foundation
import Testing

struct InstalledTests {
    @Test func versionInNameReadsTheLeadingDigits() {
        #expect(Installed.versionInName(bundle("Xcode-27.0.0-release.candidate.app")) == "27.0.0")
        #expect(Installed.versionInName(bundle("Xcode-26.6.app")) == "26.6")
        #expect(Installed.versionInName(bundle("Xcode_27.0.0_Release_Candidate.app")) == "27.0.0")
        #expect(Installed.versionInName(bundle("Xcode.app")) == nil)
        #expect(Installed.versionInName(bundle("Xcode-beta.app")) == nil)
    }

    @Test func leftoverMatchesTheVersionInTheDirectoryName() {
        let candidates = [bundle("Xcode-27.0.0-release.candidate.app")]
        #expect(Installed.leftover(matching: "27", in: candidates) == candidates[0])
        #expect(Installed.leftover(matching: "27.0", in: candidates) == candidates[0])
        #expect(Installed.leftover(matching: "26", in: candidates) == nil)
    }

    /// "latest" and a build number say nothing about the name, so they never match a leftover.
    @Test func leftoverIgnoresQueriesWithoutVersionNumbers() {
        let candidates = [bundle("Xcode-27.0.0-release.candidate.app")]
        #expect(Installed.leftover(matching: "latest", in: candidates) == nil)
        #expect(Installed.leftover(matching: "27A266a", in: candidates) == nil)
    }

    /// Xcode hard-links thousands of files; the space they take counts once, the way `du` counts it.
    @Test func sizeCountsAHardLinkedFileOnce() throws {
        let app = FileManager.default.temporaryDirectory.appendingPathComponent("SizeTest-\(UUID().uuidString).app")
        try FileManager.default.createDirectory(
            at: app.appendingPathComponent("Contents"),
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: app) }
        let file = app.appendingPathComponent("Contents/tool")
        try Data(repeating: 1, count: 1_048_576).write(to: file)
        let single = Installed.size(of: app)
        try FileManager.default.linkItem(at: file, to: app.appendingPathComponent("Contents/tool-link"))

        #expect(single >= 1_048_576)
        #expect(Installed.size(of: app) == single)
    }

    private func bundle(_ name: String) -> URL {
        URL(fileURLWithPath: "/Applications").appendingPathComponent(name)
    }
}
