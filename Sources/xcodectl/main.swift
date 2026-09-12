//
// Copyright (c) 2026 Daniel Bauke
//

import ArgumentParser
import Foundation

// MARK: - ResultBox

// Hand-rolled entry point instead of `@main`: async main runs commands inside the dispatch main
// queue, and the login window's nested run loop cannot drain that queue (WebKit stays blank).
// Sync commands run on the main thread; async ones run on a background task while main waits.

private final class ResultBox<T>: @unchecked Sendable {
    var result: Result<T, Error>?
}

/// Runs async work from synchronous code, blocking the calling thread until it finishes.
func runBlocking<T>(_ work: @escaping @Sendable () async throws -> T) throws -> T {
    let box = ResultBox<T>()
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        box.result = await Result { try await work() }
        done.signal()
    }
    done.wait()
    return try box.result!.get()
}

let command: ParsableCommand
do {
    command = try XcodeCtl.parseAsRoot()
} catch {
    XcodeCtl.exit(withError: error)
}

do {
    if let asyncCommand = command as? AsyncParsableCommand {
        nonisolated(unsafe) var copy = asyncCommand
        try runBlocking { try await copy.run() }
    } else {
        var copy = command
        try copy.run()
    }
} catch {
    XcodeCtl.exit(withError: error)
}
