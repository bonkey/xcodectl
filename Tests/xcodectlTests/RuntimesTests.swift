//
// Copyright (c) 2026 Daniel Bauke
//

@testable import xcodectl
import XCTest

// MARK: - RuntimesTests

final class RuntimesTests: XCTestCase {
    // MARK: - Index parsing

    func testParseKeepsOnlyTheCurrentCryptexFormat() throws {
        let runtimes = try Runtimes.parse(makeIndex([
            makeEntry(platform: "com.apple.platform.iphoneos", version: "26.5", build: "23F77"),
            makeEntry(
                platform: "com.apple.platform.iphoneos",
                version: "17.5",
                build: "21F79",
                contentType: "diskImage"),
            makeEntry(platform: "com.apple.platform.iphoneos", version: "12.4", build: "16G73", contentType: "package"),
        ]))
        XCTAssertEqual(runtimes.map(\.build), ["23F77"])
    }

    func testParseReadsEveryPlatform() throws {
        let runtimes = try Runtimes.parse(makeIndex([
            makeEntry(platform: "com.apple.platform.iphoneos", version: "26.0", build: "23A1"),
            makeEntry(platform: "com.apple.platform.appletvos", version: "26.0", build: "23J1"),
            makeEntry(platform: "com.apple.platform.watchos", version: "26.0", build: "23R1"),
            makeEntry(platform: "com.apple.platform.xros", version: "26.0", build: "23M1"),
        ]))
        XCTAssertEqual(Set(runtimes.map(\.platform)), Set(RuntimePlatform.allCases))
    }

    func testParseSkipsAnUnknownPlatform() throws {
        let runtimes = try Runtimes.parse(makeIndex([
            makeEntry(platform: "com.apple.platform.macosx", version: "26.0", build: "23X1"),
        ]))
        XCTAssertTrue(runtimes.isEmpty)
    }

    // MARK: - Apple Silicon selection

    /// Apple publishes many builds twice, arm64-only and universal. This tool is Apple Silicon only,
    /// so the arm64-only artifact wins and the row appears once.
    func testForThisMacPrefersTheAppleSiliconArtifactOverTheUniversalOne() throws {
        let runtimes = try Runtimes.parse(makeIndex([
            makeEntry(
                platform: "com.apple.platform.iphoneos",
                version: "26.5",
                build: "23F77",
                architectures: ["arm64", "x86_64"]),
            makeEntry(
                platform: "com.apple.platform.iphoneos",
                version: "26.5",
                build: "23F77",
                architectures: ["arm64"]),
        ]))
        XCTAssertEqual(runtimes.count, 1)
        XCTAssertEqual(runtimes[0].architectures, ["arm64"])
    }

    func testForThisMacKeepsTheUniversalArtifactWhenNoAppleSiliconOneExists() throws {
        let runtimes = try Runtimes.parse(makeIndex([
            makeEntry(
                platform: "com.apple.platform.iphoneos",
                version: "26.5",
                build: "23F77",
                architectures: ["arm64", "x86_64"]),
        ]))
        XCTAssertEqual(runtimes.map(\.architectures), [["arm64", "x86_64"]])
        XCTAssertFalse(runtimes[0].isAppleSiliconOnly)
    }

    func testDifferentBuildsOfOneVersionBothSurvive() throws {
        let runtimes = try Runtimes.parse(makeIndex([
            makeEntry(platform: "com.apple.platform.appletvos", version: "27.0", build: "24J360"),
            makeEntry(
                platform: "com.apple.platform.appletvos",
                version: "27.0",
                build: "24J5356a",
                name: "tvOS 27.0 beta 4 Simulator Runtime"),
        ]))
        XCTAssertEqual(runtimes.map(\.build), ["24J360", "24J5356a"])
    }

    // MARK: - Listing

    func testDefaultListingKeepsTheNewestMajorOfEachPlatform() throws {
        let runtimes = try Runtimes.parse(makeIndex([
            makeEntry(platform: "com.apple.platform.iphoneos", version: "27.0", build: "24A1"),
            makeEntry(platform: "com.apple.platform.iphoneos", version: "26.5", build: "23F1"),
            makeEntry(platform: "com.apple.platform.appletvos", version: "26.0", build: "23J1"),
        ]))
        XCTAssertEqual(Runtimes.defaultListing(runtimes).map(\.build), ["24A1", "23J1"])
    }

    func testDefaultListingNarrowsToOnePlatform() throws {
        let runtimes = try Runtimes.parse(makeIndex([
            makeEntry(platform: "com.apple.platform.iphoneos", version: "27.0", build: "24A1"),
            makeEntry(platform: "com.apple.platform.appletvos", version: "27.0", build: "24J1"),
        ]))
        XCTAssertEqual(Runtimes.defaultListing(runtimes, platform: .tvos).map(\.build), ["24J1"])
    }

    /// A beta newer than the newest release shows, so a running beta cycle is visible; a beta of a
    /// version that already shipped does not.
    func testCurrentListingKeepsBetasNewerThanTheNewestRelease() throws {
        let runtimes = try Runtimes.parse(makeIndex([
            makeEntry(
                platform: "com.apple.platform.iphoneos",
                version: "27.2",
                build: "24B1",
                name: "iOS 27.2 beta Simulator Runtime"),
            makeEntry(platform: "com.apple.platform.iphoneos", version: "27.0", build: "24A1"),
            makeEntry(
                platform: "com.apple.platform.iphoneos",
                version: "27.0",
                build: "24A51",
                name: "iOS 27.0 beta 2 Simulator Runtime"),
        ]))
        XCTAssertEqual(Runtimes.defaultListing(runtimes).map(\.build), ["24B1", "24A1"])
    }

    func testStableListingDropsEveryBeta() throws {
        let runtimes = try Runtimes.parse(makeIndex([
            makeEntry(
                platform: "com.apple.platform.iphoneos",
                version: "27.2",
                build: "24B1",
                name: "iOS 27.2 beta Simulator Runtime"),
            makeEntry(platform: "com.apple.platform.iphoneos", version: "27.0", build: "24A1"),
        ]))
        XCTAssertEqual(Runtimes.defaultListing(runtimes, platform: nil, .stable).map(\.build), ["24A1"])
    }

    // MARK: - Resolution

    func testResolveMatchesABuildExactly() throws {
        let runtimes = try makeCatalog()
        XCTAssertEqual(try Runtimes.resolve("24A1", platform: .ios, in: runtimes).build, "24A1")
    }

    /// A version is not unique: a release and its beta share one. The release wins.
    func testResolvePrefersTheReleaseOverABetaOfTheSameVersion() throws {
        let runtimes = try makeCatalog()
        XCTAssertEqual(try Runtimes.resolve("27.0", platform: .ios, in: runtimes).build, "24A1")
    }

    func testResolveMatchesAVersionPrefix() throws {
        let runtimes = try makeCatalog()
        XCTAssertEqual(try Runtimes.resolve("27", platform: .ios, in: runtimes).build, "24A1")
    }

    func testResolveStaysWithinItsPlatform() throws {
        let runtimes = try makeCatalog()
        XCTAssertThrowsError(try Runtimes.resolve("24A1", platform: .tvos, in: runtimes))
    }

    func testResolveRejectsAnUnknownVersion() throws {
        let runtimes = try makeCatalog()
        XCTAssertThrowsError(try Runtimes.resolve("99.0", platform: .ios, in: runtimes))
    }

    // MARK: - Host requirements

    /// Some prereleases pin themselves to one exact Xcode.
    func testRuntimePinnedToOneXcodeRejectsEveryOther() throws {
        let runtimes = try Runtimes.parse(makeIndex([
            makeEntry(
                platform: "com.apple.platform.iphoneos",
                version: "27.1",
                build: "24A94401",
                minXcode: "27.1.0",
                maxXcode: "27.1.0"),
        ]))
        XCTAssertTrue(runtimes[0].runs(onXcode: "27.1"))
        XCTAssertFalse(runtimes[0].runs(onXcode: "27.0"))
        XCTAssertFalse(runtimes[0].runs(onXcode: "27.2"))
    }

    func testRuntimeWithoutRequirementsRunsAnywhere() throws {
        let runtimes = try makeCatalog()
        XCTAssertTrue(runtimes[0].runs(onXcode: "16.1"))
    }

    // MARK: - Size estimate

    func testEstimatedSizeSumsTheNewestReleaseOfEachPlatform() throws {
        let runtimes = try Runtimes.parse(makeIndex([
            makeEntry(platform: "com.apple.platform.iphoneos", version: "27.0", build: "24A1", size: 8_000_000_000),
            makeEntry(platform: "com.apple.platform.appletvos", version: "27.0", build: "24J1", size: 3_000_000_000),
        ]))
        XCTAssertEqual(Runtimes.estimatedSize([.ios, .tvos], in: runtimes), 11_000_000_000)
        XCTAssertEqual(Runtimes.estimatedSize([.ios], in: runtimes), 8_000_000_000)
    }

    func testEstimatedSizeIgnoresBetas() throws {
        let runtimes = try Runtimes.parse(makeIndex([
            makeEntry(
                platform: "com.apple.platform.iphoneos",
                version: "27.2",
                build: "24B1",
                name: "iOS 27.2 beta Simulator Runtime",
                size: 9_000_000_000),
            makeEntry(platform: "com.apple.platform.iphoneos", version: "27.0", build: "24A1", size: 8_000_000_000),
        ]))
        XCTAssertEqual(Runtimes.estimatedSize([.ios], in: runtimes), 8_000_000_000)
    }
}

// MARK: - SimCtlTests

final class SimCtlTests: XCTestCase {
    func testParseReadsEveryRegistration() throws {
        let runtimes = try SimCtl.parse(makeSimctlOutput([
            (
                "4AA57150",
                "com.apple.platform.iphonesimulator",
                "27.1",
                "24A94401",
                "Ready",
                7_873_719_649,
                "/System/Library/AssetsV2/com_apple_MobileAsset_iOSSimulatorRuntime/abc.asset/AssetData"),
        ]))
        XCTAssertEqual(runtimes.count, 1)
        XCTAssertEqual(runtimes[0].identifier, "4AA57150")
        XCTAssertEqual(runtimes[0].platform, .ios)
        XCTAssertEqual(runtimes[0].build, "24A94401")
        XCTAssertTrue(runtimes[0].isReady)
    }

    /// The leftovers that hold disk space are exactly the ones `simctl runtime list` will not print.
    func testParseKeepsUnusableRegistrations() throws {
        let runtimes = try SimCtl.parse(makeSimctlOutput([
            (
                "471299F8",
                "com.apple.platform.appletvsimulator",
                "26.0",
                "23J5316g",
                "Unusable",
                3_300_000_000,
                "/System/Library/AssetsV2/com_apple_MobileAsset_appleTVOSSimulatorRuntime/def.asset/AssetData"),
        ]))
        XCTAssertEqual(runtimes.count, 1)
        XCTAssertFalse(runtimes[0].isReady)
        XCTAssertEqual(runtimes[0].state, "Unusable")
    }

    func testAssetDirectoryIsTheAssetBundleHoldingTheSpace() throws {
        let runtimes = try SimCtl.parse(makeSimctlOutput([
            (
                "A",
                "com.apple.platform.iphonesimulator",
                "26.5",
                "23F77",
                "Ready",
                1,
                "/System/Library/AssetsV2/com_apple_MobileAsset_iOSSimulatorRuntime/abc.asset/AssetData/Restore/x.dmg"),
        ]))
        XCTAssertEqual(
            runtimes[0].assetDirectory?.path,
            "/System/Library/AssetsV2/com_apple_MobileAsset_iOSSimulatorRuntime/abc.asset")
    }

    /// A runtime installed from a plain disk image has no MobileAsset behind it.
    func testAssetDirectoryIsNilForADiskImageRuntime() throws {
        let runtimes = try SimCtl.parse(makeSimctlOutput([
            (
                "A",
                "com.apple.platform.iphonesimulator",
                "26.5",
                "23F77",
                "Ready",
                1,
                "/Library/Developer/CoreSimulator/Images/abc.dmg"),
        ]))
        XCTAssertNil(runtimes[0].assetDirectory)
    }

    func testParseRejectsOutputThatIsNotJSON() {
        XCTAssertThrowsError(try SimCtl.parse(Data("not json".utf8)))
    }
}

// MARK: - RuntimeInstallerTests

final class RuntimeInstallerTests: XCTestCase {
    func testProgressFractionReadsAPercentage() {
        XCTAssertEqual(
            RuntimeInstaller.progressFraction("Downloading tvOS 26.0 Simulator: 41.5 % (1.4 GB of 3.5 GB)"),
            0.415)
    }

    /// xcodebuild prints progress in the host locale, so the separator can be a comma. The tool forces
    /// the C locale, but a stray comma must not read as 0.
    func testProgressFractionAcceptsADecimalComma() {
        XCTAssertEqual(RuntimeInstaller.progressFraction("Downloading: 41,5 % (1,4 GB of 3,5 GB)"), 0.415)
    }

    func testProgressFractionIgnoresLinesWithoutAPercentage() {
        XCTAssertNil(RuntimeInstaller.progressFraction("Downloading tvOS 26.0 Simulator: Installing..."))
        XCTAssertNil(RuntimeInstaller.progressFraction("Finding content..."))
    }

    func testProgressFractionClampsToOne() {
        XCTAssertEqual(RuntimeInstaller.progressFraction("100 %"), 1)
    }

    func testAlreadyInstalledRecognisesADuplicateImage() {
        XCTAssertTrue(RuntimeInstaller.isAlreadyInstalled(
            "Error Domain=SimDiskImageErrorDomain Code=9 \"Duplicate of image at /Library/...\""))
        XCTAssertFalse(RuntimeInstaller.isAlreadyInstalled("Error Domain=NSPOSIXErrorDomain Code=22"))
    }
}

// MARK: - RuntimeSelectionTests

final class RuntimeSelectionTests: XCTestCase {
    func testAllSelectsEveryPlatformInOneRun() {
        let selection = RuntimeSelection(argument: "all")
        XCTAssertEqual(selection?.platforms, RuntimePlatform.allCases)
        XCTAssertEqual(selection?.isAll, true)
    }

    func testCommaListSelectsThosePlatforms() {
        let selection = RuntimeSelection(argument: "ios,watchos")
        XCTAssertEqual(selection?.platforms, [.ios, .watchos])
        XCTAssertEqual(selection?.isAll, false)
    }

    func testCommaListIgnoresCaseSpacingAndRepeats() {
        XCTAssertEqual(RuntimeSelection(argument: " iOS , watchOS , ios ")?.platforms, [.ios, .watchos])
    }

    func testUnknownPlatformIsRejected() {
        XCTAssertNil(RuntimeSelection(argument: "ios,android"))
        XCTAssertNil(RuntimeSelection(argument: ""))
    }
}
