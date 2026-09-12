//
// Copyright (c) 2026 Daniel Bauke
//

import ArgumentParser
import Foundation
import Noora

// MARK: - XcodeCtl

@main
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
            Install.self,
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
    let installed = Installed.all()
    let active = Installed.activePath()?.standardizedFileURL.path
    var rows = [["VERSION", "BUILD", "RELEASED", "STATUS"]]
    for r in releases {
        var status = ""
        if let hit = installed.first(where: { $0.build.lowercased() == r.build.lowercased() }) {
            status = hit.path.standardizedFileURL.path == active ? "* active" : "installed"
        }
        rows.append([r.display, r.build, r.dateString, status])
    }
    return rows
}

// MARK: - Login

struct Login: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Sign in to Apple Developer in a window; keeps the session in your Keychain.",
        discussion: "Two-factor codes (trusted device, SMS) work. Security keys and passkeys cannot be used in an embedded web view.")

    func run() async throws {
        let cookies = try await MainActor.run { try LoginWindow().run() }.map(Cookie.init)
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
            abstract: "Available Xcode versions (latest major + newest beta major; regex searches everything).")

    @Argument(help: "Regex matched against version and build, e.g. '26\\.[45]' or '27.*beta'.")
    var pattern: String?

    func run() async throws {
        let all = try await Releases.fetch()
        let shown = try pattern.map { try Releases.search(all, regex: $0) } ?? Releases.defaultListing(all)
        guard !shown.isEmpty else {
            throw Fail("nothing matches \(pattern ?? "")")
        }
        printTable(releaseRows(shown))
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

// MARK: - Install

struct Install: AsyncParsableCommand {
    static let configuration =
        CommandConfiguration(abstract: "Download and install an Xcode version into /Applications.")

    @Argument(help: "26.1, 27, 27-rc1, '27 beta 3', 27A266a, latest, latest-beta. Omit for a picker.")
    var version: String?

    @Flag(help: "Run `approve` afterwards (needs sudo).")
    var approve = false

    @Flag(help: "Run `select` afterwards (needs sudo).")
    var select = false

    func run() async throws {
        let releases = try await Releases.fetch()
        let release: Release
        if let version {
            let (r, note) = try Query(version).resolve(in: releases)
            if let note {
                ui.info(InfoAlert(stringLiteral: note))
            }
            release = r
        } else {
            release = try pickRelease(releases)
        }

        let xcode: InstalledXcode
        if let existing = Installed.find(build: release.build) {
            ui.info(InfoAlert(stringLiteral: "Xcode \(release.display) is already installed at \(existing.path.path)"))
            xcode = existing
        } else {
            xcode = try await install(release)
        }

        if approve {
            try Installer.approve(xcode)
        }
        if select {
            try Installer.select(xcode)
        }
        if !approve, !select {
            ui
                .info(
                    InfoAlert(
                        stringLiteral: "next: `xcodectl approve \(release.display)` (license, first launch; needs sudo) and `xcodectl select \(release.display)`"))
        }
    }

    private func pickRelease(_ releases: [Release]) throws -> Release {
        let installed = Installed.all().map { $0.build.lowercased() }
        var choices: [Choice<Release>] = []
        if let stable = releases.first(where: \.isFinal) {
            choices.append(choice(stable, "latest", installed))
        }
        if let pre = releases.first(where: { !$0.isFinal }),
           let stable = releases.first(where: \.isFinal),
           pre.dateString > stable.dateString
        {
            choices.append(choice(pre, "latest beta", installed))
        }
        return try pick("Which Xcode?", from: choices)
    }

    private func choice(_ r: Release, _ label: String, _ installed: [String]) -> Choice<Release> {
        let mark = installed.contains(r.build.lowercased()) ? "  (installed)" : ""
        return Choice(description: "\(r.display)  \(r.build)  \(r.dateString)  \(label)\(mark)", value: r)
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
        let xcode = try await Installed.resolve(version)
        let wasActive = Installed.isActive(xcode)
        try await ui.progressStep(
            message: "Removing \(xcode.name)",
            successMessage: "Removed \(xcode.name)",
            errorMessage: "Remove failed",
            showSpinner: true)
        { _ in
            try Installer.remove(xcode)
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
