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
        #expect(install.select == true)
    }

    /// No runtime to install, so nothing needs the Xcode approved.
    @Test func `install with no runtimes takes --no-approve`() throws {
        let install = try #require(
            XcodeCtl.parseAsRoot(["install", "27.1", "--runtimes", "none", "--no-approve"]) as? Install)
        #expect(install.runtimeSelection?.platforms == [])
        #expect(throws: Error.self) {
            try XcodeCtl.parseAsRoot(["install", "27.1", "--runtimes", "ios", "--no-approve"])
        }
    }

    @Test func `remove Xcode keeping runtimes`() throws {
        let remove = try #require(XcodeCtl.parseAsRoot(["remove", "27.1", "--keep-runtimes"]) as? Remove)
        #expect(remove.version == "27.1")
        #expect(remove.keepRuntimes == true)
    }

    @Test func `upgrade takes one version, scope and beta flags`() throws {
        let all = try #require(XcodeCtl.parseAsRoot(["upgrade", "--beta", "--dry-run"]) as? Upgrade)
        #expect(all.version == nil)
        #expect(all.beta == true)
        #expect(all.dryRun)
        #expect(all.minor == nil)
        #expect(all.keep == nil)
        let one = try #require(XcodeCtl.parseAsRoot(["upgrade", "27", "--minor", "--keep"]) as? Upgrade)
        #expect(one.version == "27")
        #expect(one.minor == true)
        #expect(one.keep == true)
    }

    @Test func `list Xcodes by regex`() throws {
        let list = try #require(XcodeCtl.parseAsRoot(["list", "26\\.[45]", "--beta"]) as? List)
        #expect(list.pattern == "26\\.[45]")
        #expect(list.beta == true)
    }

    @Test func `installed without sizes`() throws {
        let installed = try #require(XcodeCtl.parseAsRoot(["installed", "--no-size"]) as? ListInstalled)
        #expect(installed.size == false)
    }

    @Test func `every flag has its inverse`() throws {
        let install = try #require(
            XcodeCtl.parseAsRoot(["install", "27", "--approve", "--clt", "--no-select"]) as? Install)
        #expect(install.approve == true)
        #expect(install.clt == true)
        #expect(install.select == false)
        #expect(install.autologin == nil)
        let installed = try #require(XcodeCtl.parseAsRoot(["installed", "--size", "--no-json"]) as? ListInstalled)
        #expect(installed.size == true)
        #expect(installed.json == false)
        let upgrade = try #require(XcodeCtl.parseAsRoot(["upgrade", "--no-keep"]) as? Upgrade)
        #expect(upgrade.keep == false)
        let remove = try #require(XcodeCtl.parseAsRoot(["remove", "27", "--no-keep-runtimes"]) as? Remove)
        #expect(remove.keepRuntimes == false)
        let notes = try #require(XcodeCtl.parseAsRoot(["release-notes", "27", "--no-plain"]) as? ReleaseNotesCommand)
        #expect(notes.plain == false)
    }

    @Test func `upgrade forwards only the flags turned off`() throws {
        let plain = try #require(XcodeCtl.parseAsRoot(["upgrade"]) as? Upgrade)
        #expect(plain.installArguments(["27A1"], select: true) == ["27A1", "--select"])
        let off = try #require(
            XcodeCtl.parseAsRoot(["upgrade", "--no-approve", "--no-clt", "--no-login"]) as? Upgrade)
        #expect(off.installArguments(["27A1"], select: false) == ["27A1", "--no-approve", "--no-clt", "--no-login"])
    }

    @Test func `upgrade forwards the runtimes to install`() throws {
        let plain = try #require(XcodeCtl.parseAsRoot(["upgrade"]) as? Upgrade)
        let ios = RuntimeSelection(argument: "ios,watchos")
        #expect(plain.installArguments(["27A1"], select: false, runtimes: ios) == ["27A1", "--runtimes", "ios,watchos"])
        #expect(plain.installArguments(["27A1"], select: false, runtimes: RuntimeSelection(argument: "all"))
            == ["27A1", "--runtimes", "all"])
    }

    /// iOS twice and tvOS, one of the iOS ones and watchOS not ready.
    @Test func `upgrade defaults to the platforms that have a ready runtime`() throws {
        let registered = try SimCtl.parse(makeSimctlOutput([
            ("A", "com.apple.platform.iphonesimulator", "27.0", "24A434", "Ready", 1, "/a.asset/AssetData"),
            ("B", "com.apple.platform.iphonesimulator", "27.1", "24A94401", "Unusable", 1, "/b.asset/AssetData"),
            ("C", "com.apple.platform.appletvsimulator", "27.0", "24J360", "Ready", 1, "/c.asset/AssetData"),
            ("D", "com.apple.platform.watchsimulator", "27.0", "24R360", "Unusable", 1, "/d.asset/AssetData"),
        ]))
        let plain = try #require(XcodeCtl.parseAsRoot(["upgrade"]) as? Upgrade)
        #expect(plain.newRuntimes(registered: registered)?.platforms == [.ios, .tvos])
        #expect(plain.newRuntimes(registered: []) == nil)
        let unapproved = try #require(XcodeCtl.parseAsRoot(["upgrade", "--no-approve"]) as? Upgrade)
        #expect(unapproved.newRuntimes(registered: registered) == nil)
        let named = try #require(XcodeCtl.parseAsRoot(["upgrade", "--runtimes", "visionos"]) as? Upgrade)
        #expect(named.newRuntimes(registered: registered)?.platforms == [.visionos])
        let none = try #require(XcodeCtl.parseAsRoot(["upgrade", "--runtimes", "none"]) as? Upgrade)
        #expect(none.newRuntimes(registered: registered) == nil)
    }

    @Test func `upgrade replaces runtimes on request`() throws {
        #expect(try (XcodeCtl.parseAsRoot(["upgrade"]) as? Upgrade)?.replaceRuntimes == nil)
        #expect(try (XcodeCtl.parseAsRoot(["upgrade", "--replace-runtimes"]) as? Upgrade)?.replaceRuntimes == true)
        #expect(try (XcodeCtl.parseAsRoot(["upgrade", "--no-replace-runtimes"]) as? Upgrade)?.replaceRuntimes == false)
        #expect(throws: Error.self) { try XcodeCtl.parseAsRoot(["upgrade", "--replace-runtimes", "--no-approve"]) }
    }

    @Test func `upgrade runtimes need an approved Xcode`() {
        #expect(throws: Error.self) { try XcodeCtl.parseAsRoot(["upgrade", "--runtimes", "ios", "--no-approve"]) }
        #expect(throws: Never.self) { try XcodeCtl.parseAsRoot(["upgrade", "--runtimes", "none", "--no-approve"]) }
    }

    @Test func `the information commands take JSON`() throws {
        #expect(try (XcodeCtl.parseAsRoot(["list", "--json"]) as? List)?.json == true)
        #expect(try (XcodeCtl.parseAsRoot(["installed", "--no-size", "--json"]) as? ListInstalled)?.json == true)
        #expect(try (XcodeCtl.parseAsRoot(["runtime", "list", "ios", "--all", "--json"]) as? RuntimeCommand.List)?
            .json == true)
        #expect(try (XcodeCtl.parseAsRoot(["runtime", "installed", "--json"]) as? RuntimeCommand.ListInstalled)?
            .json == true)
        #expect(try (XcodeCtl.parseAsRoot(["auth", "status", "--json"]) as? AuthCommand.Status)?.json == true)
    }

    // MARK: - Runtimes

    @Test func `runtimes is another name for runtime`() throws {
        let list = try #require(XcodeCtl.parseAsRoot(["runtimes", "list", "tvos"]) as? RuntimeCommand.List)
        #expect(list.platform == .tvos)
    }

    @Test func `runtime list`() throws {
        let ios = try #require(
            XcodeCtl.parseAsRoot(["runtime", "list", "IOS", "--all", "--beta"]) as? RuntimeCommand.List)
        #expect(ios.platform == .ios)
        #expect(ios.all == true)
        #expect(ios.beta == true)
        let every = try #require(XcodeCtl.parseAsRoot(["runtime", "list"]) as? RuntimeCommand.List)
        #expect(every.platform == nil)
    }

    @Test func `runtime installed`() throws {
        let every = try #require(XcodeCtl.parseAsRoot(["runtime", "installed"]) as? RuntimeCommand.ListInstalled)
        #expect(every.platform == nil)
        let tvos = try #require(XcodeCtl.parseAsRoot(["runtime", "installed", "tvos"]) as? RuntimeCommand.ListInstalled)
        #expect(tvos.platform == .tvos)
    }

    @Test func `runtime install`() throws {
        let install = try #require(
            XcodeCtl.parseAsRoot(["runtime", "install", "ios", "26.0", "--xcode", "27"]) as? RuntimeCommand.Install)
        #expect(install.platform == .ios)
        #expect(install.version == "26.0")
        #expect(install.xcode == "27")
        let tvos = try #require(XcodeCtl.parseAsRoot(["runtime", "install", "tvos"]) as? RuntimeCommand.Install)
        #expect(tvos.version == nil)
        let older = try #require(
            XcodeCtl.parseAsRoot(["runtime", "install", "ios", "17", "--no-login"]) as? RuntimeCommand.Install)
        #expect(older.autologin == false)
    }

    @Test func `runtime remove`() throws {
        let remove = try #require(
            XcodeCtl.parseAsRoot(["runtime", "remove", "ios", "26.0"]) as? RuntimeCommand.Remove)
        #expect(remove.platform == .ios)
        #expect(remove.version == "26.0")
        let ios = try #require(XcodeCtl.parseAsRoot(["runtime", "remove", "ios"]) as? RuntimeCommand.Remove)
        #expect(ios.version == nil)
        let any = try #require(XcodeCtl.parseAsRoot(["runtime", "remove"]) as? RuntimeCommand.Remove)
        #expect(any.platform == nil)
    }

    @Test func `runtime prune`() throws {
        let leftovers = try #require(
            XcodeCtl.parseAsRoot(["runtime", "prune", "--dry-run"]) as? RuntimeCommand.Prune)
        #expect(leftovers.dryRun)
        #expect(leftovers.unused == nil)
        let unused = try #require(XcodeCtl.parseAsRoot(["runtime", "prune", "--unused"]) as? RuntimeCommand.Prune)
        #expect(unused.unused == true)
        #expect(!unused.dryRun)
    }

    @Test func `Xcode commands take no runtime forms`() {
        let rejected = [
            ["list", "ios", "--all"],
            ["installed", "runtimes"],
            ["installed", "ios"],
            ["install", "27.1", "--xcode", "27"],
            ["remove", "ios", "26.0"],
            ["prune"],
        ]
        for arguments in rejected {
            #expect(throws: Error.self, "\(arguments)") { try XcodeCtl.parseAsRoot(arguments) }
        }
    }

    @Test func `runtime commands take no Xcode options`() {
        let rejected = [
            ["runtime", "install", "ios", "--select"],
            ["runtime", "install", "ios", "--no-approve"],
            ["runtime", "install", "ios", "--no-clt"],
            ["runtime", "install", "ios", "--runtimes", "all"],
            ["runtime", "list", "--by-date"],
            ["runtime", "installed", "--no-size"],
            ["runtime", "remove", "ios", "--keep-runtimes"],
        ]
        for arguments in rejected {
            #expect(throws: Error.self, "\(arguments)") { try XcodeCtl.parseAsRoot(arguments) }
        }
    }

    @Test func `malformed runtime commands are rejected`() {
        let rejected = [
            ["runtime", "install"],
            ["runtime", "install", "ios", "26", "27"],
            ["runtime", "install", "runtimes"],
            ["runtime", "remove", "26.0"],
            ["runtime", "list", "27"],
        ]
        for arguments in rejected {
            #expect(throws: Error.self, "\(arguments)") { try XcodeCtl.parseAsRoot(arguments) }
        }
    }

    @Test func `the old command names are gone`() {
        #expect(throws: Error.self) { try XcodeCtl.parseAsRoot(["list-installed"]) }
        #expect(throws: Error.self) { try XcodeCtl.parseAsRoot(["update"]) }
        #expect(throws: Error.self) { try XcodeCtl.parseAsRoot(["runtime", "list-installed"]) }
    }
}
