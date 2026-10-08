//
// Copyright (c) 2026 Daniel Bauke
//

@testable import xcodectl
import XCTest

// MARK: - RuntimesTests

final class RuntimesTests: XCTestCase {
    // MARK: - Index parsing

    /// Disk images (iOS 16 and 17) download from their own URL; installer packages (iOS 15 and
    /// older) are not read.
    func testParseKeepsCryptexesAndDiskImagesButNotPackages() throws {
        let runtimes = try Runtimes.parse(makeIndex([
            makeEntry(platform: "com.apple.platform.iphoneos", version: "26.5", build: "23F77"),
            makeEntry(
                platform: "com.apple.platform.iphoneos",
                version: "17.5",
                build: "21F79",
                contentType: "diskImage"),
            makeEntry(platform: "com.apple.platform.iphoneos", version: "12.4", build: "16G73", contentType: "package"),
        ]))
        XCTAssertEqual(runtimes.map(\.build), ["23F77", "21F79"])
        XCTAssertNil(runtimes[0].source)
        XCTAssertEqual(
            runtimes[1].source?.absoluteString,
            "https://download.developer.apple.com/Developer_Tools/21F79/21F79.dmg")
    }

    func testParseSkipsADiskImageWithoutASource() throws {
        var entry = makeEntry(
            platform: "com.apple.platform.iphoneos",
            version: "17.5",
            build: "21F79",
            contentType: "diskImage")
        entry["source"] = nil
        XCTAssertTrue(try Runtimes.parse(makeIndex([entry])).isEmpty)
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

    func testResolveTakesTheNewestReleaseOfAnOlderMajor() throws {
        let runtimes = try Runtimes.parse(makeIndex([
            makeEntry(platform: "com.apple.platform.iphoneos", version: "18.0", build: "22A3351"),
            makeEntry(
                platform: "com.apple.platform.iphoneos",
                version: "17.5",
                build: "21F5058d",
                name: "iOS 17.5 beta 2 Simulator Runtime",
                contentType: "diskImage"),
            makeEntry(
                platform: "com.apple.platform.iphoneos",
                version: "17.5",
                build: "21F79",
                contentType: "diskImage"),
            makeEntry(
                platform: "com.apple.platform.iphoneos",
                version: "17.4",
                build: "21E213",
                contentType: "diskImage"),
        ]))
        XCTAssertEqual(try Runtimes.resolve("17", platform: .ios, in: runtimes).build, "21F79")
        XCTAssertEqual(try Runtimes.resolve("17.4", platform: .ios, in: runtimes).build, "21E213")
    }

    func testResolveStaysWithinItsPlatform() throws {
        let runtimes = try makeCatalog()
        XCTAssertThrowsError(try Runtimes.resolve("24A1", platform: .tvos, in: runtimes))
    }

    func testResolveRejectsAnUnknownVersion() throws {
        let runtimes = try makeCatalog()
        XCTAssertThrowsError(try Runtimes.resolve("99.0", platform: .ios, in: runtimes)) { error in
            XCTAssertTrue("\(error)".contains("`xcodectl list ios --all`"), "\(error)")
        }
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

    // MARK: - Asset server

    /// Xcode 27 refuses a cryptex the index lists without architectures, which is every one before
    /// iOS 26, so this tool installs those itself.
    func testCryptexWithoutArchitecturesInstallsFromTheAssetServerThroughXcode27AndNewer() throws {
        let runtime = try makeCryptexWithoutArchitectures()
        XCTAssertTrue(runtime.installsFromAssetServer(onXcode: "27.0"))
        XCTAssertTrue(runtime.installsFromAssetServer(onXcode: "27.2"))
        XCTAssertTrue(runtime.installsFromAssetServer(onXcode: "28.0"))
    }

    func testXcode26InstallsACryptexWithoutArchitecturesThroughXcodebuild() throws {
        let runtime = try makeCryptexWithoutArchitectures()
        XCTAssertFalse(runtime.installsFromAssetServer(onXcode: "26.4"))
        XCTAssertFalse(runtime.installsFromAssetServer(onXcode: "26.4.1"))
    }

    func testCryptexWithArchitecturesInstallsThroughXcodebuild() throws {
        let runtimes = try Runtimes.parse(makeIndex([
            makeEntry(platform: "com.apple.platform.iphoneos", version: "26.0", build: "23A339"),
            makeEntry(
                platform: "com.apple.platform.appletvos",
                version: "26.0",
                build: "23J352",
                architectures: ["arm64", "x86_64"]),
        ]))
        XCTAssertEqual(runtimes.count, 2)
        for runtime in runtimes {
            XCTAssertFalse(runtime.installsFromAssetServer(onXcode: "27.0"), runtime.build)
        }
    }

    func testDiskImageNeverInstallsFromTheAssetServer() throws {
        var entry = makeEntry(
            platform: "com.apple.platform.iphoneos",
            version: "17.5",
            build: "21F79",
            contentType: "diskImage")
        entry["architectures"] = nil
        let runtimes = try Runtimes.parse(makeIndex([entry]))
        XCTAssertFalse(runtimes[0].installsFromAssetServer(onXcode: "27.0"))
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

    /// iOS 18.6 the way the index lists it: a cryptex without an `architectures` key.
    private func makeCryptexWithoutArchitectures() throws -> SimulatorRuntime {
        var entry = makeEntry(platform: "com.apple.platform.iphoneos", version: "18.6", build: "22G86")
        entry["architectures"] = nil
        return try XCTUnwrap(Runtimes.parse(makeIndex([entry])).first)
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

    func testAlreadyInstalledRecognisesAnAlreadyDownloadedRuntime() {
        XCTAssertTrue(RuntimeInstaller.isAlreadyInstalled(
            "Finding content...\niOS 24B5084k (arm64Only) is already downloaded."))
        XCTAssertFalse(RuntimeInstaller.isAlreadyInstalled("Finding content...\nDownloading iOS 27.2: 41.5 %"))
    }

    /// Without a build, xcodebuild finds nothing left to download for the runtime its Xcode uses.
    func testAlreadyInstalledRecognisesNoNeededDownloadables() {
        XCTAssertTrue(RuntimeInstaller.isAlreadyInstalled(
            "Finding content...\nNo needed downloadables found for arm64Only"))
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

// MARK: - RuntimeMatchTests

final class RuntimeMatchTests: XCTestCase {
    /// `simctl runtime match list -j` for Xcode 27.0 with only iOS installed: iOS resolves to a newer
    /// runtime build than its SDK, the others to their SDK build although nothing is installed.
    func testParseMatchesReadsTheChosenRuntimeOfEverySDK() throws {
        let output = """
        {
          "appletvos27.0" : {"chosenRuntimeBuild" : "24J360", "defaultBuild" : "24J360", "sdkBuild" : "24J360"},
          "iphoneos27.0" : {"chosenRuntimeBuild" : "24A434", "defaultBuild" : "24A430", "sdkBuild" : "24A430"},
          "watchos27.0" : {"chosenRuntimeBuild" : "24R360", "defaultBuild" : "24R360", "sdkBuild" : "24R360"}
        }
        """
        XCTAssertEqual(try SimCtl.parseMatches(Data(output.utf8)), ["24j360", "24a434", "24r360"])
    }

    func testParseMatchesRejectsOutputThatIsNotJSON() {
        XCTAssertThrowsError(try SimCtl.parseMatches(Data("not json".utf8)))
    }

    /// A chosen build with no registration behind it is a platform without a runtime installed.
    func testUsedTakesTheInstalledRuntimesWithAChosenBuild() throws {
        let used = try Runtimes.used(by: ["24a434", "24r360"], in: installed())
        XCTAssertEqual(used.map(\.build), ["24A434"])
    }

    func testUsedSkipsRegistrationsThatAreNotReady() throws {
        let installed = try SimCtl.parse(makeSimctlOutput([
            ("A", "com.apple.platform.iphonesimulator", "27.0", "24A434", "Unusable", 1, "/x.asset/AssetData"),
        ]))
        XCTAssertEqual(Runtimes.used(by: ["24a434"], in: installed), [])
    }

    func testExclusiveKeepsWhatAnotherXcodeUses() throws {
        let exclusive = try Runtimes.exclusive(
            to: ["24a434", "24j360"],
            others: [["24a94401", "24j360"]],
            in: installed())
        XCTAssertEqual(exclusive.map(\.build), ["24A434"])
    }

    func testExclusiveWithoutOtherXcodesIsEverythingUsed() throws {
        let exclusive = try Runtimes.exclusive(to: ["24a434", "24j360"], others: [], in: installed())
        XCTAssertEqual(exclusive.map(\.build), ["24A434", "24J360"])
    }

    /// iOS 27.0 and 27.1 plus tvOS 27.0, all ready.
    private func installed() throws -> [InstalledRuntime] {
        try SimCtl.parse(makeSimctlOutput([
            ("A", "com.apple.platform.iphonesimulator", "27.0", "24A434", "Ready", 8_067_000_161, "/a.asset/AssetData"),
            (
                "B",
                "com.apple.platform.iphonesimulator",
                "27.1",
                "24A94401",
                "Ready",
                7_873_719_649,
                "/b.asset/AssetData"),
            (
                "C",
                "com.apple.platform.appletvsimulator",
                "27.0",
                "24J360",
                "Ready",
                3_300_000_000,
                "/c.asset/AssetData"),
        ]))
    }
}
