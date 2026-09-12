//
// Copyright (c) 2026 Daniel Bauke
//

import AppKit
import ArgumentParser
import Foundation

/// AppKit owns the main thread (the login window needs a real app run loop, and libraries such as
/// unxip schedule work on the main queue). The command itself runs as a task and ends the process.
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

Task.detached {
    do {
        var command = try XcodeCtl.parseAsRoot()
        if var asyncCommand = command as? AsyncParsableCommand {
            try await asyncCommand.run()
        } else {
            try command.run()
        }
        exit(0)
    } catch {
        XcodeCtl.exit(withError: error)
    }
}

app.run()
