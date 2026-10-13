//
// Copyright (c) 2026 Daniel Bauke
//

@testable import xcodectl
import XCTest

// MARK: - JSONOutputTests

/// The keys of `--json` are a contract for scripts and agents; the golden strings pin them.
final class JSONOutputTests: XCTestCase {
    // MARK: - list

    func testOnlyTheFinalOfASharedBuildIsInstalled() {
        let listed = entries([finalRelease, candidate], installed: [app], active: nil)
        XCTAssertEqual(listed.map(\.installed), [true, false])
        XCTAssertEqual(listed.map(\.active), [false, false])
    }

    func testTheActiveAppIsMarkedActive() {
        let listed = entries([finalRelease, candidate], installed: [app], active: app.path.path)
        XCTAssertEqual(listed.map(\.active), [true, false])
    }

    func testAPrereleaseIsMarked() {
        XCTAssertEqual(entries([finalRelease, candidate], installed: [], active: nil).map(\.prerelease), [false, true])
    }

    func testWithoutAMinimumMacOSTheKeyIsLeftOut() {
        XCTAssertNil(entries([finalRelease], installed: [], active: nil)[0].macOS)
    }

    func testAMacOSOlderThanTheMinimumDoesNotRunIt() {
        let release = makeRelease("27.0", "27A266a", (2026, 9, 14), requires: "26.6")
        XCTAssertEqual(
            entries([release], installed: [], active: nil, macOS: "26.4")[0].macOS,
            .init(minimum: "26.6", newest: nil, runsHere: false))
    }

    func testAMacOSNewerThanTheNewestSupportedDoesNotRunIt() {
        let release = makeRelease("26.4", "17E192", (2026, 3, 24), requires: "26.2")
        let requirements = [SystemRequirements.Row(xcode: "26.4", newestMacOS: "26.x")]
        XCTAssertEqual(
            entries([release], installed: [], active: nil, requirements: requirements)[0].macOS,
            .init(minimum: "26.2", newest: "26.x", runsHere: false))
    }

    func testASupportedMacOSRunsIt() {
        let release = makeRelease("27.0", "27A266a", (2026, 9, 14), requires: "26.6")
        XCTAssertEqual(
            entries([release], installed: [], active: nil, requirements: unbounded)[0].macOS,
            .init(minimum: "26.6", newest: nil, runsHere: true))
    }

    func testWithoutAnAppleRowWhetherItRunsIsUnknown() {
        let release = makeRelease("27.0", "27A266a", (2026, 9, 14), requires: "26.6")
        XCTAssertEqual(
            entries([release], installed: [], active: nil)[0].macOS,
            .init(minimum: "26.6", newest: nil, runsHere: nil))
    }

    func testAReleaseEncodes() throws {
        let release = makeRelease("27.0", "27A266a", (2026, 9, 14), requires: "26.6")
        let listed = entries([release], installed: [app], active: app.path.path, requirements: unbounded)
        XCTAssertEqual(try encodeJSON(listed), """
        [
          {
            "active" : true,
            "build" : "27A266a",
            "installed" : true,
            "macOS" : {
              "minimum" : "26.6",
              "runsHere" : true
            },
            "prerelease" : false,
            "released" : "2026-09-14",
            "version" : "27.0"
          }
        ]
        """)
    }

    // MARK: - list <platform>

    func testACatalogRuntimeIsInstalledWhenAReadyRegistrationHasItsBuild() throws {
        let installed = try SimCtl.parse(makeSimctlOutput([
            ("A", "com.apple.platform.iphonesimulator", "27.0", "24A1", "Ready", 1, "/a.asset/AssetData"),
            ("B", "com.apple.platform.appletvsimulator", "27.0", "24J1", "Unusable", 1, "/b.asset/AssetData"),
        ]))
        let entries = try runtimeJSON(makeCatalog(), installed: installed)
        XCTAssertEqual(entries.first { $0.build == "24A1" }?.installed, true)
        XCTAssertEqual(entries.first { $0.build == "24J1" }?.installed, false)
    }

    func testTheBetaRuntimeIsAPrerelease() throws {
        let entries = try runtimeJSON(makeCatalog(), installed: [])
        XCTAssertEqual(entries.first { $0.build == "24A51" }?.prerelease, true)
        XCTAssertEqual(entries.first { $0.build == "24A51" }?.version, "27.0")
        XCTAssertEqual(entries.first { $0.build == "24A1" }?.prerelease, false)
    }

    func testARuntimeWithoutASizeLeavesItOut() throws {
        let catalog = try Runtimes.parse(makeIndex([
            makeEntry(platform: "com.apple.platform.iphoneos", version: "27.0", build: "24A1", size: 0),
        ]))
        XCTAssertNil(runtimeJSON(catalog, installed: [])[0].size)
    }

    func testARuntimeEncodes() throws {
        let catalog = try Runtimes.parse(makeIndex([
            makeEntry(platform: "com.apple.platform.iphoneos", version: "27.0", build: "24A1"),
        ]))
        XCTAssertEqual(try encodeJSON(runtimeJSON(catalog, installed: [])), """
        [
          {
            "build" : "24A1",
            "installed" : false,
            "platform" : "ios",
            "prerelease" : false,
            "size" : 3600000000,
            "version" : "27.0"
          }
        ]
        """)
    }

    // MARK: - installed

    func testAnUnsizedXcodeLeavesItsSizeOut() {
        XCTAssertNil(installedJSON([(app, nil, [])], active: nil)[0].size)
    }

    func testTheActiveXcodeIsMarkedActive() {
        let entries = installedJSON([(app, 0, []), (beta, 0, [])], active: beta.path.path)
        XCTAssertEqual(entries.map(\.active), [false, true])
    }

    func testAnInstalledXcodeEncodesWithTheRuntimesItUses() throws {
        let entries = try installedJSON([(app, 3_583_873_024, registrations())], active: app.path.path)
        XCTAssertEqual(try encodeJSON(entries), """
        [
          {
            "active" : true,
            "build" : "27A266a",
            "path" : "/Applications/Xcode-27.0.app",
            "runtimes" : [
              {
                "build" : "24A434",
                "platform" : "ios",
                "size" : 8067000161,
                "version" : "27.0"
              }
            ],
            "size" : 3583873024,
            "version" : "27.0"
          }
        ]
        """)
    }

    // MARK: - installed runtimes

    func testARegistrationEncodesWithItsStateAndIdentifier() throws {
        XCTAssertEqual(try encodeJSON(registrationJSON(registrations())), """
        [
          {
            "build" : "24A434",
            "identifier" : "A",
            "platform" : "ios",
            "size" : 8067000161,
            "state" : "Ready",
            "version" : "27.0"
          }
        ]
        """)
    }

    func testARegistrationOfAnUnknownPlatformLeavesItOut() throws {
        let runtimes = try SimCtl.parse(makeSimctlOutput([
            ("A", "com.apple.platform.unknown", "1.0", "1A1", "Unusable", 0, "/a.dmg"),
        ]))
        XCTAssertNil(registrationJSON(runtimes)[0].platform)
    }

    // MARK: - auth status

    func testASignedInSessionEncodesItsSource() throws {
        XCTAssertEqual(try encodeJSON(SessionJSON(signedIn: true, source: "keychain")), """
        {
          "signedIn" : true,
          "source" : "keychain"
        }
        """)
    }

    func testASignedOutSessionEncodesTheReason() throws {
        XCTAssertEqual(try encodeJSON(SessionJSON(signedIn: false, reason: "not signed in")), """
        {
          "reason" : "not signed in",
          "signedIn" : false
        }
        """)
    }

    /// A release candidate and its final release carry the same build.
    private let finalRelease = makeRelease("27.0", "27A266a", (2026, 9, 14))
    private let candidate = makeRelease("27.0", "27A266a", (2026, 9, 9), kind: .init(rc: 1))
    private let app = makeApp("Xcode-27.0.app", version: "27.0", build: "27A266a")
    private let beta = makeApp("Xcode-27.1-beta1.app", version: "27.1", build: "27B5001a")
    /// Apple's row for 27.0, with no newest macOS.
    private let unbounded = [SystemRequirements.Row(xcode: "27.0", newestMacOS: nil)]

    private func registrations() throws -> [InstalledRuntime] {
        try SimCtl.parse(makeSimctlOutput([
            ("A", "com.apple.platform.iphonesimulator", "27.0", "24A434", "Ready", 8_067_000_161, "/a.asset/AssetData"),
        ]))
    }
}

/// `releaseJSON` on macOS 27.0 without Apple's page unless a test gives other values.
private func entries(
    _ releases: [Release],
    installed: [InstalledXcode],
    active: String?,
    requirements: [SystemRequirements.Row] = [],
    macOS: String = "27.0")
    -> [ReleaseJSON]
{
    releaseJSON(releases, installed: installed, active: active, requirements: requirements, macOS: macOS)
}
