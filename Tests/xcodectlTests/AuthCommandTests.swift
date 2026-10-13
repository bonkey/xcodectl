//
// Copyright (c) 2026 Daniel Bauke
//

@testable import xcodectl
import ArgumentParser
import Foundation
import Testing

/// Serialized because `withSession` sets XCODECTL_SESSION for the whole process.
@Suite(.serialized)
struct AuthCommandTests {
    @Test func `auth subcommands parse`() throws {
        #expect(try XcodeCtl.parseAsRoot(["auth", "login"]) is Login)
        #expect(try XcodeCtl.parseAsRoot(["auth", "status"]) is AuthCommand.Status)
        #expect(try XcodeCtl.parseAsRoot(["auth", "export"]) is AuthCommand.Export)
        #expect(try XcodeCtl.parseAsRoot(["auth", "import"]) is AuthCommand.Import)
        #expect(try XcodeCtl.parseAsRoot(["auth", "logout"]) is AuthCommand.Logout)
    }

    /// A session without Apple's login cookie fails before any request goes out.
    @Test func `status with JSON exits one without an error`() async throws {
        try await withSession("[]") {
            var status = try #require(XcodeCtl.parseAsRoot(["auth", "status", "--json"]) as? AuthCommand.Status)
            await #expect(throws: ExitCode.failure) {
                try await status.run()
            }
        }
    }

    @Test func `status without JSON still fails with the expiry`() async throws {
        try await withSession("[]") {
            var status = try #require(XcodeCtl.parseAsRoot(["auth", "status"]) as? AuthCommand.Status)
            let error = try await #require(throws: SessionExpired.self) {
                try await status.run()
            }
            // The missing login cookie's message, not Apple's: the session came from the environment.
            #expect("\(error)".contains("auth export"), "\(error)")
        }
    }

    @Test func `the old command names are gone`() {
        #expect(throws: Error.self) { try XcodeCtl.parseAsRoot(["login"]) }
        #expect(throws: Error.self) { try XcodeCtl.parseAsRoot(["session", "export"]) }
        #expect(throws: Error.self) { try XcodeCtl.parseAsRoot(["session", "import"]) }
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
