// Orpheon for iOS: a port of Orpheon (https://github.com/kota-zo/Orpheon, formerly Myspoti), GPL-3.0.
// Derived from the Kotlin sources by kota-zo and contributors. Keep these notices; if you ever
// distribute this, publish your complete source under GPL-3.0 (see LICENSE and NOTICE.md).
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum SpotifyError: Error, LocalizedError {
    case notSignedIn
    case http(Int, String)
    case gql(String, String)
    case notSpotifyHost(String)
    case token(String)
    case premiumRequired
    case noDevice
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn: return "You are not signed in to Spotify."
        case .http(let code, let body): return "Spotify answered HTTP \(code)\(body.isEmpty ? "" : ": " + body)"
        case .gql(let op, let message): return "\(op): \(message)"
        case .notSpotifyHost(let h): return "Not a Spotify host: \(h)"
        case .token(let m): return "Token: \(m)"
        case .premiumRequired: return "Spotify only lets Premium accounts control playback from another app."
        case .noDevice: return "No Spotify device is available. Open the Spotify app on this phone (or another device) and try again."
        case .unavailable(let m): return m
        }
    }
}

/// The web access token the Web Player holds for the signed-in account.
struct WebToken: Codable, Equatable {
    var access: String
    var expiresAtMs: Int64
    var clientId: String
    /// The page's `clientVersion` (`spotify-app-version`).
    var appVersion: String
    var anonymous: Bool
}

/// Where web tokens come from: the Web Player page, driven by `TokenBridge`.
protocol TokenSource: AnyObject {
    func webToken(forceRefresh: Bool) async throws -> WebToken
}

struct ClientToken: Codable {
    var value: String
    var expiresAtMs: Int64
    var clientId: String
}

let spotifyJsonType = "application/json;charset=UTF-8"
let spotifyUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15"

func isSpotifyHost(_ host: String?) -> Bool {
    guard let h = host?.lowercased() else { return false }
    return h == "spotify.com" || h.hasSuffix(".spotify.com")
}

/// Direct HTTP to Spotify with the Web Player's credentials: the web token from the page (see
/// `TokenBridge`), and a client token minted here and kept about 14 days.
actor SpotifyHTTP {
    private let tokens: TokenSource
    private let session: URLSession
    private let store: KeyValueStore
    private var language: String
    private var deviceId: String

    private var web: WebToken?
    private var client: ClientToken?
    private var webTask: Task<WebToken, Error>?
    private var webFetchedAtMs: Int64 = 0
    /// Set by a 401: the next token request asks the page for a new token instead of its cached one.
    private var forceNextToken = false

    init(tokens: TokenSource, store: KeyValueStore, language: String = "en", session: URLSession? = nil) {
        self.tokens = tokens
        self.store = store
        self.language = language
        if let session = session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.default
            cfg.timeoutIntervalForRequest = 25
            cfg.timeoutIntervalForResource = 60
            cfg.httpShouldSetCookies = false
            cfg.httpCookieAcceptPolicy = .never
            self.session = URLSession(configuration: cfg)
        }
        if let id = store.get("clientDeviceId") {
            self.deviceId = id
        } else {
            let id = UUID().uuidString.lowercased()
            store.set("clientDeviceId", id)
            self.deviceId = id
        }
    }

    func setLanguage(_ code: String) { language = code }

    /// Drops the cached web token (it belongs to one account); the client token is kept.
    func forgetWebToken() {
        web = nil
        store.set("webToken", nil)
    }

    private func tokenWasRefused() {
        forgetWebToken()
        forceNextToken = true
    }

    /// Forgets everything about the account (a sign-out).
    func forgetAccount() {
        web = nil
        client = nil
        store.set("webToken", nil)
        store.set("clientToken", nil)
    }

    // MARK: Tokens

    /// The credentials, refreshed exactly as `send` does. `forceRefresh` (after a 401 elsewhere) asks the page again.
    func credentials(forceRefresh: Bool = false) async throws -> (web: WebToken, client: ClientToken) {
        if forceRefresh { tokenWasRefused() }
        let w = try await webToken()
        let c = try await clientToken(for: w)
        return (w, c)
    }

    /// True when the page's token belongs to a signed-in user.
    func isSignedIn() async -> Bool {
        do {
            let fresh = nowMs() - webFetchedAtMs < 10_000
            if !fresh { web = nil }
            let w = try await webToken()
            return !w.anonymous
        } catch {
            return false
        }
    }

    private func storedWebToken(_ now: Int64) -> WebToken? {
        guard let text = store.get("webToken"), let data = text.data(using: .utf8),
              let t = try? JSONDecoder().decode(WebToken.self, from: data),
              !t.anonymous, t.expiresAtMs - now > 120_000 else { return nil }
        return t
    }

    func hasToken() -> Bool {
        let now = nowMs()
        if let w = web, !w.anonymous, w.expiresAtMs - now > 60_000 { return true }
        return storedWebToken(now) != nil
    }

    private func webToken() async throws -> WebToken {
        let now = nowMs()
        if let w = web, w.expiresAtMs - now > 60_000 { return w }
        if let t = storedWebToken(now) { web = t; return t }
        if let task = webTask { return try await task.value }
        let source = tokens
        let force = forceNextToken
        forceNextToken = false
        let task = Task<WebToken, Error> { try await source.webToken(forceRefresh: force) }
        webTask = task
        do {
            let w = try await task.value
            webTask = nil
            web = w
            webFetchedAtMs = nowMs()
            if !w.anonymous, let data = try? JSONEncoder().encode(w), let text = String(data: data, encoding: .utf8) {
                store.set("webToken", text)
            }
            return w
        } catch {
            webTask = nil
            throw error
        }
    }

    private func clientToken(for w: WebToken) async throws -> ClientToken {
        let now = nowMs()
        func fresh(_ t: ClientToken) -> Bool {
            t.expiresAtMs - now > 3_600_000 && (t.clientId.isEmpty || t.clientId == w.clientId)
        }
        if let c = client, fresh(c) { return c }
        if let text = store.get("clientToken"), let data = text.data(using: .utf8),
           let c = try? JSONDecoder().decode(ClientToken.self, from: data), fresh(c) {
            client = c
            return c
        }
        let c = try await mintClientToken(w)
        client = c
        if let data = try? JSONEncoder().encode(c), let text = String(data: data, encoding: .utf8) {
            store.set("clientToken", text)
        }
        return c
    }

    private func mintClientToken(_ w: WebToken) async throws -> ClientToken {
        let body: JSON = [
            "client_data": [
                "client_version": .string(w.appVersion),
                "client_id": .string(w.clientId),
                "js_sdk_data": [
                    "device_brand": "unknown",
                    "device_model": "unknown",
                    "os": "mac",
                    "os_version": "unknown",
                    "device_id": .string(deviceId),
                    "device_type": "computer",
                ],
            ],
        ]
        var req = URLRequest(url: URL(string: "https://clienttoken.spotify.com/v1/clienttoken")!)
        req.httpMethod = "POST"
        req.httpBody = body.jsonData()
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue("application/json", forHTTPHeaderField: "accept")
        req.setValue(spotifyUserAgent, forHTTPHeaderField: "user-agent")
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard let json = try? JSON.parse(data), let granted = json.obj("granted_token"),
              let token = granted.str("token") else {
            throw SpotifyError.gql("clienttoken", "HTTP \(code): \(String(data: data.prefix(200), encoding: .utf8) ?? "")")
        }
        let seconds = granted.long("expires_after_seconds") ?? 86_400
        return ClientToken(value: token, expiresAtMs: nowMs() + seconds * 1000, clientId: w.clientId)
    }

    // MARK: Requests

    /// Sends a request with the Web Player's headers. Returns the status and the body.
    func send(_ method: String, _ url: String, body: Data? = nil,
              contentType: String = spotifyJsonType, accept: String = "application/json",
              headers: [String: String] = [:]) async throws -> (status: Int, data: Data) {
        guard let target = URL(string: url), isSpotifyHost(target.host) else {
            throw SpotifyError.notSpotifyHost(URL(string: url)?.host ?? url)
        }
        let (w, c) = try await credentials()
        var req = URLRequest(url: target)
        req.httpMethod = method
        req.setValue("Bearer \(w.access)", forHTTPHeaderField: "authorization")
        req.setValue(c.value, forHTTPHeaderField: "client-token")
        req.setValue("WebPlayer", forHTTPHeaderField: "app-platform")
        req.setValue(w.appVersion, forHTTPHeaderField: "spotify-app-version")
        req.setValue(accept, forHTTPHeaderField: "accept")
        req.setValue(language, forHTTPHeaderField: "accept-language")
        req.setValue("https://open.spotify.com", forHTTPHeaderField: "origin")
        req.setValue("https://open.spotify.com/", forHTTPHeaderField: "referer")
        req.setValue(spotifyUserAgent, forHTTPHeaderField: "user-agent")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if let body = body {
            req.httpBody = body
            req.setValue(contentType, forHTTPHeaderField: "content-type")
        } else if method != "GET" && method != "DELETE" && method != "HEAD" {
            req.httpBody = Data()
        }
        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { tokenWasRefused() }
        return (status, data)
    }

    /// Same as `send`, for the public Web API on `api.spotify.com` (the web token works there too).
    /// Returns the status, the body and the `Retry-After` seconds when Spotify asked to slow down.
    func sendAPI(_ method: String, _ url: String, body: JSON? = nil) async throws -> (status: Int, data: Data, retryAfter: Double?) {
        guard let target = URL(string: url), isSpotifyHost(target.host) else {
            throw SpotifyError.notSpotifyHost(URL(string: url)?.host ?? url)
        }
        let (w, _) = try await credentials()
        var req = URLRequest(url: target)
        req.httpMethod = method
        req.setValue("Bearer \(w.access)", forHTTPHeaderField: "authorization")
        req.setValue("application/json", forHTTPHeaderField: "accept")
        req.setValue(language, forHTTPHeaderField: "accept-language")
        req.setValue(spotifyUserAgent, forHTTPHeaderField: "user-agent")
        if let body = body {
            req.httpBody = body.jsonData()
            req.setValue("application/json", forHTTPHeaderField: "content-type")
        } else if method != "GET" && method != "DELETE" {
            req.httpBody = Data()
            req.setValue("application/json", forHTTPHeaderField: "content-type")
        }
        let (data, resp) = try await session.data(for: req)
        let http = resp as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        if status == 401 { tokenWasRefused() }
        let retry = http?.value(forHTTPHeaderField: "Retry-After").flatMap { Double($0) }
        return (status, data, retry)
    }

    func getJSON(_ url: String) async throws -> JSON? {
        let (code, data) = try await send("GET", url)
        switch code {
        case 200: return try JSON.parse(data)
        case 204, 404: return nil
        default: throw SpotifyError.http(code, String(data: data.prefix(200), encoding: .utf8) ?? "")
        }
    }

    func postJSON(_ url: String, _ body: JSON) async throws -> JSON? {
        let (code, data) = try await send("POST", url, body: body.jsonData())
        guard (200..<300).contains(code) else {
            throw SpotifyError.http(code, String(data: data.prefix(200), encoding: .utf8) ?? "")
        }
        return data.isEmpty ? nil : try? JSON.parse(data)
    }
}
