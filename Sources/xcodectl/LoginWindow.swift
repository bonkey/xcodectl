//
// Copyright (c) 2026 Daniel Bauke
//

import AppKit
import Foundation
import WebKit

/// One window with a WKWebView on a throwaway data store. Returns the apple.com cookies once
/// Apple's portal reports a signed-in session (`myacinfo` present on the downloads page).
@MainActor
final class LoginWindow: NSObject, NSWindowDelegate, WKNavigationDelegate {
    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800), configuration: config)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false)
        super.init()
        window.title = "xcodectl — sign in to Apple Developer"
        window.contentView = webView
        window.center()
        window.delegate = self
        window.isReleasedWhenClosed = false
        webView.navigationDelegate = self
    }

    static let startURL = URL(string: "https://developer.apple.com/download/all")!

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        if debug {
            eprint("[login] start \(webView.url?.absoluteString ?? "?")")
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if debug {
            eprint("[login] finished \(webView.url?.absoluteString ?? "?")")
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        eprint("[login] navigation failed: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        eprint("[login] navigation failed: \(error.localizedDescription)")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        eprint("[login] WebKit content process terminated")
    }

    /// Blocks on a modal run loop until signed in (cookies) or the window is closed (throws).
    func run() throws -> [HTTPCookie] {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        webView.load(URLRequest(url: Self.startURL))
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)

        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        let code = app.runModal(for: window)
        timer.invalidate()
        window.orderOut(nil)
        app.setActivationPolicy(.prohibited)
        guard code == .OK, let result else {
            throw Fail("login cancelled")
        }
        return result
    }

    func windowWillClose(_ notification: Notification) {
        if result == nil {
            NSApp.stopModal(withCode: .abort)
        }
    }

    private let window: NSWindow
    private let webView: WKWebView
    private var timer: Timer?
    private var result: [HTTPCookie]?

    private var debug: Bool {
        ProcessInfo.processInfo.environment["XCODECTL_DEBUG"] != nil
    }

    private func poll() {
        guard result == nil,
              let url = webView.url,
              url.host == "developer.apple.com",
              url.path.hasPrefix("/download")
        else {
            return
        }
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self, result == nil,
                  cookies.contains(where: { $0.name == Session.loginCookie })
            else {
                return
            }
            result = cookies.filter { $0.domain.lowercased().hasSuffix("apple.com") }
            NSApp.stopModal(withCode: .OK)
        }
    }
}
