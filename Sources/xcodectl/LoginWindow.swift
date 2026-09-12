//
// Copyright (c) 2026 Daniel Bauke
//

import AppKit
import Foundation
import LibFido2Swift
import WebKit

/// One window with a WKWebView on a throwaway data store. `run()` returns the apple.com cookies
/// once Apple's portal reports a signed-in session (`myacinfo` present on the downloads page).
///
/// WebKit refuses WebAuthn for domains a third-party app cannot associate with (apple.com), so
/// the page's `navigator.credentials.get` is routed through a user script to libfido2, which
/// talks to the security key over USB and hands the signed assertion back to the page.
@MainActor
final class LoginWindow: NSObject, NSWindowDelegate, WKNavigationDelegate, WKScriptMessageHandler {
    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.addUserScript(WKUserScript(
            source: Self.webAuthnShim, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800), configuration: config)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false)
        super.init()
        // The web view copies its configuration; register on the copy it actually uses.
        webView.configuration.userContentController.add(self, name: "webauthn")
        window.title = Self.title
        window.contentView = webView
        window.center()
        window.delegate = self
        window.isReleasedWhenClosed = false
        webView.navigationDelegate = self
    }

    static let startURL = URL(string: "https://developer.apple.com/download/all")!
    static let title = "xcodectl — sign in to Apple Developer"

    /// Shows the window and waits until signed in (cookies) or the window is closed (throws).
    func run() async throws -> [HTTPCookie] {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        webView.load(URLRequest(url: Self.startURL))
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        defer {
            webView.configuration.userContentController.removeScriptMessageHandler(forName: "webauthn")
            window.orderOut(nil)
            app.setActivationPolicy(.prohibited)
        }
        while true {
            try await Task.sleep(for: .seconds(1))
            if closed {
                throw Fail("login cancelled")
            }
            if let cookies = await signedInCookies() {
                return cookies
            }
        }
    }

    func windowWillClose(_: Notification) {
        closed = true
    }

    // MARK: - Navigation diagnostics

    func webView(_ webView: WKWebView, didStartProvisionalNavigation _: WKNavigation!) {
        if debug {
            eprint("[login] start \(webView.url?.absoluteString ?? "?")")
        }
    }

    func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
        if debug {
            eprint("[login] finished \(webView.url?.absoluteString ?? "?")")
        }
    }

    func webView(_: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError error: Error) {
        eprint("[login] navigation failed: \(error.localizedDescription)")
    }

    func webView(_: WKWebView, didFail _: WKNavigation!, withError error: Error) {
        eprint("[login] navigation failed: \(error.localizedDescription)")
    }

    func webViewWebContentProcessDidTerminate(_: WKWebView) {
        eprint("[login] WebKit content process terminated")
    }

    // MARK: - WebAuthn bridge

    /// Message from the page: `{id, challenge, rpId, allow: [credentialId], origin}` (base64), or `{log}`.
    func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else {
            return
        }
        if let log = body["log"] as? String {
            if debug {
                eprint("[login] page: \(log)")
            }
            return
        }
        guard let id = body["id"] as? String,
              let challenge = body["challenge"] as? String,
              let rpId = body["rpId"] as? String,
              let allow = body["allow"] as? [String],
              let origin = body["origin"] as? String
        else {
            return
        }
        let frame = message.frameInfo // the promise lives in the frame that asked (Apple's auth iframe)
        Task {
            window.title = "Touch your security key…"
            defer { window.title = Self.title }
            do {
                let response = try await assert(rpId: rpId, challenge: challenge, allow: allow, origin: origin)
                if debug {
                    eprint("[login] assertion signed, credential \(response.credentialID.prefix(12))…")
                }
                resolve(id, response, in: frame)
            } catch {
                eprint("[login] security key failed: \(error)")
                reject(id, error, in: frame)
            }
        }
    }

    /// Replaces navigator.credentials.get with a call into the app; the result is shaped like a real
    /// PublicKeyCredential (own properties on objects carrying the native prototypes).
    private static let webAuthnShim = """
    (function () {
      if (!navigator.credentials || !window.PublicKeyCredential) { return; }
      var pending = {};
      function log(m) { try { window.webkit.messageHandlers.webauthn.postMessage({ log: String(m) }); } catch (e) {} }
      window.addEventListener("error", function (e) { log("error: " + e.message); });
      window.addEventListener("unhandledrejection", function (e) { log("rejection: " + (e.reason && (e.reason.name + " " + e.reason.message))); });
      function b64(buf) {
        var v = buf instanceof ArrayBuffer ? new Uint8Array(buf) : new Uint8Array(buf.buffer, buf.byteOffset, buf.byteLength);
        return btoa(String.fromCharCode.apply(null, v));
      }
      function buf(s) { return Uint8Array.from(atob(s), function (c) { return c.charCodeAt(0); }).buffer; }
      function b64url(s) { return s.replace(/\\+/g, "-").replace(/\\//g, "_").replace(/=+$/, ""); }
      window.__xcodectl = {
        resolve: function (id, r) {
          var p = pending[id]; if (!p) { log("resolve: no pending request " + id); return; } delete pending[id];
          log("resolving security key request");
          var response = {
            clientDataJSON: buf(r.clientData),
            authenticatorData: buf(r.authenticatorData),
            signature: buf(r.signatureData),
            userHandle: r.userHandle ? buf(r.userHandle) : null
          };
          Object.setPrototypeOf(response, AuthenticatorAssertionResponse.prototype);
          var cred = {
            id: b64url(r.credentialID),
            rawId: buf(r.credentialID),
            type: "public-key",
            authenticatorAttachment: "cross-platform",
            response: response,
            getClientExtensionResults: function () { return {}; }
          };
          Object.setPrototypeOf(cred, PublicKeyCredential.prototype);
          p.resolve(cred);
        },
        reject: function (id, message) {
          var p = pending[id]; if (!p) { return; } delete pending[id];
          p.reject(new DOMException(message, "NotAllowedError"));
        }
      };
      function bridgedGet(options) {
        var pk = options && options.publicKey;
        if (!pk) { return Promise.reject(new DOMException("unsupported", "NotSupportedError")); }
        var id = String(Date.now()) + Math.random().toString(36).slice(2);
        return new Promise(function (resolve, reject) {
          pending[id] = { resolve: resolve, reject: reject };
          log("security key request " + (pk.rpId || "") + " " + ((pk.allowCredentials || []).length) + " credentials");
          window.webkit.messageHandlers.webauthn.postMessage({
            id: id,
            challenge: b64(pk.challenge),
            rpId: pk.rpId || location.hostname,
            allow: (pk.allowCredentials || []).map(function (c) { return b64(c.id); }),
            origin: location.origin
          });
        });
      }
      var proto = Object.getPrototypeOf(navigator.credentials);
      try { Object.defineProperty(proto, "get", { value: bridgedGet, writable: true, configurable: true }); } catch (e) { log("proto patch failed: " + e); }
      try { Object.defineProperty(navigator.credentials, "get", { value: bridgedGet, writable: true, configurable: true }); } catch (e) { log("instance patch failed: " + e); }
      log("shim installed in " + location.href.slice(0, 60) + " -> " + (navigator.credentials.get === bridgedGet ? "bridged" : "NOT bridged"));
    })();
    """

    private let window: NSWindow
    private let webView: WKWebView
    private var closed = false

    private var debug: Bool {
        ProcessInfo.processInfo.environment["XCODECTL_DEBUG"] != nil
    }

    /// JSON string literal.
    private static func js(_ s: String) -> String {
        let array = String(decoding: try! JSONSerialization.data(withJSONObject: [s]), as: UTF8.self)
        return String(array.dropFirst().dropLast())
    }

    private func assert(
        rpId: String,
        challenge: String,
        allow: [String],
        origin: String) async throws
        -> ChallengeResponse
    {
        let fido = FIDO2()
        guard fido.hasDeviceAttached() else {
            throw Fail("no security key attached; plug in your key and press Continue again")
        }
        var pin: String?
        if try fido.deviceHasPin() {
            guard let entered = await askPin() else {
                throw Fail("PIN entry cancelled")
            }
            pin = entered
        }
        let args = ChallengeArgs(rpId: rpId, validCredentials: allow, devPin: pin, challenge: challenge, origin: origin)
        // Blocks until the key is touched; keep it off the main thread.
        return try await Task.detached { try fido.respondToChallenge(args: args) }.value
    }

    private func askPin() async -> String? {
        let alert = NSAlert()
        alert.messageText = "Security key PIN"
        alert.informativeText = "Enter the PIN of your security key, then touch the key when it blinks."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        let response = await alert.beginSheetModal(for: window)
        return response == .alertFirstButtonReturn ? field.stringValue : nil
    }

    private func resolve(_ id: String, _ r: ChallengeResponse, in frame: WKFrameInfo) {
        let userHandle = r.userHandle.isEmpty ? "" : Data(r.userHandle.utf8).base64EncodedString()
        let payload: [String: String] = [
            "credentialID": r.credentialID, "clientData": r.clientData, "authenticatorData": r.authenticatorData,
            "signatureData": r.signatureData, "userHandle": userHandle,
        ]
        let json = String(decoding: try! JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
        evaluate("window.__xcodectl.resolve(\(Self.js(id)), \(json))", in: frame)
    }

    private func reject(_ id: String, _ error: Error, in frame: WKFrameInfo) {
        let message = (error as? Fail)?.description ?? "security key error: \(error)"
        evaluate("window.__xcodectl.reject(\(Self.js(id)), \(Self.js(message)))", in: frame)
    }

    private func evaluate(_ script: String, in frame: WKFrameInfo) {
        webView.evaluateJavaScript(script, in: frame, in: .page) { [debug] result in
            if debug, case let .failure(error) = result {
                eprint("[login] evaluate failed: \(error)")
            }
        }
    }

    /// The apple.com cookies once the downloads page reports a login session, else nil.
    private func signedInCookies() async -> [HTTPCookie]? {
        guard let url = webView.url, url.host == "developer.apple.com", url.path.hasPrefix("/download") else {
            return nil
        }
        let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        guard cookies.contains(where: { $0.name == Session.loginCookie }) else {
            return nil
        }
        return cookies.filter { $0.domain.lowercased().hasSuffix("apple.com") }
    }
}
