//
// Copyright (c) 2026 Daniel Bauke
//

@testable import xcodectl
import AppleArchive
import CryptoKit
import Foundation
import System
import XCTest

final class RuntimeAssetTests: XCTestCase {
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    // MARK: - Lookup

    func testRequestAsksForOneBuildOfThePlatformsAssetType() throws {
        let runtime = SimulatorRuntime(
            name: "tvOS 18.5 Simulator Runtime",
            platform: .tvos,
            version: "18.5",
            build: "22L572",
            architectures: [],
            size: 0,
            minXcode: nil,
            maxXcode: nil,
            source: nil)
        let request = RuntimeAsset.request(for: runtime)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://gdmf.apple.com/v2/assets")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["AssetAudience"] as? String, "02d8e57e-dd1c-4090-aa50-b4ed2aef0062")
        XCTAssertEqual(body["AssetType"] as? String, "com.apple.MobileAsset.appleTVOSSimulatorRuntime")
        XCTAssertEqual(body["ClientVersion"] as? Int, 2)
        XCTAssertEqual(body["RequestedBuild"] as? String, "22L572")
    }

    func testParseReadsTheArchiveItsKeyAndItsChecksum() throws {
        let asset = try RuntimeAsset.parse(makeToken(iOS186), build: "22G86")
        XCTAssertEqual(
            asset.url.absoluteString,
            "https://updates.cdn-apple.com/2025/mobileassets/043-18341/791B091D-2B91-47E1-9FCD-0C115650A8F4/"
                + "com_apple_MobileAsset_iOSSimulatorRuntime/BA59E4A4-296E-40D2-8551-66E0F7881682.aar")
        XCTAssertEqual(asset.key, Data(base64Encoded: "Fx/EgjGjPyFgJ6DDXUfzd/i/UJ6kDJmtGLbba7gPess="))
        XCTAssertEqual(asset.sha256, Data(base64Encoded: "cmEUANfLNCVIBXudKMOsDgJ3GHlrq/hFRUVKB/ClI80="))
    }

    /// Betas carry a lowercase letter ("22A5282m"); the build matches whatever its case.
    func testParseMatchesTheBuildIgnoringCase() throws {
        XCTAssertNoThrow(try RuntimeAsset.parse(makeToken(iOS186), build: "22g86"))
    }

    func testParseRejectsAnAnswerForAnotherBuild() throws {
        XCTAssertThrowsError(try RuntimeAsset.parse(makeToken(iOS186), build: "22F76"))
    }

    /// The server answers an unknown build with HTTP 422 and a token whose payload says why.
    func testParseReportsTheServersMessageForAnUnknownBuild() throws {
        let answer = #"{"Status": "422 Unprocessable Entity", "Message": "Build not found: 99Z999"}"#
        XCTAssertThrowsError(try RuntimeAsset.parse(makeToken(answer), build: "99Z999")) { error in
            XCTAssertTrue("\(error)".contains("Build not found: 99Z999"), "\(error)")
        }
    }

    func testParseRejectsAnAnswerThatIsNotAToken() {
        XCTAssertThrowsError(try RuntimeAsset.parse(Data("<html>Service Unavailable</html>".utf8), build: "22G86"))
    }

    // MARK: - Verify

    func testVerifyKeepsAnArchiveThatMatches() throws {
        let archive = root.appendingPathComponent("a.aar")
        try Data("archive".utf8).write(to: archive)
        let asset = makeAsset(sha256: Data(SHA256.hash(data: Data("archive".utf8))))
        XCTAssertNoThrow(try asset.verify(archive))
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path))
    }

    /// A corrupt download goes, so the next run downloads it again instead of failing the same way.
    func testVerifyDeletesAnArchiveThatDoesNotMatch() throws {
        let archive = root.appendingPathComponent("a.aar")
        try Data("archive".utf8).write(to: archive)
        let asset = makeAsset(sha256: Data(SHA256.hash(data: Data("other".utf8))))
        XCTAssertThrowsError(try asset.verify(archive))
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.path))
    }

    // MARK: - Extract

    func testExtractWritesTheDiskImageOfTheExtractOperation() throws {
        let key = SymmetricKey(size: .bits256)
        let image = makeImage()
        let archive = try makeArchive(key: key, image: image)
        let asset = makeAsset(key: key.withUnsafeBytes { Data($0) })
        let extracted = try asset.extractDiskImage(from: archive, into: root.appendingPathComponent("out"))
        XCTAssertEqual(extracted.lastPathComponent, "043-18670-100.dmg")
        XCTAssertEqual(extracted.deletingLastPathComponent().lastPathComponent, "AssetData")
        XCTAssertEqual(try Data(contentsOf: extracted), image)
    }

    func testExtractRejectsTheWrongKey() throws {
        let archive = try makeArchive(key: SymmetricKey(size: .bits256), image: makeImage())
        let asset = makeAsset(key: SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
        XCTAssertThrowsError(try asset.extractDiskImage(from: archive, into: root.appendingPathComponent("out"))) {
            XCTAssertTrue("\($0)".contains("cannot decrypt runtime.aar"), "\($0)")
        }
    }

    /// The asset server's answer for iOS 18.6, trimmed to a few of its fields.
    private let iOS186 = """
    {
      "Assets": [
        {
          "ArchiveDecryptionKey": "Fx/EgjGjPyFgJ6DDXUfzd/i/UJ6kDJmtGLbba7gPess=",
          "AssetFormat": "AppleArchive",
          "AssetType": "com.apple.MobileAsset.iOSSimulatorRuntime",
          "Build": "22G86",
          "SimulatorVersion": "18.6",
          "_DownloadSize": 8858370048,
          "_Measurement": "GBigzRk9P+raLH/2oEGL3niWFro=",
          "_Measurement-SHA256": "cmEUANfLNCVIBXudKMOsDgJ3GHlrq/hFRUVKB/ClI80=",
          "_UnarchivedSize": 9131044864,
          "__BaseURL": "https://updates.cdn-apple.com/2025/mobileassets/043-18341/791B091D-2B91-47E1-9FCD-0C115650A8F4/",
          "__RelativePath": "com_apple_MobileAsset_iOSSimulatorRuntime/BA59E4A4-296E-40D2-8551-66E0F7881682.aar"
        }
      ],
      "AssetAudience": "02d8e57e-dd1c-4090-aa50-b4ed2aef0062"
    }
    """

    private var root: URL!

    /// A signed token the way the asset server sends one: base64url header, payload and signature.
    private func makeToken(_ payload: String) -> Data {
        let parts = [#"{"alg":"ES256"}"#, payload, "signature"].map {
            Data($0.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return Data(parts.joined(separator: ".").utf8)
    }

    private func makeAsset(key: Data = Data(), sha256: Data = Data()) -> RuntimeAsset {
        RuntimeAsset(url: URL(string: "https://updates.cdn-apple.com/a.aar")!, key: key, sha256: sha256)
    }

    /// Compressible zeros, then random bytes the compressor stores as they are, over several blocks.
    private func makeImage() -> Data {
        Data(count: 1 << 20) + Data((0 ..< 2 << 20).map { _ in UInt8.random(in: .min ... .max) })
    }

    /// An archive shaped like Apple's: AEA around an AppleArchive of patch operations, whose extract
    /// operation carries a pbzx-compressed AppleArchive of the asset's files.
    private func makeArchive(key: SymmetricKey, image: Data) throws -> URL {
        let files = root.appendingPathComponent("files")
        try FileManager.default.createDirectory(
            at: files.appendingPathComponent("AssetData"),
            withIntermediateDirectories: true)
        try image.write(to: files.appendingPathComponent("AssetData/043-18670-100.dmg"))
        try Data("<plist/>".utf8).write(to: files.appendingPathComponent("Info.plist"))

        let payload = root.appendingPathComponent("payload.pbzx")
        try ArchiveByteStream.withFileStream(
            path: FilePath(payload.path),
            mode: .writeOnly,
            options: [.create, .truncate],
            permissions: FilePermissions(rawValue: 0o644))
        { file in
            try ArchiveByteStream.withCompressionStream(using: .lzma, writingTo: file) { compressed in
                try ArchiveStream.withEncodeStream(writingTo: compressed) { encoder in
                    try encoder.writeDirectoryContents(
                        archiveFrom: FilePath(files.path),
                        keySet: XCTUnwrap(ArchiveHeader.FieldKeySet("TYP,PAT,MOD,DAT")))
                }
            }
        }

        let archive = root.appendingPathComponent("runtime.aar")
        let context = ArchiveEncryptionContext(
            profile: .hkdf_sha256_aesctr_hmac__symmetric__none,
            compressionAlgorithm: .lzfse)
        try context.setSymmetricKey(key)
        try ArchiveByteStream.withFileStream(
            path: FilePath(archive.path),
            mode: .writeOnly,
            options: [.create, .truncate],
            permissions: FilePermissions(rawValue: 0o644))
        { file in
            let encrypted = try XCTUnwrap(
                ArchiveByteStream.encryptionStream(writingTo: file, encryptionContext: context))
            try ArchiveStream.withEncodeStream(writingTo: encrypted) { encoder in
                // An operation other than extract comes first and is skipped.
                try write(operation: "M", blob: Data("manifest".utf8), to: encoder)
                try write(operation: "E", blob: Data(contentsOf: payload), to: encoder)
            }
            try encrypted.close()
        }
        return archive
    }

    /// One patch operation. AppleArchive reads no entry without a type, so each carries one.
    private func write(operation: Unicode.Scalar, blob: Data, to encoder: ArchiveStream) throws {
        let header = ArchiveHeader()
        let type = UInt64(ArchiveHeader.EntryType.metadata.rawValue)
        header.append(.uint(key: ArchiveHeader.FieldKey("TYP"), value: type))
        header.append(.uint(key: ArchiveHeader.FieldKey("YOP"), value: UInt64(operation.value)))
        header.append(.blob(key: ArchiveHeader.FieldKey("DAT"), size: UInt64(blob.count)))
        try encoder.writeHeader(header)
        try blob.withUnsafeBytes { try encoder.writeBlob(key: ArchiveHeader.FieldKey("DAT"), from: $0) }
    }
}
