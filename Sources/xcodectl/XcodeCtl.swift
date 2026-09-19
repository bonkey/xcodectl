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
        abstract: "Install, approve, switch and remove Xcode versions.",
        version: version,
        subcommands: [
            Login.self,
            SessionCommand.self,
            List.self,
            ListInstalled.self,
            ReleaseNotesCommand.self,
            Install.self,
            InstallClt.self,
            Approve.self,
            Select.self,
            Remove.self,
            DownloadURL.self,
        ])
}

let ui = Noora()

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
    if let pre = releases.first(where: { !$0.isFinal }),
       let stable = releases.first(where: \.isFinal),
       pre.dateString > stable.dateString
    {
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
    guard let first = rows.first else {
        return
    }
    let widths = (0 ..< first.count).map { c in rows.map { $0[c].count }.max() ?? 0 }
    for row in rows {
        print(row.enumerated().map { $0.offset == row.count - 1 ? $0.element : $0.element.padding(
            toLength: widths[$0.offset],
            withPad: " ",
            startingAt: 0) }
            .joined(separator: "  ").trimmingCharacters(in: .whitespaces))
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
private func statusOwners(
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

    func run() async throws {
        let window = await MainActor.run { LoginWindow() }
        let cookies = try await window.run().map(Cookie.init)
        let withTicket = try await ui.progressStep(message: "Fetching download ticket") { _ in
            try await Session.refreshTicket(cookies)
        }
        try Session.save(withTicket)
        ui.success("Signed in. Runners: `xcodectl session export` here, `xcodectl session import` there.")
    }
}

// MARK: - SessionCommand

struct SessionCommand: AsyncParsableCommand {
    struct Export: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print the session as one base64 line.")

        func run() async throws {
            guard let (cookies, _) = try Session.load() else {
                throw Fail("not signed in: run `xcodectl login`")
            }
            try print(Session.encode(cookies))
        }
    }

    struct Import: AsyncParsableCommand {
        static let configuration =
            CommandConfiguration(abstract: "Read a base64 session from stdin into this machine's Keychain.")

        func run() async throws {
            let blob = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
            let cookies = try Session.decode(blob)
            guard cookies.contains(where: { $0.name == Session.loginCookie })
            else {
                throw Fail("blob has no Apple login session")
            }
            try Session.save(cookies)
            ui.success("Session stored in the Keychain.")
        }
    }

    static let configuration = CommandConfiguration(
        commandName: "session",
        abstract: "Move the Apple session to another machine.",
        subcommands: [Export.self, Import.self])
}

// MARK: - List

struct List: AsyncParsableCommand {
    static let configuration =
        CommandConfiguration(
            abstract: "Available Xcode versions (the two latest majors; regex searches everything).",
            discussion: """
            Without a regex: finals of the two latest majors, plus any prerelease newer than the newest \
            final. --stable keeps finals only, --beta keeps prereleases only. A regex searches every \
            release; --stable / --beta narrow the matches.
            """)

    @Argument(help: "Regex matched against version and build, e.g. '26\\.[45]' or '27.*beta'.")
    var pattern: String?

    @Flag(help: "Only final releases.")
    var stable = false

    @Flag(help: "Only betas, rcs and other prereleases.")
    var beta = false

    func validate() throws {
        guard !(stable && beta) else {
            throw Fail("--stable and --beta exclude each other")
        }
    }

    func run() async throws {
        async let requirements = SystemRequirements.fetch()
        let all = try await Releases.fetch()
        let shown: [Release] =
            if let pattern {
                try Releases.filter(Releases.search(all, regex: pattern), stable ? .stable : beta ? .beta : .all)
            } else {
                Releases.defaultListing(all, stable ? .stable : beta ? .beta : .current)
            }
        guard !shown.isEmpty else {
            throw Fail("nothing matches \(pattern ?? "")")
        }
        let marks = await Compatibility.column(shown, requirements: requirements)
        printTable(zip(releaseRows(shown), marks).map { $0 + [$1] })
    }
}

// MARK: - ListInstalled

struct ListInstalled: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list-installed",
        abstract: "Xcode versions in /Applications.")

    func run() async throws {
        let installed = Installed.all()
        guard !installed.isEmpty else {
            throw Fail("no Xcode installed in /Applications")
        }
        var rows = [["VERSION", "BUILD", "PATH", ""]]
        for x in installed {
            rows.append([x.version, x.build, x.path.path, Installed.isActive(x) ? "* active" : ""])
        }
        printTable(rows)
    }
}

// MARK: - ReleaseNotesCommand

struct ReleaseNotesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "release-notes",
        abstract: "Show the release notes of an Xcode version, or what changed between two.",
        discussion: """
        With a second version: the list items and paragraphs its notes add (+) and drop (-) compared \
        to the first. --abridged and --ask send the notes to a model: OpenRouter or OpenAI with the key \
        in OPENROUTER_API_KEY or OPENAI_API_KEY, or a server of your own with --base-url and --model.
        """)

    @Argument(help: "Xcode version, same forms as `install`. Omit for a picker.")
    var version: String?

    @Argument(help: "A second version to compare the first with.")
    var other: String?

    @Flag(help: "Print the Markdown as Apple serves it. Default: rendered for the terminal.")
    var markdown = false

    @Flag(help: "Print plain text, without markup or colors; the default when the output is not a terminal.")
    var plain = false

    @Flag(help: "A summary for a developer of apps, written by a model.")
    var abridged = false

    @Option(help: "Answer a question about the notes with a model, e.g. \"which macOS is required?\"")
    var ask: String?

    @Option(help: "Environment variable holding the API key. Default: OPENROUTER_API_KEY, then OPENAI_API_KEY.")
    var keyEnv: String?

    @Option(help: "API the key belongs to. Default: by the variable that is set, else openai.")
    var provider: Provider?

    @Option(
        name: .customLong("base-url"),
        help: "Another OpenAI-compatible API, e.g. Ollama at http://localhost:11434/v1; needs --model, not a key.")
    var baseURL: String?

    @Option(help: "Model id. Default: gpt-5.6-luna.")
    var model: String?

    func validate() throws {
        guard [abridged, ask != nil, other != nil].filter(\.self).count <= 1 else {
            throw Fail("--abridged, --ask and a second version exclude each other")
        }
        guard !(markdown && plain) else {
            throw Fail("--markdown and --plain exclude each other")
        }
        guard abridged || ask != nil || (keyEnv == nil && provider == nil && baseURL == nil && model == nil) else {
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
        } else if abridged || ask != nil {
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
        if markdown {
            print(text)
        } else if plain || isatty(STDOUT_FILENO) != 1 {
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
        CommandConfiguration(abstract: "Download and install an Xcode version into /Applications.")

    @Argument(help: "26.1, 27, 27-rc1, '27 beta 3', 27A266a, latest, latest-beta. Omit for a picker.")
    var version: String?

    @Flag(help: "Skip `approve` (license, first launch; needs sudo). Default: approve after installing.")
    var noApprove = false

    @Flag(help: "Run `select` afterwards (needs sudo).")
    var select = false

    @Flag(help: "Skip upgrading the Command Line Tools to this version (Software Update, needs sudo).")
    var noClt = false

    func run() async throws {
        let release = try await resolveOrPickRelease(version, "Which Xcode?")

        let xcode: InstalledXcode
        if let existing = Installed.find(build: release.build) {
            ui.info(InfoAlert(stringLiteral: "Xcode \(release.display) is already installed at \(existing.path.path)"))
            xcode = existing
        } else {
            xcode = try await install(release)
        }

        if !noApprove {
            try Installer.approve(xcode)
        }
        if !noClt {
            Installer.upgradeCommandLineTools(for: release)
        }
        if select {
            try Installer.select(xcode)
        } else {
            ui.info(InfoAlert(stringLiteral: "next: `xcodectl select \(release.display)` to make it the active Xcode"))
        }
    }

    private func install(_ release: Release) async throws -> InstalledXcode {
        if let required = release.requires, !versionAtLeast(macOSVersion(), required) {
            throw Fail("Xcode \(release.display) needs macOS \(required); this Mac runs \(macOSVersion())")
        }
        guard let url = release.downloadURL else {
            throw Fail("no download link for \(release.display)")
        }
        if FileManager.default.fileExists(atPath: release.installPath.path) {
            throw Fail("\(release.installPath.path) exists but is not Xcode \(release.build); remove it first")
        }

        try Paths.ensureCache()
        let xip = Paths.cache.appendingPathComponent(release.xipName)
        if !FileManager.default.fileExists(atPath: xip.path) {
            let cookies = try await Session.ensureTicket()
            let header = Session.header(cookies, host: url.host!)
            let connections = Int(ProcessInfo.processInfo.environment["XCODECTL_CONNECTIONS"] ?? "") ?? Downloader
                .defaultConnections
            let downloader = Downloader(url: url, cookieHeader: header, destination: xip, connections: connections)
            try await ui.progressBarStep(
                message: "Downloading Xcode \(release.display)",
                successMessage: "Downloaded Xcode \(release.display)",
                errorMessage: "Download failed")
            { update in
                try await downloader.run(progress: update)
            }
        }

        let app = try await ui.progressStep(
            message: "Expanding \(release.xipName)",
            successMessage: "Expanded \(release.xipName)",
            errorMessage: "Expanding failed",
            showSpinner: true)
        { _ in
            try await Installer.expand(xip: xip)
        }
        try Installer.move(app, to: release.installPath)
        try? FileManager.default.removeItem(at: xip)

        guard let xcode = Installed.read(release.installPath) else {
            throw Fail("installed to \(release.installPath.path) but cannot read its version.plist")
        }
        ui.success(SuccessAlert(stringLiteral: "Installed Xcode \(release.display) at \(release.installPath.path)"))
        return xcode
    }
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

    @Argument(help: "Installed version; omit for a picker.")
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

    @Argument(help: "Installed version; omit for a picker.")
    var version: String?

    func run() async throws {
        let xcode = try await resolveOrPick(version, "Select which Xcode?")
        try Installer.select(xcode)
        ui.success(SuccessAlert(stringLiteral: "Active: \(xcode.path.path)"))
    }
}

// MARK: - Remove

struct Remove: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Delete an installed Xcode from /Applications.")

    @Argument(help: "Installed version.")
    var version: String

    func run() async throws {
        let path = try await target()
        let name = path.lastPathComponent
        let wasActive = Installed.isActive(path)
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

// MARK: - DownloadURL

struct DownloadURL: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "_download",
        abstract: "Download any URL with the parallel downloader.",
        shouldDisplay: false)

    @Argument var url: String
    @Argument var destination: String
    @Flag var withTicket = false

    func run() async throws {
        guard let url = URL(string: url) else {
            throw Fail("bad URL")
        }
        var header = ""
        if withTicket {
            let cookies = try await Session.ensureTicket()
            header = Session.header(cookies, host: url.host!)
        }
        let connections = Int(ProcessInfo.processInfo.environment["XCODECTL_CONNECTIONS"] ?? "") ?? Downloader
            .defaultConnections
        let downloader = Downloader(
            url: url,
            cookieHeader: header,
            destination: URL(fileURLWithPath: destination),
            connections: connections)
        try await ui.progressBarStep(
            message: "Downloading \(url.lastPathComponent)",
            successMessage: "Downloaded",
            errorMessage: "Download failed")
        { update in
            try await downloader.run(progress: update)
        }
    }
}
