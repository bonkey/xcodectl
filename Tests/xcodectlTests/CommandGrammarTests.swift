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

    func testInstalledWithoutSizes() throws {
        let installed = try XCTUnwrap(XcodeCtl.parseAsRoot(["installed", "--no-size"]) as? ListInstalled)
        XCTAssertTrue(installed.noSize)
        XCTAssertNil(installed.runtimes)
    }

    // MARK: - Runtimes

    func testRuntimeWordsAreRecognized() {
        XCTAssertEqual(RuntimeTarget(argument: "ios")?.platform, .ios)
        XCTAssertEqual(RuntimeTarget(argument: "IOS")?.platform, .ios)
        XCTAssertEqual(RuntimeTarget(argument: "visionos")?.platform, .visionos)
        XCTAssertNotNil(RuntimeTarget(argument: "runtimes"))
        XCTAssertNil(RuntimeTarget(argument: "runtimes")?.platform)
    }

    func testXcodeVersionQueriesAreNotRuntimeWords() {
        for query in ["27.1", "27", "latest", "latest-beta", "27A266a", "27 rc", "27-rc1"] {
            XCTAssertNil(RuntimeTarget(argument: query), query)
        }
    }

    func testInstallRuntime() throws {
        let install = try XCTUnwrap(XcodeCtl.parseAsRoot(["install", "ios", "26.0", "--xcode", "27"]) as? Install)
        XCTAssertEqual(install.versions, ["ios", "26.0"])
        XCTAssertEqual(install.xcode, "27")
        XCTAssertNoThrow(try XcodeCtl.parseAsRoot(["install", "tvos"]))
        let older = try XCTUnwrap(XcodeCtl.parseAsRoot(["install", "ios", "17", "--no-autologin"]) as? Install)
        XCTAssertFalse(older.autologin)
    }

    func testListRuntimes() throws {
        let list = try XCTUnwrap(XcodeCtl.parseAsRoot(["list", "ios", "--all"]) as? List)
        XCTAssertEqual(list.pattern, "ios")
        XCTAssertTrue(list.all)
        XCTAssertNoThrow(try XcodeCtl.parseAsRoot(["list", "runtimes", "--beta"]))
    }

    func testInstalledRuntimes() throws {
        let installed = try XCTUnwrap(XcodeCtl.parseAsRoot(["installed", "runtimes"]) as? ListInstalled)
        XCTAssertNotNil(installed.runtimes)
        XCTAssertNil(installed.runtimes?.platform)
        let tvos = try XCTUnwrap(XcodeCtl.parseAsRoot(["installed", "tvos"]) as? ListInstalled)
        XCTAssertEqual(tvos.runtimes?.platform, .tvos)
    }

    func testRemoveRuntime() throws {
        let remove = try XCTUnwrap(XcodeCtl.parseAsRoot(["remove", "ios", "26.0"]) as? Remove)
        XCTAssertEqual(remove.version, "ios")
        XCTAssertEqual(remove.runtimeVersion, "26.0")
        XCTAssertNoThrow(try XcodeCtl.parseAsRoot(["remove", "ios"]))
        XCTAssertNoThrow(try XcodeCtl.parseAsRoot(["remove", "runtimes"]))
    }

    func testPrune() throws {
        let prune = try XCTUnwrap(XcodeCtl.parseAsRoot(["prune", "--dry-run"]) as? Prune)
        XCTAssertTrue(prune.dryRun)
    }

    func testOptionsOfTheOtherKindAreRejected() {
        let rejected = [
            ["install", "ios", "--select"],
            ["install", "ios", "--no-approve"],
            ["install", "ios", "--no-clt"],
            ["install", "ios", "--runtimes", "all"],
            ["install", "27.1", "--xcode", "27"],
            ["list", "--all"],
            ["list", "27", "--all"],
            ["installed", "ios", "--no-size"],
            ["remove", "ios", "--keep-runtimes"],
        ]
        for arguments in rejected {
            XCTAssertThrowsError(try XcodeCtl.parseAsRoot(arguments), "\(arguments)")
        }
    }

    func testMalformedRuntimeTargetsAreRejected() {
        let rejected = [
            ["install", "ios", "26", "27"],
            ["install", "runtimes"],
            ["installed", "27.1"],
            ["remove", "27.1", "26.0"],
            ["remove", "runtimes", "26.0"],
        ]
        for arguments in rejected {
            XCTAssertThrowsError(try XcodeCtl.parseAsRoot(arguments), "\(arguments)")
        }
    }

    func testTheOldCommandNamesAreGone() {
        XCTAssertThrowsError(try XcodeCtl.parseAsRoot(["list-installed"]))
        XCTAssertThrowsError(try XcodeCtl.parseAsRoot(["runtime", "list"]))
        XCTAssertThrowsError(try XcodeCtl.parseAsRoot(["runtime", "install", "ios"]))
        XCTAssertThrowsError(try XcodeCtl.parseAsRoot(["runtime", "prune"]))
    }
}
