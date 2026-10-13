//
// Copyright (c) 2026 Daniel Bauke
//

@testable import xcodectl
import Foundation
import Testing

struct CommandGrammarTests {
    @Test func installTakesSeveralXcodes() throws {
        let install = try #require(XcodeCtl.parseAsRoot(["install", "27.1", "26.4"]) as? Install)
        #expect(install.versions == ["27.1", "26.4"])
    }

    @Test func installXcodeWithRuntimesAndSelect() throws {
        let install = try #require(
            XcodeCtl.parseAsRoot(["install", "27.1", "--runtimes", "ios", "--select"]) as? Install)
        #expect(install.versions == ["27.1"])
        #expect(install.runtimeSelection?.platforms == [.ios])
        #expect(install.select)
    }

    @Test func removeXcodeKeepingRuntimes() throws {
        let remove = try #require(XcodeCtl.parseAsRoot(["remove", "27.1", "--keep-runtimes"]) as? Remove)
        #expect(remove.version == "27.1")
        #expect(remove.keepRuntimes)
    }

    @Test func listXcodesByRegex() throws {
        let list = try #require(XcodeCtl.parseAsRoot(["list", "26\\.[45]", "--beta"]) as? List)
        #expect(list.pattern == "26\\.[45]")
        #expect(list.beta)
    }

    @Test func installedWithoutSizes() throws {
        let installed = try #require(XcodeCtl.parseAsRoot(["installed", "--no-size"]) as? ListInstalled)
        #expect(installed.noSize)
        #expect(installed.runtimes == nil)
    }

    @Test func theInformationCommandsTakeJSON() throws {
        #expect(try (XcodeCtl.parseAsRoot(["list", "--json"]) as? List)?.json == true)
        #expect(try (XcodeCtl.parseAsRoot(["list", "ios", "--all", "--json"]) as? List)?.json == true)
        #expect(try (XcodeCtl.parseAsRoot(["installed", "--no-size", "--json"]) as? ListInstalled)?.json == true)
        #expect(try (XcodeCtl.parseAsRoot(["installed", "runtimes", "--json"]) as? ListInstalled)?.json == true)
        #expect(try (XcodeCtl.parseAsRoot(["auth", "status", "--json"]) as? AuthCommand.Status)?.json == true)
    }

    // MARK: - Runtimes

    @Test func runtimeWordsAreRecognized() {
        #expect(RuntimeTarget(argument: "ios")?.platform == .ios)
        #expect(RuntimeTarget(argument: "IOS")?.platform == .ios)
        #expect(RuntimeTarget(argument: "visionos")?.platform == .visionos)
        #expect(RuntimeTarget(argument: "runtimes") != nil)
        #expect(RuntimeTarget(argument: "runtimes")?.platform == nil)
    }

    @Test func xcodeVersionQueriesAreNotRuntimeWords() {
        for query in ["27.1", "27", "latest", "latest-beta", "27A266a", "27 rc", "27-rc1"] {
            #expect(RuntimeTarget(argument: query) == nil, "\(query)")
        }
    }

    @Test func installRuntime() throws {
        let install = try #require(XcodeCtl.parseAsRoot(["install", "ios", "26.0", "--xcode", "27"]) as? Install)
        #expect(install.versions == ["ios", "26.0"])
        #expect(install.xcode == "27")
        #expect(throws: Never.self) { try XcodeCtl.parseAsRoot(["install", "tvos"]) }
        let older = try #require(XcodeCtl.parseAsRoot(["install", "ios", "17", "--no-autologin"]) as? Install)
        #expect(!older.autologin)
    }

    @Test func listRuntimes() throws {
        let list = try #require(XcodeCtl.parseAsRoot(["list", "ios", "--all"]) as? List)
        #expect(list.pattern == "ios")
        #expect(list.all)
        #expect(throws: Never.self) { try XcodeCtl.parseAsRoot(["list", "runtimes", "--beta"]) }
    }

    @Test func installedRuntimes() throws {
        let installed = try #require(XcodeCtl.parseAsRoot(["installed", "runtimes"]) as? ListInstalled)
        #expect(installed.runtimes != nil)
        #expect(installed.runtimes?.platform == nil)
        let tvos = try #require(XcodeCtl.parseAsRoot(["installed", "tvos"]) as? ListInstalled)
        #expect(tvos.runtimes?.platform == .tvos)
    }

    @Test func removeRuntime() throws {
        let remove = try #require(XcodeCtl.parseAsRoot(["remove", "ios", "26.0"]) as? Remove)
        #expect(remove.version == "ios")
        #expect(remove.runtimeVersion == "26.0")
        #expect(throws: Never.self) { try XcodeCtl.parseAsRoot(["remove", "ios"]) }
        #expect(throws: Never.self) { try XcodeCtl.parseAsRoot(["remove", "runtimes"]) }
    }

    @Test func prune() throws {
        let prune = try #require(XcodeCtl.parseAsRoot(["prune", "--dry-run"]) as? Prune)
        #expect(prune.dryRun)
    }

    @Test func optionsOfTheOtherKindAreRejected() {
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
            #expect(throws: Error.self, "\(arguments)") { try XcodeCtl.parseAsRoot(arguments) }
        }
    }

    @Test func malformedRuntimeTargetsAreRejected() {
        let rejected = [
            ["install", "ios", "26", "27"],
            ["install", "runtimes"],
            ["installed", "27.1"],
            ["remove", "27.1", "26.0"],
            ["remove", "runtimes", "26.0"],
        ]
        for arguments in rejected {
            #expect(throws: Error.self, "\(arguments)") { try XcodeCtl.parseAsRoot(arguments) }
        }
    }

    @Test func theOldCommandNamesAreGone() {
        #expect(throws: Error.self) { try XcodeCtl.parseAsRoot(["list-installed"]) }
        #expect(throws: Error.self) { try XcodeCtl.parseAsRoot(["runtime", "list"]) }
        #expect(throws: Error.self) { try XcodeCtl.parseAsRoot(["runtime", "install", "ios"]) }
        #expect(throws: Error.self) { try XcodeCtl.parseAsRoot(["runtime", "prune"]) }
    }
}
