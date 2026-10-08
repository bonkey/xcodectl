//
// Copyright (c) 2026 Daniel Bauke
//

@testable import xcodectl
import XCTest

final class CommandGrammarTests: XCTestCase {
    func testInstallTakesSeveralXcodes() throws {
        let install = try XCTUnwrap(XcodeCtl.parseAsRoot(["install", "27.1", "26.4"]) as? Install)
        XCTAssertEqual(install.versions, ["27.1", "26.4"])
    }

    func testInstallXcodeWithRuntimesAndSelect() throws {
        let install = try XCTUnwrap(
            XcodeCtl.parseAsRoot(["install", "27.1", "--runtimes", "ios", "--select"]) as? Install)
        XCTAssertEqual(install.versions, ["27.1"])
        XCTAssertEqual(install.runtimeSelection?.platforms, [.ios])
        XCTAssertTrue(install.select)
    }

    func testRemoveXcodeKeepingRuntimes() throws {
        let remove = try XCTUnwrap(XcodeCtl.parseAsRoot(["remove", "27.1", "--keep-runtimes"]) as? Remove)
        XCTAssertEqual(remove.version, "27.1")
        XCTAssertTrue(remove.keepRuntimes)
    }

    func testListXcodesByRegex() throws {
        let list = try XCTUnwrap(XcodeCtl.parseAsRoot(["list", "26\\.[45]", "--beta"]) as? List)
        XCTAssertEqual(list.pattern, "26\\.[45]")
        XCTAssertTrue(list.beta)
    }

    func testListInstalledWithoutSizes() throws {
        let installed = try XCTUnwrap(XcodeCtl.parseAsRoot(["list-installed", "--no-size"]) as? ListInstalled)
        XCTAssertTrue(installed.noSize)
    }
}
