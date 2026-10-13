//
// Copyright (c) 2026 Daniel Bauke
//

@testable import xcodectl
import Foundation
import Testing

struct ReleaseNotesTests {
    @Test func `Markdown URL adds the suffix to documentation pages`() throws {
        let page = "https://developer.apple.com/documentation/xcode-release-notes/xcode-27_1-release-notes"
        #expect(try ReleaseNotes.markdownURL(release(notes: page)).absoluteString == page + ".md")
    }

    @Test func `Markdown URL rejects archived pages, PDFs and missing links`() {
        #expect(throws: Error.self) { try ReleaseNotes.markdownURL(release(notes: nil)) }
        #expect(throws: Error.self) {
            try ReleaseNotes.markdownURL(
                release(notes: "https://developer.apple.com/library/content/releasenotes/RN-Xcode/Introduction.html"))
        }
        #expect(throws: Error.self) {
            try ReleaseNotes.markdownURL(
                release(notes: "https://download.developer.apple.com/Developer_Tools/xcode_v1.5/read_me.pdf"))
        }
    }

    @Test func `clean drops the metadata comment and the footer`() {
        let cleaned = ReleaseNotes.clean(served)
        #expect(cleaned.hasPrefix("# Xcode 27.1 Release Notes"))
        #expect(cleaned.hasSuffix("- Fixed: a crash.  (3)"))
    }

    @Test func `plain removes markup`() {
        let plain = ReleaseNotes
            .plain("### Testing\n\n#### Known Issues\n\n- Use `a` **now**, see [the guide](https://x.y/z).")
        #expect(plain == "TESTING\n\nKnown Issues\n\n- Use a now, see the guide.")
    }

    @Test func `rendered styles headings, bullets and inline markup`() {
        let esc = "\u{1B}"
        #expect(
            ReleaseNotes.rendered(
                "### Testing\n\n- Use `a` **now**, see [the guide](/documentation/xcode).",
                theme: .ansi) ==
                """
                \(esc)[1;34mTesting\(esc)[0m

                \(esc)[36m•\(esc)[39m Use \(esc)[33ma\(esc)[39m \(esc)[1mnow\(esc)[22m, see \
                \(esc)]8;;https://developer.apple.com/documentation/xcode\(esc)\\\(esc)[4;34mthe guide\(esc)[24;39m\(esc)]8;;\(esc)\\.
                """)
    }

    @Test func `rendered takes the colors of the theme`() {
        let esc = "\u{1B}"
        #expect(
            ReleaseNotes.rendered("+ Added.\n\n- Dropped.", diff: true, theme: .ansi) ==
                "\(esc)[1;32m+\(esc)[0m Added.\n\n\(esc)[1;31m-\(esc)[0m Dropped.")
        #expect(ReleaseNotes.rendered("# Xcode", theme: .dark) == "\(esc)[1;4;38;2;219;97;162mXcode\(esc)[0m")
        #expect(ReleaseNotes.rendered("# Xcode", theme: .light) == "\(esc)[1;4;38;2;130;80;223mXcode\(esc)[0m")
    }

    @Test func `is light reads the background an OSC 11 reply names`() {
        #expect(ReleaseNotes.Theme.isLight("\u{1B}]11;rgb:f6f6/f8f8/fafa\u{07}") == true)
        #expect(ReleaseNotes.Theme.isLight("\u{1B}]11;rgb:1010/1212/1616\u{1B}\\") == false)
        #expect(ReleaseNotes.Theme.isLight("\u{1B}]11;rgb:ff/ff/ff\u{07}") == true)
        #expect(ReleaseNotes.Theme.isLight("garbage") == nil)
    }

    @Test func `unknown names are the code spans the notes do not hold`() {
        let notes = "Opt out with the `IBC_COCOATOUCH_COMPILER_MODE` = `simulator` build setting. Use `#Preview`."
        let summary = "Set `IBC_COCOATOUCH_COMPILER_MODE = simulator`, not `IBC_COCATOUCH_COMPILER_MODE`; use `#Preview`."
        #expect(ReleaseNotes.unknownNames(in: summary, notes: notes) == ["IBC_COCATOUCH_COMPILER_MODE"])
    }

    @Test func `without empty headings keeps headings with text or subheadings`() {
        let summary = "## Before you upgrade\n\n- One.\n\n## Known issues\n\n## New\n\n### Testing\n\n- Two.\n\n## Deprecated\n"
        #expect(
            ReleaseNotes.withoutEmptyHeadings(summary) ==
                "## Before you upgrade\n\n- One.\n\n## New\n\n### Testing\n\n- Two.")
    }

    @Test func `blocks keep an item with its workaround under its headings`() {
        let blocks = ReleaseNotes.blocks(ReleaseNotes.clean(served))
        #expect(blocks.map(\.path) == [
            [],
            ["## Overview"],
            ["## Overview", "### Testing", "#### Known Issues"],
            ["## Overview", "### Testing", "#### Known Issues"],
            ["## Overview", "### Testing", "#### Resolved Issues"],
        ])
        #expect(blocks[1].text == "Xcode 27.1 includes Swift 6.4.\nIt requires macOS 26.6.")
        #expect(blocks[2].text.hasPrefix("- Tests may crash"))
        #expect(blocks[2].text.hasSuffix("(https://example.com/guide)."))
        #expect(blocks[3].text == "- Second issue.  (2)")
    }

    @Test func `diff lists added and dropped items under their headings`() {
        let known = ["### Testing", "#### Known Issues"]
        let fixed = ["### Testing", "#### Resolved Issues"]
        let old = [Block(path: known, text: "- Stays.  (1)"), Block(path: known, text: "- Goes.  (2)")]
        let new = [Block(path: known, text: "- Stays. (1)"), Block(path: fixed, text: "- Fixed: goes.  (2)")]
        #expect(ReleaseNotes.diff(old: old, new: new) == """
        ### Testing

        #### Known Issues

        - Goes.  (2)

        #### Resolved Issues

        + Fixed: goes.  (2)
        """)
    }

    @Test func `diff of equal notes is nil`() {
        let blocks = ReleaseNotes.blocks(ReleaseNotes.clean(served))
        #expect(ReleaseNotes.diff(old: blocks, new: blocks) == nil)
    }

    private typealias Block = ReleaseNotes.Block

    private let served = """

    <!--
    {
      "title" : "Xcode 27.1 Release Notes"
    }
    -->

    # Xcode 27.1 Release Notes

    Update your apps.

    ## Overview

    Xcode 27.1 includes Swift 6.4.
    It requires macOS 26.6.

    ### Testing

    #### Known Issues

    - Tests may crash with `UIImage`.  (1)

      **Workaround:** See [the guide](https://example.com/guide).
    - Second issue.  (2)

    #### Resolved Issues

    - Fixed: a crash.  (3)

    ---

    Copyright &copy; 2026 Apple Inc. All rights reserved.
    """

    private func release(notes: String?) -> Release {
        Release(
            name: "Xcode",
            version: .init(number: "27.1", build: "27B100", release: .init(release: true)),
            date: .init(year: 2026, month: 10, day: 1),
            requires: nil,
            links: .init(download: nil, notes: notes.map { .init(url: URL(string: $0)!) }))
    }
}
