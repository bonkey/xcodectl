//
// Copyright (c) 2026 Daniel Bauke
//

@testable import xcodectl
import Foundation

/// One release the way data.json describes it.
func makeRelease(
    _ number: String,
    _ build: String,
    _ date: (Int, Int, Int),
    kind: Release.Kind = .init(release: true),
    requires: String? = nil)
    -> Release
{
    Release(
        name: "Xcode",
        version: .init(number: number, build: build, release: kind),
        date: .init(year: date.0, month: date.1, day: date.2),
        requires: requires,
        links: nil)
}

func makeApp(_ name: String, version: String, build: String) -> InstalledXcode {
    InstalledXcode(
        path: URL(fileURLWithPath: "/Applications").appendingPathComponent(name),
        version: version,
        build: build)
}

// MARK: - Simulator runtimes

/// One `downloadables` entry the way index2.dvtdownloadableindex describes it.
func makeEntry(
    platform: String,
    version: String,
    build: String,
    name: String? = nil,
    contentType: String = "cryptexDiskImage",
    architectures: [String] = ["arm64"],
    size: Int64 = 3_600_000_000,
    minXcode: String? = nil,
    maxXcode: String? = nil)
    -> [String: Any]
{
    var entry: [String: Any] = [
        "category": "simulator",
        "contentType": contentType,
        "platform": platform,
        "name": name ?? "\(version) Simulator Runtime",
        "simulatorVersion": ["version": version, "buildUpdate": build],
        "architectures": architectures,
        "fileSize": size,
    ]
    if contentType == "cryptexDiskImage" {
        entry["downloadMethod"] = "mobileAsset"
    }
    var requirements: [String: Any] = [:]
    if let minXcode {
        requirements["minXcodeVersion"] = minXcode
    }
    if let maxXcode {
        requirements["maxXcodeVersion"] = maxXcode
    }
    if !requirements.isEmpty {
        entry["hostRequirements"] = requirements
    }
    return entry
}

/// The index as a binary property list, the way Apple serves it.
func makeIndex(_ entries: [[String: Any]]) -> Data {
    let index: [String: Any] = ["version": 2, "downloadables": entries]
    return (try? PropertyListSerialization.data(fromPropertyList: index, format: .xml, options: 0)) ?? Data()
}

/// `simctl runtime list -j` output: runtimes keyed by identifier.
func makeSimctlOutput(
    _ runtimes: [(
        id: String,
        platform: String,
        version: String,
        build: String,
        state: String,
        size: Int64,
        path: String)])
    -> Data
{
    var root: [String: Any] = [:]
    for runtime in runtimes {
        root[runtime.id] = [
            "platformIdentifier": runtime.platform,
            "version": runtime.version,
            "build": runtime.build,
            "state": runtime.state,
            "kind": "Patchable Cryptex Disk Image",
            "sizeBytes": runtime.size,
            "path": runtime.path,
            "deletable": true,
        ]
    }
    return (try? JSONSerialization.data(withJSONObject: root)) ?? Data()
}

/// A small catalog: iOS 27.0 released plus its beta, and a tvOS entry.
func makeCatalog() throws -> [SimulatorRuntime] {
    try Runtimes.parse(makeIndex([
        makeEntry(platform: "com.apple.platform.iphoneos", version: "27.0", build: "24A1"),
        makeEntry(
            platform: "com.apple.platform.iphoneos",
            version: "27.0",
            build: "24A51",
            name: "iOS 27.0 beta 2 Simulator Runtime"),
        makeEntry(platform: "com.apple.platform.appletvos", version: "27.0", build: "24J1"),
    ]))
}
