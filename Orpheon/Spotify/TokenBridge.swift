// Orpheon for iOS: a port of Orpheon (https://github.com/kota-zo/Orpheon, formerly Myspoti), GPL-3.0.
// Derived from the Kotlin sources by kota-zo and contributors. Keep these notices; if you ever
// distribute this, publish your complete source under GPL-3.0 (see LICENSE and NOTICE.md).
import Foundation
import UIKit
import WebKit

/// Runs the official Web Player page (open.spotify.com) in a hidden web view, signed in with the
/// user's own cookies, and lets the page mint the web access token: no secret is computed here.
/// This is the iOS counterpart of Orpheon's page bridge. The page never plays anything on iOS (it
/// cannot: no Widevine); it only holds the session, as it does on the Android app.
@MainActor
final class TokenBridge: NSObject, TokenSource, WKNavigationDelegate, WKScriptMessageHandler {
    private(set) var webView: WKWebView
    private var latest: WebToken?
    private var appVersion: String
    private(set) var buildVersion: String?
    private var pageReady = false
    private var loading = false
    private var readyWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private let fallbackVersion: String

    static let homeURL = URL(string: "https://open.spotify.com/")!

    init(fallbackVersion: String = "1.3.6.1874.g61b9bcdb1ef2") {
        self.fallbackVersion = fallbackVersion
        self.appVersion = fallbackVersion
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore.default()
        let controller = WKUserContentController()
        let script = WKUserScript(source: TokenBridge.script, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        controller.addUserScript(script)
        config.userContentController = controller
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        view.customUserAgent = spotifyUserAgent
        self.webView = view
        super.init()
        controller.add(self, name: "orpheon")
        view.navigationDelegate = self
    }

    /// Puts the page in the window as a nearly invisible 2x2 view. iOS slows down web views that are
    /// not on screen; a visible one keeps the page's timers and requests running normally.
    func attachToWindow() {
        guard webView.superview == nil else { return }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.flatMap { $0.windows }
        guard let window = windows.first(where: { $0.isKeyWindow }) ?? windows.first else { return }
        webView.frame = CGRect(x: 0, y: 0, width: 2, height: 2)
        webView.alpha = 0.01
        webView.isUserInteractionEnabled = false
        window.insertSubview(webView, at: 0)
    }

    // MARK: TokenSource

    func webToken(forceRefresh: Bool) async throws -> WebToken {
        try await ensureLoaded()
        let old = latest?.access
        let stale = latest.map { $0.expiresAtMs - nowMs() < 60_000 } ?? true
        let expired = latest.map { $0.expiresAtMs - nowMs() < 5_000 } ?? true
        if forceRefresh || stale {
            var fresh = await pageToken()
            // A refused token the page still holds is no answer: load the page again.
            if let f = fresh, forceRefresh, f.access == old { fresh = nil }
            if let f = fresh {
                accept(f)
            } else if forceRefresh || expired {
                try await reloadAndWait()
                if latest == nil, let f = await pageToken() { accept(f) }
            }
        }
        guard let t = latest else { throw SpotifyError.token("the Web Player page gave no token") }
        if t.anonymous { throw SpotifyError.notSignedIn }
        return t
    }

    // MARK: Page

    private func ensureLoaded() async throws {
        attachToWindow()
        if pageReady || latest != nil { return }
        if !loading { load() }
        await waitReady(timeout: 40)
        if !pageReady && latest == nil { throw SpotifyError.token("the Web Player page did not start") }
    }

    private func load() {
        attachToWindow()
        loading = true
        pageReady = false
        webView.load(URLRequest(url: TokenBridge.homeURL))
    }

    /// Loads the page again and waits for its token (after a sign-in, a sign-out or a refused token).
    func reloadAndWait() async throws {
        latest = nil
        load()
        await waitReady(timeout: 40)
        // A token intercepted from the page's own request counts even when its services were not found.
        var waited = 0
        while latest == nil && waited < 20 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            waited += 1
        }
    }

    /// Forgets the page and its token (a sign-out or another account).
    func reset() {
        latest = nil
        pageReady = false
        loading = false
        webView.stopLoading()
        webView.load(URLRequest(url: URL(string: "about:blank")!))
    }

    /// Waits until the page announced itself, or `timeout` seconds. Each waiter has its own timer, so one
    /// call's timeout never cuts another call's wait short.
    private func waitReady(timeout: Double) async {
        if pageReady { return }
        let id = UUID()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            readyWaiters[id] = c
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self?.release(id)
            }
        }
    }

    private func release(_ id: UUID) {
        if let c = readyWaiters.removeValue(forKey: id) { c.resume() }
    }

    private func flushReadyWaiters() {
        let all = readyWaiters
        readyWaiters.removeAll()
        for (_, c) in all { c.resume() }
    }

    private func pageToken() async -> WebToken? {
        guard pageReady else { return nil }
        let js = "return await window.__orpheon.getToken();"
        do {
            let result = try await webView.callAsyncJavaScript(js, arguments: [:], in: nil, contentWorld: .page)
            return parseToken(result)
        } catch {
            return nil
        }
    }

    private func accept(_ t: WebToken) {
        latest = t
    }

    private func parseToken(_ any: Any?) -> WebToken? {
        guard let d = any as? [String: Any], let access = d["accessToken"] as? String else { return nil }
        let expires: Int64
        if let n = d["expiresAtMs"] as? NSNumber { expires = n.int64Value }
        else if let n = d["accessTokenExpirationTimestampMs"] as? NSNumber { expires = n.int64Value }
        else { expires = nowMs() + 55 * 60_000 }
        let version = (d["appVersion"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? appVersion
        if let v = d["appVersion"] as? String, !v.isEmpty { appVersion = v }
        return WebToken(
            access: access, expiresAtMs: expires,
            clientId: (d["clientId"] as? String) ?? "",
            appVersion: version,
            anonymous: (d["isAnonymous"] as? Bool) ?? false)
    }

    private func readConfig(_ base64: String?) {
        guard let b = base64, let data = Data(base64Encoded: b.trimmingCharacters(in: .whitespacesAndNewlines), options: .ignoreUnknownCharacters),
              let json = try? JSON.parse(data) else { return }
        if let v = json.str("clientVersion"), !v.isEmpty { appVersion = v }
        buildVersion = json.str("buildVersion")
    }

    // MARK: WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "ready":
            readConfig(body["config"] as? String)
            pageReady = true
            loading = false
            flushReadyWaiters()
        case "token":
            // `/api/token` answered the page: {accessToken, accessTokenExpirationTimestampMs, clientId, isAnonymous}.
            if let t = body["token"] as? [String: Any], t["accessToken"] is String {
                var merged = t
                merged["appVersion"] = appVersion
                if let p = parseToken(merged) { accept(p) }
            }
        case "config":
            readConfig(body["config"] as? String)
        default:
            break
        }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // The page's script announces itself; a page without the Web Player's services still has the intercepted token.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            guard let self = self else { return }
            if !self.pageReady { self.loading = false; self.flushReadyWaiters() }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loading = false
        flushReadyWaiters()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loading = false
        flushReadyWaiters()
    }

    // MARK: Cookies

    static func spDcCookie() async -> HTTPCookie? {
        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        return cookies.first { $0.name == "sp_dc" && $0.domain.contains("spotify.com") && !$0.value.isEmpty }
    }

    static func hasSession() async -> Bool { await spDcCookie() != nil }

    /// Sets the `sp_dc` session cookie by hand (copied from a browser that is signed in).
    static func setSpDc(_ value: String) async {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let props: [HTTPCookiePropertyKey: Any] = [
            .name: "sp_dc", .value: trimmed, .domain: ".spotify.com", .path: "/",
            .secure: "TRUE", .expires: Date().addingTimeInterval(365 * 24 * 3600),
        ]
        if let cookie = HTTPCookie(properties: props) {
            await WKWebsiteDataStore.default().httpCookieStore.setCookie(cookie)
        }
    }

    /// Removes every cookie and page data of Spotify's web (a sign-out).
    static func clearSession() async {
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await store.dataRecords(ofTypes: types)
        let spotify = records.filter { $0.displayName.contains("spotify") || $0.displayName.contains("scdn") }
        await store.removeData(ofTypes: types, for: spotify)
    }

    // MARK: Page script

    /// Injected at document start: keeps the page "visible", reports `/api/token` answers, and
    /// finds the page's own `TokenProvider` (the lookup Orpheon's player bridge uses) to ask for a token.
    static let script = """
    (function () {
      if (window.__orpheon) return;
      var post = function (msg) {
        try { window.webkit.messageHandlers.orpheon.postMessage(msg); } catch (e) {}
      };
      try {
        Object.defineProperty(Document.prototype, 'hidden', { configurable: true, get: function () { return false; } });
        Object.defineProperty(Document.prototype, 'visibilityState', { configurable: true, get: function () { return 'visible'; } });
        document.hasFocus = function () { return true; };
      } catch (e) {}
      try {
        var origFetch = window.fetch;
        if (origFetch) {
          window.fetch = function (input) {
            var p = origFetch.apply(this, arguments);
            try {
              var url = (typeof input === 'string') ? input : ((input && input.url) || '');
              if (url.indexOf('/api/token') !== -1) {
                p.then(function (r) { return r.clone().json(); })
                 .then(function (j) { post({ type: 'token', token: j }); })
                 .catch(function () {});
              }
            } catch (e) {}
            return p;
          };
        }
      } catch (e) {}
      var findPlatform = function () {
        var host = document.getElementById('main') || document.body;
        if (!host) return null;
        var roots = [host].concat(Array.prototype.slice.call(host.querySelectorAll('*')));
        for (var i = 0; i < roots.length; i++) {
          var el = roots[i];
          var key = Object.keys(el).find(function (k) { return k.indexOf('__reactContainer$') === 0; });
          if (!key) continue;
          var stack = [el[key]];
          while (stack.length) {
            var f = stack.pop();
            if (!f) continue;
            var v = f.memoizedProps && f.memoizedProps.value;
            if (v && typeof v === 'object' && typeof v.getRegistry === 'function') return v;
            if (f.sibling) stack.push(f.sibling);
            if (f.child) stack.push(f.child);
          }
        }
        return null;
      };
      var services = function () {
        var platform = findPlatform();
        if (!platform) return null;
        var registry = platform.getRegistry();
        var found = null;
        registry._map.forEach(function (_v, key) {
          if (key && key.description === 'TokenProvider') found = key;
        });
        if (!found) return null;
        return { platform: platform, token: registry.resolve(found) };
      };
      window.__orpheon = {
        ready: function () { try { return !!services(); } catch (e) { return false; } },
        getToken: async function () {
          var s = services();
          if (!s) throw new Error('page not ready');
          var t = await s.token.getToken();
          return {
            accessToken: t.accessToken,
            expiresAtMs: t.accessTokenExpirationTimestampMs,
            clientId: t.clientId,
            appVersion: s.platform.version,
            isAnonymous: !!t.isAnonymous
          };
        },
        config: function () {
          try { var el = document.getElementById('appServerConfig'); return el ? el.textContent : null; } catch (e) { return null; }
        }
      };
      var tries = 0;
      var timer = setInterval(function () {
        tries++;
        var ok = false;
        try { ok = window.__orpheon.ready(); } catch (e) {}
        if (ok) { clearInterval(timer); post({ type: 'ready', config: window.__orpheon.config() }); }
        else if (tries > 160) { clearInterval(timer); post({ type: 'config', config: window.__orpheon.config() }); }
      }, 500);
    })();
    """
}
