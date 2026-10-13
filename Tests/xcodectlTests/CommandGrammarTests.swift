//
// Copyright (c) 2026 Daniel Bauke
//

@testable import xcodectl
import Foundation
import Testing

struct CommandGrammarTests {
    @Test func `install takes several Xcodes`() throws {
        let install = try #require(XcodeCtl.parseAsRoot(["install", "27.1", "26.4"]) as? Install)
        #expect(install.versions == ["27.1", "26.4"])
    }

    @Test func `install Xcode with runtimes and select`() throws {
        let install = try #require(
            XcodeCtl.parseAsRoot(["install", "27.1", "--runtimes", "ios", "--select"]) as? Install)
        #expect(install.versions == ["27.1"])
        #expect(install.runtimeSelection?.platforms == [.ios])
        #expect(install.select)
    }

    @Test func `remove Xcode keeping runtimes`() throws {
        let remove = try #require(XcodeCtl.parseAsRoot(["remove", "27.1", "--keep-runtimes"]) as? Remove)
        #expect(remove.version == "27.1")
        #expect(remove.keepRuntimes)
    }

    @Test func `list Xcodes by regex`() throws {
        let list = try #require(XcodeCtl.parseAsRoot(["list", "26\\.[45]", "--beta"]) as? List)
        #expect(list.pattern == "26\\.[45]")
        #expect(list.beta)
    }

    @Test func `installed without sizes`() throws {
        let installed = try #require(XcodeCtl.parseAsRoot(["installed", "--no-size"]) as? ListInstalled)
        #expect(installed.noSize)
        #expect(installed.runtimes == nil)
    }

    @Test func `the information commands take JSON`() throws {
        #expect(try (XcodeCtl.parseAsRoot(["list", "--json"]) as? List)?.json == true)
        #expect(try (XcodeCtl.parseAsRoot(["list", "ios", "--all", "--json"]) as? List)?.json == true)
        #expect(try (XcodeCtl.parseAsRoot(["installed", "--no-size", "--json"]) as? ListInstalled)?.json == true)
        #expect(try (XcodeCtl.parseAsRoot(["installed", "runtimes", "--json"]) as? ListInstalled)?.json == true)
        #expect(try (XcodeCtl.parseAsRoot(["auth", "status", "--json"]) as? AuthCommand.Status)?.json == true)
    }

    // MARK: - Runtimes

    @Test func `runtime words are recognized`() {
        #expect(RuntimeTarget(argument: "ios")?.platform == .ios)
        #expect(RuntimeTarget(argument: "IOS")?.platform == .ios)
        #expect(RuntimeTarget(argument: "visionos")?.platform == .visionos)
        #expect(RuntimeTarget(argument: "runtimes") != nil)
        #expect(RuntimeTarget(argument: "runtimes")?.platform == nil)
    }

    @Test func `Xcode version queries are not runtime words`() {
        for query in ["27.1", "27", "latest", "latest-beta", "27A266a", "27 rc", "27-rc1"] {
            #expect(RuntimeTarget(argument: query) == nil, "\(query)")
        }
    }

    @Test func `install runtime`() throws {
        let install = try #require(XcodeCtl.parseAsRoot(["install", "ios", "26.0", "--xcode", "27"]) as? Install)
        #expect(install.versions == ["ios", "26.0"])
        #expect(install.xcode == "27")
        #expect(throws: Never.self) { try XcodeCtl.parseAsRoot(["install", "tvos"]) }
        let older = try #require(XcodeCtl.parseAsRoot(["install", "ios", "17", "--no-autologin"]) as? Install)
        #expect(!older.autologin)
    }

    @Test func `list runtimes`() throws {
        let list = try #require(XcodeCtl.parseAsRoot(["list", "ios", "--all"]) as? List)
        #expect(list.pattern == "ios")
        #expect(list.all)
        #expect(throws: Never.self) { try XcodeCtl.parseAsRoot(["list", "runtimes", "--beta"]) }
    }

    @Test func `installed runtimes`() throws {
        let installed = try #require(XcodeCtl.parseAsRoot(["installed", "runtimes"]) as? ListInstalled)
        #expect(installed.runtimes != nil)
        #expect(installed.runtimes?.platform == nil)
        let tvos = try #require(XcodeCtl.parseAsRoot(["installed", "tvos"]) as? ListInstalled)
        #expect(tvos.runtimes?.platform == .tvos)
    }

    @Test func `remove runtime`() throws {
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

    @Test func `options of the other kind are rejected`() {
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

    @Test func `malformed runtime targets are rejected`() {
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

    @Test func `the old command names are gone`() {
        #expect(throws: Error.self) { try XcodeCtl.parseAsRoot(["list-installed"]) }
        #expect(throws: Error.self) { try XcodeCtl.parseAsRoot(["runtime", "list"]) }
        #expect(throws: Error.self) { try XcodeCtl.parseAsRoot(["runtime", "install", "ios"]) }
        #expect(throws: Error.self) { try XcodeCtl.parseAsRoot(["runtime", "prune"]) }
    }
}
