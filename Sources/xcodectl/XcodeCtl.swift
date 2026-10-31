//
// Copyright (c) 2026 Daniel Bauke
//

import ArgumentParser
import Foundation
import Noora

// MARK: - XcodeCtl

struct XcodeCtl: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "xcodectl",
        abstract: "Install, approve, switch and remove Xcode versions and their simulator runtimes.",
        discussion: "If you are an agent, run `xcodectl reference` for the help of every command.",
        version: version,
        subcommands: [
            AuthCommand.self,
            List.self,
            ListInstalled.self,
            ReleaseNotesCommand.self,
            Install.self,
            Upgrade.self,
            InstallClt.self,
            Approve.self,
            Select.self,
            Remove.self,
            RuntimeCommand.self,
            ConfigCommand.self,
            Reference.self,
        ])
}

let ui = Noora()
/// Noora on stderr, for commands whose stdout is data (a session blob, JSON).
let stderrUI = Noora(
    standardPipelines: StandardPipelines(output: StandardErrorPipeline(), error: StandardErrorPipeline()))

// MARK: - Choice

struct Choice<Value>: CustomStringConvertible, Equatable {
    let description: String
    let value: Value

    static func == (a: Choice, b: Choice) -> Bool {
        a.description == b.description
    }
}

func pick<Value>(_ question: String, from choices: [Choice<Value>], filter: Bool = false) throws -> Value {
    guard isInteractive else {
        throw Fail("no version given and no terminal to ask; pass a version")
    }
    guard !choices.isEmpty else {
        throw Fail("nothing to choose from")
    }
    return ui.singleChoicePrompt(
        question: TerminalText(stringLiteral: question),
        options: choices,
        filterMode: filter ? .enabled : .disabled).value
}

func resolveOrPick(_ version: String?, _ question: String) async throws -> InstalledXcode {
    if let version {
        return try await Installed.resolve(version)
    }
    return try pickInstalled(question)
}

/// Shell completion for an argument naming an installed Xcode: each installed version once.
func completeInstalledVersion(_: [String], _: Int, _: String) -> [String] {
    var seen = Set<String>()
    return Installed.all().map(\.version).filter { seen.insert($0).inserted }
}

/// A release from a version query, or from a latest / latest beta picker when none is given.
func resolveOrPickRelease(_ version: String?, _ question: String) async throws -> Release {
    let releases = try await Releases.fetch()
    guard let version else {
        return try pickRelease(question, from: releases)
    }
    let (release, note) = try Query(version).resolve(in: releases)
    if let note {
        ui.info(InfoAlert(stringLiteral: note))
    }
    return release
}

func pickRelease(_ question: String, from releases: [Release]) throws -> Release {
    let installed = Installed.all().map { $0.build.lowercased() }
    func choice(_ r: Release, _ label: String) -> Choice<Release> {
        let mark = installed.contains(r.build.lowercased()) ? "  (installed)" : ""
        return Choice(description: "\(r.display)  \(r.build)  \(r.dateString)  \(label)\(mark)", value: r)
    }
    var choices: [Choice<Release>] = []
    if let stable = releases.first(where: \.isFinal) {
        choices.append(choice(stable, "latest"))
    }
    if let pre = Releases.sorted(releases, by: .byVersion).first, !pre.isFinal {
        choices.append(choice(pre, "latest beta"))
    }
    return try pick(question, from: choices)
}

func pickInstalled(_ question: String) throws -> InstalledXcode {
    let installed = Installed.all()
    guard !installed.isEmpty else {
        throw Fail("no Xcode installed in /Applications")
    }
    return try pick(question, from: installed.map {
        Choice(
            description: "\($0.version) (\($0.build))  \($0.name)\(Installed.isActive($0) ? "  *active" : "")",
            value: $0)
    })
}

func printTable(_ rows: [[String]]) {
    tableLines(rows).forEach { print($0) }
}

func tableLines(_ rows: [[String]]) -> [String] {
    guard let first = rows.first else {
        return []
    }
    let widths = (0 ..< first.count).map { c in rows.map { $0[c].count }.max() ?? 0 }
    return rows.map { row in
        row.enumerated().map { $0.offset == row.count - 1 ? $0.element : $0.element.padding(
            toLength: widths[$0.offset],
            withPad: " ",
            startingAt: 0) }
            .joined(separator: "  ")
            .replacingOccurrences(of: " +$", with: "", options: .regularExpression)
    }
}

func releaseRows(_ releases: [Release]) -> [[String]] {
    releaseRows(
        releases,
        installed: Installed.all(),
        active: Installed.activePath()?.standardizedFileURL.path)
}

func releaseRows(_ releases: [Release], installed: [InstalledXcode], active: String?) -> [[String]] {
    let owners = statusOwners(releases, installed, active: active)
    var rows = [["VERSION", "BUILD", "RELEASED", "STATUS"]]
    for (index, r) in releases.enumerated() {
        var status = ""
        if let hit = owners[index] {
            status = hit.path.standardizedFileURL.path == active ? "* active" : "installed"
        }
        rows.append([r.display, r.build, r.dateString, status])
    }
    return rows
}

/// The installed app each row reports, by row index. A release candidate and its final release share
/// a build, so the final row takes the app and the candidate row stays empty.
func statusOwners(
    _ releases: [Release],
    _ installed: [InstalledXcode],
    active: String?)
    -> [Int: InstalledXcode]
{
    var owners: [Int: InstalledXcode] = [:]
    for xcode in installed {
        let matching = releases.indices.filter { releases[$0].build.lowercased() == xcode.build.lowercased() }
        guard let row = matching.first(where: { releases[$0].isFinal }) ?? matching.first else {
            continue
        }
        if owners[row] == nil || xcode.path.standardizedFileURL.path == active {
            owners[row] = xcode
        }
    }
    return owners
}

// MARK: - Login

struct Login: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Sign in to Apple Developer in a window; keeps the session in your Keychain.",
        discussion: "Two-factor codes and security keys (YubiKey etc.) work; the key is driven by the tool itself.")

    /// Signs in through the window, hidden while Apple needs no input, and stores the session, download ticket
    /// included, in the Keychain. Progress goes to `ui`; `stderrUI` keeps stdout clean for a command that prints data.
    static func signIn(ui: Noorable = xcodectl.ui) async throws -> [Cookie] {
        // Best effort: an unreadable or locked Keychain only costs the trusted-browser shortcut.
        let stored = (try? Keychain.read()).flatMap { try? JSONDecoder().decode([Cookie].self, from: $0) } ?? []
        let seed = Session.seed(stored)
        let window = await MainActor.run { LoginWindow(seed: seed) }
        let cookies = try await ui.progressStep(message: "Signing in to Apple Developer") { _ in
            try await window.run().map(Cookie.init)
        }
        let withTicket = try await ui.progressStep(message: "Fetching download ticket") { _ in
            try await Session.refreshTicket(cookies)
        }
        try Session.save(withTicket)
        return withTicket
    }

    /// The sign-in for `--login` on `install` and `update`; nil when it is off or nobody is at the terminal to use the
    /// window.
    static func autologin(_ enabled: Bool) -> Session.SignIn? {
        guard enabled, isInteractive else {
            return nil
        }
        return {
            ui.info(InfoAlert(stringLiteral: "No valid Apple session; signing in again"))
            return try await signIn()
        }
    }

    /// The sign-in for `--login` on `auth status` and `auth export`; nil when it is off or nobody is at the terminal.
    /// Stdout may be a pipe (`auth export | pbcopy`), so only stdin decides, and messages go to stderr.
    static func login(_ enabled: Bool) -> Session.SignIn? {
        guard enabled, isatty(STDIN_FILENO) == 1 else {
            return nil
        }
        return {
            stderrUI.info(InfoAlert(stringLiteral: "No valid Apple session; signing in again"))
            return try await signIn(ui: stderrUI)
        }
    }

    func run() async throws {
        _ = try await Self.signIn()
        ui.success("Signed in. Runners: `xcodectl auth export` here, `xcodectl auth import` there.")
    }
}

// MARK: - AuthCommand

struct AuthCommand: AsyncParsableCommand {
    struct Status: AsyncParsableCommand {
        static let configuration =
            CommandConfiguration(abstract: "Ask Apple whether the session is still signed in; exits 1 when not.")

        @Flag(inversion: .prefixedNo, help: "Print JSON; still exits 1 when not signed in.")
        var json: Bool?

        @Flag(
            name: .customLong("login"),
            inversion: .prefixedNo,
            help: "Open the sign-in window when the session is missing or expired (needs a terminal; never with --json).")
        var login: Bool?

        func run() async throws {
            let source: Session.Source
            do {
                // --json is for scripts: it reports the expiry instead of waiting on a window.
                source = try await Session.verify(signIn: Login.login(login != false && json != true)).source
            } catch let expired as SessionExpired where json == true {
                try signedOut(expired.description)
            }
            guard json == true else {
                ui.success("Signed in (\(source == .keychain ? "Keychain" : Session.envKey)).")
                return
            }
            try printJSON(SessionJSON(signedIn: true, source: source == .keychain ? "keychain" : "environment"))
        }

        /// With `--json`, the reason goes to stdout as JSON and the exit code alone tells the failure.
        private func signedOut(_ reason: String) throws -> Never {
            guard json == true else {
                throw Fail(reason)
            }
            try printJSON(SessionJSON(signedIn: false, reason: reason))
            throw ExitCode.failure
        }
    }

    struct Export: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Check the session with Apple, then print it as one base64 line or copy it with --copy.")

        @Flag(
            name: .customLong("login"),
            inversion: .prefixedNo,
            help: "Open the sign-in window when the session is missing or expired (needs a terminal).")
        var login: Bool?

        @Flag(inversion: .prefixedNo, help: "Copy the session to the clipboard instead of printing it.")
        var copy: Bool?

        func run() async throws {
            let (cookies, _) = try await Session.verify(signIn: Login.login(login != false))
            let blob = try Session.encode(cookies)
            guard copy == true else {
                print(blob)
                return
            }
            await Clipboard.copy(blob)
            ui.success("Session copied to the clipboard.")
        }
    }

    struct Import: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Check a base64 session from stdin (or the clipboard with --paste) with Apple and store it in the Keychain.",
            discussion: """
            Over ssh the login Keychain is locked: macOS gives each ssh connection its own security session. \
            Import unlocks it for its own connection, which works while you are logged in at the runner's console:

              xcodectl auth export | ssh runner xcodectl auth import

            When that unlock fails, unlock it yourself in the same connection. With `ControlMaster auto`, \
            `ControlPath ~/.ssh/cm-%C` and `ControlPersist 10m` for the host in ~/.ssh/config, the commands \
            share one connection, so one unlock serves the import:

              ssh -t runner security unlock-keychain
              xcodectl auth export | ssh runner xcodectl auth import
            """)

        @Flag(
            inversion: .prefixedNo,
            help: "Read the session from the clipboard when stdin is a terminal; a pipe wins.")
        var paste: Bool?

        @Flag(
            inversion: .prefixedNo,
            help: "Over ssh, unlock the login Keychain when it is locked.")
        var unlockKeychain: Bool?

        /// A pipe on stdin holds the blob, so `paste = true` in the config file does not shadow it.
        static func readsClipboard(paste: Bool?, stdinIsTerminal: Bool) -> Bool {
            paste == true && stdinIsTerminal
        }

        /// Only a remote session needs it: a local one gets macOS's own password prompt.
        static func unlocksKeychain(unlockKeychain: Bool?, remote: Bool) -> Bool {
            unlockKeychain != false && remote
        }

        static func store(_ blob: String, unlock: Bool = false) async throws {
            let cookies = try Session.decode(blob)
            guard cookies.contains(where: { $0.name == Session.loginCookie })
            else {
                throw Fail("blob has no Apple login session")
            }
            let verified: [Cookie]
            do {
                verified = try await Session.refreshTicket(cookies)
            } catch is SessionExpired {
                throw Fail(
                    "Apple no longer accepts this session: run `xcodectl auth login` and `auth export` again on your Mac")
            }
            try Session.save(verified, unlock: unlock)
        }

        func run() async throws {
            let blob: String
            if Self.readsClipboard(paste: paste, stdinIsTerminal: isatty(STDIN_FILENO) == 1) {
                guard let text = await Clipboard.paste(),
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else {
                    throw Fail("clipboard holds no text: run `xcodectl auth export --copy` on your Mac")
                }
                blob = text
            } else {
                blob = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
            }
            try await Self.store(
                blob,
                unlock: Self.unlocksKeychain(unlockKeychain: unlockKeychain, remote: Keychain.sessionIsRemote))
            ui.success("Session stored in the Keychain.")
        }
    }

    struct Logout: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Delete the session from this machine's Keychain.")

        func run() async throws {
            try Keychain.delete()
            ui.success("Session removed from the Keychain.")
            if ProcessInfo.processInfo.environment[Session.envKey]?.isEmpty == false {
                ui.warning(WarningAlert(stringLiteral: "\(Session.envKey) is set and still signs you in"))
            }
        }
    }

    static let configuration = CommandConfiguration(
        commandName: "auth",
        abstract: "Sign in to Apple Developer, check the session and move it to runners.",
        subcommands: [Login.self, Status.self, Export.self, Import.self, Logout.self])
}

// MARK: - List

struct List: AsyncParsableCommand {
    static let configuration =
        CommandConfiguration(
            abstract: "Available Xcode versions (two latest majors; a regex searches all).",
            discussion: """
            Without a regex: the newest release of each minor of the newest major, the newest release of \
            the major before it, any prerelease newer than the newest final, and every installed Xcode. \
            --stable keeps finals only, --beta keeps prereleases only. A regex searches every \
            release; --stable / --beta narrow the matches. Xcode versions list highest version first, or \
            newest first with --by-date. `xcodectl runtime list` lists simulator runtimes.
            """)

    @Argument(help: "Regex matched against version and build, e.g. '26\\.[45]' or '27.*beta'.")
    var pattern: String?

    @Flag(inversion: .prefixedNo, help: "Only final releases.")
    var stable: Bool?

    @Flag(inversion: .prefixedNo, help: "Only betas, rcs and other prereleases.")
    var beta: Bool?

    @Flag
    var order: Releases.Order?

    @Flag(inversion: .prefixedNo, help: "Print JSON instead of a table; nothing found is [].")
    var json: Bool?

    func validate() throws {
        guard !(stable == true && beta == true) else {
            throw Fail("--stable and --beta exclude each other")
        }
    }

    func run() async throws {
        async let requirements = SystemRequirements.fetch()
        let all = try await Releases.fetch()
        let shown: [Release] =
            if let pattern {
                try Releases.filter(
                    Releases.search(all, regex: pattern),
                    stable == true ? .stable : beta == true ? .beta : .all)
            } else {
                Releases.defaultListing(
                    all,
                    stable == true ? .stable : beta == true ? .beta : .current,
                    installed: Installed.all().map(\.build))
            }
        guard !shown.isEmpty || json == true else {
            throw Fail("nothing matches \(pattern ?? "")")
        }
        let sorted = Releases.sorted(shown, by: order ?? .byVersion)
        if json == true {
            try await printJSON(releaseJSON(sorted, requirements: requirements))
            return
        }
        let marks = await Compatibility.column(sorted, requirements: requirements)
        printTable(zip(releaseRows(sorted), marks).map { $0 + [$1] })
    }
}

// MARK: - ListInstalled

struct ListInstalled: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "installed",
        abstract: "Xcode versions in /Applications with size and the simulator runtimes they use.",
        discussion: """
        A runtime shows under every Xcode that uses it. When simctl cannot tell, the runtimes are left out. \
        Sizing an Xcode reads every file in it, so at a terminal the table shows at once and the sizes \
        fill in; elsewhere it prints once they are known. `xcodectl runtime installed` lists every \
        simulator runtime registration.
        """)

    @Flag(inversion: .prefixedNo, help: "Size each Xcode, which reads every file in its bundle. Default: on.")
    var size: Bool?

    @Flag(inversion: .prefixedNo, help: "Print JSON instead of a table; nothing installed is [].")
    var json: Bool?

    func run() async throws {
        let installed = Installed.all()
        guard !installed.isEmpty else {
            guard json == true else {
                throw Fail("no Xcode installed in /Applications")
            }
            try printJSON([InstalledXcodeJSON]())
            return
        }
        let registered = (try? SimCtl.runtimes()) ?? []
        let used = await withTaskGroup(of: (Int, [InstalledRuntime]).self) { group in
            for (index, xcode) in installed.enumerated() {
                group.addTask {
                    (index, Runtimes.used(by: (try? SimCtl.runtimeMatches(for: xcode)) ?? [], in: registered))
                }
            }
            var used = [[InstalledRuntime]](repeating: [], count: installed.count)
            for await (index, runtimes) in group {
                used[index] = runtimes
            }
            return used
        }
        let active = Installed.activePath()?.standardizedFileURL.path
        var entries = zip(installed, used).map { (xcode: $0, size: Int64?.none, runtimes: $1) }
        guard size != false else {
            try show(entries, active: active)
            return
        }
        // Redrawing in place needs a terminal; a pipe, a CI log or --json gets the finished listing once.
        let live = isInteractive && json != true ? Renderer() : nil
        let draw = { live?.render(
            tableLines(installedRows(entries, active: active, unknownSize: "…")).joined(separator: "\n"),
            standardPipeline: StandardOutputPipeline()) }
        draw()
        await withTaskGroup(of: (Int, Int64).self) { group in
            for (index, xcode) in installed.enumerated() {
                group.addTask { (index, Installed.size(of: xcode.path)) }
            }
            for await (index, size) in group {
                entries[index].size = size
                draw()
            }
        }
        if live == nil {
            try show(entries, active: active)
        }
    }

    /// The finished Xcode listing: JSON with `--json`, else the table.
    private func show(
        _ entries: [(xcode: InstalledXcode, size: Int64?, runtimes: [InstalledRuntime])],
        active: String?)
        throws
    {
        if json == true {
            try printJSON(installedJSON(entries, active: active))
        } else {
            printTable(installedRows(entries, active: active))
        }
    }
}

/// One row per Xcode, each followed by an indented row per runtime it uses. An Xcode without a
/// size shows `unknownSize`.
func installedRows(
    _ installed: [(xcode: InstalledXcode, size: Int64?, runtimes: [InstalledRuntime])],
    active: String?,
    unknownSize: String = "")
    -> [[String]]
{
    var rows = [["VERSION", "BUILD", "SIZE", "PATH", ""]]
    for (xcode, size, runtimes) in installed {
        let mark = xcode.path.standardizedFileURL.path == active ? "* active" : ""
        rows.append([xcode.version, xcode.build, size.map(formatBytes) ?? unknownSize, xcode.path.path, mark])
        for runtime in runtimes {
            rows.append(["  \(runtime.display)", runtime.build, formatBytes(runtime.size), "", ""])
        }
    }
    return rows
}

// MARK: - ReleaseNotesCommand

struct ReleaseNotesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "release-notes",
        abstract: "Show the release notes of an Xcode version, or what changed between two.",
        discussion: """
        With a second version: the list items and paragraphs its notes add (+) and drop (-) compared \
        to the first. --abridged and --ask send the notes to a model: OpenRouter, OpenAI or Gemini with \
        the key in OPENROUTER_API_KEY, OPENAI_API_KEY or GEMINI_API_KEY, or a server of your own with \
        --base-url and --model.
        """)

    @Argument(help: "Xcode version, same forms as `install`. Omit for a picker.")
    var version: String?

    @Argument(help: "A second version to compare the first with.")
    var other: String?

    @Flag(inversion: .prefixedNo, help: "Print the Markdown as Apple serves it. Default: rendered for the terminal.")
    var markdown: Bool?

    @Flag(
        inversion: .prefixedNo,
        help: "Print plain text, without markup or colors; the default when the output is not a terminal.")
    var plain: Bool?

    @Flag(inversion: .prefixedNo, help: "A summary for a developer of apps, written by a model.")
    var abridged: Bool?

    @Option(help: "Answer a question about the notes with a model, e.g. \"which macOS is required?\"")
    var ask: String?

    @Option(
        help: "Environment variable holding the API key. Default: OPENROUTER_API_KEY, then OPENAI_API_KEY, then GEMINI_API_KEY.")
    var keyEnv: String?

    @Option(help: "API the key belongs to. Default: by the variable that is set, else openai.")
    var provider: Provider?

    @Option(
        name: .customLong("base-url"),
        help: "Another OpenAI-compatible API, e.g. Ollama at http://localhost:11434/v1; needs --model, not a key.")
    var baseURL: String?

    @Option(help: "Model id. Default: gpt-5.6-luna, on Gemini gemini-3.8-flash.")
    var model: String?

    func validate() throws {
        guard [abridged == true, ask != nil, other != nil].filter(\.self).count <= 1 else {
            throw Fail("--abridged, --ask and a second version exclude each other")
        }
        guard !(markdown == true && plain == true) else {
            throw Fail("--markdown and --plain exclude each other")
        }
        guard abridged == true || ask != nil || (keyEnv == nil && provider == nil && baseURL == nil && model == nil)
        else {
            throw Fail("--key-env, --provider, --base-url and --model need --abridged or --ask")
        }
    }

    func run() async throws {
        let release = try await resolveOrPickRelease(version, "Release notes of which Xcode?")
        async let compatibility = other == nil && ask == nil ? Compatibility.line(for: release) : nil
        let notes = try await ReleaseNotes.fetch(release)
        if let other {
            let newer = try await resolveOrPickRelease(other, "Compare with which Xcode?")
            guard try ReleaseNotes.markdownURL(newer) != ReleaseNotes.markdownURL(release) else {
                throw Fail("Xcode \(release.display) and \(newer.display) share one release notes page")
            }
            let changes = try await ReleaseNotes.diff(
                old: ReleaseNotes.blocks(notes),
                new: ReleaseNotes.blocks(ReleaseNotes.fetch(newer)))
            guard let changes else {
                throw Fail("the release notes of Xcode \(release.display) and \(newer.display) do not differ")
            }
            show("# Xcode \(release.display) → \(newer.display) release notes\n\n\(changes)", diff: true)
        } else if abridged == true || ask != nil {
            let backend = try ReleaseNotes.backend(HostedModel.resolve(
                environment: ProcessInfo.processInfo.environment, keyEnv: keyEnv, provider: provider,
                baseURL: baseURL, model: model))
            if let ask {
                try await show(thinking("Asking \(backend.name)") {
                    try await ReleaseNotes.answer(ask, from: notes, with: backend)
                })
            } else {
                try await show(
                    thinking("Summarizing with \(backend.name)") { try await ReleaseNotes.abridge(notes, with: backend)
                    },
                    compatibility: compatibility)
            }
        } else {
            await show(notes, compatibility: compatibility)
        }
    }

    private func show(_ text: String, diff: Bool = false, compatibility: String? = nil) {
        let text = Compatibility.adding(compatibility, to: text)
        if markdown == true {
            print(text)
        } else if plain == true || isatty(STDOUT_FILENO) != 1 {
            print(ReleaseNotes.plain(text))
        } else {
            // A blank line sets the notes off from the messages above them.
            print("\n" + ReleaseNotes.rendered(text, diff: diff, theme: .current()))
        }
    }

    /// A spinner while the model works, on a terminal only, so piped output holds nothing but the result.
    private func thinking(_ message: String, _ work: @escaping () async throws -> String) async throws -> String {
        guard isInteractive else {
            return try await work()
        }
        return try await ui
            .progressStep(message: message, successMessage: nil, errorMessage: nil, showSpinner: true) { _ in
                try await work()
            }
    }
}

// MARK: - Install

struct Install: AsyncParsableCommand {
    static let configuration =
        CommandConfiguration(
            abstract: "Download and install an Xcode version into /Applications.",
            discussion: "`xcodectl runtime install` installs one simulator runtime on its own.")

    @Argument(help: """
    26.1, 27, 27-rc1, '27 beta 3', 27A266a, latest, latest-beta. Several install in parallel. \
    Omit for a picker.
    """)
    var versions: [String] = []

    @Flag(
        inversion: .prefixedNo,
        help: "Run `approve` after installing (license, first launch; needs sudo). Default: on.")
    var approve: Bool?

    @Flag(inversion: .prefixedNo, help: "Run `select` afterwards (needs sudo).")
    var select: Bool?

    @Flag(
        inversion: .prefixedNo,
        help: "Upgrade the Command Line Tools to this version (Software Update, needs sudo). Default: on.")
    var clt: Bool?

    @Flag(
        name: .customLong("login"),
        inversion: .prefixedNo,
        help: "Open the sign-in window when the Apple session is missing or expired (only at a terminal).")
    var autologin: Bool?

    @Option(
        name: .customLong("runtimes"),
        help: "Also install simulator runtimes matching this Xcode: 'all', a list like 'ios,watchos', or 'none'.")
    var runtimeSelection: RuntimeSelection?

    func validate() throws {
        // Runtimes install through this Xcode's own xcodebuild, which an unapproved Xcode refuses to run.
        guard (runtimeSelection?.platforms ?? []).isEmpty || approve != false else {
            throw Fail("--runtimes needs an approved Xcode; drop --no-approve")
        }
        guard select != true || versions.count <= 1 else {
            throw Fail("--select takes one version; run `xcodectl select` afterwards")
        }
    }

    func run() async throws {
        var releases: [Release] = []
        if versions.isEmpty {
            releases = try await [resolveOrPickRelease(nil, "Which Xcode?")]
        } else {
            let all = try await Releases.fetch()
            for version in versions {
                let (release, note) = try Query(version).resolve(in: all)
                if let note {
                    ui.info(InfoAlert(stringLiteral: note))
                }
                if !releases.contains(where: { $0.build == release.build }) {
                    releases.append(release)
                }
            }
        }

        var xcodes: [String: InstalledXcode] = [:]
        var missing: [Release] = []
        for release in releases {
            if let existing = Installed.find(build: release.build) {
                ui
                    .info(
                        InfoAlert(
                            stringLiteral: "Xcode \(release.display) is already installed at \(existing.path.path)"))
                xcodes[release.build] = existing
            } else {
                missing.append(release)
            }
        }
        if !missing.isEmpty {
            try await xcodes.merge(install(missing)) { $1 }
        }

        for release in releases {
            let xcode = xcodes[release.build]!
            if approve != false {
                try Installer.approve(xcode)
            }
            if clt != false {
                Installer.upgradeCommandLineTools(for: release)
            }
            if let runtimeSelection, !runtimeSelection.platforms.isEmpty {
                try await installRuntimes(runtimeSelection, using: xcode)
            }
            if select == true {
                try Installer.select(xcode)
            }
        }
        if select != true {
            let version = releases.count == 1 ? releases[0].display : "<version>"
            ui.info(InfoAlert(stringLiteral: "next: `xcodectl select \(version)` to make it the active Xcode"))
        }
    }

    /// Downloads all releases at once, then expands them all at once. Keyed by build.
    private func install(_ releases: [Release]) async throws -> [String: InstalledXcode] {
        for release in releases {
            if let required = release.requires, !versionAtLeast(macOSVersion(), required) {
                throw Fail("Xcode \(release.display) needs macOS \(required); this Mac runs \(macOSVersion())")
            }
            guard release.downloadURL != nil else {
                throw Fail("no download link for \(release.display)")
            }
            if FileManager.default.fileExists(atPath: release.installPath.path) {
                throw Fail("\(release.installPath.path) exists but is not Xcode \(release.build); remove it first")
            }
        }
        // Claimed before downloading: the lock also keeps a parallel run off the same archive.
        let dirs = try releases.map { try Installer.expandDirectory(for: $0.build) }
        // An earlier run expanded these but could not move them into /Applications.
        let expanded = dirs.map(Installer.expanded(in:))
        for app in expanded.compactMap(\.self) {
            ui.info(InfoAlert(stringLiteral: "reusing \(app.path), expanded by an earlier run"))
        }
        let pending = releases.indices.filter { expanded[$0] == nil }

        try Paths.ensureCache()
        let xip = { (release: Release) in Paths.cache.appendingPathComponent(release.xipName) }
        let downloads = pending.map { releases[$0] }.filter { !FileManager.default.fileExists(atPath: xip($0).path) }
        if !downloads.isEmpty {
            let cookies = try await Session.ensureTicket(signIn: Login.autologin(autologin ?? true))
            let connections = Int(ProcessInfo.processInfo.environment["XCODECTL_CONNECTIONS"] ?? "") ?? Downloader
                .defaultConnections
            let names = downloads.map { "Xcode \($0.display)" }.joined(separator: ", ")
            let fractions = Fractions(count: downloads.count)
            try await ui.progressBarStep(
                message: "Downloading \(names)",
                successMessage: "Downloaded \(names)",
                errorMessage: "Download failed")
            { update in
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for (i, release) in downloads.enumerated() {
                        let url = release.downloadURL!
                        let downloader = Downloader(
                            url: url,
                            cookieHeader: Session.header(cookies, host: url.host!),
                            destination: xip(release),
                            connections: connections)
                        group.addTask {
                            try await downloader.run { fractions.set(i, $0, report: update) }
                        }
                    }
                    try await group.waitForAll()
                }
            }
        }

        var apps = expanded
        if !pending.isEmpty {
            try Installer.checkFreeSpace(forExpanding: pending.count)
            let names = pending.map { releases[$0].xipName }.joined(separator: ", ")
            apps = try await ui.progressStep(
                message: "Expanding \(names)",
                successMessage: "Expanded \(names)",
                errorMessage: "Expanding failed",
                showSpinner: true)
            { _ in
                try await withThrowingTaskGroup(of: (Int, URL).self) { group in
                    for i in pending {
                        group.addTask { try await (i, Installer.expand(xip: xip(releases[i]), into: dirs[i])) }
                    }
                    var result = expanded
                    for try await (i, app) in group {
                        result[i] = app
                    }
                    return result
                }
            }
        }

        var xcodes: [String: InstalledXcode] = [:]
        for (release, app) in zip(releases, apps.map { $0! }) {
            try Installer.move(app, to: release.installPath)
            try? FileManager.default.removeItem(at: xip(release))
            guard let xcode = Installed.read(release.installPath) else {
                throw Fail("installed to \(release.installPath.path) but cannot read its version.plist")
            }
            ui.success(SuccessAlert(stringLiteral: "Installed Xcode \(release.display) at \(release.installPath.path)"))
            xcodes[release.build] = xcode
        }
        return xcodes
    }
}

// MARK: - Upgrade

struct Upgrade: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Move each installed Xcode, or the ones named, to the newest release of its major; the old one goes.",
        discussion: """
        A final release moves to the newest final release of its major (27.0 to 27.2), with --minor to \
        the newest of its major.minor (27.0 to 27.0.1). Betas and rcs stay unless --beta, which moves \
        them to the newest build of their line, prerelease or final (27.2-beta1 to 27.2-beta2 or 27.2); \
        a final never moves to a prerelease. Once the new Xcode is installed and approved, the old one is \
        selected out of the way if it was active, then removed with the simulator runtimes only it \
        uses; --keep leaves it installed. A newest release already installed next to an older one \
        counts as installed, so a run that failed while removing finishes the job when run again. \
        Before the old one goes, the new Xcode gets its simulator runtime for each platform that has a \
        runtime installed; --runtimes names the platforms instead, --runtimes none skips them. \
        --replace-runtimes then deletes every ready runtime no installed Xcode uses, older OS versions \
        kept for testing included, with the simulators on it, also when nothing needed upgrading; \
        leftovers that are not ready stay for `runtime prune`.
        """)

    @Argument(
        help: "Installed version: 27, 27.0, 27.0.1, 27A266a. Omit for every installed Xcode.",
        completion: .custom(completeInstalledVersion))
    var version: String?

    @Flag(inversion: .prefixedNo, help: "Newest build of the same major.minor instead of the same major.")
    var minor: Bool?

    @Flag(inversion: .prefixedNo, help: "Keep the old Xcode and its runtimes installed; the active Xcode stays.")
    var keep: Bool?

    @Flag(
        inversion: .prefixedNo,
        help: "Also move installed betas and rcs, to the newest build of their line, beta or final.")
    var beta: Bool?

    @Flag(
        inversion: .prefixedNo,
        help: "Run `approve` after installing (license, first launch; needs sudo). Default: on.")
    var approve: Bool?

    @Flag(inversion: .prefixedNo, help: "Upgrade the Command Line Tools (Software Update, needs sudo). Default: on.")
    var clt: Bool?

    @Flag(
        name: .customLong("login"),
        inversion: .prefixedNo,
        help: "Open the sign-in window when the Apple session is missing or expired (only at a terminal).")
    var autologin: Bool?

    @Option(
        name: .customLong("runtimes"),
        help: """
        Simulator runtimes for each new Xcode: 'all', a list like 'ios,watchos', or 'none'. \
        Default: the platforms that have a runtime installed.
        """)
    var runtimeSelection: RuntimeSelection?

    @Flag(
        inversion: .prefixedNo,
        help: """
        Afterwards delete every simulator runtime no installed Xcode uses, older OS versions too, with \
        the simulators on it.
        """)
    var replaceRuntimes: Bool?

    @Flag(help: "Only print what would be installed and removed.")
    var dryRun = false

    func validate() throws {
        // Runtimes install through the new Xcode's own xcodebuild, which an unapproved Xcode refuses to run.
        guard (runtimeSelection?.platforms ?? []).isEmpty || approve != false else {
            throw Fail("--runtimes needs an approved Xcode; drop --no-approve")
        }
        // Only simctl under each installed Xcode, the new one included, says which runtimes are in use.
        guard replaceRuntimes != true || approve != false else {
            throw Fail("--replace-runtimes needs an approved Xcode; drop --no-approve")
        }
    }

    func run() async throws {
        let replacing = try await upgradeXcodes()
        if replaceRuntimes == true {
            try await removeUnusedRuntimes(replacing: replacing)
        }
    }

    /// The `install` invocation for these builds, carrying the flags that were turned off.
    func installArguments(_ builds: [String], select: Bool, runtimes: RuntimeSelection? = nil) -> [String] {
        builds + (approve == false ? ["--no-approve"] : []) + (clt == false ? ["--no-clt"] : [])
            + (autologin == false ? ["--no-login"] : []) + (select ? ["--select"] : [])
            + (runtimes.map { ["--runtimes", $0.argument] } ?? [])
    }

    /// The runtimes `install` adds to each new Xcode, nil for none: the ones --runtimes names, else
    /// one for every platform that has a ready runtime. An unapproved Xcode cannot install them.
    func newRuntimes(registered: [InstalledRuntime]) -> RuntimeSelection? {
        if let runtimeSelection {
            return runtimeSelection.platforms.isEmpty ? nil : runtimeSelection
        }
        guard approve != false else {
            return nil
        }
        let platforms = Set(registered.filter(\.isReady).compactMap(\.platform))
        return RuntimeSelection(argument: RuntimePlatform.allCases.filter(platforms.contains).map(\.rawValue)
            .joined(separator: ","))
    }

    /// Whether old Xcodes go, or would go in a dry run.
    private func upgradeXcodes() async throws -> Bool {
        let installed = try await targets()
        let releases = try await Releases.fetch()
        var plan = Releases.upgrades(
            for: installed,
            in: releases,
            scope: minor == true ? .minor : .major,
            prereleases: beta == true)
        if keep == true {
            plan.removeAll { Installed.find(build: $0.to.build) != nil }
        }
        let skipped = beta == true ? [] : installed.filter { xcode in
            let own = releases.filter { $0.build.lowercased() == xcode.build.lowercased() }
            return !own.isEmpty && !own.contains(where: \.isFinal)
        }
        for xcode in skipped {
            ui.info(InfoAlert(stringLiteral: "\(xcode.name) is a prerelease; --beta upgrades it"))
        }
        guard !plan.isEmpty else {
            ui.success(SuccessAlert(stringLiteral: skipped.isEmpty
                    ? "Every installed Xcode is up to date" : "Nothing else to upgrade"))
            return false
        }
        // Before installing: the new Xcode is selected only in place of an old one that was active.
        let wasActive = plan.map { $0.from.contains(where: Installed.isActive) }
        for (pair, active) in zip(plan, wasActive) {
            let olds = pair.from.map(\.name).joined(separator: ", ")
            let then = keep == true ? "" : "; then removed" + (active ? ", \(pair.to.display) selected" : "")
            ui.info(InfoAlert(stringLiteral: "\(olds) -> Xcode \(pair.to.display) \(pair.to.build)\(then)"))
        }
        var registered: [InstalledRuntime] = []
        if runtimeSelection == nil {
            if approve == false {
                ui.info(InfoAlert(stringLiteral: "simulator runtimes skipped: they need an approved Xcode"))
            } else {
                do {
                    registered = try SimCtl.runtimes()
                } catch {
                    ui.warning(WarningAlert(stringLiteral:
                        "cannot tell which simulator runtimes are installed (\(error)); --runtimes names them"))
                }
            }
        }
        let runtimes = newRuntimes(registered: registered)
        if let runtimes {
            ui.info(InfoAlert(stringLiteral:
                "runtimes for the new Xcode: \(runtimes.platforms.map(\.display).joined(separator: ", "))"))
        }
        guard !dryRun else {
            return keep != true
        }
        // With one target that replaces the active Xcode, `install --select` makes the switch itself.
        let selectOnInstall = keep != true && plan.count == 1 && wasActive[0]
        try await Install.parse(installArguments(plan.map(\.to.build), select: selectOnInstall, runtimes: runtimes))
            .run()
        guard keep != true else {
            return false
        }
        for (pair, active) in zip(plan, wasActive) {
            // Selecting before removing keeps `remove` from picking a replacement of its own.
            if active, !selectOnInstall, let xcode = Installed.find(build: pair.to.build) {
                try Installer.select(xcode)
                ui.success(SuccessAlert(stringLiteral: "Active: \(xcode.path.path)"))
            }
            // --replace-runtimes deletes the old Xcode's runtimes afterwards, with their simulators.
            for old in pair.from {
                try await Remove.parse([old.build] + (replaceRuntimes == true ? ["--keep-runtimes"] : [])).run()
            }
        }
        return true
    }

    /// Deletes every ready runtime no installed Xcode uses, with its simulators.
    private func removeUnusedRuntimes(replacing: Bool) async throws {
        guard let unused = try unusedRuntimes(in: SimCtl.runtimes()) else {
            return
        }
        guard dryRun else {
            guard !unused.isEmpty else {
                ui.success(SuccessAlert(stringLiteral: "Every simulator runtime is in use"))
                return
            }
            try await removeRuntimes(unused, simulators: true)
            return
        }
        guard !unused.isEmpty || replacing else {
            ui.success(SuccessAlert(stringLiteral: "Every simulator runtime is in use"))
            return
        }
        if !unused.isEmpty {
            printUnusedRuntimes(unused)
        }
        let also = replacing ? ", then the ones only the replaced Xcodes use," : ""
        ui.info(InfoAlert(stringLiteral: "--replace-runtimes would delete \(unused.count) unused runtime"
                + "\(unused.count == 1 ? "" : "s")\(also) with the simulators on them"))
    }

    /// The installed Xcodes to upgrade: every one, or those matching the version: "27" is every 27.x,
    /// "27.0" every 27.0 build, a build number or "latest" exactly one.
    private func targets() async throws -> [InstalledXcode] {
        let all = Installed.all()
        guard !all.isEmpty else {
            throw Fail("no Xcode installed in /Applications")
        }
        guard let version else {
            return all
        }
        let query = try Query(version)
        guard !query.components.isEmpty else {
            return try await [Installed.resolve(version)]
        }
        let hits = all.filter { query.matchesNumber($0.version) }
        guard !hits.isEmpty else {
            throw Fail("\(version) is not installed; see `xcodectl installed`")
        }
        return hits
    }
}

// MARK: - Fractions

/// Progress of parallel downloads, as one average fraction.
private final class Fractions: @unchecked Sendable {
    init(count: Int) {
        values = Array(repeating: 0, count: count)
    }

    /// Records one download's progress and reports the average, one report at a time.
    func set(_ index: Int, _ value: Double, report: (Double) -> Void) {
        lock.withLock {
            values[index] = value
            report(values.reduce(0, +) / Double(values.count))
        }
    }

    private let lock = NSLock()
    private var values: [Double]
}

// MARK: - InstallClt

struct InstallClt: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install-clt",
        abstract: "Install only the Command Line Tools of an Xcode version (Software Update, sudo).")

    @Argument(help: "Xcode version, same forms as `install`. Omit for a picker.")
    var version: String?

    func run() async throws {
        let release = try await resolveOrPickRelease(version, "Command Line Tools of which Xcode?")
        try Installer.installCommandLineTools(Installer.commandLineToolsVersion(for: release))
    }
}

// MARK: - Approve

struct Approve: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Accept the license, run first launch and enable developer mode (sudo).",
        aliases: ["accept"])

    @Argument(help: "Installed version; omit for a picker.", completion: .custom(completeInstalledVersion))
    var version: String?

    func run() async throws {
        let xcode = try await resolveOrPick(version, "Approve which Xcode?")
        try Installer.approve(xcode)
        ui.success(SuccessAlert(stringLiteral: "Approved \(xcode.name)"))
    }
}

// MARK: - Select

struct Select: AsyncParsableCommand {
    static let configuration =
        CommandConfiguration(abstract: "Make an installed Xcode the active one (xcode-select, sudo).")

    @Argument(help: "Installed version; omit for a picker.", completion: .custom(completeInstalledVersion))
    var version: String?

    func run() async throws {
        let xcode = try await resolveOrPick(version, "Select which Xcode?")
        try Installer.select(xcode)
        ui.success(SuccessAlert(stringLiteral: "Active: \(xcode.path.path)"))
    }
}

// MARK: - Remove

struct Remove: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Delete an installed Xcode with the simulator runtimes only it uses.",
        discussion: """
        Runtimes another installed Xcode also uses stay. `xcodectl runtime remove` deletes one simulator \
        runtime.
        """)

    @Argument(help: "Installed version.", completion: .custom(completeInstalledVersion))
    var version: String

    @Flag(inversion: .prefixedNo, help: "Keep the simulator runtimes this Xcode uses.")
    var keepRuntimes: Bool?

    func run() async throws {
        let path = try await target()
        let name = path.lastPathComponent
        let wasActive = Installed.isActive(path)
        if keepRuntimes != true {
            try await removeOwnRuntimes(of: path)
        }
        try await ui.progressStep(
            message: "Removing \(name)",
            successMessage: "Removed \(name)",
            errorMessage: "Remove failed",
            showSpinner: true)
        { _ in
            try Installer.remove(at: path)
        }
        guard wasActive else {
            return
        }
        let remaining = Installed.all()
        guard !remaining.isEmpty else {
            return
        }
        let next = isInteractive ? try pickInstalled("That was the active Xcode. Select which one now?") : remaining[0]
        try Installer.select(next)
        ui.success(SuccessAlert(stringLiteral: "Active: \(next.path.path)"))
    }

    /// Runtimes go before the Xcode: only the Xcode can say which runtimes it uses, and simctl comes
    /// with Xcode, so it may not run once the Xcode is gone. A bundle an earlier remove left
    /// incomplete has nothing to ask.
    private func removeOwnRuntimes(of app: URL) async throws {
        guard let xcode = Installed.read(app) else {
            return
        }
        let exclusive: [InstalledRuntime]
        do {
            let others = try Installed.all()
                .filter { $0.path.standardizedFileURL.path != app.standardizedFileURL.path }
                .map(SimCtl.runtimeMatches(for:))
            exclusive = try Runtimes.exclusive(
                to: SimCtl.runtimeMatches(for: xcode),
                others: others,
                in: SimCtl.runtimes())
        } catch {
            ui.warning(WarningAlert(stringLiteral:
                "cannot tell which simulator runtimes \(xcode.name) uses (\(error)); keeping them"))
            return
        }
        do {
            try await removeRuntimes(exclusive)
        } catch {
            throw Fail("\(error); `xcodectl remove \(version) --keep-runtimes` removes the Xcode alone")
        }
    }

    /// The bundle to delete: an installed Xcode, or one a `remove` that failed part way through left
    /// behind, which no longer has the version.plist that `Installed.resolve` reads.
    private func target() async throws -> URL {
        do {
            return try await Installed.resolve(version).path
        } catch {
            guard let leftover = Installed.leftover(matching: version) else {
                throw error
            }
            ui.info(InfoAlert(stringLiteral:
                "\(leftover.lastPathComponent) is incomplete, from an earlier remove; deleting the rest"))
            return leftover
        }
    }
}

// MARK: - Releases.Order + EnumerableFlag

extension Releases.Order: EnumerableFlag {
    static func help(for value: Self) -> ArgumentHelp? {
        switch value {
        case .byVersion:
            "Highest version first (default)."
        case .byDate:
            "Newest release date first."
        }
    }
}

// MARK: - RuntimePlatform + ExpressibleByArgument

extension RuntimePlatform: ExpressibleByArgument {
    init?(argument: String) {
        self.init(rawValue: argument.lowercased())
    }

    static var allValueStrings: [String] {
        allCases.map(\.rawValue)
    }
}

// MARK: - RuntimeSelection

/// The value of `install --runtimes`: `all`, `none`, or a comma-separated list like `ios,watchos`.
struct RuntimeSelection: ExpressibleByArgument, Equatable {
    init?(argument: String) {
        let text = argument.lowercased().trimmingCharacters(in: .whitespaces)
        if text == "all" {
            platforms = RuntimePlatform.allCases
            isAll = true
            return
        }
        if text == "none" {
            platforms = []
            isAll = false
            return
        }
        var chosen: [RuntimePlatform] = []
        for part in text.split(separator: ",") {
            guard let platform = RuntimePlatform(argument: part.trimmingCharacters(in: .whitespaces)) else {
                return nil
            }
            if !chosen.contains(platform) {
                chosen.append(platform)
            }
        }
        guard !chosen.isEmpty else {
            return nil
        }
        platforms = chosen
        isAll = false
    }

    static var allValueStrings: [String] {
        ["all", "none"] + RuntimePlatform.allValueStrings
    }

    let platforms: [RuntimePlatform]
    /// `all` becomes one `-downloadAllPlatforms` run rather than one run per platform.
    let isAll: Bool

    /// The selection as `--runtimes` takes it.
    var argument: String {
        isAll ? "all" : platforms.isEmpty ? "none" : platforms.map(\.rawValue).joined(separator: ",")
    }
}

// MARK: - Runtime helpers

func runtimeRows(_ runtimes: [SimulatorRuntime], installed: [InstalledRuntime]) -> [[String]] {
    let ready = Set(installed.filter(\.isReady).map { $0.build.lowercased() })
    var rows = [["PLATFORM", "VERSION", "BUILD", "SIZE", "STATUS"]]
    for runtime in runtimes {
        rows.append([
            runtime.platform.display,
            runtime.version + (runtime.isBeta ? " beta" : ""),
            runtime.build,
            runtime.size > 0 ? formatBytes(runtime.size) : "",
            ready.contains(runtime.build.lowercased()) ? "installed" : "",
        ])
    }
    return rows
}

func pickInstalledRuntime(_ question: String, from runtimes: [InstalledRuntime]) throws -> InstalledRuntime {
    guard !runtimes.isEmpty else {
        throw Fail("no simulator runtime installed")
    }
    return try pick(question, from: runtimes.map {
        Choice(
            description: "\($0.display) (\($0.build))  \(formatBytes($0.size))\($0.isReady ? "" : "  \($0.state)")",
            value: $0)
    })
}

/// The Xcode a runtime installs through: a named one, else the active one.
func runtimeHost(_ version: String?) async throws -> InstalledXcode {
    if let version {
        return try await Installed.resolve(version)
    }
    guard let active = Installed.activePath(), let xcode = Installed.read(active) else {
        throw Fail("no active Xcode; run `xcodectl select <version>` or pass --xcode")
    }
    return xcode
}

func installRuntimes(_ selection: RuntimeSelection, using xcode: InstalledXcode) async throws {
    if let catalog = try? await Runtimes.fetch() {
        let estimate = Runtimes.estimatedSize(selection.platforms, in: catalog)
        if estimate > 0 {
            ui.info(InfoAlert(stringLiteral:
                "\(selection.platforms.map(\.display).joined(separator: ", ")) runtimes: about \(formatBytes(estimate)) to download"))
        }
    }
    if selection.isAll {
        try await downloadRuntime(nil, label: "all simulator runtimes", using: xcode)
        return
    }
    for platform in selection.platforms {
        try await downloadRuntime(platform, label: "\(platform.display) runtime", using: xcode)
    }
}

/// Without a build, Xcode picks the runtime matching the Xcode it runs from.
func downloadRuntime(
    _ platform: RuntimePlatform?,
    build: String? = nil,
    appleSiliconOnly: Bool = true,
    label: String,
    using xcode: InstalledXcode)
    async throws
{
    do {
        try await ui.progressBarStep(
            message: "Downloading \(label)",
            successMessage: "Installed \(label)",
            errorMessage: "Installing \(label) failed")
        { update in
            try RuntimeInstaller.install(
                platform,
                build: build,
                appleSiliconOnly: appleSiliconOnly,
                using: xcode,
                progress: update)
        }
    } catch let failure as Fail where RuntimeInstaller.isAlreadyInstalled(failure.description) {
        ui.info(InfoAlert(stringLiteral: "\(label) is already installed"))
    }
}

/// A disk-image runtime downloads with the Apple session, like an Xcode, and simctl registers it.
/// CoreSimulator keeps its own copy, so the download goes once it is registered.
func installDiskImageRuntime(
    _ runtime: SimulatorRuntime,
    from source: URL,
    autologin: Bool,
    using xcode: InstalledXcode)
    async throws
{
    let label = "\(runtime.display) (\(runtime.build))"
    let registered = (try? SimCtl.runtimes()) ?? []
    guard !registered.contains(where: { $0.isReady && $0.build.lowercased() == runtime.build.lowercased() }) else {
        ui.info(InfoAlert(stringLiteral: "\(label) is already installed"))
        return
    }
    try Paths.ensureCache()
    let image = Paths.cache.appendingPathComponent(source.lastPathComponent)
    if !FileManager.default.fileExists(atPath: image.path) {
        let cookies = try await Session.ensureTicket(signIn: Login.autologin(autologin))
        let connections = Int(ProcessInfo.processInfo.environment["XCODECTL_CONNECTIONS"] ?? "") ?? Downloader
            .defaultConnections
        let downloader = Downloader(
            url: source,
            cookieHeader: Session.header(cookies, host: source.host!),
            destination: image,
            connections: connections)
        try await ui.progressBarStep(
            message: "Downloading \(label)",
            successMessage: "Downloaded \(label)",
            errorMessage: "Download failed")
        { update in
            try await downloader.run(progress: update)
        }
    }
    try await ui.progressStep(
        message: "Adding \(label)",
        successMessage: "Installed \(label)",
        errorMessage: "Installing \(label) failed",
        showSpinner: true)
    { _ in
        try SimCtl.add(image, using: xcode)
    }
    try? FileManager.default.removeItem(at: image)
}

/// A cryptex runtime that Xcode 27 and newer cannot download. Apple's asset server names its archive
/// and key; the archive downloads like an Xcode but without a session, the disk image inside it is
/// expanded next to it, and simctl registers that. The archive goes once expanded and the image once
/// registered, which keeps the peak disk use near twice the runtime's size.
func installAssetRuntime(_ runtime: SimulatorRuntime, using xcode: InstalledXcode) async throws {
    let label = "\(runtime.display) (\(runtime.build))"
    let registered = (try? SimCtl.runtimes()) ?? []
    guard !registered.contains(where: { $0.isReady && $0.build.lowercased() == runtime.build.lowercased() }) else {
        ui.info(InfoAlert(stringLiteral: "\(label) is already installed"))
        return
    }
    let asset = try await RuntimeAsset.lookup(runtime)
    try Paths.ensureCache()
    let archive = Paths.cache.appendingPathComponent(asset.url.lastPathComponent)
    if !FileManager.default.fileExists(atPath: archive.path) {
        let connections = Int(ProcessInfo.processInfo.environment["XCODECTL_CONNECTIONS"] ?? "") ?? Downloader
            .defaultConnections
        let downloader = Downloader(url: asset.url, cookieHeader: "", destination: archive, connections: connections)
        try await ui.progressBarStep(
            message: "Downloading \(label)",
            successMessage: "Downloaded \(label)",
            errorMessage: "Download failed")
        { update in
            try await downloader.run(progress: update)
        }
    }
    let directory = Paths.cache.appendingPathComponent(runtime.build)
    defer { try? FileManager.default.removeItem(at: directory) }
    let image = try await ui.progressStep(
        message: "Expanding \(label)",
        successMessage: "Expanded \(label)",
        errorMessage: "Expanding \(label) failed",
        showSpinner: true)
    { _ in
        try asset.verify(archive)
        try? FileManager.default.removeItem(at: directory)
        let expanded = try asset.extractDiskImage(from: archive, into: directory)
        try FileManager.default.removeItem(at: archive)
        return expanded
    }
    try await ui.progressStep(
        message: "Adding \(label)",
        successMessage: "Installed \(label)",
        errorMessage: "Installing \(label) failed",
        showSpinner: true)
    { _ in
        try SimCtl.add(image, using: xcode)
    }
}

/// Deletes registrations and reports whether the disk space actually came back. CoreSimulator frees
/// the MobileAsset behind a runtime only once the last registration referencing it is gone, and it
/// says nothing when it skips that, so check. With `simulators`, the devices left without a runtime
/// go too.
func removeRuntimes(_ runtimes: [InstalledRuntime], simulators: Bool = false) async throws {
    for runtime in runtimes {
        let label = "\(runtime.display) (\(runtime.build))"
        let asset = runtime.assetDirectory
        try await ui.progressStep(
            message: "Removing \(label)",
            successMessage: "Removed \(label)",
            errorMessage: "Removing \(label) failed",
            showSpinner: true)
        { _ in
            try SimCtl.delete(runtime)
        }
        guard let asset, FileManager.default.fileExists(atPath: asset.path) else {
            if runtime.size > 0 {
                ui.info(InfoAlert(stringLiteral: "Freed \(formatBytes(runtime.size))"))
            }
            continue
        }
        ui.warning(WarningAlert(stringLiteral: "\(formatBytes(runtime.size)) stays on disk: another runtime "
                + "registration still references this asset. `xcodectl runtime installed` shows them all."))
    }
    if simulators {
        try await removeSimulators(on: runtimes)
    }
}

/// Deletes the devices that these deleted runtimes leave without a runtime. A device names its runtime
/// by version, so a device that another build of that version still serves stays.
func removeSimulators(on runtimes: [InstalledRuntime]) async throws {
    var names: [String: String] = [:]
    for runtime in runtimes {
        if let identifier = runtime.runtimeIdentifier {
            names[identifier] = runtime.display
        }
    }
    let devices = try SimCtl.devices().filter { names[$0.runtimeIdentifier] != nil }
    let served = Dictionary(grouping: devices.filter(\.isAvailable), by: \.runtimeIdentifier)
    for (identifier, kept) in served.sorted(by: { $0.key < $1.key }) {
        ui.info(InfoAlert(stringLiteral: "\(kept.count) simulator\(kept.count == 1 ? "" : "s") on "
                + "\(names[identifier] ?? identifier) stay: another runtime still serves them"))
    }
    let orphans = devices.filter { !$0.isAvailable }
    guard !orphans.isEmpty else {
        return
    }
    let label = "\(orphans.count) simulator\(orphans.count == 1 ? "" : "s")"
    try await ui.progressStep(
        message: "Deleting \(label)",
        successMessage: "Deleted \(label)",
        errorMessage: "Deleting \(label) failed",
        showSpinner: true)
    { _ in
        try SimCtl.deleteDevices(orphans)
    }
}

/// The ready runtimes no installed Xcode uses, nil when an Xcode cannot tell which runtimes it uses:
/// only an Xcode can say that, so then every runtime stays.
func unusedRuntimes(in registered: [InstalledRuntime]) -> [InstalledRuntime]? {
    var matches: [[RuntimeMatch]] = []
    for xcode in Installed.all() {
        do {
            try matches.append(SimCtl.runtimeMatches(for: xcode))
        } catch {
            ui.warning(WarningAlert(stringLiteral:
                "cannot tell which simulator runtimes \(xcode.name) uses (\(error)); keeping every runtime"))
            return nil
        }
    }
    return Runtimes.unused(by: matches, in: registered)
}

/// Runtimes about to go with their simulators, and how many simulators each has.
func printUnusedRuntimes(_ runtimes: [InstalledRuntime]) {
    let devices = (try? SimCtl.devices()) ?? []
    printTable([["PLATFORM", "VERSION", "BUILD", "SIZE", "SIMULATORS"]] + runtimes.map { runtime in
        let simulators = devices.filter { $0.runtimeIdentifier == runtime.runtimeIdentifier }.count
        return [
            runtime.platform?.display ?? "?",
            runtime.version,
            runtime.build,
            formatBytes(runtime.size),
            String(simulators),
        ]
    })
}

// MARK: - ConfigCommand

struct ConfigCommand: ParsableCommand {
    struct Init: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Write the config file with every key commented out at its default.")

        func run() throws {
            let path = Config.path
            guard !FileManager.default.fileExists(atPath: path.path) else {
                throw Fail("\(path.path) exists; `xcodectl config check` reads it, delete it to start over")
            }
            try FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try Config.template().write(to: path, atomically: true, encoding: .utf8)
            ui.success(SuccessAlert(stringLiteral: "Wrote \(path.path)"))
        }
    }

    struct Check: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Read the config file back: every setting it makes, or what is wrong with it (exit 1).")

        func run() throws {
            let path = Config.path
            guard let config = try Config.load() else {
                throw Fail("no config at \(path.path); `xcodectl config init` writes one")
            }
            let problems = config.problems()
            guard problems.isEmpty else {
                for problem in problems {
                    eprint(problem)
                }
                throw Fail("\(problems.count) problem\(problems.count == 1 ? "" : "s") in \(path.path)")
            }
            let settings = config.effectiveSettings()
            for setting in settings {
                print(setting)
            }
            ui.success(SuccessAlert(stringLiteral: settings.isEmpty
                    ? "\(path.path) sets nothing; every key is commented out" : "\(path.path) is fine"))
        }
    }

    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Defaults for flags and options in ~/.config/xcodectl/config.toml (or XCODECTL_CONFIG).",
        discussion: """
        A [table] per command, keys named like its flags without `--`: `approve = false` under [install] is \
        `install --no-approve` unless --approve is typed. Keys before the first table reach every command that \
        has them. A value that does not fit the run, such as `select = true` for `install 27 26`, is ignored.
        """,
        subcommands: [Init.self, Check.self])
}

// MARK: - RuntimeCommand

struct RuntimeCommand: AsyncParsableCommand {
    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Simulator runtimes Apple offers for this Mac: the newest major of each platform.",
            discussion: """
            --all lists every version. Runtimes from iOS 18, tvOS 18, watchOS 11 and visionOS 2 on need no \
            Apple ID: Apple serves them publicly and the Xcode used installs them. Older ones, back to iOS 16, \
            tvOS 16, watchOS 9 and visionOS 1, are disk images that download with the Apple session.
            """)

        @Argument(help: "ios, tvos, watchos or visionos. Omit for every platform.")
        var platform: RuntimePlatform?

        @Flag(inversion: .prefixedNo, help: "Only final releases.")
        var stable: Bool?

        @Flag(inversion: .prefixedNo, help: "Only betas, rcs and other prereleases.")
        var beta: Bool?

        @Flag(inversion: .prefixedNo, help: "Every version, not just the newest major of each platform.")
        var all: Bool?

        @Flag(inversion: .prefixedNo, help: "Print JSON instead of a table; nothing found is [].")
        var json: Bool?

        func validate() throws {
            guard !(stable == true && beta == true) else {
                throw Fail("--stable and --beta exclude each other")
            }
        }

        func run() async throws {
            let catalog = try await Runtimes.fetch()
            let installed = (try? SimCtl.runtimes()) ?? []
            let kind: Runtimes.Filter =
                stable == true ? .stable : beta == true ? .beta : all == true ? .all : .current
            let shown = all == true
                ? Runtimes.filter(catalog.filter { platform == nil || $0.platform == platform }, kind)
                : Runtimes.defaultListing(catalog, platform: platform, kind)
            guard !shown.isEmpty || json == true else {
                throw Fail("no runtimes match")
            }
            if json == true {
                try printJSON(runtimeJSON(shown, installed: installed))
                return
            }
            printTable(runtimeRows(shown, installed: installed))
        }
    }

    struct ListInstalled: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "installed",
            abstract: "Every simulator runtime registration, leftovers simctl hides included.",
            discussion: """
            `simctl runtime list` shows usable images only, so an interrupted download or a broken image \
            stays invisible there while still holding several gigabytes; `xcodectl runtime prune` deletes \
            those. `xcodectl installed` shows the runtimes each Xcode uses.
            """)

        @Argument(help: "ios, tvos, watchos or visionos. Omit for every platform.")
        var platform: RuntimePlatform?

        @Flag(inversion: .prefixedNo, help: "Print JSON instead of a table; nothing installed is [].")
        var json: Bool?

        func run() throws {
            let installed = try SimCtl.runtimes().filter { platform == nil || $0.platform == platform }
            guard !installed.isEmpty || json == true else {
                throw Fail("no \(platform?.display ?? "simulator") runtime installed")
            }
            if json == true {
                try printJSON(registrationJSON(installed))
                return
            }
            var rows = [["PLATFORM", "VERSION", "BUILD", "SIZE", "STATE", "IDENTIFIER"]]
            for runtime in installed {
                rows.append([
                    runtime.platform?.display ?? "?",
                    runtime.version,
                    runtime.build,
                    formatBytes(runtime.size),
                    runtime.isReady ? "" : runtime.state,
                    runtime.identifier,
                ])
            }
            printTable(rows)
        }
    }

    struct Install: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Install a simulator runtime through the active Xcode or the one --xcode names.",
            discussion: """
            Without a version, the one matching that Xcode. A runtime older than iOS 18 downloads with the \
            Apple session. Through Xcode 27 or newer, one older than iOS 26 downloads from Apple's asset \
            server, without xcodebuild, which no longer offers it.
            """)

        @Argument(help: "ios, tvos, watchos or visionos.")
        var platform: RuntimePlatform

        @Argument(help: "Version or build, e.g. 26.0, or 17 for the newest iOS 17. Omit for the Xcode's own.")
        var version: String?

        @Flag(
            name: .customLong("login"),
            inversion: .prefixedNo,
            help: """
            Open the sign-in window when the Apple session is missing or expired (only at a terminal). \
            Only runtimes older than iOS 18 need it.
            """)
        var autologin: Bool?

        @Option(
            help: "Install through this Xcode instead of the active one.",
            completion: .custom(completeInstalledVersion))
        var xcode: String?

        func run() async throws {
            let host = try await runtimeHost(xcode)
            guard let version else {
                try await downloadRuntime(platform, label: "\(platform.display) runtime", using: host)
                return
            }
            let runtime = try await Runtimes.resolve(version, platform: platform, in: Runtimes.fetch())
            guard runtime.runs(onXcode: host.version) else {
                throw Fail("\(runtime.display) (\(runtime.build)) needs a different Xcode than \(host.name) "
                    + "(\(host.version)); see `xcodectl runtime list \(platform.rawValue) --all`")
            }
            if let source = runtime.source {
                try await installDiskImageRuntime(runtime, from: source, autologin: autologin ?? true, using: host)
                return
            }
            if runtime.installsFromAssetServer(onXcode: host.version) {
                try await installAssetRuntime(runtime, using: host)
                return
            }
            try await downloadRuntime(
                platform,
                build: runtime.build,
                appleSiliconOnly: runtime.isAppleSiliconOnly,
                label: "\(runtime.display) (\(runtime.build))",
                using: host)
        }
    }

    struct Remove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Delete an installed simulator runtime: the version or build given, else one picked from a list.")

        @Argument(help: "ios, tvos, watchos or visionos. Omit to pick from every installed runtime.")
        var platform: RuntimePlatform?

        @Argument(help: "Version or build. Omit for a picker.")
        var version: String?

        func run() async throws {
            let candidates = try SimCtl.runtimes().filter { platform == nil || $0.platform == platform }
            guard let version else {
                try await removeRuntimes([pickInstalledRuntime("Remove which runtime?", from: candidates)])
                return
            }
            let text = version.lowercased()
            let hits = candidates.filter { $0.version.lowercased() == text || $0.build.lowercased() == text }
            guard !hits.isEmpty else {
                throw Fail("no installed runtime matching \"\(version)\"; see `xcodectl runtime installed`")
            }
            try await removeRuntimes(hits)
        }
    }

    struct Prune: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Delete simulator runtime registrations that are no longer usable but still take disk space.",
            discussion: """
            --unused also deletes every ready runtime no installed Xcode uses, older OS versions kept for \
            testing included, with the simulators on it. A simulator stays when another build of its OS \
            version is still installed.
            """)

        @Flag(
            inversion: .prefixedNo,
            help: "Also delete every ready runtime no installed Xcode uses, with the simulators on it.")
        var unused: Bool?

        @Flag(help: "List what would go without deleting anything.")
        var dryRun = false

        func run() async throws {
            let registered = try SimCtl.runtimes()
            let leftovers = registered.filter { !$0.isReady }
            let notInUse = unused == true ? unusedRuntimes(in: registered) ?? [] : []
            guard !leftovers.isEmpty || !notInUse.isEmpty else {
                ui.success(SuccessAlert(stringLiteral: "Nothing to prune"))
                return
            }
            guard !dryRun else {
                if !leftovers.isEmpty {
                    let total = leftovers.reduce(0) { $0 + $1.size }
                    printTable([["PLATFORM", "VERSION", "BUILD", "SIZE", "STATE"]] + leftovers.map {
                        [$0.platform?.display ?? "?", $0.version, $0.build, formatBytes($0.size), $0.state]
                    })
                    ui.info(InfoAlert(stringLiteral:
                        "\(formatBytes(total)) in \(leftovers.count) leftover registrations"))
                }
                if !notInUse.isEmpty {
                    printUnusedRuntimes(notInUse)
                    ui.info(InfoAlert(stringLiteral: "--unused would delete \(notInUse.count) unused runtime"
                            + "\(notInUse.count == 1 ? "" : "s") with the simulators on them"))
                }
                return
            }
            try await removeRuntimes(leftovers)
            if !notInUse.isEmpty {
                try await removeRuntimes(notInUse, simulators: true)
            }
        }
    }

    static let configuration = CommandConfiguration(
        commandName: "runtime",
        abstract: "List, install, remove and prune simulator runtimes.",
        subcommands: [List.self, ListInstalled.self, Install.self, Remove.self, Prune.self],
        aliases: ["runtimes"])
}

// MARK: - Reference

struct Reference: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Print the help of every command and subcommand.")

    /// Every command `--help` shows, the root first, each headed by the words that invoke it.
    static func text() -> String {
        commands(XcodeCtl.self, path: [])
            .map { command in
                let help = XcodeCtl.helpMessage(for: command.command).trimmingCharacters(in: .whitespacesAndNewlines)
                return "# \(command.invocation)\n\n\(help)"
            }
            .joined(separator: "\n\n")
    }

    func run() {
        print(Self.text())
    }

    private static func commands(
        _ command: ParsableCommand.Type,
        path: [String])
        -> [(invocation: String, command: ParsableCommand.Type)]
    {
        guard command.configuration.shouldDisplay else {
            return []
        }
        let words = path + [command._commandName]
        return [(words.joined(separator: " "), command)]
            + command.configuration.subcommands.flatMap { commands($0, path: words) }
    }
}
