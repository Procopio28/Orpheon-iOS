import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

var failures = 0
func check(_ cond: Bool, _ msg: String) { if !cond { failures += 1 }; print(cond ? "ok   " : "FAIL ", msg) }

// ---- shelves / cards
let home = """
{"data":{"home":{"greeting":{"transformedLabel":"Good evening"},
 "homeChips":[{"id":"music-chip","label":{"transformedLabel":"Music"},"subChips":[]}],
 "sectionContainer":{"sections":{"items":[
  {"uri":"spotify:section:1","data":{"__typename":"HomeGenericSectionData","title":{"transformedLabel":"Jump back in"}},
   "sectionItems":{"totalCount":2,"items":[
     {"content":{"__typename":"PlaylistResponseWrapper","data":{"__typename":"Playlist","uri":"spotify:playlist:37i9dQZF1DX","name":"Chill Mix","description":"x",
       "ownerV2":{"data":{"name":"Spotify"}},"images":{"items":[{"sources":[{"url":"https://i.scdn.co/image/p","width":300,"height":300}]}]}}}},
     {"content":{"__typename":"AlbumResponseWrapper","data":{"__typename":"Album","uri":"spotify:album:abc","name":"Alb",
       "artists":{"items":[{"uri":"spotify:artist:1","profile":{"name":"Art"}}]},"coverArt":{"sources":[{"url":"https://i.scdn.co/image/a","width":640,"height":640}]}}}}
   ]}},
  {"uri":"spotify:section:ad","data":{"__typename":"HomePromotionShelf"},"sectionItems":{"items":[]}}
 ]}}}}}
"""
do {
    let j = try JSON.parse(home)
    let sections = j.list("data.home.sectionContainer.sections.items")
    let shelves = sections.compactMap { mapShelf($0) }
    check(shelves.count == 1, "one shelf, promotion dropped (\(shelves.count))")
    check(shelves[0].title == "Jump back in", "shelf title")
    check(shelves[0].items.count == 2, "two cards")
    check(shelves[0].items[0].kind == .playlist && shelves[0].items[0].subtitle == "Spotify", "playlist card")
    check(shelves[0].items[1].kind == .album && shelves[0].items[1].subtitle == "Art", "album card")
    check(Route.from(card: shelves[0].items[0]) == .playlist("spotify:playlist:37i9dQZF1DX"), "route from card")
    let chips = j.list("data.home.homeChips").compactMap { mapHomeChip($0) }
    check(chips.count == 1 && chips[0].id == "music-chip", "chips")
} catch { check(false, "home parse \(error)") }

// ---- library mapping helpers
check(podcastFilterId(["Playlists", "Artists", "Podcasts"]) == "Podcasts", "podcast filter id")
check(podcastFilterId(["Playlists", "Shows"]) == "Shows", "podcast filter id (show)")
check(stableFolderUri("spotify:user:me:folder:abc123:My%20Folder") == "spotify:user:me:folder:abc123", "stable folder uri")

// ---- playlist rows
let row = """
{"uid":"u1","addedAt":{"isoString":"2024-05-01T10:00:00Z"},"itemV2":{"data":{"__typename":"Track","uri":"spotify:track:t1","name":"Song",
 "trackDuration":{"totalMilliseconds":200000},"artists":{"items":[{"uri":"spotify:artist:a","profile":{"name":"A"}}]},
 "albumOfTrack":{"uri":"spotify:album:z","name":"Z","coverArt":{"sources":[{"url":"u","width":64}]}},"playability":{"playable":false}}}}
"""
do {
    let r = try JSON.parse(row)
    var t = mapPlaylistItem(r.at("itemV2.data"), uid: r.str("uid"))
    t?.addedAt = r.str("addedAt.isoString")
    check(t?.uid == "u1" && t?.playable == false && t?.durationMs == 200000, "playlist row")
    let eps = try JSON.parse("""
    {"__typename":"Episode","uri":"spotify:episode:e1","name":"Ep","duration":{"totalMilliseconds":600000},"podcastV2":{"data":{"uri":"spotify:show:s","name":"Show"}}}
    """)
    let asTrack = mapPlaylistItem(eps, uid: "q")
    check(asTrack?.uri == "spotify:episode:e1" && asTrack?.artists.first?.name == "Show", "episode as track row")
} catch { check(false, "row parse \(error)") }

// ---- sorting
func tr(_ n: String, _ a: String, _ d: Int64, _ added: String) -> Track {
    Track(uri: "spotify:track:\(n)", name: n, durationMs: d, artists: [ArtistRef(uri: "spotify:artist:\(a)", name: a)], album: AlbumRef(uri: "", name: "alb-\(n)"), addedAt: added)
}
let list = [tr("b", "z", 300, "2024-01-02"), tr("a", "y", 100, "2024-01-03"), tr("c", "x", 200, "2024-01-01")]
check(list.sortedFor(.title).map { $0.name } == ["a", "b", "c"], "sort title")
check(list.sortedFor(.artist).map { $0.name } == ["c", "a", "b"], "sort artist")
check(list.sortedFor(.duration, descending: true).map { $0.name } == ["b", "c", "a"], "sort duration desc")
check(list.sortedFor(.addedAt).map { $0.name } == ["c", "b", "a"], "sort added")
check(list.sortedFor(.custom).map { $0.name } == ["b", "a", "c"], "custom keeps order")

// ---- LRC
let lrc = "[00:12.50] Hello\n[00:15.00][01:00.10] Again\n[00:20] Last line\nnot a line"
let lines = LyricsService.parseLrc(lrc)
check(lines.count == 4, "lrc line count \(lines.count)")
check(lines[0].startMs == 12500 && lines[0].text == "Hello", "lrc first")
check(lines.map { $0.startMs } == [12500, 15000, 20000, 60100], "lrc sorted + multi-tag: \(lines.map { $0.startMs })")
check(lines[0].endMs == 15000, "lrc end")

// ---- Connect state mapping
let state = """
{"is_playing":true,"progress_ms":5000,"shuffle_state":true,"repeat_state":"context","currently_playing_type":"track",
 "context":{"uri":"spotify:album:z"},
 "device":{"id":"dev1","name":"iPhone","type":"Smartphone","is_active":true,"volume_percent":55},
 "actions":{"disallows":{"seeking":true}},
 "item":{"type":"track","uri":"spotify:track:t1","name":"Song","duration_ms":200000,"explicit":true,
   "artists":[{"uri":"spotify:artist:a","name":"A"}],
   "album":{"uri":"spotify:album:z","name":"Z","images":[{"url":"https://i/big","width":640,"height":640},{"url":"https://i/small","width":64,"height":64}]}}}
"""
do {
    let j = try JSON.parse(state)
    let m = ConnectAPI.mapState(j)
    check(m.state.item?.name == "Song" && m.state.item?.explicit == true, "state item")
    check(m.state.shuffle && m.state.repeatMode == .context && !m.state.isPaused, "state flags")
    check(m.state.restrictions.canSeek == false && m.state.restrictions.canPause, "restrictions")
    check(m.device?.name == "iPhone" && m.device?.active == true, "device")
    check(m.state.item?.imageUrl == "https://i/big", "image picked")
    let ad = ConnectAPI.mapState(try JSON.parse("{\"is_playing\":true,\"currently_playing_type\":\"ad\",\"item\":null}"))
    check(ad.state.item == nil, "ad is not an item")
    let ep = ConnectAPI.mapItem(try JSON.parse("""
    {"type":"episode","uri":"spotify:episode:e","name":"E","duration_ms":1000,"images":[],"show":{"uri":"spotify:show:s","name":"S","images":[{"url":"https://i/show","width":300}]}}
    """))
    check(ep?.kind == .episode && ep?.artists.first?.name == "S" && ep?.imageUrl == "https://i/show", "episode item")
} catch { check(false, "state parse \(error)") }

// PlayerState position maths
let ps = PlayerState(item: nil, contextUri: nil, isPaused: false, positionMs: 1000, timestampMs: 10_000, shuffle: false, repeatMode: .off)
check(ps.positionAt(nowMs: 20_000) == 1000, "no item -> frozen position")

// ---- HTTP + GQL end to end with a stubbed network
final class StubProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (Int, Data))?
    static var seen: [URLRequest] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        StubProtocol.seen.append(request)
        let (code, data) = StubProtocol.handler?(request) ?? (500, Data())
        let resp = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
final class FakeTokens: TokenSource {
    var calls = 0
    func webToken(forceRefresh: Bool) async throws -> WebToken {
        calls += 1
        return WebToken(access: "tok\(calls)", expiresAtMs: nowMs() + 3_600_000, clientId: "cid", appVersion: "1.2.3", anonymous: false)
    }
}

func runNetworkTests() async {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("orph-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let store = KeyValueStore(fileName: "t-\(UUID().uuidString).json")
    let cfg = URLSessionConfiguration.ephemeral
    cfg.protocolClasses = [StubProtocol.self]
    let tokens = FakeTokens()
    let http = SpotifyHTTP(tokens: tokens, store: store, session: URLSession(configuration: cfg))
    let opsData = try! Data(contentsOf: URL(fileURLWithPath: "Orpheon/Resources/gql-ops.json"))
    let ops = OpsStore(cacheURL: dir.appendingPathComponent("ops.json"))
    ops.update(try! GqlOps.parse(opsData))
    let gql = GqlClient(http: http, store: ops)
    let service = SpotifyService(http: http, gql: gql)

    StubProtocol.handler = { req in
        let url = req.url!.absoluteString
        if url.contains("clienttoken") { return (200, Data("{\"granted_token\":{\"token\":\"ct\",\"expires_after_seconds\":1209600}}".utf8)) }
        if url.contains("pathfinder") {
            let body = String(data: req.httpBodyStreamData() ?? req.httpBody ?? Data(), encoding: .utf8) ?? ""
            if body.contains("searchTracks") {
                return (200, Data("""
                {"data":{"searchV2":{"tracksV2":{"totalCount":1,"items":[{"item":{"data":{"__typename":"Track","uri":"spotify:track:1","name":"T","duration":{"totalMilliseconds":1000},"artists":{"items":[]}}}}]}}}}
                """.utf8))
            }
            if body.contains("isCurated") {
                return (200, Data("{\"data\":{\"lookup\":[{\"data\":{\"isCurated\":true}},{\"data\":{\"isCurated\":false}}]}}".utf8))
            }
            if body.contains("addToLibrary") { return (200, Data("{\"errors\":[{\"message\":\"boom\"}]}".utf8)) }
            return (200, Data("{\"data\":{}}".utf8))
        }
        return (404, Data())
    }
    do {
        let page = try await service.searchTracks("hello")
        check(page.items.count == 1 && page.items[0].name == "T", "search through stubbed pathfinder")
        let seen = StubProtocol.seen.last { $0.url!.absoluteString.contains("pathfinder") }!
        check(seen.value(forHTTPHeaderField: "authorization") == "Bearer tok1", "bearer header")
        check(seen.value(forHTTPHeaderField: "client-token") == "ct", "client-token header")
        check(seen.value(forHTTPHeaderField: "app-platform") == "WebPlayer", "app-platform header")
        check(tokens.calls == 1, "one token fetch for several requests")
        let flags = try await service.contains(["spotify:track:a", "spotify:track:b"])
        check(flags == [true, false], "contains() maps isCurated: \(flags)")
        do { try await service.addToLibrary(["spotify:album:x"]); check(false, "mutation with errors must throw") }
        catch { check(true, "mutation error surfaces: \(error.localizedDescription)") }
    } catch { check(false, "network test threw \(error)") }
}

extension URLRequest {
    func httpBodyStreamData() -> Data? {
        guard let s = httpBodyStream else { return nil }
        s.open(); defer { s.close() }
        var data = Data(); var buf = [UInt8](repeating: 0, count: 4096)
        while s.hasBytesAvailable { let n = s.read(&buf, maxLength: buf.count); if n <= 0 { break }; data.append(buf, count: n) }
        return data
    }
}

let sem = DispatchSemaphore(value: 0)
Task { await runNetworkTests(); sem.signal() }
sem.wait()
print(failures == 0 ? "ALL PASSED" : "FAILURES: \(failures)")
exit(failures == 0 ? 0 : 1)
