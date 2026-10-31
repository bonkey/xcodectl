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

    @Test func `export and import take the clipboard flags`() throws {
        let export = try #require(XcodeCtl.parseAsRoot(["auth", "export", "--copy"]) as? AuthCommand.Export)
        #expect(export.copy == true)
        let plainExport = try #require(XcodeCtl.parseAsRoot(["auth", "export"]) as? AuthCommand.Export)
        #expect(plainExport.copy != true)
        let `import` = try #require(XcodeCtl.parseAsRoot(["auth", "import", "--paste"]) as? AuthCommand.Import)
        #expect(`import`.paste == true)
        let plainImport = try #require(XcodeCtl.parseAsRoot(["auth", "import"]) as? AuthCommand.Import)
        #expect(plainImport.paste != true)
    }

    /// `auth export | ssh runner xcodectl auth import` works with `paste = true` in the runner's config file.
    @Test func `import reads a pipe even with paste on`() {
        #expect(!AuthCommand.Import.readsClipboard(paste: true, stdinIsTerminal: false))
        #expect(AuthCommand.Import.readsClipboard(paste: true, stdinIsTerminal: true))
        #expect(!AuthCommand.Import.readsClipboard(paste: nil, stdinIsTerminal: true))
        #expect(!AuthCommand.Import.readsClipboard(paste: false, stdinIsTerminal: true))
    }

    /// `auth export | ssh runner xcodectl auth import` works without `security unlock-keychain` first.
    @Test func `import unlocks the keychain over ssh only`() throws {
        #expect(AuthCommand.Import.unlocksKeychain(unlockKeychain: nil, remote: true))
        #expect(AuthCommand.Import.unlocksKeychain(unlockKeychain: true, remote: true))
        #expect(!AuthCommand.Import.unlocksKeychain(unlockKeychain: false, remote: true))
        #expect(!AuthCommand.Import.unlocksKeychain(unlockKeychain: nil, remote: false))
        #expect(!AuthCommand.Import.unlocksKeychain(unlockKeychain: true, remote: false))
        let off = try #require(
            XcodeCtl.parseAsRoot(["auth", "import", "--no-unlock-keychain"]) as? AuthCommand.Import)
        #expect(off.unlockKeychain == false)
        #expect(try #require(XcodeCtl.parseAsRoot(["auth", "import"]) as? AuthCommand.Import).unlockKeychain == nil)
    }

    /// XCODECTL_SESSION replaces a Keychain read, never the write `auth import` exists for.
    @Test func `locked keychain hint fits the access`() {
        let read = Keychain.hint(errSecInteractionNotAllowed, read: true)
        #expect(read.contains("same ssh connection") && read.contains(Session.envKey), "\(read)")
        let write = Keychain.hint(errSecInteractionNotAllowed)
        #expect(write.contains("auth import --help") && !write.contains(Session.envKey), "\(write)")
        #expect(Keychain.hint(errSecItemNotFound).isEmpty)
    }

    /// After its own unlock a refusal is another version's session, not the lock.
    @Test func `keychain hint names another version's session`() {
        let read = Keychain.hint(errSecInteractionNotAllowed, read: true, unlocked: true)
        #expect(read.contains("another xcodectl version") && read.contains("import it again"), "\(read)")
        #expect(!read.contains("unlock-keychain"), "\(read)")
        let owner = Keychain.hint(errSecInvalidOwnerEdit)
        #expect(owner.contains("another xcodectl version") && owner.contains("console"), "\(owner)")
    }

    /// Over ssh, `install` and the other commands that use the stored session work without `security unlock-keychain`.
    @Test func `keychain tries once more after its own unlock`() {
        func run(_ first: OSStatus, unlock: Bool = true, unlocks: Bool = true) -> [String] {
            var calls = 0
            var unlockCalls = 0
            let unlockKeychain = {
                unlockCalls += 1
                return unlocks
            }
            let result = Keychain.unlocking(unlock, with: unlockKeychain) {
                calls += 1
                return calls == 1 ? first : errSecSuccess
            }
            return ["\(result.status)", "\(result.unlocked)", "\(calls)", "\(unlockCalls)"]
        }
        let (success, locked, owner) = (
            "\(errSecSuccess)",
            "\(errSecInteractionNotAllowed)",
            "\(errSecInvalidOwnerEdit)")
        #expect(run(errSecInteractionNotAllowed) == [success, "true", "2", "1"])
        #expect(run(errSecInvalidOwnerEdit) == [success, "true", "2", "1"])
        #expect(run(errSecInteractionNotAllowed, unlock: false) == [locked, "false", "1", "0"])
        #expect(run(errSecInvalidOwnerEdit, unlocks: false) == [owner, "false", "1", "1"])
        #expect(run(errSecItemNotFound) == ["\(errSecItemNotFound)", "false", "1", "0"])
        #expect(run(errSecSuccess) == [success, "false", "1", "0"])
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

    @Test func `login is on unless turned off`() throws {
        #expect(try #require(XcodeCtl.parseAsRoot(["auth", "status"]) as? AuthCommand.Status).login != false)
        #expect(try #require(XcodeCtl.parseAsRoot(["auth", "status", "--no-login"]) as? AuthCommand.Status)
            .login == false)
        #expect(try #require(XcodeCtl.parseAsRoot(["auth", "export"]) as? AuthCommand.Export).login != false)
        #expect(try #require(XcodeCtl.parseAsRoot(["auth", "export", "--no-login"]) as? AuthCommand.Export)
            .login == false)
    }

    /// Export asks Apple first; without the login cookie that fails before any request goes out.
    @Test func `export without a login cookie fails with the expiry`() async throws {
        try await withSession("[]") {
            var export = try #require(XcodeCtl.parseAsRoot(["auth", "export"]) as? AuthCommand.Export)
            await #expect(throws: SessionExpired.self) {
                try await export.run()
            }
        }
    }

    /// Login still fails for an XCODECTL_SESSION session; `AutologinTests` pin that the window never opens for one.
    @Test func `export with login keeps an environment session`() async throws {
        try await withSession("[]") {
            var export = try #require(XcodeCtl.parseAsRoot(["auth", "export", "--login"]) as? AuthCommand.Export)
            await #expect(throws: SessionExpired.self) {
                try await export.run()
            }
        }
    }

    @Test func `import rejects a blob without a login cookie`() async throws {
        let error = try await #require(throws: Fail.self) {
            try await AuthCommand.Import.store(Data("[]".utf8).base64EncodedString())
        }
        #expect("\(error)".contains("no Apple login session"), "\(error)")
    }

    /// An expired login cookie is refused before any request or Keychain write.
    @Test func `import rejects an expired login cookie`() async throws {
        let expired = """
        [{"domain":".apple.com","path":"/","name":"myacinfo","value":"v","expires":0,"secure":true}]
        """
        let error = try await #require(throws: Fail.self) {
            try await AuthCommand.Import.store(Data(expired.utf8).base64EncodedString())
        }
        #expect("\(error)".contains("auth export"), "\(error)")
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
