//
// Copyright (c) 2026 Daniel Bauke
//

import Foundation

#if canImport(FoundationModels)
    import FoundationModels
#endif

// MARK: - ReleaseNotes

enum ReleaseNotes {
    /// One list item or paragraph, with the `##` and deeper heading lines above it.
    struct Block: Equatable {
        let path: [String]
        let text: String
    }

    /// Blocks of one `###` section that fit a single model request.
    struct Chunk: Equatable {
        let heading: String?
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

    /// Characters of notes per model request. The on-device model holds 4096 tokens, prompt and reply together.
    static let chunkLimit = 6000

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

    static func chunks(_ blocks: [Block], limit: Int = chunkLimit) -> [Chunk] {
        var chunks: [Chunk] = []
        var heading: String?
        var lines: [String] = []
        var shown: [String] = []
        func flush() {
            if !lines.isEmpty {
                let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                chunks.append(Chunk(heading: heading, text: text))
            }
            lines = []
            shown = []
        }
        for block in blocks {
            let section = block.path.last { (headingLevel($0) ?? 0) <= 3 }
            let below = block.path.filter { (headingLevel($0) ?? 0) > 3 }
            if section != heading || lines.joined(separator: "\n").count + block.text.count > limit {
                flush()
                heading = section
            }
            lines += headings(of: below, after: shown) + [block.text, ""]
            shown = below
        }
        flush()
        return chunks
    }

    /// The chunks a question is answered from, in document order: everything above the first `###`
    /// section, then the sections sharing the most words with the question, as many as fit `limit`.
    static func relevant(_ chunks: [Chunk], to question: String, limit: Int = chunkLimit) -> [Chunk] {
        // Five letters of a word match its other forms: "required" finds "requires".
        let stems = Set(question.lowercased().split { !$0.isLetter && !$0.isNumber }.filter { $0.count > 3 }
            .map { $0.prefix(5) })
        func score(_ chunk: Chunk) -> Int {
            guard headingLevel(chunk.heading ?? "") == 3 else {
                return Int.max
            }
            /// A word in the section name outweighs words in its text, which many sections share.
            func hits(_ text: String) -> Int {
                stems.filter { text.lowercased().contains($0) }.count
            }
            return 3 * hits(chunk.heading ?? "") + hits(chunk.text)
        }
        var room = limit
        var kept = Set<Int>()
        for (index, chunk) in chunks.enumerated().sorted(by: { score($0.element) > score($1.element) })
            where score(chunk) > 0 && chunk.text.count <= room
        {
            kept.insert(index)
            room -= chunk.text.count
        }
        return kept.sorted().map { chunks[$0] }
    }

    /// Joins neighbouring pieces into texts of at most `limit` characters; a longer piece stays alone.
    static func packed(_ pieces: [String], limit: Int = chunkLimit) -> [String] {
        pieces.reduce(into: [String]()) { texts, piece in
            if let last = texts.last, last.count + piece.count + 2 <= limit {
                texts[texts.count - 1] = last + "\n\n" + piece
            } else {
                texts.append(piece)
            }
        }
    }

    /// Markdown of the title, the overview as it is, and what the on-device model rates highest in
    /// the sections.
    static func abridge(_ markdown: String) async throws -> String {
        #if canImport(FoundationModels)
            if #available(macOS 26.0, *) {
                try requireModel()
                let all = chunks(blocks(markdown), limit: chunkLimit / 2)
                let overview = all.filter { headingLevel($0.heading ?? "") == 2 }.map(\.text)
                let sections = all.filter { headingLevel($0.heading ?? "") == 3 }
                    .map { [$0.heading, $0.text].compactMap(\.self).joined(separator: "\n\n") }
                let points = try await mostImportant(sections.isEmpty ? overview : sections).map { "- \($0)" }
                return ([title(markdown)].compactMap(\.self) + overview
                    + ["## What matters most", points.joined(separator: "\n")])
                    .joined(separator: "\n\n")
            }
        #endif
        throw Fail(needsModel)
    }

    /// The on-device model's answer to a question, from the parts of the notes that mention its words.
    static func answer(_ question: String, from markdown: String) async throws -> String {
        #if canImport(FoundationModels)
            if #available(macOS 26.0, *) {
                try requireModel()
                return try await answerOnDevice(question, from: markdown)
            }
        #endif
        throw Fail(needsModel)
    }

    private static let needsModel = "--abridged and --ask need macOS 26 or later with Apple Intelligence"

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

#if canImport(FoundationModels)
    @available(macOS 26.0, *)
    extension ReleaseNotes {
        @Generable
        struct Point {
            @Guide(
                description: """
                5 requirement or breaking change, 4 deprecation or known issue, 3 major new feature, \
                2 minor feature, 1 routine fix
                """,
                .range(1 ... 5))
            var importance: Int

            @Guide(description: "The area of Xcode, then what changed, in at most 25 words")
            var text: String
        }

        @Generable
        struct Digest {
            @Guide(description: "The changes that matter most, none repeated", .maximumCount(3))
            var points: [Point]
        }

        private static let instructions = """
        You extract the changes that matter from a part of the Xcode release notes, for a developer \
        who decides whether to upgrade. Keep API, tool and setting names and version numbers. Use only \
        facts from the text.
        """

        private static let answerInstructions = """
        You answer a question about one Xcode version from an excerpt of its release notes. Use only \
        facts from the excerpt and quote version numbers exactly. Answer in one to three sentences. \
        If the excerpt holds nothing about the question, say that the release notes do not cover it.
        """

        private static func requireModel() throws {
            guard case let .unavailable(reason) = SystemLanguageModel.default.availability else {
                return
            }
            switch reason {
            case .deviceNotEligible:
                throw Fail("this Mac does not support Apple Intelligence")

            case .appleIntelligenceNotEnabled:
                throw Fail("Apple Intelligence is off: turn it on in System Settings")

            case .modelNotReady:
                throw Fail("the Apple Intelligence model is not downloaded yet; try again later")

            @unknown default:
                throw Fail("the Apple Intelligence model is not available")
            }
        }

        private static func answerOnDevice(_ question: String, from markdown: String) async throws -> String {
            // Small chunks, so that several sections fit one request.
            let excerpt = relevant(chunks(blocks(markdown), limit: chunkLimit / 4), to: question)
                .map { [$0.heading, $0.text].compactMap(\.self).joined(separator: "\n\n") }
            // The question stands on both sides of the excerpt; the small model loses it otherwise.
            let prompt = (["Question: \(question)", title(markdown) ?? ""] + excerpt + ["Question: \(question)"])
                .joined(separator: "\n\n")
            do {
                let session = LanguageModelSession(instructions: answerInstructions)
                let reply = try await session.respond(to: prompt, options: GenerationOptions(samplingMode: .greedy))
                return reply.content.trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                throw Fail("the on-device model gave no answer: \(error.localizedDescription)")
            }
        }

        /// The model names and rates up to three changes in each part of the notes; the highest rated
        /// ones, in the order of the notes, make the summary. It rates a short text far better than it
        /// picks from a long list.
        private static func mostImportant(_ pieces: [String], count: Int = 10) async throws -> [String] {
            var points: [Point] = []
            for text in packed(pieces, limit: chunkLimit / 2) {
                let session = LanguageModelSession(instructions: instructions)
                // The model sometimes runs on for minutes; a capped reply fails fast and its part is skipped.
                let reply = try? await session.respond(
                    to: text,
                    generating: Digest.self,
                    options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 500))
                points += reply?.content.points.filter { new in !points.contains { $0.text == new.text } } ?? []
            }
            guard !points.isEmpty else {
                throw Fail("the on-device model gave no summary")
            }
            let top = points.enumerated()
                .sorted { ($0.element.importance, $1.offset) > ($1.element.importance, $0.offset) }
                .prefix(count)
            return top.sorted { $0.offset < $1.offset }.map(\.element.text)
        }
    }
#endif
