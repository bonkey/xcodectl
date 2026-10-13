//
// Copyright (c) 2026 Daniel Bauke
//

@testable import xcodectl
import Foundation
import Testing

final class InstallerTests {
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
        try? FileManager.default.removeItem(at: root)
    }

    @Test func `expand directory prefers the first root`() throws {
        let first = root.appendingPathComponent("first/tmp")
        let second = root.appendingPathComponent("second/tmp")
        #expect(
            try Installer.expandDirectory(for: "27A1", in: [first, second]).path ==
                first.appendingPathComponent("27A1").path)
        #expect(!FileManager.default.fileExists(atPath: second.path))
    }

    @Test func `expand directory empties what an earlier run of the same build left`() throws {
        let tmp = root.appendingPathComponent("tmp")
        let dir = tmp.appendingPathComponent("27A1")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent("stale"))
        #expect(try Installer.expandDirectory(for: "27A1", in: [tmp]).path == dir.path)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == [])
    }

    @Test func `expand directory keeps an expansion an earlier run finished`() throws {
        let tmp = root.appendingPathComponent("tmp")
        let dir = tmp.appendingPathComponent("27A1")
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("Xcode.app"),
            withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent(Installer.expandedMarker))
        #expect(try Installer.expandDirectory(for: "27A1", in: [tmp]).path == dir.path)
        #expect(Installer.expanded(in: dir)?.path == dir.appendingPathComponent("Xcode.app").path)
    }

    @Test func `expanded ignores an unfinished expansion`() throws {
        let dir = root.appendingPathComponent("tmp/27A1")
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("Xcode.app"),
            withIntermediateDirectories: true)
        #expect(Installer.expanded(in: dir) == nil)
    }

    @Test func `expand directory removes what an earlier run of another build left`() throws {
        let tmp = root.appendingPathComponent("tmp")
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("26F1/Xcode.app"),
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("Xcode.app"),
            withIntermediateDirectories: true)
        _ = try Installer.expandDirectory(for: "27A1", in: [tmp])
        #expect(try FileManager.default.contentsOfDirectory(atPath: tmp.path) == ["27A1"])
    }

    @Test func `expand directory keeps the directory of another running build`() throws {
        let tmp = root.appendingPathComponent("tmp")
        let other = try Installer.expandDirectory(for: "26F1", in: [tmp])
        try Data().write(to: other.appendingPathComponent("expanding"))
        _ = try Installer.expandDirectory(for: "27A1", in: [tmp])
        #expect(try FileManager.default.contentsOfDirectory(atPath: other.path) == ["expanding"])
    }

    @Test func `expand directory refuses a build another run is installing`() throws {
        let tmp = root.appendingPathComponent("tmp")
        let dir = try Installer.expandDirectory(for: "27A1", in: [tmp])
        try Data().write(to: dir.appendingPathComponent("expanding"))
        #expect(throws: Error.self) { try Installer.expandDirectory(for: "27A1", in: [tmp]) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["expanding"])
    }

    @Test func `expand directory falls back when the first root cannot be created`() throws {
        try lock()
        let fallback = root.appendingPathComponent("fallback/tmp")
        #expect(
            try Installer.expandDirectory(for: "27A1", in: [locked.appendingPathComponent("tmp"), fallback]).path ==
                fallback.appendingPathComponent("27A1").path)
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(
            atPath: fallback.appendingPathComponent("27A1").path,
            isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }

    @Test func `expand directory falls back when the first root exists but is read-only`() throws {
        try lock()
        let fallback = root.appendingPathComponent("fallback/tmp")
        #expect(
            try Installer.expandDirectory(for: "27A1", in: [locked, fallback]).path ==
                fallback.appendingPathComponent("27A1").path)
    }

    @Test func `expand directory throws when no root can be created`() throws {
        try lock()
        #expect(throws: Error.self) {
            try Installer.expandDirectory(for: "27A1", in: [locked.appendingPathComponent("tmp")])
        }
    }

    private let root: URL

    /// Stands in for an /Applications this process may not write to.
    private var locked: URL {
        root.appendingPathComponent("locked")
    }

    private func lock() throws {
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
    }
}
