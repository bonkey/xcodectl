//
// Copyright (c) 2026 Daniel Bauke
//

import AppleArchive
import CryptoKit
import Foundation
import System

// MARK: - RuntimeAsset

/// A cryptex simulator runtime as Apple's public asset server describes it: an encrypted archive on
/// Apple's CDN and the key that opens it. Neither needs an Apple session.
struct RuntimeAsset: Equatable {
    static let server = URL(string: "https://gdmf.apple.com/v2/assets")!

    /// The audience xcodebuild asks the asset server for simulator runtimes in.
    static let audience = "02d8e57e-dd1c-4090-aa50-b4ed2aef0062"

    let url: URL
    let key: Data
    let sha256: Data

    static func lookup(_ runtime: SimulatorRuntime) async throws -> RuntimeAsset {
        let response: Data
        do {
            response = try await URLSession.shared.data(for: request(for: runtime)).0
        } catch {
            throw Fail("cannot reach Apple's asset server: \(error.localizedDescription)")
        }
        return try parse(response, build: runtime.build)
    }

    static func request(for runtime: SimulatorRuntime) -> URLRequest {
        var request = URLRequest(url: server)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "AssetAudience": audience,
            // The asset type is the dotted form of its directory under /System/Library/AssetsV2.
            "AssetType": runtime.platform.assetType.replacingOccurrences(of: "_", with: "."),
            "ClientVersion": 2,
            "RequestedBuild": runtime.build,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// The server answers with a signed token whose middle part is the JSON listing the assets. The
    /// signature is not checked: the answer comes over TLS from Apple, and the archive is checked
    /// against the SHA-256 it lists.
    static func parse(_ token: Data, build: String) throws -> RuntimeAsset {
        let parts = String(decoding: token, as: UTF8.self).split(separator: ".")
        var payload = parts.count == 3 ? String(parts[1]) : ""
        payload = payload.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let json = Data(base64Encoded: payload),
              let response = try? JSONDecoder().decode(Response.self, from: json)
        else {
            throw Fail("cannot read Apple's asset server response")
        }
        guard let asset = response.assets?.first(where: { $0.build.lowercased() == build.lowercased() }),
              let url = URL(string: asset.baseURL + asset.relativePath),
              let key = Data(base64Encoded: asset.key),
              let sha256 = Data(base64Encoded: asset.sha256)
        else {
            throw Fail("Apple's asset server has no runtime \(build)\(response.message.map { ": \($0)" } ?? "")")
        }
        return RuntimeAsset(url: url, key: key, sha256: sha256)
    }

    /// Checks a downloaded archive against the SHA-256 the server lists. An archive that does not
    /// match is deleted, so the next run downloads it again.
    func verify(_ archive: URL) throws {
        let file = try FileDescriptor.open(FilePath(archive.path), .readOnly)
        defer { try? file.close() }
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 16 << 20, alignment: 16)
        defer { buffer.deallocate() }
        var hasher = SHA256()
        while true {
            let count = try file.read(into: buffer)
            guard count > 0 else {
                break
            }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: buffer[..<count]))
        }
        guard Data(hasher.finalize()) == sha256 else {
            try? FileManager.default.removeItem(at: archive)
            throw Fail("\(archive.lastPathComponent) does not match Apple's checksum; run the install again")
        }
    }

    /// Expands the archive into `directory` and returns the runtime disk image in it.
    ///
    /// The archive is AEA, encrypted with `key`. Inside is an AppleArchive of patch operations: the
    /// extract operation carries a pbzx-compressed AppleArchive of the asset's files, and the runtime
    /// is its `AssetData/*.dmg`. Every layer streams, so memory use stays small.
    func extractDiskImage(from archive: URL, into directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try ArchiveByteStream.withFileStream(
            path: FilePath(archive.path),
            mode: .readOnly,
            options: [],
            permissions: [])
        { file in
            guard let context = ArchiveEncryptionContext(from: file) else {
                throw Fail("\(archive.lastPathComponent) is not an encrypted Apple archive")
            }
            try context.setSymmetricKey(SymmetricKey(data: key))
            guard let decrypted = ArchiveByteStream.decryptionStream(readingFrom: file, encryptionContext: context)
            else {
                throw Fail("cannot decrypt \(archive.lastPathComponent)")
            }
            defer { try? decrypted.close() }
            try ArchiveStream.withDecodeStream(readingFrom: decrypted) { operations in
                while let header = try operations.readHeader() {
                    guard case let .uint(_, operation)? = header.field(forKey: Self.operationKey),
                          operation == Self.extractOperation,
                          case let .blob(_, size, _)? = header.field(forKey: Self.dataKey)
                    else {
                        continue
                    }
                    try ArchiveByteStream.withStream(wrapping: BlobStream(operations, size: size)) { blob in
                        try Self.expand(blob, into: directory)
                    }
                }
            }
        }
        let assetData = directory.appendingPathComponent("AssetData")
        let files = (try? FileManager.default.contentsOfDirectory(at: assetData, includingPropertiesForKeys: nil)) ?? []
        guard let image = files.first(where: { $0.pathExtension == "dmg" }) else {
            throw Fail("no disk image in \(archive.lastPathComponent)")
        }
        return image
    }

    private static let operationKey = ArchiveHeader.FieldKey("YOP")
    private static let dataKey = ArchiveHeader.FieldKey("DAT")
    private static let extractOperation = UInt64(UInt8(ascii: "E"))

    /// Expands a compressed AppleArchive into a directory. Entries may name an owner, which only root
    /// can set, so that is skipped.
    private static func expand(_ compressed: ArchiveByteStream, into directory: URL) throws {
        try ArchiveByteStream.withDecompressionStream(readingFrom: compressed) { archive in
            try ArchiveStream.withDecodeStream(readingFrom: archive) { decoder in
                try ArchiveStream.withExtractStream(
                    extractingTo: FilePath(directory.path),
                    flags: .ignoreOperationNotPermitted)
                { extractor in
                    _ = try ArchiveStream.process(readingFrom: decoder, writingTo: extractor)
                }
            }
        }
    }
}

// MARK: RuntimeAsset.Response

extension RuntimeAsset {
    /// The fields of the asset server's answer this tool reads.
    private struct Response: Decodable {
        struct Asset: Decodable {
            enum CodingKeys: String, CodingKey {
                case build = "Build"
                case baseURL = "__BaseURL"
                case relativePath = "__RelativePath"
                case key = "ArchiveDecryptionKey"
                case sha256 = "_Measurement-SHA256"
            }

            let build: String
            let baseURL: String
            let relativePath: String
            let key: String
            let sha256: String
        }

        enum CodingKeys: String, CodingKey {
            case assets = "Assets"
            case message = "Message"
        }

        let assets: [Asset]?
        let message: String?
    }

    /// The data blob of an archive stream's current entry, read as a byte stream. Sequential reads only.
    private final class BlobStream: ArchiveByteStreamProtocol {
        init(_ archive: ArchiveStream, size: UInt64) {
            self.archive = archive
            remaining = size
        }

        func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
            let count = Int(min(UInt64(buffer.count), remaining))
            if count > 0 {
                let part = UnsafeMutableRawBufferPointer(rebasing: buffer[..<count])
                try archive.readBlob(key: RuntimeAsset.dataKey, into: part)
                remaining -= UInt64(count)
            }
            return count
        }

        func read(into buffer: UnsafeMutableRawBufferPointer, atOffset offset: Int64) throws -> Int {
            throw ArchiveError.invalidValue
        }

        func write(from buffer: UnsafeRawBufferPointer) throws -> Int {
            throw ArchiveError.invalidValue
        }

        func write(from buffer: UnsafeRawBufferPointer, atOffset offset: Int64) throws -> Int {
            throw ArchiveError.invalidValue
        }

        func seek(toOffset offset: Int64, relativeTo origin: FileDescriptor.SeekOrigin) throws -> Int64 {
            throw ArchiveError.invalidValue
        }

        func cancel() {}

        func close() throws {}

        private let archive: ArchiveStream
        private var remaining: UInt64
    }
}
