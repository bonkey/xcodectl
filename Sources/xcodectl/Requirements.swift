//
// Copyright (c) 2026 Daniel Bauke
//

import Foundation
import Noora

// MARK: - SystemRequirements

/// The "Supported macOS Versions" column of Apple's Xcode system requirements page.
enum SystemRequirements {
    /// One row of the page's tables.
    struct Row: Equatable {
        /// "27.1", "26.4.1", "15.0.x"; a beta row ("Xcode 27.1 beta") without its "beta".
        let xcode: String
        /// The newest macOS Apple supports this Xcode on, "26.x" or "26.1.x"; nil for "or later".
        let newestMacOS: String?
    }

    static let url = URL(string: "https://developer.apple.com/xcode/system-requirements/")!

    static var cacheFile: URL {
        Paths.cache.appendingPathComponent("system-requirements.html")
    }

    /// Rows of the live page, else of the last copy that had any; none when neither is there.
    static func fetch() async -> [Row] {
        if let (data, response) = try? await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 10)),
           (response as? HTTPURLResponse)?.statusCode == 200
        {
            let rows = parse(String(decoding: data, as: UTF8.self))
            if !rows.isEmpty {
                try? Paths.ensureCache()
                try? data.write(to: cacheFile, options: .atomic)
                return rows
            }
        }
        guard let cached = try? Data(contentsOf: cacheFile) else {
            return []
        }
        return parse(String(decoding: cached, as: UTF8.self))
    }

    /// Rows of every table whose heading row has an "Xcode" and a "Supported macOS" column.
    static func parse(_ html: String) -> [Row] {
        let version = #/\d+(?:\.(?:\d+|x))*/#
        var columns: (xcode: Int, macOS: Int)?
        var rows: [Row] = []
        for row in html.matches(of: #/(?s)<tr(?:\s[^>]*)?>(.*?)</tr>/#) {
            let cells = row.1.matches(of: #/(?s)<t([hd])(?:\s[^>]*)?>(.*?)</t[hd]>/#)
            let texts = cells.map { text(String($0.2)) }
            if !cells.isEmpty, cells.allSatisfy({ $0.1 == "h" }) {
                columns = texts.firstIndex { $0.contains("Xcode") }.flatMap { xcode in
                    texts.firstIndex { $0.localizedCaseInsensitiveContains("Supported macOS") }.map { (xcode, $0) }
                }
                continue
            }
            guard let columns, max(columns.xcode, columns.macOS) < texts.count,
                  let xcode = texts[columns.xcode].firstMatch(of: version),
                  let newest = texts[columns.macOS].matches(of: version).last
            else {
                continue
            }
            let unbounded = texts[columns.macOS].contains("or later")
            rows.append(Row(xcode: String(xcode.output), newestMacOS: unbounded ? nil : String(newest.output)))
        }
        return rows
    }

    /// The row of `release`: the one of its version (a "27.1 beta" row serves the 27.1 betas), else
    /// one of its major and minor version, as the page lists some only under a patch ("26.4.1", no "26.4").
    static func row(for release: Release, in rows: [Row]) -> Row? {
        let number = release.version.number
        return rows.first { same(number, $0.xcode) } ?? rows.first { same(number, $0.xcode, depth: 2) }
    }

    /// Cell text without tags, entities and runs of whitespace.
    private static func text(_ html: String) -> String {
        html.replacing(#/<[^>]*>|&#?\w+;/#, with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    /// Whether two versions agree in their first `depth` components; a missing component counts as 0
    /// and an "x" matches the rest.
    private static func same(_ a: String, _ b: String, depth: Int = .max) -> Bool {
        let first = a.split(separator: ".")
        let second = b.split(separator: ".")
        for i in 0 ..< min(max(first.count, second.count), depth) {
            let x = i < first.count ? first[i] : "0"
            let y = i < second.count ? second[i] : "0"
            if x == "x" || y == "x" {
                return true
            }
            if Int(x) != Int(y) {
                return false
            }
        }
        return true
    }
}

// MARK: - Compatibility

/// Whether an Xcode release runs on a macOS version, as Apple states it.
enum Compatibility: Equatable {
    case supported
    /// The macOS is older than the release needs.
    case needsMacOS(String)
    /// The macOS is newer than the newest one Apple supports the release on.
    case onlyUpToMacOS(String)
    /// data.json names no minimum, or Apple's page has no row for the release.
    case unknown

    /// The minimum macOS is data.json's `requires`, exact for each beta; the newest is the one of
    /// the release's row on Apple's page.
    init(_ release: Release, macOS: String, requirements: [SystemRequirements.Row]) {
        guard let required = release.requires else {
            self = .unknown
            return
        }
        guard versionAtLeast(macOS, required) else {
            self = .needsMacOS(required)
            return
        }
        guard let row = SystemRequirements.row(for: release, in: requirements) else {
            self = .unknown
            return
        }
        if let newest = row.newestMacOS, !Self.isAtMost(macOS, newest) {
            self = .onlyUpToMacOS(newest)
        } else {
            self = .supported
        }
    }

    /// The macOS versions `release` runs on: "26.2–26.x", "26.6 or later", or "from 12.5" when
    /// Apple's page has no row for it; nil when data.json names no minimum.
    static func range(of release: Release, requirements: [SystemRequirements.Row]) -> String? {
        guard let required = release.requires else {
            return nil
        }
        guard let row = SystemRequirements.row(for: release, in: requirements) else {
            return "from \(required)"
        }
        return row.newestMacOS.map { "\(required)–\($0)" } ?? "\(required) or later"
    }

    /// The `list` column for `releases`: its heading, then a cell per release, empty without a minimum.
    static func column(_ releases: [Release], requirements: [SystemRequirements.Row]) -> [String] {
        let macOS = macOSVersion()
        return ["MACOS"] + releases.map { release in
            range(of: release, requirements: requirements).map {
                ui.format(Compatibility(release, macOS: macOS, requirements: requirements).text(range: $0))
            } ?? ""
        }
    }

    /// "**macOS:** ✗ 26.2–26.x; this Mac runs 27.0.0", a paragraph for the notes of `release`; nil
    /// without a minimum.
    static func line(for release: Release) async -> String? {
        let macOS = macOSVersion()
        let requirements = await SystemRequirements.fetch()
        return range(of: release, requirements: requirements).map {
            let text = Compatibility(release, macOS: macOS, requirements: requirements).text(range: $0)
            return "**macOS:** \(text.plain()); this Mac runs \(macOS)"
        }
    }

    /// `markdown` with `line` as a paragraph under its title, or above everything when it has none.
    static func adding(_ line: String?, to markdown: String) -> String {
        guard let line else {
            return markdown
        }
        let lines = markdown.components(separatedBy: "\n")
        let split = lines.firstIndex { $0.hasPrefix("# ") }.map { $0 + 1 } ?? 0
        let above = lines[..<split].joined(separator: "\n")
        let below = lines[split...].joined(separator: "\n").trimmingCharacters(in: .newlines)
        return [above, line, below].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// Whether `macOS` is at most `newest`, compared on the components `newest` names before its "x":
    /// "27.0.0" is past "26.x", "26.1.3" is within "26.1.x".
    static func isAtMost(_ macOS: String, _ newest: String) -> Bool {
        let limit = newest.split(separator: ".").prefix { $0 != "x" }
        return versionAtLeast(
            limit.joined(separator: "."),
            macOS.split(separator: ".").prefix(limit.count).joined(separator: "."))
    }

    /// `range` behind "✓" when this macOS is in it and "✗" when not; bare when that is unknown.
    func text(range: String) -> TerminalText {
        switch self {
        case .supported:
            "\(.success("✓")) \(.raw(range))"

        case .needsMacOS,
             .onlyUpToMacOS:
            "\(.danger("✗")) \(.raw(range))"

        case .unknown:
            "\(.raw(range))"
        }
    }
}
