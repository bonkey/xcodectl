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

    private func bundle(_ name: String) -> URL {
        URL(fileURLWithPath: "/Applications").appendingPathComponent(name)
    }
}
