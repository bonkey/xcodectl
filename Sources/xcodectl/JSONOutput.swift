//
// Copyright (c) 2026 Daniel Bauke
//

import Foundation

// MARK: - JSON output

/// `--json` output: the facts of a table as typed values, with sorted keys. A value that is not
/// known leaves its key out. The keys are a contract for scripts and agents.
func encodeJSON(_ value: some Encodable) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return try String(decoding: encoder.encode(value), as: UTF8.self)
}

func printJSON(_ value: some Encodable) throws {
    try print(encodeJSON(value))
}

// MARK: - ReleaseJSON

/// One Xcode release of `list --json`.
struct ReleaseJSON: Encodable, Equatable {
    /// The macOS versions the release runs on, and whether this Mac's is one of them.
    struct MacOS: Encodable, Equatable {
        let minimum: String
        /// Absent when Apple names no upper bound or has no row for the release.
        let newest: String?
        let runsHere: Bool?
    }

    let version: String
    let build: String
    let released: String
    let prerelease: Bool
    let installed: Bool
    let active: Bool
    let macOS: MacOS?
}

func releaseJSON(_ releases: [Release], requirements: [SystemRequirements.Row]) -> [ReleaseJSON] {
    releaseJSON(
        releases,
        installed: Installed.all(),
        active: Installed.activePath()?.standardizedFileURL.path,
        requirements: requirements,
        macOS: macOSVersion())
}

func releaseJSON(
    _ releases: [Release],
    installed: [InstalledXcode],
    active: String?,
    requirements: [SystemRequirements.Row],
    macOS: String)
    -> [ReleaseJSON]
{
    let owners = statusOwners(releases, installed, active: active)
    return releases.enumerated().map { index, release in
        ReleaseJSON(
            version: release.display,
            build: release.build,
            released: release.dateString,
            prerelease: !release.isFinal,
            installed: owners[index] != nil,
            active: owners[index].map { $0.path.standardizedFileURL.path == active } ?? false,
            macOS: release.requires.map {
                ReleaseJSON.MacOS(
                    minimum: $0,
                    newest: SystemRequirements.row(for: release, in: requirements)?.newestMacOS,
                    runsHere: Compatibility(release, macOS: macOS, requirements: requirements).runsHere)
            })
    }
}

extension Compatibility {
    /// Whether this Mac runs the release; nil when that is not known.
    fileprivate var runsHere: Bool? {
        switch self {
        case .supported: true
        case .needsMacOS,
             .onlyUpToMacOS: false
        case .unknown: nil
        }
    }
}

// MARK: - RuntimeJSON

/// One simulator runtime of `list <platform> --json`.
struct RuntimeJSON: Encodable, Equatable {
    let platform: String
    let version: String
    let build: String
    let prerelease: Bool
    let size: Int64?
    let installed: Bool
}

func runtimeJSON(_ runtimes: [SimulatorRuntime], installed: [InstalledRuntime]) -> [RuntimeJSON] {
    let ready = Set(installed.filter(\.isReady).map { $0.build.lowercased() })
    return runtimes.map {
        RuntimeJSON(
            platform: $0.platform.rawValue,
            version: $0.version,
            build: $0.build,
            prerelease: $0.isBeta,
            size: $0.size > 0 ? $0.size : nil,
            installed: ready.contains($0.build.lowercased()))
    }
}

// MARK: - InstalledXcodeJSON

/// One Xcode of `installed --json`, with the simulator runtimes it uses.
struct InstalledXcodeJSON: Encodable, Equatable {
    struct Runtime: Encodable, Equatable {
        let platform: String?
        let version: String
        let build: String
        let size: Int64
    }

    let version: String
    let build: String
    let path: String
    let size: Int64?
    let active: Bool
    let runtimes: [Runtime]
}

func installedJSON(
    _ installed: [(xcode: InstalledXcode, size: Int64?, runtimes: [InstalledRuntime])],
    active: String?)
    -> [InstalledXcodeJSON]
{
    installed.map { xcode, size, runtimes in
        InstalledXcodeJSON(
            version: xcode.version,
            build: xcode.build,
            path: xcode.path.path,
            size: size,
            active: xcode.path.standardizedFileURL.path == active,
            runtimes: runtimes.map {
                .init(platform: $0.platform?.rawValue, version: $0.version, build: $0.build, size: $0.size)
            })
    }
}

// MARK: - InstalledRuntimeJSON

/// One simulator runtime registration of `runtime installed --json`.
struct InstalledRuntimeJSON: Encodable, Equatable {
    let identifier: String
    let platform: String?
    let version: String
    let build: String
    let size: Int64
    let state: String
}

func registrationJSON(_ runtimes: [InstalledRuntime]) -> [InstalledRuntimeJSON] {
    runtimes.map {
        InstalledRuntimeJSON(
            identifier: $0.identifier,
            platform: $0.platform?.rawValue,
            version: $0.version,
            build: $0.build,
            size: $0.size,
            state: $0.state)
    }
}

// MARK: - SessionJSON

/// `auth status --json`: where the session comes from, or why there is none.
struct SessionJSON: Encodable, Equatable {
    let signedIn: Bool
    var source: String?
    var reason: String?
}
