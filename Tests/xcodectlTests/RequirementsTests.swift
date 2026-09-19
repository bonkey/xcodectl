//
// Copyright (c) 2026 Daniel Bauke
//

@testable import xcodectl
import XCTest

final class RequirementsTests: XCTestCase {
    func testParseReadsTheXcodeAndTheNewestMacOSOfEveryRow() {
        XCTAssertEqual(SystemRequirements.parse(page), [
            .init(xcode: "27.1", newestMacOS: nil),
            .init(xcode: "27", newestMacOS: nil),
            .init(xcode: "26.6", newestMacOS: "26.x"),
            .init(xcode: "26.4.1", newestMacOS: "26.x"),
            .init(xcode: "26", newestMacOS: "26.x"),
            .init(xcode: "16.4", newestMacOS: "26.1.x"),
            .init(xcode: "15.4", newestMacOS: "14.x"),
            .init(xcode: "15.1", newestMacOS: "14.x"),
            .init(xcode: "15.0.x", newestMacOS: "14.x"),
            .init(xcode: "14.3", newestMacOS: "13.x"),
        ])
    }

    func testParseSkipsTablesWithoutASupportedMacOSColumn() {
        let sdks = """
        <table><tr><th>Xcode Version</th><th>macOS SDK</th></tr>
        <tr><td>Xcode 27</td><td>macOS 27</td></tr></table>
        """
        XCTAssertEqual(SystemRequirements.parse(sdks), [])
        XCTAssertEqual(SystemRequirements.parse("<html><body>Service unavailable</body></html>"), [])
    }

    func testParseReadsCellsWithNumericEntitiesAndARowHeading() {
        let table = """
        <table><tr><th>Xcode Version</th><th>Supported macOS Versions</th></tr>
        <tr><th scope="row">Xcode&#160;27</th><td>macOS&#160;Tahoe&#160;26.6&#160;or&#160;later</td></tr>
        <tr><th scope="row">Xcode&#160;26.6</th><td>macOS&#160;Tahoe&#160;26.2&#160;&ndash;&#160;26.x</td></tr></table>
        """
        XCTAssertEqual(SystemRequirements.parse(table), [
            .init(xcode: "27", newestMacOS: nil),
            .init(xcode: "26.6", newestMacOS: "26.x"),
        ])
    }

    func testRowIsTheOneOfTheVersionElseOfItsMajorAndMinor() {
        let rows = SystemRequirements.parse(page)
        func row(_ number: String, _ kind: Release.Kind = .init(release: true)) -> String? {
            SystemRequirements.row(for: makeRelease(number, "", (2026, 1, 1), kind: kind), in: rows)?.xcode
        }
        XCTAssertEqual(row("27.0"), "27")
        XCTAssertEqual(row("27.0", .init(beta: 3)), "27")
        XCTAssertEqual(row("27.1", .init(beta: 1)), "27.1")
        XCTAssertEqual(row("26.4.1"), "26.4.1")
        XCTAssertEqual(row("26.4"), "26.4.1")
        XCTAssertEqual(row("26.4", .init(beta: 2)), "26.4.1")
        XCTAssertEqual(row("15.0.1"), "15.0.x")
        XCTAssertEqual(row("14.3"), "14.3")
        XCTAssertNil(row("26.7"))
        XCTAssertNil(row("13.4.1"))
    }

    func testIsAtMostComparesTheComponentsBeforeTheX() {
        XCTAssertTrue(Compatibility.isAtMost("25.6.0", "26.x"))
        XCTAssertTrue(Compatibility.isAtMost("26.0.0", "26.x"))
        XCTAssertTrue(Compatibility.isAtMost("26.9.3", "26.x"))
        XCTAssertFalse(Compatibility.isAtMost("27.0.0", "26.x"))
        XCTAssertTrue(Compatibility.isAtMost("26.1.9", "26.1.x"))
        XCTAssertFalse(Compatibility.isAtMost("26.2.0", "26.1.x"))
    }

    func testSupportedFromTheMinimumOnWhenThePageSetsNoLimit() {
        XCTAssertEqual(compatibility("27.0", requires: "26.6", on: "26.6.0"), .supported)
        XCTAssertEqual(compatibility("27.0", requires: "26.6", on: "99.0.0"), .supported)
        XCTAssertEqual(compatibility("27.0", .init(beta: 3), requires: "26.4", on: "26.4.1"), .supported)
    }

    func testNeedsMacOSBelowTheMinimumOfItsBuild() {
        XCTAssertEqual(compatibility("27.0", requires: "26.6", on: "26.5.9"), .needsMacOS("26.6"))
        XCTAssertEqual(compatibility("27.0", .init(beta: 3), requires: "26.4", on: "26.3.0"), .needsMacOS("26.4"))
    }

    func testOnlyUpToMacOSPastTheNewestOnThePage() {
        XCTAssertEqual(compatibility("26.6", requires: "26.2", on: "26.9.1"), .supported)
        XCTAssertEqual(compatibility("26.6", requires: "26.2", on: "27.0.0"), .onlyUpToMacOS("26.x"))
        XCTAssertEqual(compatibility("16.4", requires: "15.3", on: "26.1.9"), .supported)
        XCTAssertEqual(compatibility("16.4", requires: "15.3", on: "26.2.0"), .onlyUpToMacOS("26.1.x"))
    }

    func testUnknownWithoutARowOrAMinimum() {
        XCTAssertEqual(compatibility("13.4.1", requires: "12.5", on: "27.0.0"), .unknown)
        XCTAssertEqual(compatibility("27.0", requires: nil, on: "27.0.0"), .unknown)
    }

    func testWithoutThePageOnlyAMissingMinimumIsKnown() {
        XCTAssertEqual(compatibility("27.0", requires: "26.6", on: "26.2.0", page: ""), .needsMacOS("26.6"))
        XCTAssertEqual(compatibility("27.0", requires: "26.6", on: "27.0.0", page: ""), .unknown)
    }

    func testTextMarksTheRangeOfMacOSVersions() {
        XCTAssertEqual(Compatibility.supported.text(range: "26.6 or later").plain(), "✓ 26.6 or later")
        XCTAssertEqual(Compatibility.needsMacOS("26.6").text(range: "26.6 or later").plain(), "✗ 26.6 or later")
        XCTAssertEqual(Compatibility.onlyUpToMacOS("26.x").text(range: "26.2–26.x").plain(), "✗ 26.2–26.x")
        XCTAssertEqual(Compatibility.unknown.text(range: "from 12.5").plain(), "from 12.5")
    }

    func testRangeRunsFromTheMinimumToTheNewestOnThePage() {
        let rows = SystemRequirements.parse(page)
        XCTAssertEqual(
            Compatibility.range(of: makeRelease("26.6", "", (2026, 1, 1), requires: "26.2"), requirements: rows),
            "26.2–26.x")
        XCTAssertEqual(
            Compatibility.range(of: makeRelease("27.0", "", (2026, 1, 1), requires: "26.6"), requirements: rows),
            "26.6 or later")
        XCTAssertEqual(
            Compatibility.range(of: makeRelease("13.4.1", "", (2026, 1, 1), requires: "12.5"), requirements: rows),
            "from 12.5")
        XCTAssertEqual(
            Compatibility.range(of: makeRelease("27.0", "", (2026, 1, 1), requires: "26.6"), requirements: []),
            "from 26.6")
        XCTAssertNil(Compatibility.range(of: makeRelease("27.0", "", (2026, 1, 1), requires: nil), requirements: rows))
    }

    func testAddingPutsTheLineUnderTheTitle() {
        XCTAssertEqual(
            Compatibility.adding("On this Mac", to: "# Xcode 27 Release Notes\n\nOverview.\n\n## Swift"),
            "# Xcode 27 Release Notes\n\nOn this Mac\n\nOverview.\n\n## Swift")
        XCTAssertEqual(Compatibility.adding("On this Mac", to: "# Xcode 27"), "# Xcode 27\n\nOn this Mac")
        XCTAssertEqual(Compatibility.adding("On this Mac", to: "Overview."), "On this Mac\n\nOverview.")
        XCTAssertEqual(Compatibility.adding(nil, to: "# Xcode 27\n\nOverview."), "# Xcode 27\n\nOverview.")
    }

    /// An excerpt of https://developer.apple.com/xcode/system-requirements/: the headings of both
    /// tables, one row with all its cells and the first two cells of others.
    private let page = """
    <accordion-panel id="xcode-26-releases" data-open>
    <h3>Latest Xcode versions</h3>
    <div>
    <table class="typography-caption">
    <thead>
    <tr>
    <th>Xcode Version</th>
    <th>Supported macOS Versions</th>
    <th>SDKs</th>
    <th>Deployment Targets</th>
    <th>Device Support</th>
    <th>Simulator</th>
    <th>Swift</th>
    </tr>
    </thead>
    <tbody>
    <tr>
    <td>Xcode&nbsp;27.1 beta</td>
    <td>macOS&nbsp;Tahoe&nbsp;26.6&nbsp;or&nbsp;later</td>
    <td>iOS&nbsp;27.1<br />
    tvOS&nbsp;27<br />
    watchOS&nbsp;27<br />
    visionOS&nbsp;27<br />
    macOS&nbsp;27<br />
    DriverKit&nbsp;27
    </td>
    <td>iOS&nbsp;15–27<br />
    iPadOS&nbsp;15–27<br />
    tvOS&nbsp;15–27<br />
    watchOS&nbsp;9-27<br />
    visionOS&nbsp;1–27<br />
    macOS&nbsp;12-27<br />
    DriverKit&nbsp;21-27
    </td>
    <td>iOS&nbsp;17&nbsp;or&nbsp;later<br>
    tvOS&nbsp;17&nbsp;or&nbsp;later<br>
    watchOS&nbsp;10&nbsp;or&nbsp;later<br>
    visionOS&nbsp;1&nbsp;or&nbsp;later
    </td>
    <td>iOS&nbsp;17&nbsp;or&nbsp;later<br>
    tvOS&nbsp;17&nbsp;or&nbsp;later<br>
    watchOS&nbsp;10&nbsp;or&nbsp;later<br>
    visionOS&nbsp;1&nbsp;or&nbsp;later
    </td>
    <td>
    <strong>Compiler:</strong><br />
    Swift&nbsp;6.4<br /><br>
    <strong>Language&nbsp;mode:</strong><br />
    Swift&nbsp;6<br />
    Swift&nbsp;5<br />
    Swift&nbsp;4.2<br />
    Swift&nbsp;4<br />
    </td>
    </tr>
    <tr>
    <td>Xcode&nbsp;27</td>
    <td>macOS&nbsp;Tahoe&nbsp;26.6&nbsp;or&nbsp;later</td>
    </tr>
    <tr>
    <td>Xcode&nbsp;26.6</td>
    <td>macOS&nbsp;Tahoe&nbsp;26.2 - macOS&nbsp;Tahoe&nbsp;26.x</td>
    </tr>
    <tr>
    <td>Xcode&nbsp;26.4.1</td>
    <td>macOS&nbsp;Tahoe&nbsp;26.2 - macOS&nbsp;Tahoe&nbsp;26.x</td>
    </tr>
    <tr>
    <td>Xcode&nbsp;26</td>
    <td>macOS&nbsp;Sequoia&nbsp;15.6 - macOS&nbsp;Tahoe&nbsp;26.x</td>
    </tr>
    </tbody>
    </table>
    </div>
    </accordion-panel>
    <accordion-panel id="other-releases">
    <h3>Other Xcode versions</h3>
    <div>
    <table class="typography-caption">
    <thead>
    <tr>
    <th>Xcode Version</th>
    <th>Supported macOS Versions</th>
    <th>SDKs</th>
    <th>Deployment Targets</th>
    <th>Device Support</th>
    <th>Simulator</th>
    <th>Swift</th>
    </tr>
    </thead>
    <tbody>
    <tr>
    <td>Xcode&nbsp;16.4</td>
    <td>macOS&nbsp;Sequoia&nbsp;15.3 - macOS&nbsp;Tahoe&nbsp;26.1.x</td>
    </tr>
    <tr>
    <td>Xcode&nbsp;15.4</td>
    <td>macOS&nbsp;Sonoma&nbsp;14.x</td>
    </tr>
    <tr>
    <td>Xcode&nbsp;15.1*</td>
    <td>macOS&nbsp;Ventura&nbsp;13.5&nbsp;-&nbsp;macOS&nbsp;Sonoma&nbsp;14.x</td>
    </tr>
    <tr>
    <td>Xcode&nbsp;15.0.x</td>
    <td>macOS&nbsp;Ventura&nbsp;13.5&nbsp;-&nbsp;macOS&nbsp;Sonoma&nbsp;14.x</td>
    </tr>
    <tr>
    <td>Xcode&nbsp;14.3*</td>
    <td>macOS&nbsp;Ventura&nbsp;13.x</td>
    </tr>
    </tbody>
    </table>
    </div>
    </accordion-panel>
    <h4 class="typography-headline-body">Exceptions</h4>
    <p>* The iOS&nbsp;15 and watchOS&nbsp;8 Simulators are not supported on macOS Sonoma 14.x.</p>
    """

    private func compatibility(
        _ number: String,
        _ kind: Release.Kind = .init(release: true),
        requires: String?,
        on macOS: String,
        page: String? = nil)
        -> Compatibility
    {
        Compatibility(
            makeRelease(number, "", (2026, 1, 1), kind: kind, requires: requires),
            macOS: macOS,
            requirements: SystemRequirements.parse(page ?? self.page))
    }
}
