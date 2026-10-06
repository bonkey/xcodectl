//
// Copyright (c) 2026 Daniel Bauke
//

@testable import xcodectl
import Foundation
import XCTest

final class InstalledTests: XCTestCase {
    func testVersionInNameReadsTheLeadingDigits() {
        XCTAssertEqual(Installed.versionInName(bundle("Xcode-27.0.0-release.candidate.app")), "27.0.0")
        XCTAssertEqual(Installed.versionInName(bundle("Xcode-26.6.app")), "26.6")
        XCTAssertEqual(Installed.versionInName(bundle("Xcode_27.0.0_Release_Candidate.app")), "27.0.0")
        XCTAssertNil(Installed.versionInName(bundle("Xcode.app")))
        XCTAssertNil(Installed.versionInName(bundle("Xcode-beta.app")))
    }

    func testLeftoverMatchesTheVersionInTheDirectoryName() {
        let candidates = [bundle("Xcode-27.0.0-release.candidate.app")]
        XCTAssertEqual(Installed.leftover(matching: "27", in: candidates), candidates[0])
        XCTAssertEqual(Installed.leftover(matching: "27.0", in: candidates), candidates[0])
        XCTAssertNil(Installed.leftover(matching: "26", in: candidates))
    }

    /// "latest" and a build number say nothing about the name, so they never match a leftover.
    func testLeftoverIgnoresQueriesWithoutVersionNumbers() {
        let candidates = [bundle("Xcode-27.0.0-release.candidate.app")]
        XCTAssertNil(Installed.leftover(matching: "latest", in: candidates))
        XCTAssertNil(Installed.leftover(matching: "27A266a", in: candidates))
    }

    /// Xcode hard-links thousands of files; the space they take counts once, the way `du` counts it.
    func testSizeCountsAHardLinkedFileOnce() throws {
        let app = FileManager.default.temporaryDirectory.appendingPathComponent("SizeTest-\(UUID().uuidString).app")
        try FileManager.default.createDirectory(
            at: app.appendingPathComponent("Contents"),
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: app) }
        let file = app.appendingPathComponent("Contents/tool")
        try Data(repeating: 1, count: 1_048_576).write(to: file)
        let single = Installed.size(of: app)
        try FileManager.default.linkItem(at: file, to: app.appendingPathComponent("Contents/tool-link"))

        XCTAssertGreaterThanOrEqual(single, 1_048_576)
        XCTAssertEqual(Installed.size(of: app), single)
    }

    private func bundle(_ name: String) -> URL {
        URL(fileURLWithPath: "/Applications").appendingPathComponent(name)
    }
}
