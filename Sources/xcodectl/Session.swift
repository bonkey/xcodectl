//
// Copyright (c) 2026 Daniel Bauke
//

import Foundation
import Security

// MARK: - Cookie

/// A cookie as we keep it: enough to rebuild a `Cookie:` header, nothing else.
struct Cookie: Codable, Equatable {
    init(_ cookie: HTTPCookie) {
        domain = cookie.domain
        path = cookie.path
        name = cookie.name
        value = cookie.value
        expires = cookie.expiresDate?.timeIntervalSince1970
        secure = cookie.isSecure
    }

    var domain: String
    var path: String
    var name: String
    var value: String
    /// Unix time; nil for a session cookie.
    var expires: Double?
    var secure: Bool

    /// Expired, or expiring within 5 minutes.
    var isExpired: Bool {
        guard let expires else {
            return false
        }
        return expires < Date().timeIntervalSince1970 + 300
    }

    var httpCookie: HTTPCookie? {
        var properties: [HTTPCookiePropertyKey: Any] = [.domain: domain, .path: path, .name: name, .value: value]
        if let expires {
            properties[.expires] = Date(timeIntervalSince1970: expires)
        }
        if secure {
            properties[.secure] = "TRUE"
        }
        return HTTPCookie(properties: properties)
    }

    /// RFC 6265 domain match: "developer.apple.com" gets ".apple.com" and "developer.apple.com" cookies.
    func matches(host: String) -> Bool {
        let d = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
        return host == d || host.hasSuffix("." + d)
    }
}

// MARK: - SessionExpired

/// No usable login session, stored or accepted by Apple; only signing in helps.
struct SessionExpired: Error, LocalizedError, CustomStringConvertible {
    let description: String

    var errorDescription: String? {
        description
    }
}

// MARK: - Session

enum Session {
    enum Source { case environment, keychain }

    /// Signs in anew and returns the stored session, download ticket included.
    typealias SignIn = () async throws -> [Cookie]

    static let envKey = "XCODECTL_SESSION"
    static let loginCookie = "myacinfo"
    static let ticketCookie = "ADCDownloadAuth"
    static let listDownloads =
        URL(string: "https://developer.apple.com/services-account/QH65B2/downloadws/listDownloads.action")!

    /// `XCODECTL_SESSION` (base64 JSON) wins; otherwise the Keychain item.
    static func load() throws -> (cookies: [Cookie], source: Source)? {
        if let blob = ProcessInfo.processInfo.environment[envKey], !blob.isEmpty {
            return try (decode(blob), .environment)
        }
        guard let data = try Keychain.read() else {
            return nil
        }
        return try (JSONDecoder().decode([Cookie].self, from: data), .keychain)
    }

    /// The stored cookies a sign-in window starts with, so Apple recognizes the browser it trusted (`DES…`) and
    /// usually signs it in without input. The login cookie and the download ticket stay out: the window waits for a
    /// fresh login cookie.
    static func seed(_ cookies: [Cookie]) -> [Cookie] {
        cookies.filter { !$0.isExpired && $0.name != loginCookie && $0.name != ticketCookie }
    }

    static func save(_ cookies: [Cookie], unlock: Bool = false) throws {
        try Keychain.write(JSONEncoder().encode(cookies), unlock: unlock)
    }

    static func encode(_ cookies: [Cookie]) throws -> String {
        try JSONEncoder().encode(cookies).base64EncodedString()
    }

    static func decode(_ blob: String) throws -> [Cookie] {
        let trimmed = blob.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = Data(base64Encoded: trimmed) else {
            throw Fail("session blob is not base64")
        }
        do { return try JSONDecoder().decode([Cookie].self, from: data) } catch {
            throw Fail("session blob is not a cookie list")
        }
    }

    static func header(_ cookies: [Cookie], host: String) -> String {
        cookies
            .filter { !$0.isExpired && $0.matches(host: host) }
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
    }

    /// Returns cookies that include a valid download ticket, refreshing it from the login session when needed.
    /// `signIn` replaces a missing or expired Keychain session; nil fails instead.
    static func ensureTicket(signIn: SignIn?) async throws -> [Cookie] {
        guard let (cookies, source) = try load() else {
            if let signIn {
                return try await signIn()
            }
            throw Fail(
                "not signed in: run `xcodectl auth login` (on a runner: `xcodectl auth import` or set \(envKey))")
        }
        return try await ensureTicket(cookies, source: source, signIn: signIn)
    }

    static func ensureTicket(_ cookies: [Cookie], source: Source, signIn: SignIn?) async throws -> [Cookie] {
        if let ticket = cookies.first(where: { $0.name == ticketCookie }), !ticket.isExpired {
            return cookies
        }
        return try await verify(cookies, source: source, signIn: signIn)
    }

    /// What `auth status` and `auth export` check: the stored session, confirmed by Apple, with a fresh ticket.
    /// Nothing stored signs in when `signIn` is set and otherwise throws `SessionExpired`.
    static func verify(signIn: SignIn?) async throws -> (cookies: [Cookie], source: Source) {
        guard let (cookies, source) = try load() else {
            if let signIn {
                return try await (signIn(), .keychain)
            }
            throw SessionExpired(description: "not signed in: run `xcodectl auth login`")
        }
        return try await (verify(cookies, source: source, signIn: signIn), source)
    }

    /// Asks Apple whether `cookies` still sign in and returns them with a fresh ticket, saved when they came from
    /// the Keychain. `signIn` replaces an expired Keychain session. A session from `XCODECTL_SESSION` never signs
    /// in: the new session would go to the Keychain, and the variable would still win on the next run.
    static func verify(_ cookies: [Cookie], source: Source, signIn: SignIn?) async throws -> [Cookie] {
        do {
            let refreshed = try await refreshTicket(cookies)
            if source == .keychain {
                try save(refreshed)
            }
            return refreshed
        } catch let error as SessionExpired {
            guard source == .keychain, let signIn else {
                throw error
            }
            return try await signIn()
        }
    }

    /// POSTs the download list with the login session; Apple answers with a fresh ADCDownloadAuth cookie.
    static func refreshTicket(_ cookies: [Cookie]) async throws -> [Cookie] {
        guard cookies.contains(where: { $0.name == loginCookie && !$0.isExpired }) else {
            throw SessionExpired(
                description: "Apple session expired: run `xcodectl auth login` again (then `auth export` for runners)")
        }
        var request = URLRequest(url: listDownloads)
        request.httpMethod = "POST"
        request.httpBody = Data()
        request.httpShouldHandleCookies = false
        request.setValue("application/json, text/javascript", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue(header(cookies, host: listDownloads.host!), forHTTPHeaderField: "Cookie")

        let (data, response) = try await isolatedSession(timeout: 30).data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw Fail("no HTTP response from Apple")
        }
        guard http.statusCode == 200 else {
            throw Fail("Apple returned HTTP \(http.statusCode) for the download list; run `xcodectl auth login` again")
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let code = json["resultCode"] as? Int ?? -1
        switch code {
        case 0: break

        case 1100: throw SessionExpired(description: "Apple session expired (1100): run `xcodectl auth login` again")

        case 2100: throw Fail(
                "Apple wants you to accept an updated agreement: open https://developer.apple.com/download/all, accept, then retry")

        default: throw Fail(
                "Apple download list failed (resultCode \(code)): \(json["userString"] as? String ?? "no details")")
        }
        let headers = http.allHeaderFields.reduce(into: [String: String]()) { acc, kv in
            if let k = kv.key as? String, let v = kv.value as? String {
                acc[k] = v
            }
        }
        let received = HTTPCookie.cookies(withResponseHeaderFields: headers, for: listDownloads)
        guard let ticket = received.first(where: { $0.name == ticketCookie }) else {
            throw Fail("Apple did not send \(ticketCookie); the download service may have changed")
        }
        var merged = cookies.filter { !($0.name == ticketCookie) && !$0.isExpired }
        merged.append(Cookie(ticket))
        return merged
    }

    /// A URLSession that never touches the shared cookie jar.
    static func isolatedSession(
        timeout: TimeInterval,
        connections: Int = 6,
        delegate: URLSessionDelegate? = nil)
        -> URLSession
    {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.timeoutIntervalForRequest = timeout
        config.httpMaximumConnectionsPerHost = connections
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }
}

// MARK: - Keychain

enum Keychain {
    static let service = "xcodectl"
    static let account = "apple-session"

    /// True when macOS opened this process's security session for a network login, such as ssh.
    static var sessionIsRemote: Bool {
        var attributes = SessionAttributeBits()
        return SessionGetInfo(callerSecuritySession, nil, &attributes) == errSecSuccess
            && attributes.contains(.sessionIsRemote)
    }

    static func read() throws -> Data? {
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw Fail("keychain read failed: \(message(status))\(hint(status, read: true))")
        }
        return item as? Data
    }

    /// With `unlock`, a write that finds the login keychain locked unlocks it and tries once more.
    static func write(_ data: Data, unlock: Bool = false) throws {
        var status = store(data)
        if status == errSecInteractionNotAllowed, unlock, unlockDefault() {
            status = store(data)
        }
        guard status == errSecSuccess else {
            throw Fail("keychain write failed: \(message(status))\(hint(status))")
        }
    }

    static func delete() throws {
        let status = SecItemDelete(base as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Fail("keychain delete failed: \(message(status))\(hint(status))")
        }
    }

    /// Over ssh the login keychain is locked; say so instead of leaving the raw OSStatus. `XCODECTL_SESSION` stands in
    /// for a read only.
    static func hint(_ status: OSStatus, read: Bool = false) -> String {
        guard status == errSecInteractionNotAllowed else {
            return ""
        }
        let otherwise = read ? ", or pass the session via \(Session.envKey)" : "; `xcodectl auth import --help` shows how"
        return " (login keychain is locked, typical over ssh: run `security unlock-keychain` in the same ssh connection first\(otherwise))"
    }

    private static var base: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func message(_ status: OSStatus) -> String {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus \(status)"
    }

    private static func store(_ data: Data) -> OSStatus {
        let update = [kSecValueData as String: data]
        var status = SecItemUpdate(base as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "xcodectl Apple Developer session"
            status = SecItemAdd(add as CFDictionary, nil)
        }
        return status
    }

    /// Unlocks the default keychain for this security session. While its owner is logged in at the console, an ssh
    /// session finds the login keychain locked and its unlock does not check the password, so an empty one serves.
    /// `SecKeychainUnlock` is exported by Security but missing from the SDK headers.
    private static func unlockDefault() -> Bool {
        typealias Unlock = @convention(c) (OpaquePointer?, UInt32, UnsafeRawPointer?, DarwinBoolean) -> OSStatus
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT, a C macro Swift does not import
        guard let symbol = dlsym(rtldDefault, "SecKeychainUnlock") else {
            return false
        }
        return unsafeBitCast(symbol, to: Unlock.self)(nil, 0, "", true) == errSecSuccess
    }
}
