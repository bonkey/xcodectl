//
// Copyright (c) 2026 Daniel Bauke
//

@testable import xcodectl
import Foundation
import Testing

struct AutologinTests {
    @Test func installSignsInByDefault() throws {
        let install = try #require(XcodeCtl.parseAsRoot(["install", "26.6"]) as? Install)
        #expect(install.autologin)
    }

    @Test func noAutologinTurnsItOff() throws {
        let install = try #require(XcodeCtl.parseAsRoot(["install", "--no-autologin", "26.6"]) as? Install)
        #expect(!install.autologin)
        let update = try #require(XcodeCtl.parseAsRoot(["update", "--no-autologin"]) as? Update)
        #expect(!update.autologin)
        let download = try #require(
            XcodeCtl.parseAsRoot(["_download", "u", "d", "--with-ticket", "--no-autologin"]) as? DownloadURL)
        #expect(!download.autologin)
    }

    @Test func refreshWithoutLoginCookieThrowsSessionExpired() async {
        await #expect(throws: SessionExpired.self) {
            try await Session.refreshTicket([])
        }
    }

    @Test func validTicketIsReturnedWithoutSigningIn() async throws {
        let cookies = [makeCookie("myacinfo"), makeCookie("ADCDownloadAuth", expires: Date() + 3600)]
        let result = try await Session.ensureTicket(cookies, source: .keychain) {
            Issue.record("signed in although the ticket is valid")
            return []
        }
        #expect(result == cookies)
    }

    @Test func expiredKeychainSessionSignsIn() async throws {
        let fresh = [makeCookie("myacinfo"), makeCookie("ADCDownloadAuth", expires: Date() + 3600)]
        var calls = 0
        let result = try await Session.ensureTicket([], source: .keychain) {
            calls += 1
            return fresh
        }
        #expect(calls == 1)
        #expect(result == fresh)
    }

    @Test func expiredKeychainSessionWithoutAutologinThrows() async {
        await #expect(throws: SessionExpired.self) {
            try await Session.ensureTicket([], source: .keychain, signIn: nil)
        }
    }

    /// A new login lands in the Keychain, but XCODECTL_SESSION would still win on the next run.
    @Test func expiredEnvironmentSessionNeverSignsIn() async {
        await #expect(throws: SessionExpired.self) {
            try await Session.ensureTicket([], source: .environment) {
                Issue.record("signed in for an XCODECTL_SESSION session")
                return []
            }
        }
    }

    private func makeCookie(_ name: String, expires: Date? = nil) -> Cookie {
        var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: "v", .domain: ".apple.com", .path: "/"]
        if let expires {
            properties[.expires] = expires
        }
        return Cookie(HTTPCookie(properties: properties)!)
    }
}
