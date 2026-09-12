//
// Copyright (c) 2026 Daniel Bauke
//

import Foundation

// MARK: - Fail

/// One-line, actionable failure. Printed by ArgumentParser as `Error: <message>`, exit 1.
struct Fail: Error, LocalizedError, CustomStringConvertible {
    init(_ message: String) {
        description = message
    }

    let description: String

    var errorDescription: String? {
        description
    }
}

// MARK: - Paths

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let base = home.appendingPathComponent(".xcodectl")
    static let cache = base.appendingPathComponent("cache")
    static let applications = URL(fileURLWithPath: "/Applications")
    static let expandTmp = applications.appendingPathComponent(".xcodectl-tmp")
    static let xcodeSelectLink = "/var/db/xcode_select_link"

    static func ensureCache() throws {
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    }
}

var isInteractive: Bool {
    isatty(STDIN_FILENO) == 1 && isatty(STDOUT_FILENO) == 1
}

func eprint(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

/// Runs `sudo <arguments>` with the terminal attached, so sudo can prompt for a password.
/// On CI with passwordless sudo it runs silently.
func sudo(_ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
    process.arguments = arguments
    process.standardInput = FileHandle.standardInput
    process.standardOutput = FileHandle.standardOutput
    process.standardError = FileHandle.standardError
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw Fail("sudo \(arguments.joined(separator: " ")) failed (exit \(process.terminationStatus))")
    }
}

func macOSVersion() -> String {
    let v = ProcessInfo.processInfo.operatingSystemVersion
    return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
}

func sysctlString(_ name: String) -> String {
    var size = 0
    sysctlbyname(name, nil, &size, nil, 0)
    var buffer = [CChar](repeating: 0, count: max(size, 1))
    sysctlbyname(name, &buffer, &size, nil, 0)
    return String(cString: buffer)
}

/// Same value as `getconf DARWIN_USER_CACHE_DIR`.
func darwinUserCacheDir() -> String {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    confstr(_CS_DARWIN_USER_CACHE_DIR, &buffer, buffer.count)
    return String(cString: buffer)
}

/// Compares dotted version strings numerically: "26.6.2" >= "26.6".
func versionAtLeast(_ actual: String, _ required: String) -> Bool {
    let a = actual.split(separator: ".").map { Int($0) ?? 0 }
    let r = required.split(separator: ".").map { Int($0) ?? 0 }
    for i in 0 ..< max(a.count, r.count) {
        let x = i < a.count ? a[i] : 0
        let y = i < r.count ? r[i] : 0
        if x != y {
            return x > y
        }
    }
    return true
}

func formatBytes(_ bytes: Int64) -> String {
    let gb = Double(bytes) / 1_073_741_824
    if gb >= 1 {
        return String(format: "%.1f GB", gb)
    }
    return String(format: "%.0f MB", Double(bytes) / 1_048_576)
}
