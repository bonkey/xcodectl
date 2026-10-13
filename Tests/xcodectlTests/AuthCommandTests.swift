//
// Copyright (c) 2026 Daniel Bauke
//

@testable import xcodectl
import ArgumentParser
import XCTest

final class AuthCommandTests: XCTestCase {
    func testAuthSubcommandsParse() throws {
        XCTAssertTrue(try XcodeCtl.parseAsRoot(["auth", "login"]) is Login)
        XCTAssertTrue(try XcodeCtl.parseAsRoot(["auth", "status"]) is AuthCommand.Status)
        XCTAssertTrue(try XcodeCtl.parseAsRoot(["auth", "export"]) is AuthCommand.Export)
        XCTAssertTrue(try XcodeCtl.parseAsRoot(["auth", "import"]) is AuthCommand.Import)
        XCTAssertTrue(try XcodeCtl.parseAsRoot(["auth", "logout"]) is AuthCommand.Logout)
    }

    /// A session without Apple's login cookie fails before any request goes out.
    func testStatusWithJSONExitsOneWithoutAnError() async throws {
        try await withSession("[]") {
            var status = try XCTUnwrap(XcodeCtl.parseAsRoot(["auth", "status", "--json"]) as? AuthCommand.Status)
            do {
                try await status.run()
                XCTFail("expected exit 1")
            } catch {
                XCTAssertEqual(error as? ExitCode, .failure, "\(error)")
            }
        }
    }

    func testStatusWithoutJSONStillFailsWithTheExpiry() async throws {
        try await withSession("[]") {
            var status = try XCTUnwrap(XcodeCtl.parseAsRoot(["auth", "status"]) as? AuthCommand.Status)
            do {
                try await status.run()
                XCTFail("expected SessionExpired")
            } catch {
                XCTAssertTrue(error is SessionExpired, "\(error)")
                // The missing login cookie's message, not Apple's: the session came from the environment.
                XCTAssertTrue("\(error)".contains("auth export"), "\(error)")
            }
        }
    }

    func testTheOldCommandNamesAreGone() {
        XCTAssertThrowsError(try XcodeCtl.parseAsRoot(["login"]))
        XCTAssertThrowsError(try XcodeCtl.parseAsRoot(["session", "export"]))
        XCTAssertThrowsError(try XcodeCtl.parseAsRoot(["session", "import"]))
    }

    /// Runs `body` with `cookies` (JSON) as the XCODECTL_SESSION session, then restores the variable.
    private func withSession(_ cookies: String, _ body: () async throws -> Void) async throws {
        let saved = ProcessInfo.processInfo.environment[Session.envKey]
        setenv(Session.envKey, Data(cookies.utf8).base64EncodedString(), 1)
        defer {
            if let saved {
                setenv(Session.envKey, saved, 1)
            } else {
                unsetenv(Session.envKey)
            }
        }
        try await body()
    }
}
