//
// Copyright (c) 2026 Daniel Bauke
//

import AnyLanguageModel
import Foundation

// MARK: - ReleaseNotes

enum ReleaseNotes {
    /// One list item or paragraph, with the `##` and deeper heading lines above it.
    struct Block: Equatable {
        let path: [String]
        let text: String
    }

    /// Foreground colors of the rendered notes, as SGR parameters.
    struct Theme: Equatable {
        /// The terminal's own palette, for terminals without 24-bit color.
        static let ansi = Theme(
            title: "35", section: "34", bullet: "36", code: "33", link: "34", added: "32", removed: "31")

        /// "GitHub Dark" of Gogh, on a dark background.
        static let dark = Theme(
            title: rgb(0xDB61A2), section: rgb(0x6CA4F8), bullet: rgb(0x2B7489), code: rgb(0xE3B341),
            link: rgb(0x6CA4F8), added: rgb(0x56D364), removed: rgb(0xF78166))

        /// "Github Light" of Gogh, on a light background.
        static let light = Theme(
            title: rgb(0x8250DF), section: rgb(0x0969DA), bullet: rgb(0x1B7C83), code: rgb(0x9A6700),
            link: rgb(0x0969DA), added: rgb(0x1A7F37), removed: rgb(0xCF222E))

        let title: String
        let section: String
        let bullet: String
        let code: String
        let link: String
        let added: String
        let removed: String

        /// XCODECTL_THEME=dark|light decides; otherwise the background the terminal reports, dark when
        /// it reports none.
        static func current() -> Theme {
            let environment = ProcessInfo.processInfo.environment
            guard ["truecolor", "24bit"].contains(environment["COLORTERM"]) else {
                return ansi
            }
            switch environment["XCODECTL_THEME"] {
            case "light":
                return light

            case "dark":
                return dark

            default:
                return terminalBackground().flatMap(isLight) == true ? light : dark
            }
        }

        /// Whether an OSC 11 reply such as "\u{1B}]11;rgb:f6f6/f8f8/fafa\u{07}" names a light color.
        static func isLight(_ reply: String) -> Bool? {
            guard let match = reply.firstMatch(of: #/rgb:([0-9a-fA-F]{2,4})\/([0-9a-fA-F]{2,4})\/([0-9a-fA-F]{2,4})/#)
            else {
                return nil
            }
            let channels = [match.1, match.2, match.3].map { Double(Int($0.prefix(2), radix: 16) ?? 0) }
            return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2] > 127
        }

        private static func rgb(_ hex: Int) -> String {
            "38;2;\(hex >> 16);\((hex >> 8) & 0xFF);\(hex & 0xFF)"
        }

        /// The terminal's reply to an OSC 11 background query; nil when it stays silent for 0.2 s.
        private static func terminalBackground() -> String? {
            let tty = open("/dev/tty", O_RDWR | O_NOCTTY)
            var original = termios()
            guard tty >= 0, tcgetattr(tty, &original) == 0 else {
                return nil
            }
            defer {
                tcsetattr(tty, TCSANOW, &original)
                close(tty)
            }
            // The reply arrives as input: read it byte by byte, unechoed. macOS cannot poll() a
            // terminal, so the read itself times out (VTIME counts tenths of a second).
            var raw = original
            raw.c_lflag &= ~tcflag_t(ICANON | ECHO)
            withUnsafeMutableBytes(of: &raw.c_cc) { controls in
                controls[Int(VMIN)] = 0
                controls[Int(VTIME)] = 2
            }
            tcsetattr(tty, TCSANOW, &raw)
            let query = "\u{1B}]11;?\u{1B}\\"
            write(tty, query, query.utf8.count)
            var reply = ""
            var byte: UInt8 = 0
            while !reply.hasSuffix("\u{07}"), !reply.hasSuffix("\u{1B}\\"), read(tty, &byte, 1) == 1 {
                reply.unicodeScalars.append(UnicodeScalar(byte))
            }
            return reply.isEmpty ? nil : reply
        }
    }

    /// Apple serves a documentation page as Markdown under the same URL plus ".md". Older notes are
    /// archived HTML or PDFs behind the login and have no such form.
    static func markdownURL(_ release: Release) throws -> URL {
        guard let url = release.notesURL else {
            throw Fail("no release notes link for Xcode \(release.display)")
        }
        guard url.host == "developer.apple.com", url.path.hasPrefix("/documentation/") else {
            throw Fail("release notes of Xcode \(release.display) are not available as text: \(url.absoluteString)")
        }
        return url.appendingPathExtension("md")
    }

    static func fetch(_ release: Release) async throws -> String {
        let url = try markdownURL(release)
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, http.mimeType == "text/markdown" else {
            throw Fail("cannot fetch the release notes of Xcode \(release.display) from \(url.absoluteString)")
        }
        return clean(String(decoding: data, as: UTF8.self))
    }

    /// Drops the metadata comment above the title and the copyright footer.
    static func clean(_ markdown: String) -> String {
        var text = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("<!--"), let end = text.range(of: "-->") {
            text = String(text[end.upperBound...])
        }
        if let rule = text.range(of: "\n---\n", options: .backwards), text[rule.upperBound...].contains("Copyright") {
            text = String(text[..<rule.lowerBound])
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Markdown without its markup: link targets, emphasis, code marks and heading hashes.
    static func plain(_ markdown: String) -> String {
        markdown.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
            .map { line in
                guard let level = headingLevel(line) else {
                    return line
                }
                let title = String(line.dropFirst(level + 1))
                return level <= 3 ? title.uppercased() : title
            }
            .joined(separator: "\n")
            .replacing(#/\[([^\]]*)\]\([^)]*\)/#) { String($0.1) }
            .replacing(#/\*\*(.+?)\*\*/#) { String($0.1) }
            .replacing(#/`([^`]*)`/#) { String($0.1) }
    }

    /// Markdown as terminal text: colored headings and bullets, bold, italic, code, and links as
    /// OSC 8 hyperlinks. With `diff`, the "+" and "-" marks of a comparison take the added and removed colors.
    static func rendered(_ markdown: String, diff: Bool = false, theme: Theme) -> String {
        var inCode = false
        return markdown.components(separatedBy: "\n").compactMap { line -> String? in
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                inCode.toggle()
                return nil
            }
            if inCode {
                return "\u{1B}[\(theme.code)m\(line)\u{1B}[39m"
            }
            if let level = headingLevel(line) {
                let style = [1: "1;4;\(theme.title)", 2: "1;\(theme.title)", 3: "1;\(theme.section)"][level] ?? "1"
                return "\u{1B}[\(style)m\(plain(String(line.dropFirst(level + 1))))\u{1B}[0m"
            }
            if diff, line.hasPrefix("+ ") || line.hasPrefix("- ") {
                let color = line.hasPrefix("+") ? theme.added : theme.removed
                return "\u{1B}[1;\(color)m\(line.prefix(1))\u{1B}[0m " + inline(String(line.dropFirst(2)), theme)
            }
            let indent = line.prefix { $0 == " " }
            if line.dropFirst(indent.count).hasPrefix("- ") {
                return indent + "\u{1B}[\(theme.bullet)m•\u{1B}[39m "
                    + inline(String(line.dropFirst(indent.count + 2)), theme)
            }
            return inline(line, theme)
        }.joined(separator: "\n")
    }

    static func title(_ markdown: String) -> String? {
        markdown.components(separatedBy: "\n").first { headingLevel($0) == 1 }
    }

    static func blocks(_ markdown: String) -> [Block] {
        var path: [String] = []
        var blocks: [Block] = []
        var current: [String] = []
        var afterBlank = true
        func flush() {
            let text = current.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                blocks.append(Block(path: path, text: text))
            }
            current = []
        }
        for line in markdown.components(separatedBy: "\n") {
            if let level = headingLevel(line) {
                flush()
                path.removeAll { (headingLevel($0) ?? 0) >= level }
                if level > 1 {
                    path.append(line)
                }
                afterBlank = true
                continue
            }
            // Indented and blank lines continue a list item: its workaround, sub-list or code.
            if line.hasPrefix("- ") || (afterBlank && !line.isEmpty && !line.hasPrefix(" ")) {
                flush()
            }
            current.append(line)
            afterBlank = line.trimmingCharacters(in: .whitespaces).isEmpty
        }
        flush()
        return blocks
    }

    /// Markdown of what `new` adds ("+") and drops ("-") compared to `old`, under the headings of each
    /// change; nil when the two hold the same blocks.
    static func diff(old: [Block], new: [Block]) -> String? {
        func key(_ block: Block) -> String {
            (block.path + block.text.split(whereSeparator: \.isWhitespace).map(String.init)).joined(separator: " ")
        }
        let oldKeys = Set(old.map(key))
        let newKeys = Set(new.map(key))
        var paths: [[String]] = []
        for block in new + old where !paths.contains(block.path) {
            paths.append(block.path)
        }
        var lines: [String] = []
        var shown: [String] = []
        for path in paths {
            let added = new.filter { $0.path == path && !oldKeys.contains(key($0)) }
            let removed = old.filter { $0.path == path && !newKeys.contains(key($0)) }
            guard !added.isEmpty || !removed.isEmpty else {
                continue
            }
            lines += headings(of: path, after: shown)
            shown = path
            for (mark, blocks) in [("+ ", added), ("- ", removed)] {
                for block in blocks {
                    lines += [mark + (block.text.hasPrefix("- ") ? String(block.text.dropFirst(2)) : block.text), ""]
                }
            }
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Links inside the notes are relative to the documentation site.
    private static let site = URL(string: "https://developer.apple.com")

    /// One line with its inline Markdown as escape sequences. Foundation parses; the styles switch
    /// off one by one, so a style around them stays on.
    private static func inline(_ line: String, _ theme: Theme) -> String {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard let parsed = try? AttributedString(markdown: line, options: options) else {
            return line
        }
        return parsed.runs.map { run in
            var text = String(parsed[run.range].characters)
            let intent = run.inlinePresentationIntent ?? []
            for (flag, on, off) in [
                (InlinePresentationIntent.stronglyEmphasized, "1", "22"),
                (.emphasized, "3", "23"),
                (.code, theme.code, "39"),
            ] where intent.contains(flag) {
                text = "\u{1B}[\(on)m\(text)\u{1B}[\(off)m"
            }
            if let link = run.link, let url = URL(string: link.absoluteString, relativeTo: site) {
                text = "\u{1B}]8;;\(url.absoluteString)\u{1B}\\\u{1B}[4;\(theme.link)m\(text)\u{1B}[24;39m\u{1B}]8;;\u{1B}\\"
            }
            return text
        }.joined()
    }

    private static func headingLevel(_ line: String) -> Int? {
        let hashes = line.prefix { $0 == "#" }.count
        return (1 ... 6).contains(hashes) && line.dropFirst(hashes).hasPrefix(" ") ? hashes : nil
    }

    /// The heading lines of `path` that differ from the ones last shown, each followed by a blank line.
    private static func headings(of path: [String], after shown: [String]) -> [String] {
        let common = zip(path, shown).prefix { $0 == $1 }.count
        return path[common...].flatMap { [$0, ""] }
    }
}

// MARK: - Model

extension ReleaseNotes {
    /// The model behind --abridged and --ask.
    struct Backend {
        /// What messages call the model.
        let name: String
        let model: any LanguageModel
        let options: GenerationOptions
    }

    private static let summaryInstructions = """
    You write the summary of the release notes of one Xcode version. In one minute the reader wants \
    to know whether to upgrade and what will affect daily work.

    The reader is a typical developer of apps for iOS, macOS and the other Apple platforms: writes \
    Swift with SwiftUI or UIKit, uses Swift packages, builds with Xcode's default settings, debugs \
    and tests on simulators and devices, and ships through the App Store. The reader works on an \
    Apple silicon Mac and keeps macOS reasonably current.

    The message holds the complete release notes as Markdown. They list new features, known issues, \
    resolved issues and deprecations by area of Xcode.

    Test every candidate bullet with one question: would this reader do or decide something \
    differently this month because of it? Keep the bullet only when the answer is clearly yes. \
    Rank what is left by how many such readers it affects, then by how badly.

    Leave out, however severe the notes make them sound:
    - C, C++ and Objective-C++: the C++ standard library, Clang, module maps, Swift and C++ interoperability.
    - Linkers, compiler and linker flags, custom toolchains, build system internals.
    - Changes in how Xcode does its work inside, such as a new compilation mode, cache or scanner, \
    when projects keep building and the reader has nothing to do. An opt-out setting does not make \
    such a change worth a bullet.
    - Intel Macs, x86_64, Rosetta, Universal binaries. That transition ended years ago and is not news.
    - DriverKit, kernel extensions, Metal and game engine internals, other niche frameworks.
    - Command line tools and their output formats, unless most app developers run them by hand.
    - Fixes to problems few readers met, and anything the reader cannot act on.
    - Versions of bundled SDKs, compilers and tools. Give a version number only where the reader must act on it.

    Reply in Markdown with these headings, in this order, and nothing before or after them:

    ## Before you upgrade
    Only what can stop this reader from upgrading or needs a decision first: the macOS this Xcode \
    requires, the OS versions of devices and simulators it stops supporting, and changed defaults \
    that break the build of a typical app project or silently change its results: what gets \
    localized, tested, signed or shipped. Often this is the requirements bullet alone. Not \
    deprecations, not new features, not changed defaults where everything keeps working as before.
    ## Known issues
    Open problems in everyday work: building, signing, debugging, previews, simulators, devices, \
    testing, Swift packages, the editor. Give the workaround when the notes have one.
    ## New
    Features this reader would change habits for.
    ## Fixed
    Resolved issues that got in the way of everyday work in earlier versions, the reason to take a \
    bug fix release.
    ## Deprecated
    Swift and Apple framework APIs and Xcode features this reader is likely to use today and has to \
    migrate from.

    The descriptions under the headings above are for you; do not repeat them. When nothing passes \
    under a heading, write the heading alone, with no bullet and no remark such as "None".

    Group the changes under a heading by area of Xcode, the most important area first:
    - An area with one change is one bullet: the area in bold, a colon, then the change.
    - An area with several changes is a bullet with only the area in bold, and under it one \
    bullet for each change, indented by two spaces. Coding Intelligence, Previews, Device Hub and \
    Testing often have several.
    An area appears once under a heading: a second bullet that starts with the same area is an \
    error. The form is:

    - **Simulator:** The one change of this area.
    - **Previews:**
      - The first change of this area.
      - The second change of this area.

    A heading holds at most six areas and an area at most four changes; when more pass the test, \
    keep those that affect the most readers. These are limits and not numbers to reach: a summary \
    is not a catalog, and a change that does not clearly pass the test is left out.

    Each change is one sentence of at most 30 words that says what changed. Add what to do about it \
    only when the notes say so, as a workaround, a setting or a replacement; never advice of your \
    own. One bullet holds one change; do not pack a list of fixes or features into it. Write the \
    names of APIs, tools, settings and flags as the notes do, letter for letter, in backticks. \
    Every statement must be in the notes: when unsure that the notes say it, leave it out. Do not \
    guess at causes or consequences.
    """

    private static let answerInstructions = """
    You answer a question about one Xcode version from its complete release notes, for a developer \
    of apps for Apple platforms. Use only facts from the notes and quote version numbers exactly. \
    Answer in one to three sentences. If the notes hold nothing about the question, say that the \
    release notes do not cover it.
    """

    /// The model of `hosted`.
    static func backend(_ hosted: HostedModel) -> Backend {
        let name = hosted.model ?? hosted.defaultModel
        var fields: [String: JSONValue] = [:]
        // A little reasoning files the changes under the right headings; more only takes longer, and
        // some models reason for minutes unless told otherwise. OpenRouter drops the field for a
        // model without reasoning; OpenAI rejects it there, so only its default model gets it.
        if hosted.provider == .openrouter, hosted.baseURL == hosted.provider.api.baseURL {
            fields["reasoning"] = ["effort": "low"]
        } else if hosted.model == nil {
            fields["reasoning_effort"] = "low"
        }
        var options = GenerationOptions()
        options[custom: OpenAILanguageModel.self] = .init(extraBody: fields)
        return Backend(
            name: ([name, "on", hosted.place] + [hosted.keyVariable.map { "(\($0))" }].compactMap(\.self))
                .joined(separator: " "),
            model: OpenAILanguageModel(baseURL: hosted.baseURL, apiKey: hosted.apiKey, model: name),
            options: options)
    }

    /// Markdown of the title and the model's summary of the whole notes.
    static func abridge(_ markdown: String, with backend: Backend) async throws -> String {
        let summary = try await reply(to: markdown, instructions: summaryInstructions, with: backend, or: "summary")
        let misspelled = unknownNames(in: summary, notes: markdown).map { "`\($0)`" }.joined(separator: ", ")
        let warning = misspelled
            .isEmpty ? [] : ["**Check against the notes:** they do not hold \(misspelled) as written."]
        return ([title(markdown)].compactMap(\.self) + [withoutEmptyHeadings(summary)] + warning)
            .joined(separator: "\n\n")
    }

    /// The code spans of a summary with a word the notes do not hold. A model sometimes misspells
    /// the name of a setting or an API.
    static func unknownNames(in summary: String, notes: String) -> [String] {
        let known = notes.replacingOccurrences(of: "`", with: "")
        return summary.matches(of: #/`([^`]+)`/#).map { String($0.1) }.filter { name in
            name.split { $0.isWhitespace || $0 == "=" }.contains { $0.count > 3 && !known.contains($0) }
        }
    }

    /// Markdown without the headings that have nothing under them. Models print the headings they
    /// were given even when told to leave out the empty ones.
    static func withoutEmptyHeadings(_ markdown: String) -> String {
        var kept: [String] = []
        for line in markdown.components(separatedBy: "\n").reversed() {
            let next = kept.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            if let level = headingLevel(line), next.map({ (headingLevel($0) ?? 7) <= level }) ?? true {
                kept = Array(kept.drop { $0.trimmingCharacters(in: .whitespaces).isEmpty })
                continue
            }
            kept.insert(line, at: 0)
        }
        return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The model's answer to a question, from the whole notes.
    static func answer(_ question: String, from markdown: String, with backend: Backend) async throws -> String {
        // The question stands on both sides of the notes, so that it is not lost behind them.
        try await reply(
            to: ["Question: \(question)", markdown, "Question: \(question)"].joined(separator: "\n\n"),
            instructions: answerInstructions, with: backend, or: "answer")
    }

    private static func reply(
        to prompt: String, instructions: String, with backend: Backend, or missing: String) async throws
        -> String
    {
        do {
            let session = LanguageModelSession(model: backend.model, instructions: instructions)
            return try await session.respond(to: prompt, options: backend.options).content
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            // The errors of a hosted model are not localized; they describe themselves, with the JSON reply of the API.
            let reason = ((error as? LocalizedError)?.errorDescription ?? "\(error)")
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            throw Fail("\(backend.name) gave no \(missing): \(reason)")
        }
    }
}
