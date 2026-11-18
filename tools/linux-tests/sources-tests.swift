import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

var failures = 0
func check(_ cond: Bool, _ msg: String) { if !cond { failures += 1 }; print(cond ? "ok   " : "FAIL ", msg) }

func tr(_ name: String, _ artist: String, _ ms: Int64, _ uri: String = "") -> Track {
    Track(uri: uri.isEmpty ? "spotify:track:\(name.hashValue)" : uri, name: name, durationMs: ms,
          artists: [ArtistRef(uri: "spotify:artist:1", name: artist)], album: AlbumRef(uri: "", name: "Album"))
}

// ---------- matcher
let rick = TrackQuery(title: "Never Gonna Give You Up", artist: "Rick Astley", durationMs: 213_573)
func s(_ t: String, _ a: String, _ d: Int64?, inTitle: Bool = false, topic: Bool = false) -> Double? {
    TrackMatcher.score(rick, TrackMatcher.Candidate(title: t, artist: a, durationMs: d, artistMayBeInTitle: inTitle, isTopicChannel: topic))
}
check(TrackMatcher.normalize("Bohemian Rhapsody - Remastered 2011") == "bohemian rhapsody", "normalize drops remaster suffix: '\(TrackMatcher.normalize("Bohemian Rhapsody - Remastered 2011"))'")
check(TrackMatcher.normalize("Song (feat. Someone) [Live]") == "song", "normalize drops brackets: '\(TrackMatcher.normalize("Song (feat. Someone) [Live]"))'")
check(TrackMatcher.normalize("Beyoncé – Halo") == "beyonce halo", "normalize accents/dashes: '\(TrackMatcher.normalize("Beyoncé – Halo"))'")
check(TrackMatcher.similarity("Rick Astley", "rick astley") == 1, "similarity case")
check((s("Never Gonna Give You Up", "Rick Astley", 213_000) ?? 0) > 0.95, "exact match scores high: \(s("Never Gonna Give You Up", "Rick Astley", 213_000) ?? -1)")
check((s("Never Gonna Give You Up", "Rick Astley", nil) ?? 0) > 0.8, "unknown duration still fine: \(s("Never Gonna Give You Up", "Rick Astley", nil) ?? -1)")
check(s("Never Gonna Give You Up", "Some Cover Band", 213_000) == nil, "wrong artist rejected")
check(s("Never Gonna Give You Up", "Rick Astley", 300_000) == nil, "wrong length rejected")
let studio = s("Never Gonna Give You Up", "Rick Astley", 213_000) ?? 0
check(s("Never Gonna Give You Up (Live at Wembley)", "Rick Astley", 213_000) == nil, "a live version is not a match for the studio track")
check(s("Never Gonna Give You Up - Karaoke Version", "Rick Astley", 213_000) == nil, "karaoke is not a match")
let lyricsSame = s("Never Gonna Give You Up (Lyrics)", "Rick Astley", 213_000, inTitle: true) ?? 0
check(lyricsSame > 0.8 && lyricsSame < studio, "a lyric video of the right audio still matches, slightly lower: \(lyricsSame)")
let yt = s("Rick Astley - Never Gonna Give You Up (Official Music Video)", "Rick Astley", 213_000, inTitle: true) ?? 0
check(yt > 0.8, "youtube-style title with artist inside: \(yt)")
let topic = s("Never Gonna Give You Up", "Rick Astley", 213_500, topic: true) ?? 0
check(topic >= studio, "topic channel gets a small bonus: \(topic)")
let lyric = s("Never Gonna Give You Up (Lyrics)", "Random Lyric Channel", 213_000, inTitle: true) ?? 0
check(lyric < 0.8, "lyric-video channel without the artist scores low: \(lyric)")
check(TrackMatcher.score(rick, .init(title: "Never Gonna Give You Up (Remix)", artist: "Rick Astley", durationMs: 213_000)) == nil, "remix rejected")
let wantRemix = TrackQuery(title: "Song (Club Remix)", artist: "A", durationMs: 200_000)
check((TrackMatcher.score(wantRemix, .init(title: "Song (Club Remix)", artist: "A", durationMs: 200_000)) ?? 0) > 0.95, "wanted remix matches itself")
check(TrackMatcher.score(wantRemix, .init(title: "Song", artist: "A", durationMs: 200_000)) == nil, "the original is not the wanted remix")
check(TrackMatcher.durationScore(200_000, 201_000) == 1 && TrackMatcher.durationScore(200_000, 205_000) == 0.7 && TrackMatcher.durationScore(0, 1) == nil, "duration score")

// ---------- ISO durations
check(YouTubeProvider.parseDuration("PT3M33S") == 213_000, "PT3M33S")
check(YouTubeProvider.parseDuration("PT1H2M3S") == 3_723_000, "PT1H2M3S")
check(YouTubeProvider.parseDuration("PT45S") == 45_000 && YouTubeProvider.parseDuration("P0D") == nil && YouTubeProvider.parseDuration(nil) == nil, "PT45S / live / nil")

// ---------- queue
var q = SourceQueue()
let list = (0..<5).map { tr("t\($0)", "a", 1000, "spotify:track:\($0)") }
q.load(list, start: 2, shuffle: false, context: "spotify:album:x")
check(q.current?.name == "t2" && q.upcoming.map { $0.name } == ["t3", "t4"], "load at 2")
check(q.advance(auto: true)?.name == "t3", "advance")
check(q.back()?.name == "t2", "back")
q.load(list, start: 4, shuffle: false)
check(q.advance(auto: true) == nil, "end of list")
q.repeatMode = .context
check(q.advance(auto: true)?.name == "t0", "repeat context wraps")
q.repeatMode = .track
check(q.advance(auto: true)?.name == "t0" && q.advance(auto: false)?.name == "t1", "repeat one only for auto-advance")
q.repeatMode = .off
q.load(list, start: 1, shuffle: true)
check(q.current?.name == "t1" && Set(q.upcoming.map { $0.name }) == Set(["t0", "t2", "t3", "t4"]) && q.order.count == 5, "shuffle keeps chosen first, no repeats")
q.setShuffle(false)
check(q.current?.name == "t1" && q.upcoming.map { $0.name } == ["t2", "t3", "t4"], "unshuffle continues in list order")
q.insertNext(tr("new", "a", 1000, "spotify:track:new"))
check(q.next?.name == "new", "insertNext plays next")
var q2 = SourceQueue(); q2.load([], start: 0, shuffle: false)
check(q2.current == nil && q2.advance(auto: true) == nil && q2.back() == nil, "empty queue is safe")

// ---------- stubbed network for providers and resolver
final class Stub: URLProtocol {
    static var handler: ((URLRequest) -> (Int, String))?
    static var urls: [String] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Stub.urls.append(request.url!.absoluteString)
        let (code, body) = Stub.handler?(request) ?? (500, "")
        let resp = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
let cfg = URLSessionConfiguration.ephemeral
cfg.protocolClasses = [Stub.self]
let session = URLSession(configuration: cfg)

let itunes = """
{"resultCount":3,"results":[
 {"wrapperType":"track","kind":"song","trackId":1559523357,"trackName":"Never Gonna Give You Up","artistName":"Rick Astley","collectionName":"Whenever You Need Somebody","trackTimeMillis":213573,"previewUrl":"https://audio-ssl.itunes.apple.com/p.m4a","artworkUrl100":"https://is1.mzstatic.com/100x100bb.jpg","isStreamable":true},
 {"wrapperType":"track","kind":"song","trackId":2,"trackName":"Never Gonna Give You Up","artistName":"Cover Band","trackTimeMillis":213000,"isStreamable":true},
 {"wrapperType":"track","kind":"song","trackId":3,"trackName":"Together Forever","artistName":"Rick Astley","trackTimeMillis":200000,"isStreamable":true}]}
"""

func runAll() async {
    // Apple Music: subscriber, non-subscriber, previews, denied
    Stub.handler = { _ in (200, itunes) }
    let sub = AppleMusicProvider(session: session, status: { .ready })
    let a1 = try? await sub.find(rick, options: SourceOptions())
    check(a1?.target == .appleStoreID("1559523357") && a1?.source == .appleMusic && a1?.isPreview == false, "apple: subscriber gets the full song id")
    check(a1?.imageUrl == "https://is1.mzstatic.com/600x600bb.jpg", "apple: bigger artwork")
    check(Stub.urls.last?.contains("entity=song") == true && Stub.urls.last?.contains("country=") == true, "apple: search url")

    let free = AppleMusicProvider(session: session, status: { .noSubscription })
    do { _ = try await free.find(rick, options: SourceOptions()); check(false, "apple: no subscription must not return full songs") }
    catch { check((error as? SourceError)?.message.contains("subscription") == true, "apple: no subscription is a setup message, premium is hidden") }
    let prev = try? await free.find(rick, options: SourceOptions(allowPreviews: true))
    check(prev?.isPreview == true && prev?.label == "Apple Music preview", "apple: preview only when allowed (\(prev?.label ?? "nil"))")
    if case .url(let u)? = prev?.target { check(u.absoluteString.hasSuffix("p.m4a"), "apple: preview url") } else { check(false, "apple: preview target") }
    let denied = AppleMusicProvider(session: session, status: { .denied })
    do { _ = try await denied.find(rick, options: SourceOptions(allowPreviews: true)); check(false, "apple: denied") }
    catch { check(true, "apple: permission denied surfaces") }
    let notStreamable = """
    {"results":[{"kind":"song","trackId":9,"trackName":"Never Gonna Give You Up","artistName":"Rick Astley","trackTimeMillis":213000,"isStreamable":false,"previewUrl":"https://x/p.m4a"}]}
    """
    Stub.handler = { _ in (200, notStreamable) }
    let ns = try? await sub.find(rick, options: SourceOptions())
    check(ns == nil, "apple: a song Apple does not stream is hidden for subscribers too")

    // YouTube
    var ytCalls = 0
    Stub.handler = { req in
        ytCalls += 1
        let u = req.url!.absoluteString
        if u.contains("/search") {
            return (200, """
            {"items":[
             {"id":{"videoId":"LYRIC1"},"snippet":{"title":"Never Gonna Give You Up (Lyrics)","channelTitle":"Lyric Channel","thumbnails":{"high":{"url":"https://i/l.jpg"}}}},
             {"id":{"videoId":"TOPIC1"},"snippet":{"title":"Never Gonna Give You Up","channelTitle":"Rick Astley - Topic","thumbnails":{"high":{"url":"https://i/t.jpg"}}}},
             {"id":{"videoId":"NOEMBED"},"snippet":{"title":"Rick Astley - Never Gonna Give You Up (Official Video)","channelTitle":"Rick Astley","thumbnails":{}}}]}
            """)
        }
        return (200, """
        {"items":[
         {"id":"LYRIC1","contentDetails":{"duration":"PT3M34S"},"status":{"embeddable":true,"privacyStatus":"public"}},
         {"id":"TOPIC1","contentDetails":{"duration":"PT3M34S"},"status":{"embeddable":true,"privacyStatus":"public"}},
         {"id":"NOEMBED","contentDetails":{"duration":"PT3M33S"},"status":{"embeddable":false,"privacyStatus":"public"}}]}
        """)
    }
    let yp = YouTubeProvider(session: session, apiKey: { "KEY" })
    let y1 = try? await yp.find(rick, options: SourceOptions())
    check(y1?.target == .youtubeVideo("TOPIC1"), "youtube: picks the Topic upload, skips non-embeddable (got \(String(describing: y1?.target)))")
    check(ytCalls == 2, "youtube: one search + one details call")
    check(Stub.urls.contains { $0.contains("videoEmbeddable=true") && $0.contains("key=KEY") }, "youtube: embeddable filter + key sent")
    let noKey = YouTubeProvider(session: session, apiKey: { nil })
    do { _ = try await noKey.find(rick, options: SourceOptions()); check(false, "youtube: no key") }
    catch { check((error as? SourceError)?.message.contains("API key") == true, "youtube: no key is a setup message") }
    Stub.handler = { _ in (403, "{\"error\":{\"message\":\"quota\",\"errors\":[{\"reason\":\"quotaExceeded\"}]}}") }
    do { _ = try await yp.find(rick, options: SourceOptions()); check(false, "youtube: quota") }
    catch { check((error as? SourceError)?.message.contains("quota") == true, "youtube: quota message") }

    // Audius
    Stub.handler = { _ in (200, """
    {"data":[
     {"id":"GATED","title":"Never Gonna Give You Up","user":{"name":"Rick Astley"},"duration":213,"is_streamable":true,"access":{"stream":false},"stream_conditions":{"usdc_purchase":{"price":100}}},
     {"id":"OPEN1","title":"Never Gonna Give You Up","user":{"name":"Rick Astley"},"duration":213,"is_streamable":true,"access":{"stream":true},"artwork":{"480x480":"https://a/480.jpg"}},
     {"id":"OTHER","title":"Different Song","user":{"name":"Someone"},"duration":100,"is_streamable":true}]}
    """) }
    let au = AudiusProvider(session: session)
    let r = try? await au.find(rick, options: SourceOptions())
    check(r?.source == .audius && r?.durationMs == 213_000, "audius: match")
    if case .url(let u)? = r?.target { check(u.absoluteString == "https://api.audius.co/v1/tracks/OPEN1/stream?app_name=OrpheonIOS", "audius: stream url (and the gated track is skipped): \(u)") } else { check(false, "audius target") }

    // Resolver: .all order, caching, setup errors not cached
    var hits: [String] = []
    final class Fake: SourceProvider {
        let id: AudioSourceID
        let result: () throws -> ResolvedAudio?
        let log: (String) -> Void
        init(_ id: AudioSourceID, log: @escaping (String) -> Void, _ r: @escaping () throws -> ResolvedAudio?) { self.id = id; self.result = r; self.log = log }
        func availability() async -> SourceAvailability { .ready }
        func find(_ q: TrackQuery, options: SourceOptions) async throws -> ResolvedAudio? { log(id.rawValue); return try result() }
    }
    let audio = ResolvedAudio(source: .audius, target: .url(URL(string: "https://x/y.mp3")!), title: "T", artist: "A", durationMs: 1000)
    let resolver = SourceResolver(providers: [
        Fake(.appleMusic, log: { hits.append($0) }) { throw SourceError.setup("needs a subscription") },
        Fake(.audius, log: { hits.append($0) }) { audio },
        Fake(.youtube, log: { hits.append($0) }) { nil },
    ])
    let t = tr("Song", "Artist", 1000, "spotify:track:abc")
    let res = await resolver.resolve(t, preference: .all, options: SourceOptions())
    if case .found(let f) = res { check(f.source == .audius, "resolver: all -> first source that works") } else { check(false, "resolver found") }
    check(hits == ["appleMusic", "audius"], "resolver: tried in order and stopped at the first match: \(hits)")
    _ = await resolver.resolve(t, preference: .all, options: SourceOptions())
    check(hits.count == 2, "resolver: second request is cached")
    let only = await resolver.resolve(tr("Other", "B", 1000, "spotify:track:def"), preference: .youtube, options: SourceOptions())
    if case .notFound(let reasons) = only { check(reasons == ["YouTube: no match"], "resolver: single-source miss reason \(reasons)") } else { check(false, "resolver miss") }
    hits.removeAll()
    _ = await resolver.resolve(tr("Other", "B", 1000, "spotify:track:def"), preference: .youtube, options: SourceOptions())
    check(hits.isEmpty, "resolver: plain miss is remembered")
    let apple = await resolver.resolve(tr("Z", "B", 1000, "spotify:track:zzz"), preference: .appleMusic, options: SourceOptions())
    if case .notFound(let reasons) = apple { check(reasons.first?.contains("subscription") == true, "resolver: setup problem reported: \(reasons)") } else { check(false, "apple setup") }
    hits.removeAll()
    _ = await resolver.resolve(tr("Z", "B", 1000, "spotify:track:zzz"), preference: .appleMusic, options: SourceOptions())
    check(hits == ["appleMusic"], "resolver: setup problems are not cached")
    check(SourcePreference.all.providers == [.appleMusic, .audius, .youtube] && SourcePreference.spotifyApp.providers.isEmpty, "preference order")
}

let sem = DispatchSemaphore(value: 0)
Task { await runAll(); sem.signal() }
sem.wait()
print(failures == 0 ? "ALL PASSED" : "FAILURES: \(failures)")
exit(failures == 0 ? 0 : 1)
