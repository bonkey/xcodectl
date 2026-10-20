//
// Copyright (c) 2026 Daniel Bauke
//

@testable import xcodectl
import Foundation
import Testing

struct AutologinTests {
    @Test func `install signs in by default`() throws {
        let install = try #require(XcodeCtl.parseAsRoot(["install", "26.6"]) as? Install)
        #expect(install.autologin != false)
    }

    @Test func `no autologin turns it off`() throws {
        let install = try #require(XcodeCtl.parseAsRoot(["install", "--no-login", "26.6"]) as? Install)
        #expect(install.autologin == false)
        let upgrade = try #require(XcodeCtl.parseAsRoot(["upgrade", "--no-login"]) as? Upgrade)
        #expect(upgrade.autologin == false)
    }

    @Test func `the old flag name is gone`() {
        #expect(throws: Error.self) { try XcodeCtl.parseAsRoot(["install", "--no-autologin", "26.6"]) }
        #expect(throws: Error.self) { try XcodeCtl.parseAsRoot(["upgrade", "--no-autologin"]) }
    }

    @Test func `refresh without login cookie throws session expired`() async {
        await #expect(throws: SessionExpired.self) {
            try await Session.refreshTicket([])
        }
    }

    @Test func `valid ticket is returned without signing in`() async throws {
        let cookies = [makeCookie("myacinfo"), makeCookie("ADCDownloadAuth", expires: Date() + 3600)]
        let result = try await Session.ensureTicket(cookies, source: .keychain) {
            Issue.record("signed in although the ticket is valid")
            return []
        }
        #expect(result == cookies)
    }

    @Test func `expired Keychain session signs in`() async throws {
        let fresh = [makeCookie("myacinfo"), makeCookie("ADCDownloadAuth", expires: Date() + 3600)]
        var calls = 0
        let result = try await Session.ensureTicket([], source: .keychain) {
            calls += 1
            return fresh
        }
        #expect(calls == 1)
        #expect(result == fresh)
    }

    @Test func `expired Keychain session without autologin throws`() async {
        await #expect(throws: SessionExpired.self) {
            try await Session.ensureTicket([], source: .keychain, signIn: nil)
        }
    }

    /// A new login lands in the Keychain, but XCODECTL_SESSION would still win on the next run.
    @Test func `expired environment session never signs in`() async {
        await #expect(throws: SessionExpired.self) {
            try await Session.ensureTicket([], source: .environment) {
                Issue.record("signed in for an XCODECTL_SESSION session")
                return []
            }
        }
    }

    @Test func `verify signs an expired Keychain session in`() async throws {
        let fresh = [makeCookie("myacinfo"), makeCookie("ADCDownloadAuth", expires: Date() + 3600)]
        var calls = 0
        let result = try await Session.verify([], source: .keychain) {
            calls += 1
            return fresh
        }
        #expect(calls == 1)
        #expect(result == fresh)
    }

    @Test func `verify without a sign-in throws`() async {
        await #expect(throws: SessionExpired.self) {
            try await Session.verify([], source: .keychain, signIn: nil)
        }
    }

    @Test func `verify never signs an environment session in`() async {
        await #expect(throws: SessionExpired.self) {
            try await Session.verify([], source: .environment) {
                Issue.record("signed in for an XCODECTL_SESSION session")
                return []
            }
        }
    }

    @Test func `sign-in window starts with the trust cookies, not the login or the ticket`() {
        let trust = makeCookie("DES54214b87a1d9ccef59b805e996e84ae0d", expires: Date() + 30 * 86400)
        let account = makeCookie("acn01", expires: Date() + 365 * 86400)
        let sso = makeCookie("aasp")
        let cookies = [
            trust, account, sso,
            makeCookie("myacinfo"),
            makeCookie("ADCDownloadAuth", expires: Date() + 3600),
            makeCookie("dslang", expires: Date() - 60),
        ]
        #expect(Session.seed(cookies) == [trust, account, sso])
    }

    @Test func `cookie survives the trip through HTTPCookie`() throws {
        let cookie = try Cookie(#require(HTTPCookie(properties: [
            .name: "DES54214b87a1d9ccef59b805e996e84ae0d", .value: "\"v=1\"", .domain: ".idmsa.apple.com", .path: "/",
            .secure: "TRUE", .expires: Date(timeIntervalSince1970: 1_795_000_000),
        ])))
        #expect(cookie.secure)
        let back = try Cookie(#require(cookie.httpCookie))
        #expect(back == cookie)
    }

    private func makeCookie(_ name: String, expires: Date? = nil) -> Cookie {
        var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: "v", .domain: ".apple.com", .path: "/"]
        if let expires {
            properties[.expires] = expires
        }
        return Cookie(HTTPCookie(properties: properties)!)
    }
}
