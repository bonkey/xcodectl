//
// Copyright (c) 2026 Daniel Bauke
//

@testable import xcodectl
import XCTest

final class ReleaseNotesTests: XCTestCase {
    func testMarkdownURLAddsTheSuffixToDocumentationPages() throws {
        let page = "https://developer.apple.com/documentation/xcode-release-notes/xcode-27_1-release-notes"
        XCTAssertEqual(try ReleaseNotes.markdownURL(release(notes: page)).absoluteString, page + ".md")
    }

    func testMarkdownURLRejectsArchivedPagesPDFsAndMissingLinks() {
        XCTAssertThrowsError(try ReleaseNotes.markdownURL(release(notes: nil)))
        XCTAssertThrowsError(try ReleaseNotes.markdownURL(
            release(notes: "https://developer.apple.com/library/content/releasenotes/RN-Xcode/Introduction.html")))
        XCTAssertThrowsError(try ReleaseNotes.markdownURL(
            release(notes: "https://download.developer.apple.com/Developer_Tools/xcode_v1.5/read_me.pdf")))
    }

    func testCleanDropsTheMetadataCommentAndTheFooter() {
        let cleaned = ReleaseNotes.clean(served)
        XCTAssertTrue(cleaned.hasPrefix("# Xcode 27.1 Release Notes"))
        XCTAssertTrue(cleaned.hasSuffix("- Fixed: a crash.  (3)"))
    }

    func testPlainRemovesMarkup() {
        let plain = ReleaseNotes
            .plain("### Testing\n\n#### Known Issues\n\n- Use `a` **now**, see [the guide](https://x.y/z).")
        XCTAssertEqual(plain, "TESTING\n\nKnown Issues\n\n- Use a now, see the guide.")
    }

    func testRenderedStylesHeadingsBulletsAndInlineMarkup() {
        let esc = "\u{1B}"
        XCTAssertEqual(
            ReleaseNotes.rendered(
                "### Testing\n\n- Use `a` **now**, see [the guide](/documentation/xcode).",
                theme: .ansi),
            """
            \(esc)[1;34mTesting\(esc)[0m

            \(esc)[36m•\(esc)[39m Use \(esc)[33ma\(esc)[39m \(esc)[1mnow\(esc)[22m, see \
            \(esc)]8;;https://developer.apple.com/documentation/xcode\(esc)\\\(esc)[4;34mthe guide\(esc)[24;39m\(esc)]8;;\(esc)\\.
            """)
    }

    func testRenderedTakesTheColorsOfTheTheme() {
        let esc = "\u{1B}"
        XCTAssertEqual(
            ReleaseNotes.rendered("+ Added.\n\n- Dropped.", diff: true, theme: .ansi),
            "\(esc)[1;32m+\(esc)[0m Added.\n\n\(esc)[1;31m-\(esc)[0m Dropped.")
        XCTAssertEqual(ReleaseNotes.rendered("# Xcode", theme: .dark), "\(esc)[1;4;38;2;219;97;162mXcode\(esc)[0m")
        XCTAssertEqual(ReleaseNotes.rendered("# Xcode", theme: .light), "\(esc)[1;4;38;2;130;80;223mXcode\(esc)[0m")
    }

    func testIsLightReadsTheBackgroundAnOSC11ReplyNames() {
        XCTAssertEqual(ReleaseNotes.Theme.isLight("\u{1B}]11;rgb:f6f6/f8f8/fafa\u{07}"), true)
        XCTAssertEqual(ReleaseNotes.Theme.isLight("\u{1B}]11;rgb:1010/1212/1616\u{1B}\\"), false)
        XCTAssertEqual(ReleaseNotes.Theme.isLight("\u{1B}]11;rgb:ff/ff/ff\u{07}"), true)
        XCTAssertNil(ReleaseNotes.Theme.isLight("garbage"))
    }

    func testUnknownNamesAreTheCodeSpansTheNotesDoNotHold() {
        let notes = "Opt out with the `IBC_COCOATOUCH_COMPILER_MODE` = `simulator` build setting. Use `#Preview`."
        let summary = "Set `IBC_COCOATOUCH_COMPILER_MODE = simulator`, not `IBC_COCATOUCH_COMPILER_MODE`; use `#Preview`."
        XCTAssertEqual(ReleaseNotes.unknownNames(in: summary, notes: notes), ["IBC_COCATOUCH_COMPILER_MODE"])
    }

    func testWithoutEmptyHeadingsKeepsHeadingsWithTextOrSubheadings() {
        let summary = "## Before you upgrade\n\n- One.\n\n## Known issues\n\n## New\n\n### Testing\n\n- Two.\n\n## Deprecated\n"
        XCTAssertEqual(
            ReleaseNotes.withoutEmptyHeadings(summary),
            "## Before you upgrade\n\n- One.\n\n## New\n\n### Testing\n\n- Two.")
    }

    func testBlocksKeepAnItemWithItsWorkaroundUnderItsHeadings() {
        let blocks = ReleaseNotes.blocks(ReleaseNotes.clean(served))
        XCTAssertEqual(blocks.map(\.path), [
            [],
            ["## Overview"],
            ["## Overview", "### Testing", "#### Known Issues"],
            ["## Overview", "### Testing", "#### Known Issues"],
            ["## Overview", "### Testing", "#### Resolved Issues"],
        ])
        XCTAssertEqual(blocks[1].text, "Xcode 27.1 includes Swift 6.4.\nIt requires macOS 26.6.")
        XCTAssertTrue(blocks[2].text.hasPrefix("- Tests may crash"))
        XCTAssertTrue(blocks[2].text.hasSuffix("(https://example.com/guide)."))
        XCTAssertEqual(blocks[3].text, "- Second issue.  (2)")
    }

    func testDiffListsAddedAndDroppedItemsUnderTheirHeadings() {
        let known = ["### Testing", "#### Known Issues"]
        let fixed = ["### Testing", "#### Resolved Issues"]
        let old = [Block(path: known, text: "- Stays.  (1)"), Block(path: known, text: "- Goes.  (2)")]
        let new = [Block(path: known, text: "- Stays. (1)"), Block(path: fixed, text: "- Fixed: goes.  (2)")]
        XCTAssertEqual(ReleaseNotes.diff(old: old, new: new), """
        ### Testing

        #### Known Issues

        - Goes.  (2)

        #### Resolved Issues

        + Fixed: goes.  (2)
        """)
    }

    func testDiffOfEqualNotesIsNil() {
        let blocks = ReleaseNotes.blocks(ReleaseNotes.clean(served))
        XCTAssertNil(ReleaseNotes.diff(old: blocks, new: blocks))
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
