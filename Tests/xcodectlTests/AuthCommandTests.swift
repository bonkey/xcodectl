//
// Copyright (c) 2026 Daniel Bauke
//

@testable import xcodectl
import XCTest

final class AuthCommandTests: XCTestCase {
    func testAuthSubcommandsParse() throws {
        XCTAssertTrue(try XcodeCtl.parseAsRoot(["auth", "login"]) is Login)
        XCTAssertTrue(try XcodeCtl.parseAsRoot(["auth", "status"]) is AuthCommand.Status)
        XCTAssertTrue(try XcodeCtl.parseAsRoot(["auth", "export"]) is AuthCommand.Export)
        XCTAssertTrue(try XcodeCtl.parseAsRoot(["auth", "import"]) is AuthCommand.Import)
        XCTAssertTrue(try XcodeCtl.parseAsRoot(["auth", "logout"]) is AuthCommand.Logout)
    }

    func testTheOldCommandNamesAreGone() {
        XCTAssertThrowsError(try XcodeCtl.parseAsRoot(["login"]))
        XCTAssertThrowsError(try XcodeCtl.parseAsRoot(["session", "export"]))
        XCTAssertThrowsError(try XcodeCtl.parseAsRoot(["session", "import"]))
    }
}
