//
// Copyright (c) 2026 Daniel Bauke
//

@testable import xcodectl
import Foundation
import Testing

// MARK: - RuntimesTests

struct RuntimesTests {
    // MARK: - Index parsing

    /// Disk images (iOS 16 and 17) download from their own URL; installer packages (iOS 15 and
    /// older) are not read.
    @Test func `parse keeps cryptexes and disk images but not packages`() throws {
        let runtimes = try Runtimes.parse(makeIndex([
            makeEntry(platform: "com.apple.platform.iphoneos", version: "26.5", build: "23F77"),
            makeEntry(
                platform: "com.apple.platform.iphoneos",
                version: "17.5",
                build: "21F79",
                contentType: "diskImage"),
            makeEntry(platform: "com.apple.platform.iphoneos", version: "12.4", build: "16G73", contentType: "package"),
        ]))
        #expect(runtimes.map(\.build) == ["23F77", "21F79"])
        #expect(runtimes[0].source == nil)
        #expect(
            runtimes[1].source?.absoluteString ==
                "https://download.developer.apple.com/Developer_Tools/21F79/21F79.dmg")
    }

    @Test func `parse skips a disk image without a source`() throws {
        var entry = makeEntry(
            platform: "com.apple.platform.iphoneos",
            version: "17.5",
            build: "21F79",
            contentType: "diskImage")
        entry["source"] = nil
        #expect(try Runtimes.parse(makeIndex([entry])).isEmpty)
    }

    @Test func `parse reads every platform`() throws {
        let runtimes = try Runtimes.parse(makeIndex([
            makeEntry(platform: "com.apple.platform.iphoneos", version: "26.0", build: "23A1"),
            makeEntry(platform: "com.apple.platform.appletvos", version: "26.0", build: "23J1"),
            makeEntry(platform: "com.apple.platform.watchos", version: "26.0", build: "23R1"),
            makeEntry(platform: "com.apple.platform.xros", version: "26.0", build: "23M1"),
        ]))
        #expect(Set(runtimes.map(\.platform)) == Set(RuntimePlatform.allCases))
    }

    @Test func `parse skips an unknown platform`() throws {
        let runtimes = try Runtimes.parse(makeIndex([
            makeEntry(platform: "com.apple.platform.macosx", version: "26.0", build: "23X1"),
        ]))
        #expect(runtimes.isEmpty)
    }

    // MARK: - Apple Silicon selection

    /// Apple publishes many builds twice, arm64-only and universal. This tool is Apple Silicon only,
    /// so the arm64-only artifact wins and the row appears once.
    @Test func `for this Mac prefers the Apple silicon artifact over the universal one`() throws {
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
        #expect(runtimes.count == 1)
        #expect(runtimes[0].architectures == ["arm64"])
    }

    @Test func `for this Mac keeps the universal artifact when no Apple silicon one exists`() throws {
        let runtimes = try Runtimes.parse(makeIndex([
            makeEntry(
                platform: "com.apple.platform.iphoneos",
                version: "26.5",
                build: "23F77",
                architectures: ["arm64", "x86_64"]),
        ]))
        #expect(runtimes.map(\.architectures) == [["arm64", "x86_64"]])
        #expect(!runtimes[0].isAppleSiliconOnly)
    }

    @Test func `different builds of one version both survive`() throws {
        let runtimes = try Runtimes.parse(makeIndex([
            makeEntry(platform: "com.apple.platform.appletvos", version: "27.0", build: "24J360"),
            makeEntry(
                platform: "com.apple.platform.appletvos",
                version: "27.0",
                build: "24J5356a",
                name: "tvOS 27.0 beta 4 Simulator Runtime"),
        ]))
        #expect(runtimes.map(\.build) == ["24J360", "24J5356a"])
    }

    // MARK: - Listing

    @Test func `default listing keeps the newest major of each platform`() throws {
        let runtimes = try Runtimes.parse(makeIndex([
            makeEntry(platform: "com.apple.platform.iphoneos", version: "27.0", build: "24A1"),
            makeEntry(platform: "com.apple.platform.iphoneos", version: "26.5", build: "23F1"),
            makeEntry(platform: "com.apple.platform.appletvos", version: "26.0", build: "23J1"),
        ]))
        #expect(Runtimes.defaultListing(runtimes).map(\.build) == ["24A1", "23J1"])
    }

    @Test func `default listing narrows to one platform`() throws {
        let runtimes = try Runtimes.parse(makeIndex([
            makeEntry(platform: "com.apple.platform.iphoneos", version: "27.0", build: "24A1"),
            makeEntry(platform: "com.apple.platform.appletvos", version: "27.0", build: "24J1"),
        ]))
        #expect(Runtimes.defaultListing(runtimes, platform: .tvos).map(\.build) == ["24J1"])
    }

    /// A beta newer than the newest release shows, so a running beta cycle is visible; a beta of a
    /// version that already shipped does not.
    @Test func `current listing keeps betas newer than the newest release`() throws {
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
        #expect(Runtimes.defaultListing(runtimes).map(\.build) == ["24B1", "24A1"])
    }

    @Test func `stable listing drops every beta`() throws {
        let runtimes = try Runtimes.parse(makeIndex([
            makeEntry(
                platform: "com.apple.platform.iphoneos",
                version: "27.2",
                build: "24B1",
                name: "iOS 27.2 beta Simulator Runtime"),
            makeEntry(platform: "com.apple.platform.iphoneos", version: "27.0", build: "24A1"),
        ]))
        #expect(Runtimes.defaultListing(runtimes, platform: nil, .stable).map(\.build) == ["24A1"])
    }

    // MARK: - Resolution

    @Test func `resolve matches a build exactly`() throws {
        let runtimes = try makeCatalog()
        #expect(try Runtimes.resolve("24A1", platform: .ios, in: runtimes).build == "24A1")
    }

    /// A version is not unique: a release and its beta share one. The release wins.
    @Test func `resolve prefers the release over a beta of the same version`() throws {
        let runtimes = try makeCatalog()
        #expect(try Runtimes.resolve("27.0", platform: .ios, in: runtimes).build == "24A1")
    }

    @Test func `resolve matches a version prefix`() throws {
        let runtimes = try makeCatalog()
        #expect(try Runtimes.resolve("27", platform: .ios, in: runtimes).build == "24A1")
    }

    @Test func `resolve takes the newest release of an older major`() throws {
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
        #expect(try Runtimes.resolve("17", platform: .ios, in: runtimes).build == "21F79")
        #expect(try Runtimes.resolve("17.4", platform: .ios, in: runtimes).build == "21E213")
    }

    @Test func `resolve stays within its platform`() throws {
        let runtimes = try makeCatalog()
        #expect(throws: Error.self) { try Runtimes.resolve("24A1", platform: .tvos, in: runtimes) }
    }

    @Test func `resolve rejects an unknown version`() throws {
        let runtimes = try makeCatalog()
        let error = try #require(throws: Error.self) {
            try Runtimes.resolve("99.0", platform: .ios, in: runtimes)
        }
        #expect("\(error)".contains("`xcodectl list ios --all`"), "\(error)")
    }

    // MARK: - Host requirements

    /// Some prereleases pin themselves to one exact Xcode.
    @Test func `runtime pinned to one Xcode rejects every other`() throws {
        let runtimes = try Runtimes.parse(makeIndex([
            makeEntry(
                platform: "com.apple.platform.iphoneos",
                version: "27.1",
                build: "24A94401",
                minXcode: "27.1.0",
                maxXcode: "27.1.0"),
        ]))
        #expect(runtimes[0].runs(onXcode: "27.1"))
        #expect(!runtimes[0].runs(onXcode: "27.0"))
        #expect(!runtimes[0].runs(onXcode: "27.2"))
    }

    @Test func `runtime without requirements runs anywhere`() throws {
        let runtimes = try makeCatalog()
        #expect(runtimes[0].runs(onXcode: "16.1"))
    }

    // MARK: - Asset server

    /// Xcode 27 refuses a cryptex the index lists without architectures, which is every one before
    /// iOS 26, so this tool installs those itself.
    @Test func `cryptex without architectures installs from the asset server through Xcode 27 and newer`() throws {
        let runtime = try makeCryptexWithoutArchitectures()
        #expect(runtime.installsFromAssetServer(onXcode: "27.0"))
        #expect(runtime.installsFromAssetServer(onXcode: "27.2"))
        #expect(runtime.installsFromAssetServer(onXcode: "28.0"))
    }

    @Test func `Xcode 26 installs a cryptex without architectures through xcodebuild`() throws {
        let runtime = try makeCryptexWithoutArchitectures()
        #expect(!runtime.installsFromAssetServer(onXcode: "26.4"))
        #expect(!runtime.installsFromAssetServer(onXcode: "26.4.1"))
    }

    @Test func `cryptex with architectures installs through xcodebuild`() throws {
        let runtimes = try Runtimes.parse(makeIndex([
            makeEntry(platform: "com.apple.platform.iphoneos", version: "26.0", build: "23A339"),
            makeEntry(
                platform: "com.apple.platform.appletvos",
                version: "26.0",
                build: "23J352",
                architectures: ["arm64", "x86_64"]),
        ]))
        #expect(runtimes.count == 2)
        for runtime in runtimes {
            #expect(!runtime.installsFromAssetServer(onXcode: "27.0"), "\(runtime.build)")
        }
    }

    @Test func `disk image never installs from the asset server`() throws {
        var entry = makeEntry(
            platform: "com.apple.platform.iphoneos",
            version: "17.5",
            build: "21F79",
            contentType: "diskImage")
        entry["architectures"] = nil
        let runtimes = try Runtimes.parse(makeIndex([entry]))
        #expect(!runtimes[0].installsFromAssetServer(onXcode: "27.0"))
    }

    // MARK: - Size estimate

    @Test func `estimated size sums the newest release of each platform`() throws {
        let runtimes = try Runtimes.parse(makeIndex([
            makeEntry(platform: "com.apple.platform.iphoneos", version: "27.0", build: "24A1", size: 8_000_000_000),
            makeEntry(platform: "com.apple.platform.appletvos", version: "27.0", build: "24J1", size: 3_000_000_000),
        ]))
        #expect(Runtimes.estimatedSize([.ios, .tvos], in: runtimes) == 11_000_000_000)
        #expect(Runtimes.estimatedSize([.ios], in: runtimes) == 8_000_000_000)
    }

    @Test func `estimated size ignores betas`() throws {
        let runtimes = try Runtimes.parse(makeIndex([
            makeEntry(
                platform: "com.apple.platform.iphoneos",
                version: "27.2",
                build: "24B1",
                name: "iOS 27.2 beta Simulator Runtime",
                size: 9_000_000_000),
            makeEntry(platform: "com.apple.platform.iphoneos", version: "27.0", build: "24A1", size: 8_000_000_000),
        ]))
        #expect(Runtimes.estimatedSize([.ios], in: runtimes) == 8_000_000_000)
    }

    /// iOS 18.6 the way the index lists it: a cryptex without an `architectures` key.
    private func makeCryptexWithoutArchitectures() throws -> SimulatorRuntime {
        var entry = makeEntry(platform: "com.apple.platform.iphoneos", version: "18.6", build: "22G86")
        entry["architectures"] = nil
        return try #require(Runtimes.parse(makeIndex([entry])).first)
    }
}

// MARK: - SimCtlTests

struct SimCtlTests {
    @Test func `parse reads every registration`() throws {
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
        #expect(runtimes.count == 1)
        #expect(runtimes[0].identifier == "4AA57150")
        #expect(runtimes[0].platform == .ios)
        #expect(runtimes[0].build == "24A94401")
        #expect(runtimes[0].isReady)
    }

    /// The leftovers that hold disk space are exactly the ones `simctl runtime list` will not print.
    @Test func `parse keeps unusable registrations`() throws {
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
        #expect(runtimes.count == 1)
        #expect(!runtimes[0].isReady)
        #expect(runtimes[0].state == "Unusable")
    }

    @Test func `asset directory is the asset bundle holding the space`() throws {
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
        #expect(
            runtimes[0].assetDirectory?.path ==
                "/System/Library/AssetsV2/com_apple_MobileAsset_iOSSimulatorRuntime/abc.asset")
    }

    /// A runtime installed from a plain disk image has no MobileAsset behind it.
    @Test func `asset directory is nil for a disk image runtime`() throws {
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
        #expect(runtimes[0].assetDirectory == nil)
    }

    @Test func `parse rejects output that is not JSON`() {
        #expect(throws: Error.self) { try SimCtl.parse(Data("not json".utf8)) }
    }
}

// MARK: - RuntimeInstallerTests

struct RuntimeInstallerTests {
    @Test func `progress fraction reads a percentage`() {
        #expect(
            RuntimeInstaller.progressFraction("Downloading tvOS 26.0 Simulator: 41.5 % (1.4 GB of 3.5 GB)") ==
                0.415)
    }

    /// xcodebuild prints progress in the host locale, so the separator can be a comma. The tool forces
    /// the C locale, but a stray comma must not read as 0.
    @Test func `progress fraction accepts a decimal comma`() {
        #expect(RuntimeInstaller.progressFraction("Downloading: 41,5 % (1,4 GB of 3,5 GB)") == 0.415)
    }

    @Test func `progress fraction ignores lines without a percentage`() {
        #expect(RuntimeInstaller.progressFraction("Downloading tvOS 26.0 Simulator: Installing...") == nil)
        #expect(RuntimeInstaller.progressFraction("Finding content...") == nil)
    }

    @Test func `progress fraction clamps to one`() {
        #expect(RuntimeInstaller.progressFraction("100 %") == 1)
    }

    @Test func `already installed recognises a duplicate image`() {
        #expect(RuntimeInstaller.isAlreadyInstalled(
            "Error Domain=SimDiskImageErrorDomain Code=9 \"Duplicate of image at /Library/...\""))
        #expect(!RuntimeInstaller.isAlreadyInstalled("Error Domain=NSPOSIXErrorDomain Code=22"))
    }

    @Test func `already installed recognises an already downloaded runtime`() {
        #expect(RuntimeInstaller.isAlreadyInstalled(
            "Finding content...\niOS 24B5084k (arm64Only) is already downloaded."))
        #expect(!RuntimeInstaller.isAlreadyInstalled("Finding content...\nDownloading iOS 27.2: 41.5 %"))
    }

    /// Without a build, xcodebuild finds nothing left to download for the runtime its Xcode uses.
    @Test func `already installed recognises no needed downloadables`() {
        #expect(RuntimeInstaller.isAlreadyInstalled(
            "Finding content...\nNo needed downloadables found for arm64Only"))
    }
}

// MARK: - SimCtlDeleteTests

struct SimCtlDeleteTests {
    /// simctl's stderr as `runTool` hands it over: the registration is gone, only the asset is in doubt.
    @Test func `removed without reclaimed asset recognises SimDiskImageError 30`() {
        #expect(SimCtl.isRemovedWithoutReclaimedAsset("""
        Error: An error was encountered processing the command (domain=com.apple.CoreSimulator.simdiskimaged.SimDiskImageError, code=30):
        Removed the runtime, but did not reclaim its MobileAsset: /System/Library/AssetsV2/com_apple_MobileAsset_iOSSimulatorRuntime/4266289161b54ac4ce863602d1cfefece9db1349.asset/AssetData/
        Run 'xcrun simctl runtime scan-and-mount' to re-register the runtime, then delete it again.
        """))
    }

    /// The timed-out purge variant carries the same code with other words.
    @Test func `removed without reclaimed asset recognises the code without the phrase`() {
        #expect(SimCtl.isRemovedWithoutReclaimedAsset("""
        Error: An error was encountered processing the command (domain=com.apple.CoreSimulator.simdiskimaged.SimDiskImageError, code=30):
        Timed out waiting for the Mobile Asset purge of /System/Library/AssetsV2/x.asset/AssetData/
        """))
    }

    @Test func `removed without reclaimed asset ignores other simctl errors`() {
        #expect(!SimCtl.isRemovedWithoutReclaimedAsset(
            "Error Domain=SimDiskImageErrorDomain Code=9 \"Duplicate of image at /Library/...\""))
        #expect(!SimCtl.isRemovedWithoutReclaimedAsset("Error Domain=NSPOSIXErrorDomain Code=22"))
    }
}

// MARK: - RuntimeSelectionTests

struct RuntimeSelectionTests {
    @Test func `all selects every platform in one run`() {
        let selection = RuntimeSelection(argument: "all")
        #expect(selection?.platforms == RuntimePlatform.allCases)
        #expect(selection?.isAll == true)
    }

    @Test func `comma list selects those platforms`() {
        let selection = RuntimeSelection(argument: "ios,watchos")
        #expect(selection?.platforms == [.ios, .watchos])
        #expect(selection?.isAll == false)
    }

    @Test func `comma list ignores case, spacing and repeats`() {
        #expect(RuntimeSelection(argument: " iOS , watchOS , ios ")?.platforms == [.ios, .watchos])
    }

    @Test func `unknown platform is rejected`() {
        #expect(RuntimeSelection(argument: "ios,android") == nil)
        #expect(RuntimeSelection(argument: "") == nil)
    }
}

// MARK: - RuntimeMatchTests

struct RuntimeMatchTests {
    /// `simctl runtime match list -j` for Xcode 27.0 with only iOS installed: iOS resolves to a newer
    /// runtime build than its SDK, the others to their SDK build although nothing is installed.
    @Test func `parse matches reads the chosen runtime of every SDK`() throws {
        let output = """
        {
          "appletvos27.0" : {"chosenRuntimeBuild" : "24J360", "defaultBuild" : "24J360", "sdkBuild" : "24J360"},
          "iphoneos27.0" : {"chosenRuntimeBuild" : "24A434", "defaultBuild" : "24A430", "sdkBuild" : "24A430"},
          "watchos27.0" : {"chosenRuntimeBuild" : "24R360", "defaultBuild" : "24R360", "sdkBuild" : "24R360"}
        }
        """
        #expect(try SimCtl.parseMatches(Data(output.utf8)) == ["24j360", "24a434", "24r360"])
    }

    @Test func `parse matches rejects output that is not JSON`() {
        #expect(throws: Error.self) { try SimCtl.parseMatches(Data("not json".utf8)) }
    }

    /// A chosen build with no registration behind it is a platform without a runtime installed.
    @Test func `used takes the installed runtimes with a chosen build`() throws {
        let used = try Runtimes.used(by: ["24a434", "24r360"], in: installed())
        #expect(used.map(\.build) == ["24A434"])
    }

    @Test func `used skips registrations that are not ready`() throws {
        let installed = try SimCtl.parse(makeSimctlOutput([
            ("A", "com.apple.platform.iphonesimulator", "27.0", "24A434", "Unusable", 1, "/x.asset/AssetData"),
        ]))
        #expect(Runtimes.used(by: ["24a434"], in: installed) == [])
    }

    @Test func `exclusive keeps what another Xcode uses`() throws {
        let exclusive = try Runtimes.exclusive(
            to: ["24a434", "24j360"],
            others: [["24a94401", "24j360"]],
            in: installed())
        #expect(exclusive.map(\.build) == ["24A434"])
    }

    @Test func `exclusive without other Xcodes is everything used`() throws {
        let exclusive = try Runtimes.exclusive(to: ["24a434", "24j360"], others: [], in: installed())
        #expect(exclusive.map(\.build) == ["24A434", "24J360"])
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
