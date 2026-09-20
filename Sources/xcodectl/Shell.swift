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

/// Environment for a tool whose output this program parses. The C locale keeps numbers in a fixed
/// form: xcodebuild otherwise prints progress as "3,56 GB" wherever the host uses a decimal comma.
private func toolEnvironment(_ extra: [String: String]) -> [String: String] {
    var environment = ProcessInfo.processInfo.environment
    environment["LC_ALL"] = "C"
    environment["LANG"] = "C"
    for (key, value) in extra {
        environment[key] = value
    }
    return environment
}

/// Runs a tool and returns its standard output, throwing the tool's own message on failure.
@discardableResult
func runTool(_ executable: URL, _ arguments: [String], environment extra: [String: String] = [:]) throws -> String {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.environment = toolEnvironment(extra)
    let output = Pipe()
    let errors = Pipe()
    process.standardOutput = output
    process.standardError = errors

    // Drain stderr while stdout is being read, so neither pipe can fill and stall the child.
    var errorData = Data()
    let draining = DispatchQueue(label: "xcodectl.runTool.stderr")
    let drained = DispatchSemaphore(value: 0)
    draining.async {
        errorData = errors.fileHandleForReading.readDataToEndOfFile()
        drained.signal()
    }

    do {
        try process.run()
    } catch {
        throw Fail("cannot run \(executable.lastPathComponent): \(error.localizedDescription)")
    }
    let outputData = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    drained.wait()

    guard process.terminationStatus == 0 else {
        let message = String(decoding: errorData.isEmpty ? outputData : errorData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        throw Fail(message.isEmpty
            ? "\(executable.lastPathComponent) failed (exit \(process.terminationStatus))"
            : message)
    }
    return String(decoding: outputData, as: UTF8.self)
}

/// Runs a tool, reporting each line it writes. Progress lines are separated by carriage returns as
/// often as by newlines, so both split a line here. On failure the whole transcript becomes the error.
func runToolStreaming(
    _ executable: URL,
    _ arguments: [String],
    environment extra: [String: String] = [:],
    onLine: @escaping @Sendable (String) -> Void)
    throws
{
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.environment = toolEnvironment(extra)
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe

    let lock = NSLock()
    var transcript = ""
    var pending = ""

    func consume(_ chunk: String) {
        guard !chunk.isEmpty else {
            return
        }
        lock.lock()
        transcript += chunk
        pending += chunk
        var parts = pending.components(separatedBy: CharacterSet(charactersIn: "\r\n"))
        pending = parts.removeLast()
        lock.unlock()
        for part in parts where !part.isEmpty {
            onLine(part)
        }
    }

    pipe.fileHandleForReading.readabilityHandler = { handle in
        consume(String(decoding: handle.availableData, as: UTF8.self))
    }
    do {
        try process.run()
    } catch {
        pipe.fileHandleForReading.readabilityHandler = nil
        throw Fail("cannot run \(executable.lastPathComponent): \(error.localizedDescription)")
    }
    process.waitUntilExit()
    pipe.fileHandleForReading.readabilityHandler = nil
    consume(String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))

    guard process.terminationStatus == 0 else {
        let message = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        throw Fail(message.isEmpty
            ? "\(executable.lastPathComponent) failed (exit \(process.terminationStatus))"
            : message)
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
