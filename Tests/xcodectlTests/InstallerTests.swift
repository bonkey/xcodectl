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

    func testExpandDirectoryPrefersTheFirstRoot() throws {
        let first = root.appendingPathComponent("first/tmp")
        let second = root.appendingPathComponent("second/tmp")
        XCTAssertEqual(
            try Installer.expandDirectory(for: "27A1", in: [first, second]).path,
            first.appendingPathComponent("27A1").path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
    }

    func testExpandDirectoryEmptiesWhatAnEarlierRunOfTheSameBuildLeft() throws {
        let tmp = root.appendingPathComponent("tmp")
        let dir = tmp.appendingPathComponent("27A1")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent("stale"))
        XCTAssertEqual(try Installer.expandDirectory(for: "27A1", in: [tmp]).path, dir.path)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [])
    }

    func testExpandDirectoryRemovesWhatAnEarlierRunOfAnotherBuildLeft() throws {
        let tmp = root.appendingPathComponent("tmp")
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("26F1/Xcode.app"),
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("Xcode.app"),
            withIntermediateDirectories: true)
        _ = try Installer.expandDirectory(for: "27A1", in: [tmp])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: tmp.path), ["27A1"])
    }

    func testExpandDirectoryKeepsTheDirectoryOfAnotherRunningBuild() throws {
        let tmp = root.appendingPathComponent("tmp")
        let other = try Installer.expandDirectory(for: "26F1", in: [tmp])
        try Data().write(to: other.appendingPathComponent("expanding"))
        _ = try Installer.expandDirectory(for: "27A1", in: [tmp])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: other.path), ["expanding"])
    }

    func testExpandDirectoryRefusesABuildAnotherRunIsInstalling() throws {
        let tmp = root.appendingPathComponent("tmp")
        let dir = try Installer.expandDirectory(for: "27A1", in: [tmp])
        try Data().write(to: dir.appendingPathComponent("expanding"))
        XCTAssertThrowsError(try Installer.expandDirectory(for: "27A1", in: [tmp]))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["expanding"])
    }

    func testExpandDirectoryFallsBackWhenTheFirstRootCannotBeCreated() throws {
        try lock()
        let fallback = root.appendingPathComponent("fallback/tmp")
        XCTAssertEqual(
            try Installer.expandDirectory(for: "27A1", in: [locked.appendingPathComponent("tmp"), fallback]).path,
            fallback.appendingPathComponent("27A1").path)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fallback.appendingPathComponent("27A1").path,
            isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testExpandDirectoryFallsBackWhenTheFirstRootExistsButIsReadOnly() throws {
        try lock()
        let fallback = root.appendingPathComponent("fallback/tmp")
        XCTAssertEqual(
            try Installer.expandDirectory(for: "27A1", in: [locked, fallback]).path,
            fallback.appendingPathComponent("27A1").path)
    }

    func testExpandDirectoryThrowsWhenNoRootCanBeCreated() throws {
        try lock()
        XCTAssertThrowsError(try Installer.expandDirectory(for: "27A1", in: [locked.appendingPathComponent("tmp")]))
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
