//
// Copyright (c) 2026 Daniel Bauke
//

import Foundation
import libunxip

// MARK: - InstalledXcode

struct InstalledXcode: Equatable {
    let path: URL
    let version: String // CFBundleShortVersionString, e.g. "27.0"
    let build: String // ProductBuildVersion, e.g. "27A266a"

    var name: String {
        path.lastPathComponent
    }

    var xcodebuild: URL {
        path.appendingPathComponent("Contents/Developer/usr/bin/xcodebuild")
    }

    var developerDir: URL {
        path.appendingPathComponent("Contents/Developer")
    }
}

// MARK: - Installed

enum Installed {
    /// Every /Applications/Xcode*.app with a readable version.plist, newest first.
    static func all() -> [InstalledXcode] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: Paths.applications.path)) ?? []
        return names
            .filter { $0.hasPrefix("Xcode") && $0.hasSuffix(".app") }
            .compactMap { read(Paths.applications.appendingPathComponent($0)) }
            .sorted { a, b in
                let x = a.version.split(separator: ".").map { Int($0) ?? 0 }
                let y = b.version.split(separator: ".").map { Int($0) ?? 0 }
                if x != y {
                    return x.lexicographicallyPrecedes(y) == false
                }
                return a.build > b.build
            }
    }

    static func read(_ app: URL) -> InstalledXcode? {
        let plist = app.appendingPathComponent("Contents/version.plist")
        guard let data = try? Data(contentsOf: plist),
              let dict = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              let version = dict["CFBundleShortVersionString"] as? String,
              let build = dict["ProductBuildVersion"] as? String
        else {
            return nil
        }
        return InstalledXcode(path: app, version: version, build: build)
    }

    /// The app `xcode-select -p` points to (via /var/db/xcode_select_link).
    static func activePath() -> URL? {
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: Paths.xcodeSelectLink)
        else {
            return nil
        }
        let url = URL(fileURLWithPath: target).standardizedFileURL
        // .../Xcode-26.6.app/Contents/Developer -> .../Xcode-26.6.app
        return url.path.hasSuffix("/Contents/Developer") ? url.deletingLastPathComponent()
            .deletingLastPathComponent() : url
    }

    static func isActive(_ xcode: InstalledXcode) -> Bool {
        activePath()?.standardizedFileURL.path == xcode.path.standardizedFileURL.path
    }

    static func find(build: String) -> InstalledXcode? {
        all().first { $0.build.lowercased() == build.lowercased() }
    }

    /// Resolves "27", "27-rc1", "27A266a" against what is installed.
    static func resolve(_ raw: String) async throws -> InstalledXcode {
        let installed = all()
        guard !installed.isEmpty else {
            throw Fail("no Xcode installed in /Applications")
        }
        let query = try Query(raw)
        if let build = query.build, let hit = installed.first(where: { $0.build.lowercased() == build }) {
            return hit
        }
        if let releases = try? await Releases.fetch(),
           let release = try? query.resolve(in: releases).release,
           let hit = installed.first(where: { $0.build.lowercased() == release.build.lowercased() })
        {
            return hit
        }
        if query.latest, let hit = installed.first {
            return hit
        }
        if let hit = installed.first(where: { query.matchesNumber($0.version) }) {
            return hit
        }
        throw Fail("\(raw) is not installed; see `xcodectl list-installed`")
    }
}

// MARK: - Installer

enum Installer {
    /// Expands the XIP into a temp dir next to /Applications (same volume, so the final move is a rename).
    static func expand(xip: URL) async throws -> URL {
        let tmp = Paths.expandTmp
        try? FileManager.default.removeItem(at: tmp)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        let free = (try? Paths.applications.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? Int64.max
        guard free > 20 * 1_073_741_824 else {
            throw Fail("only \(formatBytes(free)) free on the /Applications volume; expanding Xcode needs about 20 GB")
        }

        let dirFD = open(tmp.path, O_RDONLY | O_DIRECTORY)
        guard dirFD >= 0 else {
            throw Fail("cannot open \(tmp.path)")
        }
        defer { close(dirFD) }
        let input = try FileHandle(forReadingFrom: xip)
        defer { try? input.close() }

        for try await _ in Unxip.makeStream(
            from: .xip(), to: .disk(),
            input: DataReader(descriptor: input.fileDescriptor),
            nil, nil, .init(compress: true, dryRun: false, output: dirFD)) {}

        let apps = ((try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? [])
            .filter { $0.hasSuffix(".app") }
        guard apps.count == 1 else {
            throw Fail("expected one .app inside the archive, found \(apps.count) (\(tmp.path) left for inspection)")
        }
        return tmp.appendingPathComponent(apps[0])
    }

    static func move(_ app: URL, to destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            throw Fail("\(destination.path) already exists; remove it first (`xcodectl remove`)")
        }
        do {
            try FileManager.default.moveItem(at: app, to: destination)
        } catch {
            throw Fail("cannot move into /Applications: \(error.localizedDescription)")
        }
        try? FileManager.default.removeItem(at: Paths.expandTmp)
    }

    /// License, first-launch packages, developer mode. All via sudo; then the marker that stops the GUI prompt.
    static func approve(_ xcode: InstalledXcode) throws {
        try sudo([xcode.xcodebuild.path, "-license", "accept"])
        try sudo([xcode.xcodebuild.path, "-runFirstLaunch"])
        try sudo(["/usr/sbin/DevToolsSecurity", "-enable"])
        let cacheDir = darwinUserCacheDir()
        let osBuild = sysctlString("kern.osversion")
        for name in [
            "com.apple.dt.Xcode.InstallCheckCache_\(osBuild)",
            "com.apple.dt.Xcode.InstallCheckCache_\(osBuild)_\(xcode.build)",
        ] {
            FileManager.default.createFile(atPath: cacheDir + name, contents: Data())
        }
    }

    static func select(_ xcode: InstalledXcode) throws {
        try sudo(["/usr/bin/xcode-select", "-s", xcode.path.path])
    }

    static func remove(_ xcode: InstalledXcode) throws {
        do {
            try FileManager.default.removeItem(at: xcode.path)
        } catch {
            try sudo(["/bin/rm", "-rf", xcode.path.path])
        }
    }
}
