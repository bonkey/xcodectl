//
// Copyright (c) 2026 Daniel Bauke
//

@testable import xcodectl
import ArgumentParser
import Testing

struct ReferenceTests {
    @Test func `reference holds the heading and usage of every leaf command`() {
        let text = Reference.text()
        let all = leaves(XcodeCtl.self, path: [])
        #expect(all.count > 10)
        for (invocation, command) in all {
            #expect(text.contains("# \(invocation)\n"))
            #expect(text.contains("USAGE: \(XcodeCtl.usageString(for: command))"))
        }
    }

    @Test func `reference heads a nested command with its full invocation`() {
        let text = Reference.text()
        #expect(text.contains("# xcodectl auth login\n"))
        #expect(text.contains("# xcodectl config init\n"))
    }

    /// Visible commands without subcommands, found by a walk of the tree apart from `Reference`.
    private func leaves(
        _ command: ParsableCommand.Type,
        path: [String])
        -> [(invocation: String, command: ParsableCommand.Type)]
    {
        guard command.configuration.shouldDisplay else {
            return []
        }
        let words = path + [command._commandName]
        let subcommands = command.configuration.subcommands
        guard !subcommands.isEmpty else {
            return [(words.joined(separator: " "), command)]
        }
        return subcommands.flatMap { leaves($0, path: words) }
    }
}
