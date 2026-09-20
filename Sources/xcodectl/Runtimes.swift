//
// Copyright (c) 2026 Daniel Bauke
//

import Foundation

// MARK: - RuntimePlatform

/// The four platforms Apple ships simulator runtimes for.
enum RuntimePlatform: String, CaseIterable {
    case ios
    case tvos
    case watchos
    case visionos

    init?(identifier: String) {
        // simctl reports the simulator platform ("com.apple.platform.iphonesimulator"), the index the
        // device one ("com.apple.platform.iphoneos"); match on the distinctive part of each.
        let text = identifier.lowercased()
        switch true {
        case text.contains("iphone"): self = .ios
        case text.contains("appletv"),
             text.contains("tvos"): self = .tvos
        case text.contains("watch"): self = .watchos
        case text.contains("xr"),
             text.contains("vision"): self = .visionos
        default: return nil
        }
    }

    /// The `platform` key of an index entry.
    var identifier: String {
        switch self {
        case .ios: "com.apple.platform.iphoneos"
        case .tvos: "com.apple.platform.appletvos"
        case .watchos: "com.apple.platform.watchos"
        case .visionos: "com.apple.platform.xros"
        }
    }

    /// The name `xcodebuild -downloadPlatform` expects.
    var downloadName: String {
        switch self {
        case .ios: "iOS"
        case .tvos: "tvOS"
        case .watchos: "watchOS"
        case .visionos: "visionOS"
        }
    }

    /// Directory under /System/Library/AssetsV2 holding this platform's runtime assets.
    var assetType: String {
        switch self {
        case .ios: "com_apple_MobileAsset_iOSSimulatorRuntime"
        case .tvos: "com_apple_MobileAsset_appleTVOSSimulatorRuntime"
        case .watchos: "com_apple_MobileAsset_watchOSSimulatorRuntime"
        case .visionos: "com_apple_MobileAsset_xrOSSimulatorRuntime"
        }
    }

    var display: String {
        downloadName
    }
}

// MARK: - SimulatorRuntime

/// One downloadable runtime from Apple's index. Only the current format: `cryptexDiskImage`
/// entries delivered as MobileAssets, which is everything from iOS 18, tvOS 18, watchOS 11 and
/// visionOS 2 onwards. The older directly downloadable images are deliberately not listed.
struct SimulatorRuntime: Equatable {
    let name: String
    let platform: RuntimePlatform
    let version: String
    let build: String
    let architectures: [String]
    let size: Int64
    let minXcode: String?
    let maxXcode: String?

    /// Apple marks prereleases in the name only ("tvOS 27.0 beta 4 Simulator Runtime").
    var isBeta: Bool {
        name.range(of: "beta", options: .caseInsensitive) != nil
    }

    /// An artifact built for Apple Silicon alone, as opposed to a universal one that also carries x86_64.
    var isAppleSiliconOnly: Bool {
        architectures == ["arm64"]
    }

    var versionComponents: [Int] {
        version.split(separator: ".").map { Int($0) ?? 0 }
    }

    /// "iOS 26.5", "tvOS 27.0 beta"
    var display: String {
        "\(platform.display) \(version)\(isBeta ? " beta" : "")"
    }

    /// Whether an Xcode may install this runtime. Some prereleases pin themselves to one exact Xcode.
    func runs(onXcode xcodeVersion: String) -> Bool {
        if let minXcode, !versionAtLeast(xcodeVersion, minXcode) {
            return false
        }
        if let maxXcode, !versionAtLeast(maxXcode, xcodeVersion) {
            return false
        }
        return true
    }
}

// MARK: - Runtimes

enum Runtimes {
    enum Filter {
        case current
        case stable
        case beta
        case all
    }

    static let url =
        URL(string: "https://devimages-cdn.apple.com/downloads/xcode/simulators/index2.dvtdownloadableindex")!

    static var cacheFile: URL {
        Paths.cache.appendingPathComponent("index2.dvtdownloadableindex")
    }

    /// Fetches the live index; falls back to the last cached copy when offline.
    /// Needs no Apple session: the index and the runtimes it points at are public.
    static func fetch() async throws -> [SimulatorRuntime] {
        let data: Data
        do {
            let (fetched, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw Fail("Apple's simulator runtime index returned an error")
            }
            data = fetched
            try? Paths.ensureCache()
            try? data.write(to: cacheFile, options: .atomic)
        } catch {
            guard let cached = try? Data(contentsOf: cacheFile) else {
                throw Fail(
                    "cannot reach Apple's simulator runtime index (\(error.localizedDescription)) and no cached copy yet")
            }
            data = cached
        }
        return try parse(data)
    }

    /// Current-format entries of the index, newest version first.
    static func parse(_ data: Data) throws -> [SimulatorRuntime] {
        let index: Index
        do {
            index = try PropertyListDecoder().decode(Index.self, from: data)
        } catch {
            throw Fail("cannot read Apple's simulator runtime index: \(error.localizedDescription)")
        }
        let runtimes = index.downloadables.compactMap { entry -> SimulatorRuntime? in
            guard entry.contentType == "cryptexDiskImage",
                  let platform = entry.platform.flatMap(RuntimePlatform.init(identifier:)),
                  let simulator = entry.simulatorVersion
            else {
                return nil
            }
            return SimulatorRuntime(
                name: entry.name ?? "\(platform.display) \(simulator.version)",
                platform: platform,
                version: simulator.version,
                build: simulator.buildUpdate,
                architectures: entry.architectures ?? [],
                size: entry.fileSize ?? 0,
                minXcode: entry.hostRequirements?.minXcodeVersion,
                maxXcode: entry.hostRequirements?.maxXcodeVersion)
        }
        return sorted(forThisMac(runtimes))
    }

    /// One entry per build. Apple publishes many builds twice, once for Apple Silicon alone and once
    /// universal; this Mac is Apple Silicon, so the arm64-only artifact wins and the universal one is
    /// the fallback for builds that have no arm64-only variant.
    static func forThisMac(_ runtimes: [SimulatorRuntime]) -> [SimulatorRuntime] {
        var best: [String: SimulatorRuntime] = [:]
        for runtime in runtimes {
            let key = "\(runtime.platform.rawValue)/\(runtime.build)"
            guard let chosen = best[key] else {
                best[key] = runtime
                continue
            }
            if runtime.isAppleSiliconOnly, !chosen.isAppleSiliconOnly {
                best[key] = runtime
            }
        }
        return Array(best.values)
    }

    /// Newest first, betas after the release that shares their version.
    static func sorted(_ runtimes: [SimulatorRuntime]) -> [SimulatorRuntime] {
        runtimes.sorted {
            if $0.versionComponents != $1.versionComponents {
                return $0.versionComponents.lexicographicallyPrecedes($1.versionComponents) == false
            }
            if $0.isBeta != $1.isBeta {
                return !$0.isBeta
            }
            return $0.build > $1.build
        }
    }

    /// Default `runtime list` set: the newest major of each platform. `.current` keeps its releases
    /// plus any beta newer than the newest release, so a running beta cycle shows and stale ones do not.
    static func defaultListing(
        _ runtimes: [SimulatorRuntime],
        platform: RuntimePlatform? = nil,
        _ kind: Filter = .current)
        -> [SimulatorRuntime]
    {
        var shown: [SimulatorRuntime] = []
        for candidate in RuntimePlatform.allCases where platform == nil || platform == candidate {
            let ofPlatform = runtimes.filter { $0.platform == candidate }
            let newestMajor = ofPlatform.compactMap(\.versionComponents.first).max()
            shown += filter(ofPlatform.filter { $0.versionComponents.first == newestMajor }, kind)
        }
        return shown
    }

    static func filter(_ runtimes: [SimulatorRuntime], _ kind: Filter) -> [SimulatorRuntime] {
        switch kind {
        case .all:
            return runtimes
        case .stable:
            return runtimes.filter { !$0.isBeta }
        case .beta:
            return runtimes.filter(\.isBeta)
        case .current:
            let newestRelease = runtimes.firstIndex { !$0.isBeta } ?? runtimes.endIndex
            return runtimes.enumerated().filter { $0.offset < newestRelease || !$0.element.isBeta }.map(\.element)
        }
    }

    /// Rough download size for a set of platforms, taking the newest release of each. Runtimes are
    /// several gigabytes apiece and removing one does not always give the space back, so `install
    /// --runtimes` says up front what it is about to fetch.
    static func estimatedSize(_ platforms: [RuntimePlatform], in runtimes: [SimulatorRuntime]) -> Int64 {
        platforms.reduce(0) { total, platform in
            total + (runtimes.first { $0.platform == platform && !$0.isBeta }?.size ?? 0)
        }
    }

    /// Picks one runtime of a platform. A bare version prefers the release over a beta of the same
    /// version; a build matches exactly.
    static func resolve(
        _ raw: String,
        platform: RuntimePlatform,
        in runtimes: [SimulatorRuntime])
        throws -> SimulatorRuntime
    {
        let ofPlatform = runtimes.filter { $0.platform == platform }
        let text = raw.lowercased()
        if let hit = ofPlatform.first(where: { $0.build.lowercased() == text }) {
            return hit
        }
        let wanted = text.split(separator: ".").map { Int($0) ?? 0 }
        let candidates = ofPlatform.filter { runtime in
            var components = runtime.versionComponents
            while components.count < wanted.count {
                components.append(0)
            }
            return Array(components.prefix(wanted.count)) == wanted
        }
        guard !candidates.isEmpty else {
            throw Fail("no \(platform.display) runtime matching \"\(raw)\"; see `xcodectl runtime list`")
        }
        return candidates.first { !$0.isBeta } ?? candidates[0]
    }
}

// MARK: Runtimes.Index

extension Runtimes {
    /// The fields of index2.dvtdownloadableindex this tool reads.
    fileprivate struct Index: Decodable {
        struct Downloadable: Decodable {
            struct SimulatorVersion: Decodable {
                let version: String
                let buildUpdate: String
            }

            struct HostRequirements: Decodable {
                let minXcodeVersion: String?
                let maxXcodeVersion: String?
            }

            let contentType: String?
            let platform: String?
            let name: String?
            let simulatorVersion: SimulatorVersion?
            let architectures: [String]?
            let fileSize: Int64?
            let hostRequirements: HostRequirements?
        }

        let downloadables: [Downloadable]
    }
}

// MARK: - InstalledRuntime

/// One runtime registration as CoreSimulator knows it.
struct InstalledRuntime: Equatable {
    let identifier: String
    let platform: RuntimePlatform?
    let version: String
    let build: String
    let state: String
    let kind: String?
    let size: Int64
    let imagePath: String?
    let deletable: Bool

    /// Anything but `Ready` is a leftover: an interrupted download or an image whose backing asset
    /// went away. These keep holding a reference to their MobileAsset, which is what stops the disk
    /// space from coming back.
    var isReady: Bool {
        state == "Ready"
    }

    /// The `<sha>.asset` directory under /System/Library/AssetsV2 backing this runtime, when it is
    /// MobileAsset-backed rather than a plain disk image.
    var assetDirectory: URL? {
        guard let imagePath, let range = imagePath.range(of: ".asset/") else {
            return nil
        }
        return URL(fileURLWithPath: String(imagePath[imagePath.startIndex ..< range.lowerBound]) + ".asset")
    }

    var display: String {
        "\(platform?.display ?? "?") \(version)"
    }
}

// MARK: - SimCtl

enum SimCtl {
    /// Every registration, including the ones `simctl runtime list` hides. The plain listing shows
    /// only usable images, so unusable leftovers stay invisible while still occupying gigabytes;
    /// the JSON listing is the only complete view.
    static func runtimes() throws -> [InstalledRuntime] {
        try parse(Data(run(executable, ["runtime", "list", "-j"]).utf8))
    }

    static func parse(_ data: Data) throws -> [InstalledRuntime] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else {
            throw Fail("cannot read `simctl runtime list -j` output")
        }
        return root.map { identifier, value in
            InstalledRuntime(
                identifier: identifier,
                platform: (value["platformIdentifier"] as? String).flatMap(RuntimePlatform.init(identifier:)),
                version: value["version"] as? String ?? "?",
                build: value["build"] as? String ?? "?",
                state: value["state"] as? String ?? "Unknown",
                kind: value["kind"] as? String,
                size: (value["sizeBytes"] as? NSNumber)?.int64Value ?? 0,
                imagePath: value["path"] as? String,
                deletable: value["deletable"] as? Bool ?? true)
        }
        .sorted {
            ($0.platform?.rawValue ?? "", $0.version, $0.build) < ($1.platform?.rawValue ?? "", $1.version, $1.build)
        }
    }

    /// Deletes a registration and, once it was the last one referencing the asset, its MobileAsset.
    ///
    /// simctl returns while the runtime is still in `Deleting` and the asset is still on disk, so
    /// wait for the registration to go; only then does its disk space reflect what actually happened.
    static func delete(_ runtime: InstalledRuntime, timeout: TimeInterval = 300) throws {
        try run(executable, ["runtime", "delete", runtime.identifier])
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard let pending = try? runtimes().first(where: { $0.identifier == runtime.identifier }),
                  pending.state == "Deleting"
            else {
                return
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        throw Fail("`simctl runtime delete \(runtime.identifier)` is still running after \(Int(timeout))s")
    }

    private static var executable: URL {
        URL(fileURLWithPath: "/usr/bin/xcrun")
    }

    @discardableResult
    private static func run(_ executable: URL, _ arguments: [String]) throws -> String {
        try runTool(executable, ["simctl"] + arguments)
    }
}

// MARK: - RuntimeInstaller

enum RuntimeInstaller {
    /// Downloads and installs a runtime through the Xcode that owns it. Without a build, Xcode picks
    /// the runtime matching that Xcode, which is what `install --runtimes` wants.
    ///
    /// `DEVELOPER_DIR` aims xcodebuild at a specific Xcode without `xcode-select`, so installing a
    /// runtime never changes which Xcode is active and never needs sudo.
    static func install(
        _ platform: RuntimePlatform?,
        build: String?,
        appleSiliconOnly: Bool,
        using xcode: InstalledXcode,
        progress: @escaping @Sendable (Double) -> Void)
        throws
    {
        var arguments: [String] = []
        if let platform {
            arguments += ["-downloadPlatform", platform.downloadName]
        } else {
            arguments.append("-downloadAllPlatforms")
        }
        if let build {
            arguments += ["-buildVersion", build]
        }
        if appleSiliconOnly {
            arguments += ["-architectureVariant", "arm64"]
        }
        try runToolStreaming(
            xcode.xcodebuild,
            arguments,
            environment: ["DEVELOPER_DIR": xcode.developerDir.path])
        { line in
            if let fraction = progressFraction(line) {
                progress(fraction)
            }
        }
    }

    /// Reads the fraction out of a line of xcodebuild's download progress. The tool writes these with
    /// carriage returns and in the host locale, so the number can carry either decimal separator.
    static func progressFraction(_ line: String) -> Double? {
        guard let match = line.firstMatch(of: #/(\d+(?:[.,]\d+)?)\s*%/#) else {
            return nil
        }
        guard let percent = Double(match.1.replacingOccurrences(of: ",", with: ".")) else {
            return nil
        }
        return min(max(percent / 100, 0), 1)
    }

    /// xcodebuild reports an already-installed runtime as a duplicate image rather than succeeding.
    static func isAlreadyInstalled(_ message: String) -> Bool {
        message.contains("SimDiskImageErrorDomain") && message.contains("Duplicate of ")
    }
}
