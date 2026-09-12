//
// Copyright (c) 2026 Daniel Bauke
//

import Foundation

// MARK: - Release

/// One entry of https://xcodereleases.com/data.json (only the fields we use).
struct Release: Decodable {
    struct Version: Decodable {
        let number: String
        let build: String
        let release: Kind
    }

    /// data.json encodes the kind as a one-key object: {"release":true}, {"beta":3}, {"rc":1}, {"gm":true},
    /// {"gmSeed":2}, {"dp":1}
    struct Kind: Decodable {
        var release: Bool?
        var beta: Int?
        var rc: Int?
        var gm: Bool?
        var gmSeed: Int?
        var dp: Int?
    }

    struct Date: Decodable {
        let year: Int
        let month: Int
        let day: Int
    }

    struct Links: Decodable {
        struct Download: Decodable {
            let url: URL
            let architectures: [String]?
        }

        let download: Download?
    }

    let name: String
    let version: Version
    let date: Date
    let requires: String?
    let links: Links?

    var isFinal: Bool {
        version.release.release == true
    }

    var build: String {
        version.build
    }

    var downloadURL: URL? {
        links?.download?.url
    }

    /// "rc" / "beta" / "gm" / "gmseed" / "dp" or nil for a final release.
    var kindName: String? {
        let k = version.release
        if k.release == true {
            return nil
        }
        if k.rc != nil {
            return "rc"
        }
        if k.beta != nil {
            return "beta"
        }
        if k.gmSeed != nil {
            return "gmseed"
        }
        if k.gm == true {
            return "gm"
        }
        if k.dp != nil {
            return "dp"
        }
        return nil
    }

    var kindNumber: Int? {
        let k = version.release
        return k.rc ?? k.beta ?? k.gmSeed ?? k.dp
    }

    /// "26.1", "27.0-rc1", "27.0-beta3", "15.0-gm"
    var display: String {
        guard let kind = kindName else {
            return version.number
        }
        return "\(version.number)-\(kind)\(kindNumber.map(String.init) ?? "")"
    }

    var dirName: String {
        "Xcode-\(display).app"
    }

    var installPath: URL {
        Paths.applications.appendingPathComponent(dirName)
    }

    var xipName: String {
        "Xcode-\(display).xip"
    }

    var numberComponents: [Int] {
        version.number.split(separator: ".").map { Int($0) ?? 0 }
    }

    var major: Int {
        numberComponents.first ?? 0
    }

    var dateString: String {
        String(format: "%04d-%02d-%02d", date.year, date.month, date.day)
    }
}

// MARK: - Releases

enum Releases {
    static let url = URL(string: "https://xcodereleases.com/data.json")!

    static var cacheFile: URL {
        Paths.cache.appendingPathComponent("data.json")
    }

    /// Fetches the live list; falls back to the last cached copy when offline.
    static func fetch() async throws -> [Release] {
        let data: Data
        do {
            let (fetched, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200
            else {
                throw Fail("xcodereleases.com returned an error")
            }
            data = fetched
            try? Paths.ensureCache()
            try? data.write(to: cacheFile, options: .atomic)
        } catch {
            guard let cached = try? Data(contentsOf: cacheFile) else {
                throw Fail("cannot reach xcodereleases.com (\(error.localizedDescription)) and no cached list yet")
            }
            data = cached
        }
        // Newest first, as served. Only Xcode entries with a download link.
        return try JSONDecoder().decode([Release].self, from: data)
            .filter { $0.name == "Xcode" && $0.downloadURL != nil }
    }

    /// Default `list` set: every version of the latest major with a final release, plus every
    /// version of a newer major that only exists as beta/rc yet.
    static func defaultListing(_ releases: [Release]) -> [Release] {
        let latestFinalMajor = releases.first(where: \.isFinal)?.major ?? 0
        let newestMajor = releases.first?.major ?? 0
        return releases.filter { $0.major == latestFinalMajor || $0.major == newestMajor }
    }

    static func search(_ releases: [Release], regex pattern: String) throws -> [Release] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            throw Fail("invalid regex: \(pattern)")
        }
        func matches(_ s: String) -> Bool {
            re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
        }
        return releases.filter { matches($0.display) || matches($0.build) }
    }
}

// MARK: - Query

/// A user-typed version: "26.1", "27", "27 rc", "27.0-rc1", "27 beta 3", "27A266a", "latest", "latest-beta".
struct Query {
    init(_ raw: String) throws {
        self.raw = raw
        let text = raw.lowercased()
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        switch text {
        case "latest",
             "stable":
            latest = true
            return

        case "latest beta",
             "latestbeta",
             "beta",
             "prerelease",
             "latest prerelease":
            latestBeta = true
            return

        default:
            break
        }
        if text.wholeMatch(of: #/\d{2}[a-z]\d+[a-z]?/#) != nil {
            build = text
            return
        }
        guard let m = text.wholeMatch(of: #/(\d+(?:\.\d+)*)(?:\s*(beta|rc|gm|gmseed|gm seed|dp)\s*(\d+)?)?/#) else {
            throw Fail("cannot understand version \"\(raw)\" (try 26.1, 27, 27-rc1, 27 beta 3, 27A266a, latest)")
        }
        components = m.1.split(separator: ".").map { Int($0) ?? 0 }
        kind = m.2.map { $0.replacingOccurrences(of: " ", with: "") }
        kindNumber = m.3.flatMap { Int($0) }
    }

    private(set) var components: [Int] = []
    private(set) var kind: String?
    private(set) var kindNumber: Int?
    private(set) var build: String?
    private(set) var latest = false
    private(set) var latestBeta = false
    let raw: String

    /// Prefix match on version components, padding the release with zeros ("27" matches 27.0, "27.0.0" matches 27.0).
    func matchesNumber(_ number: String) -> Bool {
        var release = number.split(separator: ".").map { Int($0) ?? 0 }
        while release.count < components.count {
            release.append(0)
        }
        return Array(release.prefix(components.count)) == components
    }

    /// Picks one release. `note` explains a fallback (no final release yet).
    func resolve(in releases: [Release]) throws -> (release: Release, note: String?) {
        if latest {
            guard let r = releases.first(where: \.isFinal) else {
                throw Fail("no final release found")
            }
            return (r, nil)
        }
        if latestBeta {
            guard let r = releases.first(where: { !$0.isFinal }) else {
                throw Fail("no prerelease found")
            }
            return (r, nil)
        }
        if let build {
            guard let r = releases.first(where: { $0.build.lowercased() == build })
            else {
                throw Fail("no Xcode with build \(raw)")
            }
            return (r, nil)
        }
        let candidates = releases.filter { matchesNumber($0.version.number) }
        guard !candidates.isEmpty else {
            throw Fail("no Xcode matching \"\(raw)\"; see `xcodectl list`")
        }
        if let kind {
            let hits = candidates.filter { $0.kindName == kind && (kindNumber == nil || $0.kindNumber == kindNumber) }
            guard let r = hits.first
            else {
                throw Fail(
                    "no Xcode matching \"\(raw)\"; see `xcodectl list \(components.map(String.init).joined(separator: "\\."))`")
            }
            return (r, nil)
        }
        if let r = candidates.first(where: \.isFinal) {
            return (r, nil)
        }
        let r = candidates[0]
        return (r, "no final release for \(raw) yet, using \(r.display)")
    }
}
