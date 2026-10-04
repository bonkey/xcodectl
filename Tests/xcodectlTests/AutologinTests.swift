//
// Copyright (c) 2026 Daniel Bauke
//

@testable import xcodectl
import XCTest

final class AutologinTests: XCTestCase {
    func testInstallSignsInByDefault() throws {
        let install = try XCTUnwrap(XcodeCtl.parseAsRoot(["install", "26.6"]) as? Install)
        XCTAssertTrue(install.autologin)
    }

    func testNoAutologinTurnsItOff() throws {
        let install = try XCTUnwrap(XcodeCtl.parseAsRoot(["install", "--no-autologin", "26.6"]) as? Install)
        XCTAssertFalse(install.autologin)
        let update = try XCTUnwrap(XcodeCtl.parseAsRoot(["update", "--no-autologin"]) as? Update)
        XCTAssertFalse(update.autologin)
        let download = try XCTUnwrap(
            XcodeCtl.parseAsRoot(["_download", "u", "d", "--with-ticket", "--no-autologin"]) as? DownloadURL)
        XCTAssertFalse(download.autologin)
    }

    func testRefreshWithoutLoginCookieThrowsSessionExpired() async {
        do {
            _ = try await Session.refreshTicket([])
            XCTFail("expected SessionExpired")
        } catch {
            XCTAssertTrue(error is SessionExpired, "\(error)")
        }
    }

    func testValidTicketIsReturnedWithoutSigningIn() async throws {
        let cookies = [makeCookie("myacinfo"), makeCookie("ADCDownloadAuth", expires: Date() + 3600)]
        let result = try await Session.ensureTicket(cookies, source: .keychain) {
            XCTFail("signed in although the ticket is valid")
            return []
        }
        XCTAssertEqual(result, cookies)
    }

    func testExpiredKeychainSessionSignsIn() async throws {
        let fresh = [makeCookie("myacinfo"), makeCookie("ADCDownloadAuth", expires: Date() + 3600)]
        var calls = 0
        let result = try await Session.ensureTicket([], source: .keychain) {
            calls += 1
            return fresh
        }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(result, fresh)
    }

    func testExpiredKeychainSessionWithoutAutologinThrows() async {
        do {
            _ = try await Session.ensureTicket([], source: .keychain, signIn: nil)
            XCTFail("expected SessionExpired")
        } catch {
            XCTAssertTrue(error is SessionExpired, "\(error)")
        }
    }

    /// A new login lands in the Keychain, but XCODECTL_SESSION would still win on the next run.
    func testExpiredEnvironmentSessionNeverSignsIn() async {
        do {
            _ = try await Session.ensureTicket([], source: .environment) {
                XCTFail("signed in for an XCODECTL_SESSION session")
                return []
            }
            XCTFail("expected SessionExpired")
        } catch {
            XCTAssertTrue(error is SessionExpired, "\(error)")
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
