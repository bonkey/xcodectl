//
// Copyright (c) 2026 Daniel Bauke
//

@testable import xcodectl
import Foundation
import Testing

struct ConfigTests {
    // MARK: - TOML

    @Test func `tables, shared keys, bools and strings`() throws {
        let config = try parse("""
        # a comment
        json = true   # trailing comment

        [install]
        approve = false
        runtimes = "ios,watchos"
        xcode = "say \\"27\\" \\\\ done # not a comment"

        [auth.status]
        login = false
        """)
        #expect(config.shared == ["json": .bool(true)])
        #expect(config.tables["install"] == [
            "approve": .bool(false),
            "runtimes": .string("ios,watchos"),
            "xcode": .string("say \"27\" \\ done # not a comment"),
        ])
        #expect(config.tables["auth.status"] == ["login": .bool(false)])
        #expect(config.value("json", in: "install") == .bool(true))
        #expect(config.value("approve", in: "install") == .bool(false))
        #expect(config.value("approve", in: "upgrade") == nil)
    }

    @Test func `malformed lines name the line`() {
        let rejected = [
            ("[install]\nbogus", "config.toml:2: expected key = value"),
            ("[install]\nclt = yes", "config.toml:2: a value is true, false or a \"quoted string\""),
            ("[install]\nxcode = \"open", "config.toml:2: unterminated string"),
            ("[install]\nxcode = \"a\" b", "config.toml:2: text after the closing quote"),
            ("[install]\nxcode = \"\\n\"", "config.toml:2: unsupported escape \\n"),
            ("\n[install]\n\n[install]", "config.toml:4: [install] appears twice"),
            ("json = true\njson = false", "config.toml:2: json appears twice"),
            ("[list]\njson = true\njson = false", "config.toml:3: json appears twice in [list]"),
            ("[in stall]", "config.toml:1: a table name holds letters, digits, - and _"),
            ("[install", "config.toml:1: a table header is [name]"),
            ("a key = true", "config.toml:1: a key holds letters, digits, - and _"),
        ]
        for (text, message) in rejected {
            #expect(throws: Fail(message), "\(text)") { try parse(text) }
        }
    }

    // MARK: - Schema

    @Test func `unknown tables, keys and wrong values are problems`() throws {
        let config = try parse("""
        bogus = true
        json = "yes"
        [update]
        keep = true
        [install]
        nope = true
        runtimes = "mars"
        clt = "no"
        [list]
        order = "newest"
        """)
        #expect(config.problems() == [
            "bogus: no command has this key",
            "json: expects true or false",
            "[install] clt: expects true or false",
            "[install] nope: unknown key",
            "[install] runtimes: \"mars\" is not one of all, none, ios, tvos, watchos, visionos",
            "[list] order: \"newest\" is not one of by-version, by-date",
            "[update]: no such command",
        ])
        #expect(try parse("[release-notes]\nmodel = \"m\"\n[install]\nruntimes = \"ios\"").problems().isEmpty)
    }

    /// The keys are a contract for config files; renaming or removing one is a breaking change.
    @Test func `the template is the contract`() {
        #expect(Config.template() == """
        # xcodectl defaults: one table per command, keys named like its flags without `--`.
        # A flag typed on the command line wins over its [command] table, which wins over the
        # shared keys above the first table. A value that does not fit the run, such as
        # `select = true` for `install 27 26`, is ignored. An unknown key or table fails every command.
        # Uncomment a line to set it. A flag shows its default, an option an example;
        # `xcodectl <command> --help` explains them. `xcodectl config check` reads the file back.

        # Shared by every command below that has the key.
        # approve = true
        # beta = false
        # clt = true
        # json = false
        # login = true
        # runtimes = "all"
        # stable = false

        [auth.status]
        # json = false
        # login = true

        [auth.export]
        # login = true
        # copy = false

        [auth.import]
        # paste = false
        # unlock-keychain = true

        [list]
        # stable = false
        # beta = false
        # json = false
        # order = "by-version"

        [installed]
        # size = true
        # json = false

        [release-notes]
        # markdown = false
        # plain = false
        # abridged = false
        # key-env = "OPENROUTER_API_KEY"
        # provider = "openai"
        # base-url = "http://localhost:11434/v1"
        # model = "gpt-5.6-luna"

        [install]
        # approve = true
        # select = false
        # clt = true
        # login = true
        # runtimes = "all"

        [upgrade]
        # minor = false
        # keep = false
        # beta = false
        # approve = true
        # clt = true
        # login = true
        # runtimes = "ios,watchos"
        # replace-runtimes = false

        [remove]
        # keep-runtimes = false

        [runtime.list]
        # stable = false
        # beta = false
        # all = false
        # json = false

        [runtime.installed]
        # json = false

        [runtime.install]
        # login = true

        [runtime.prune]
        # unused = false

        """)
    }

    @Test func `the template, uncommented, checks clean and sets every key`() throws {
        let uncommented = Config.template().split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in line.wholeMatch(of: #/# [a-z-]+ = .*/#) == nil ? String(line) : String(line.dropFirst(2)) }
            .joined(separator: "\n")
        let config = try parse(uncommented)
        #expect(config.problems().isEmpty)
        #expect(config.effectiveSettings().count == Config.schema.flatMap(\.keys).count)
        #expect(config.effectiveSettings().first == "auth.status.json = false")
    }

    @Test func `effective settings resolve the shared keys per command`() throws {
        let config = try parse("json = true\n[list]\njson = false\n[install]\nclt = false")
        #expect(config.effectiveSettings() == [
            "auth.status.json = true",
            "list.json = false",
            "installed.json = true",
            "install.clt = false",
            "runtime.list.json = true",
            "runtime.installed.json = true",
        ])
    }

    // MARK: - Merge

    @Test func `config fills in what was not typed and typed wins`() throws {
        let toml = "[install]\nclt = false\nruntimes = \"ios\"\n[installed]\nsize = false"
        let install: Install = try command(["install", "27"], toml)
        #expect(install.clt == false)
        #expect(install.approve == nil)
        #expect(install.runtimeSelection?.platforms == [.ios])
        let typed: Install = try command(["install", "27", "--clt", "--runtimes", "all"], toml)
        #expect(typed.clt == true)
        #expect(typed.runtimeSelection?.isAll == true)
        let installed: ListInstalled = try command(["installed"], toml)
        #expect(installed.size == false)
        let notes: ReleaseNotesCommand = try command(
            ["release-notes", "27"], "[release-notes]\nabridged = true\nprovider = \"openai\"\nmodel = \"m\"")
        #expect(notes.abridged == true)
        #expect(notes.provider == .openai)
        #expect(notes.model == "m")
        let list: List = try command(["list", "27"], "[list]\norder = \"by-date\"")
        #expect(list.order == .byDate)
    }

    @Test func `shared keys reach every command that has them and tables beat them`() throws {
        let toml = "json = true\nlogin = false\n[list]\njson = false"
        #expect(try command(["list", "27"], toml, as: List.self).json == false)
        #expect(try command(["installed"], toml, as: ListInstalled.self).json == true)
        #expect(try command(["auth", "status"], toml, as: AuthCommand.Status.self).json == true)
        #expect(try command(["auth", "status"], toml, as: AuthCommand.Status.self).login == false)
        #expect(try command(["auth", "export"], toml, as: AuthCommand.Export.self).login == false)
        #expect(try command(["install", "27"], toml, as: Install.self).autologin == false)
        #expect(try command(["upgrade"], toml, as: Upgrade.self).autologin == false)
        #expect(try command(["installed", "--no-json"], toml, as: ListInstalled.self).json == false)
    }

    @Test func `values that do not fit the invocation are dropped`() throws {
        #expect(try command(["install", "27", "26"], "[install]\nselect = true", as: Install.self).select == nil)
        #expect(try command(["install", "27", "--runtimes", "all"], "[install]\napprove = false", as: Install.self)
            .approve == nil)
        // Two config keys that exclude each other: the one listed first in the template wins.
        let conflicting: Install = try command(["install", "27"], "[install]\napprove = false\nruntimes = \"ios\"")
        #expect(conflicting.approve == false)
        #expect(conflicting.runtimeSelection == nil)
        #expect(try command(["list", "--beta"], "[list]\nstable = true", as: List.self).stable == nil)
        #expect(try command(
            ["release-notes", "27"],
            "[release-notes]\nprovider = \"openai\"",
            as: ReleaseNotesCommand.self)
            .provider == nil)
        #expect(try command(
            ["release-notes", "27", "--markdown"],
            "[release-notes]\nplain = true",
            as: ReleaseNotesCommand.self)
            .plain == nil)
    }

    @Test func `runtime commands read their own tables and the shared keys`() throws {
        let toml = "login = false\n[install]\nlogin = true\n[runtime.list]\nall = true\n[runtime.prune]\nunused = true"
        #expect(try command(["runtime", "install", "ios"], toml, as: RuntimeCommand.Install.self).autologin == false)
        #expect(try command(["runtime", "list"], toml, as: RuntimeCommand.List.self).all == true)
        #expect(try command(["runtime", "prune"], toml, as: RuntimeCommand.Prune.self).unused == true)
        #expect(try parse("[list]\nall = true").problems() == ["[list] all: unknown key"])
    }

    @Test func `upgrade reads its own table, not install's`() throws {
        #expect(try command(["upgrade"], "[install]\napprove = false", as: Upgrade.self).approve == nil)
        let upgrade: Upgrade = try command(["upgrade"], "[upgrade]\napprove = false\nlogin = false")
        #expect(upgrade.installArguments(["27A1"], select: false) == ["27A1", "--no-approve", "--no-login"])
    }

    @Test func `upgrade takes runtimes from its table, and only for an approved Xcode`() throws {
        #expect(try command(["upgrade"], "[upgrade]\nruntimes = \"none\"", as: Upgrade.self).runtimeSelection?
            .platforms == [])
        #expect(try command(["upgrade"], "runtimes = \"ios\"", as: Upgrade.self).runtimeSelection?.platforms == [.ios])
        let unapproved: Upgrade = try command(["upgrade", "--no-approve"], "[upgrade]\nruntimes = \"ios\"")
        #expect(unapproved.runtimeSelection == nil)
        #expect(try command(["upgrade"], "[upgrade]\nreplace-runtimes = true", as: Upgrade.self)
            .replaceRuntimes == true)
    }

    @Test func `an empty config changes nothing and a broken one fails the command`() throws {
        let install = try #require(XcodeCtl.parseConfigured(["install", "27"], config: Config()) as? Install)
        #expect(install.approve == nil)
        #expect(throws: Fail.self) {
            try XcodeCtl.parseConfigured(["list"], config: parse("[list]\nbogus = true\nnope = true"))
        }
        // Commands without settings, and `config` itself, never read the file.
        #expect(throws: Never.self) {
            try XcodeCtl.parseConfigured(["config", "check"], config: parse("[list]\nbogus = true"))
        }
    }

    private func parse(_ text: String) throws -> Config {
        try Config.parse(text, file: "config.toml")
    }

    private func command<T>(_ arguments: [String], _ toml: String, as _: T.Type = T.self) throws -> T {
        try #require(XcodeCtl.parseConfigured(arguments, config: parse(toml)) as? T)
    }
}
