// Orpheon for iOS: a port of Orpheon (https://github.com/kota-zo/Orpheon, formerly Myspoti), GPL-3.0.
// Derived from the Kotlin sources by kota-zo and contributors. Keep these notices; if you ever
// distribute this, publish your complete source under GPL-3.0 (see LICENSE and NOTICE.md).
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Persisted GraphQL operations of the Web Player: name -> sha256 hash.
final class GqlOps {
    let hashes: [String: String]
    let buildVersion: String?
    /// The Web Player's `clientVersion` the table was captured from (`spotify-app-version`).
    let clientVersion: String?

    init(hashes: [String: String], buildVersion: String? = nil, clientVersion: String? = nil) {
        self.hashes = hashes
        self.buildVersion = buildVersion
        self.clientVersion = clientVersion
    }

    func hash(_ name: String) throws -> String {
        guard let h = hashes[name] else { throw SpotifyError.gql(name, "unknown operation") }
        return h
    }

    var names: Set<String> { Set(hashes.keys) }

    static func parse(_ data: Data) throws -> GqlOps {
        let json = try JSON.parse(data)
        guard case .object(let ops)? = json.at("operations") else {
            throw SpotifyError.gql("ops", "no operations in the table")
        }
        var out: [String: String] = [:]
        for (name, op) in ops {
            if let h = op.str("hash") { out[name] = h }
        }
        return GqlOps(hashes: out, buildVersion: json.str("buildVersion"), clientVersion: json.str("clientVersion"))
    }

    /// The table shipped with the app (captured from build 1.3.6.1874).
    static func bundled() -> GqlOps {
        if let url = Bundle.main.url(forResource: "gql-ops", withExtension: "json"),
           let data = try? Data(contentsOf: url), let ops = try? parse(data) {
            return ops
        }
        return GqlOps(hashes: [:])
    }

    /// The cached table if any, else the bundled one.
    static func load(cache: URL) -> GqlOps {
        if let data = try? Data(contentsOf: cache), let ops = try? parse(data), !ops.hashes.isEmpty {
            // A cache older than the bundled table (a new app version) loses to it.
            let bundled = bundled()
            if ops.hashes.count >= bundled.hashes.count / 2 { return ops }
            return bundled
        }
        return bundled()
    }
}

/// The operation table in use; it can change while the app runs (a new Spotify build).
final class OpsStore {
    private var current: GqlOps
    private let lock = NSLock()
    let cacheURL: URL

    init(cacheURL: URL = KeyValueStore.directory.appendingPathComponent("gql-ops.json")) {
        self.cacheURL = cacheURL
        self.current = GqlOps.load(cache: cacheURL)
    }

    var ops: GqlOps {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    func update(_ new: GqlOps) {
        lock.lock(); current = new; lock.unlock()
    }
}

/// Keeps the operation table in step with Spotify's releases, from public files only: the
/// open.spotify.com page names its build and lists its JS bundles; each bundle defines operations
/// as `new X("name","query","hash")`. Runs only when the build changed.
final class GqlOpsUpdater {
    private let store: OpsStore
    private let session: URLSession
    private static let bundleRe = try! NSRegularExpression(pattern: "https://open\\.spotifycdn\\.com/cdn/build/web-player/[^\"']+?\\.js")
    private static let opRe = try! NSRegularExpression(pattern: "new [\\w$]+(?:\\.[\\w$]+)?\\(\"(\\w+)\",\"(query|mutation|subscription)\",\"([0-9a-f]{64})\"")
    /// The least time between two looks at Spotify's current build.
    static let checkGapMs: Int64 = 6 * 3_600_000

    init(store: OpsStore) {
        self.store = store
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: cfg)
    }

    private var checkedURL: URL { store.cacheURL.appendingPathExtension("checked") }

    func isDue(now: Int64 = nowMs()) -> Bool {
        guard let text = try? String(contentsOf: checkedURL, encoding: .utf8), let last = Int64(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return true }
        let gap = now - last
        return !(gap >= 0 && gap < Self.checkGapMs)
    }

    private func markChecked(_ now: Int64) {
        try? String(now).write(to: checkedURL, atomically: true, encoding: .utf8)
    }

    private func get(_ url: String) async throws -> String {
        var req = URLRequest(url: URL(string: url)!)
        req.setValue(spotifyUserAgent, forHTTPHeaderField: "user-agent")
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw SpotifyError.http(code, url) }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// `<script id="...">base64 JSON</script>` blocks of the page.
    static func script(_ html: String, id: String) -> JSON? {
        guard let re = try? NSRegularExpression(pattern: "<script id=\"\(id)\"[^>]*>([^<]+)</script>"),
              let m = re.firstMatch(in: html, range: NSRange(location: 0, length: (html as NSString).length)),
              m.numberOfRanges > 1 else { return nil }
        let raw = (html as NSString).substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
        if let d = Data(base64Encoded: raw, options: .ignoreUnknownCharacters), let j = try? JSON.parse(d) { return j }
        return try? JSON.parse(raw)
    }

    /// Fetches the current build; returns a new table when it changed, else nil.
    func refresh(bundlesAllowed: Bool = true) async -> GqlOps? {
        let now = nowMs()
        let current = store.ops
        guard let html = try? await get("https://open.spotify.com/") else { return nil }
        let build = Self.script(html, id: "appServerConfig")?.str("buildVersion")
        var urls: [String] = []
        let ns = html as NSString
        for m in Self.bundleRe.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let u = ns.substring(with: m.range)
            if !urls.contains(u) { urls.append(u) }
        }
        if let map = Self.script(html, id: "__CDN_FILE_URLS__"), case .object(let o) = map {
            for (_, v) in o {
                if let u = v.stringValue, u.hasSuffix(".js"), u.contains("/web-player/"), !urls.contains(u) { urls.append(u) }
            }
        }
        if urls.isEmpty { return nil }
        if let build = build, build == current.buildVersion { markChecked(now); return nil }
        if !bundlesAllowed { return nil }

        var found: [String: String] = [:]
        let list = urls
        await withTaskGroup(of: String?.self) { group in
            var next = 0
            var running = 0
            while next < list.count || running > 0 {
                while running < 6 && next < list.count {
                    let url = list[next]
                    next += 1
                    running += 1
                    group.addTask { [self] in try? await self.get(url) }
                }
                if let body = await group.next() {
                    running -= 1
                    if let body = body {
                        let b = body as NSString
                        for m in Self.opRe.matches(in: body, range: NSRange(location: 0, length: b.length)) where m.numberOfRanges > 3 {
                            found[b.substring(with: m.range(at: 1))] = b.substring(with: m.range(at: 3))
                        }
                    }
                } else {
                    break
                }
            }
        }
        // A partial download must not drop operations: keep the known ones it did not see.
        if found.count < current.hashes.count / 2 { return nil }
        var merged = current.hashes
        for (k, v) in found { merged[k] = v }
        var operations: [String: JSON] = [:]
        for (k, v) in merged { operations[k] = ["hash": .string(v)] }
        let out: JSON = ["buildVersion": build.map { JSON.string($0) } ?? .null, "operations": .object(operations)]
        try? out.jsonData().write(to: store.cacheURL, options: .atomic)
        markChecked(now)
        return GqlOps(hashes: merged, buildVersion: build)
    }
}

/// Operations that change something: not replayed when their outcome is unknown, and any error fails them.
func isMutation(_ name: String) -> Bool {
    let re = try! NSRegularExpression(pattern: "^(add|remove|move|update|delete|set|Set|create|follow|unfollow|pin|unpin|edit|save|ban|unban|clear)[A-Z]")
    return re.firstMatch(in: name, range: NSRange(location: 0, length: (name as NSString).length)) != nil
}

/// Throws when `response` reports a failure: errors without data for a read, any error or no data
/// at all for a mutation, where partial data would otherwise pass for a success.
func checkErrors(_ name: String, _ response: JSON) throws {
    guard response.isObject else { return }
    let errors = response.list("errors")
    let data = response.obj("data")
    let failed = isMutation(name) ? (!errors.isEmpty || data == nil) : (!errors.isEmpty && data == nil)
    if !failed { return }
    let message = errors.first?.str("message") ?? "no result"
    throw SpotifyError.gql(name, message)
}

/// The Web Player's GraphQL straight to api-partner: persisted queries by name and hash.
final class GqlClient {
    private let http: SpotifyHTTP
    private let store: OpsStore
    private let updater: GqlOpsUpdater
    private let endpoint = "https://api-partner.spotify.com/pathfinder/v2/query"
    private var refreshing = false
    private let lock = NSLock()

    init(http: SpotifyHTTP, store: OpsStore) {
        self.http = http
        self.store = store
        self.updater = GqlOpsUpdater(store: store)
    }

    var ops: GqlOps { store.ops }

    private func beginRefresh() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if refreshing { return false }
        refreshing = true
        return true
    }

    private func endRefresh() {
        lock.lock(); refreshing = false; lock.unlock()
    }

    /// Reads the current Web Player build's operation list once (a changed build, or an unknown operation).
    @discardableResult
    func refreshOps() async -> Bool {
        if !beginRefresh() { return false }
        defer { endRefresh() }
        if let fresh = await updater.refresh() {
            store.update(fresh)
            return true
        }
        return false
    }

    /// A look at Spotify's current build when one is due (at most every six hours).
    func refreshOpsIfDue() async {
        if updater.isDue() { await refreshOps() }
    }

    private func isPersistedQueryMissing(_ response: JSON) -> Bool {
        for e in response.list("errors") {
            let m = (e.str("message") ?? "").lowercased()
            if m.contains("persistedquerynotfound") || m.contains("persisted query") { return true }
        }
        return false
    }

    /// Runs a persisted GraphQL operation and returns the whole `{data: ...}` response.
    func query(_ name: String, _ variables: JSON = [:]) async throws -> JSON {
        var attempt = 0
        while true {
            let hash = try store.ops.hash(name)
            let body: JSON = [
                "variables": variables,
                "operationName": .string(name),
                "extensions": ["persistedQuery": ["version": 1, "sha256Hash": .string(hash)]],
            ]
            let (code, data) = try await http.send("POST", endpoint, body: body.jsonData())
            if code == 200 {
                let response = try JSON.parse(data)
                if attempt == 0, isPersistedQueryMissing(response) {
                    attempt += 1
                    if await refreshOps() { continue }
                }
                try checkErrors(name, response)
                return response
            }
            // A refused token is replaced by the next request; a stale hash by a new operation table.
            if attempt == 0 && code == 401 { attempt += 1; continue }
            if attempt == 0 && !isMutation(name) && (code == 400 || code == 404) {
                attempt += 1
                if await refreshOps() { continue }
            }
            throw SpotifyError.http(code, String(data: data.prefix(200), encoding: .utf8) ?? "")
        }
    }
}
