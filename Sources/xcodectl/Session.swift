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

    /// RFC 6265 domain match: "developer.apple.com" gets ".apple.com" and "developer.apple.com" cookies.
    func matches(host: String) -> Bool {
        let d = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
        return host == d || host.hasSuffix("." + d)
    }
}

// MARK: - Session

enum Session {
    enum Source { case environment, keychain }

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

    static func save(_ cookies: [Cookie]) throws {
        try Keychain.write(JSONEncoder().encode(cookies))
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
    static func ensureTicket() async throws -> [Cookie] {
        guard let (cookies, source) = try load() else {
            throw Fail("not signed in: run `xcodectl login` (on a runner: `xcodectl session import` or set \(envKey))")
        }
        if let ticket = cookies.first(where: { $0.name == ticketCookie }), !ticket.isExpired {
            return cookies
        }
        let refreshed = try await refreshTicket(cookies)
        if source == .keychain {
            try save(refreshed)
        }
        return refreshed
    }

    /// POSTs the download list with the login session; Apple answers with a fresh ADCDownloadAuth cookie.
    static func refreshTicket(_ cookies: [Cookie]) async throws -> [Cookie] {
        guard cookies.contains(where: { $0.name == loginCookie && !$0.isExpired }) else {
            throw Fail("Apple session expired: run `xcodectl login` again (then `session export` for runners)")
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
            throw Fail("Apple returned HTTP \(http.statusCode) for the download list; run `xcodectl login` again")
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let code = json["resultCode"] as? Int ?? -1
        switch code {
        case 0: break

        case 1100: throw Fail("Apple session expired (1100): run `xcodectl login` again")

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
            throw Fail("keychain read failed: \(message(status))\(hint(status))")
        }
        return item as? Data
    }

    static func write(_ data: Data) throws {
        let update = [kSecValueData as String: data]
        var status = SecItemUpdate(base as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "xcodectl Apple Developer session"
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw Fail("keychain write failed: \(message(status))\(hint(status))")
        }
    }

    static func delete() {
        SecItemDelete(base as CFDictionary)
    }

    private static var base: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// Over ssh the login keychain is locked; say so instead of leaving the raw OSStatus.
    private static func hint(_ status: OSStatus) -> String {
        guard status == errSecInteractionNotAllowed else {
            return ""
        }
        return " (login keychain is locked, typical over ssh: run `security unlock-keychain` first, or pass the session via \(Session.envKey))"
    }

    private static func message(_ status: OSStatus) -> String {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus \(status)"
    }
}
