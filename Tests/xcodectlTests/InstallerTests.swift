//
// Copyright (c) 2026 Daniel Bauke
//

@testable import xcodectl
import Foundation
import XCTest

final class InstallerTests: XCTestCase {
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
        try FileManager.default.removeItem(at: root)
    }

    func testExpandDirectoryPrefersTheFirstCandidate() throws {
        let first = root.appendingPathComponent("first/tmp")
        let second = root.appendingPathComponent("second/tmp")
        XCTAssertEqual(try Installer.expandDirectory(in: [first, second]), first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
    }

    func testExpandDirectoryEmptiesWhatAnEarlierRunLeft() throws {
        let tmp = root.appendingPathComponent("tmp")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try Data().write(to: tmp.appendingPathComponent("stale"))
        XCTAssertEqual(try Installer.expandDirectory(in: [tmp]), tmp)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: tmp.path), [])
    }

    func testExpandDirectoryFallsBackWhenTheFirstCandidateCannotBeCreated() throws {
        try lock()
        let fallback = root.appendingPathComponent("fallback/tmp")
        XCTAssertEqual(try Installer.expandDirectory(in: [locked.appendingPathComponent("tmp"), fallback]), fallback)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: fallback.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testExpandDirectoryThrowsWhenNoCandidateCanBeCreated() throws {
        try lock()
        XCTAssertThrowsError(try Installer.expandDirectory(in: [locked.appendingPathComponent("tmp")]))
    }

    private var root: URL!

    /// Stands in for an /Applications this process may not write to.
    private var locked: URL {
        root.appendingPathComponent("locked")
    }

    private func lock() throws {
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
    }
}
