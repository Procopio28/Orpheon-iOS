// Orpheon for iOS: a port of Orpheon (https://github.com/kota-zo/Orpheon, formerly Myspoti), GPL-3.0.
// Derived from the Kotlin sources by kota-zo and contributors. Keep these notices; if you ever
// distribute this, publish your complete source under GPL-3.0 (see LICENSE and NOTICE.md).
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private func makeSession() -> URLSession {
    let cfg = URLSessionConfiguration.default
    cfg.timeoutIntervalForRequest = 15
    return URLSession(configuration: cfg)
}

private func getJSON(_ session: URLSession, _ comps: URLComponents) async throws -> (status: Int, json: JSON?) {
    guard let url = comps.url else { throw SourceError.network("bad url") }
    var req = URLRequest(url: url)
    req.setValue("Orpheon-iOS/1.0", forHTTPHeaderField: "User-Agent")
    let (data, resp) = try await session.data(for: req)
    let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
    return (status, try? JSON.parse(data))
}

// MARK: - Apple Music

/// Finds the song in Apple's public catalogue (the iTunes Search API, no key). The song is then played
/// by Apple's own player with the user's own subscription; without one, only the 30-second preview Apple
/// publishes exists, and it is used only when the user allowed previews.
final class AppleMusicProvider: SourceProvider {
    let id = AudioSourceID.appleMusic
    private let session: URLSession
    private let status: () async -> AppleMusicStatus
    private let country: () -> String

    init(session: URLSession? = nil,
         country: @escaping () -> String = { Locale.current.regionCode ?? "US" },
         status: @escaping () async -> AppleMusicStatus) {
        self.session = session ?? makeSession()
        self.country = country
        self.status = status
    }

    func availability() async -> SourceAvailability {
        let s = await status()
        return s == .ready ? .ready : .needsSetup(s.text)
    }

    func find(_ q: TrackQuery, options: SourceOptions) async throws -> ResolvedAudio? {
        let account = await status()
        if account == .denied || account == .unknown && !options.allowPreviews {
            throw SourceError.setup(account.text)
        }
        if account == .noSubscription && !options.allowPreviews {
            throw SourceError.setup("needs an Apple Music subscription (full songs are not available without one)")
        }
        var comps = URLComponents(string: "https://itunes.apple.com/search")!
        comps.queryItems = [
            URLQueryItem(name: "term", value: "\(q.artist) \(q.title)"),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "12"),
            URLQueryItem(name: "country", value: country()),
        ]
        let (code, json) = try await getJSON(session, comps)
        guard code == 200, let results = json?.list("results") else { throw SourceError.network("Apple search answered \(code)") }
        let songs = results.filter { ($0.str("kind") ?? "song") == "song" }
        guard let hit = TrackMatcher.best(q, songs, { r in
            TrackMatcher.Candidate(title: r.str("trackName") ?? "", artist: r.str("artistName") ?? "", durationMs: r.long("trackTimeMillis"))
        }) else { return nil }
        let r = hit.item
        let art = r.str("artworkUrl100")?.replacingOccurrences(of: "100x100", with: "600x600")
        let streamable = r.bool("isStreamable") ?? true
        if account == .ready, streamable, let id = r.long("trackId") {
            return ResolvedAudio(source: .appleMusic, target: .appleStoreID(String(id)),
                                 title: r.str("trackName") ?? q.title, artist: r.str("artistName") ?? q.artist,
                                 durationMs: r.long("trackTimeMillis") ?? q.durationMs, imageUrl: art, isPreview: false, score: hit.score)
        }
        // No subscription, or not on Apple Music: the full song is out of reach. Previews only if allowed.
        if options.allowPreviews, let p = r.str("previewUrl"), let u = URL(string: p) {
            return ResolvedAudio(source: .appleMusic, target: .url(u), title: r.str("trackName") ?? q.title,
                                 artist: r.str("artistName") ?? q.artist, durationMs: 30_000, imageUrl: art, isPreview: true, score: hit.score)
        }
        return nil
    }
}

// MARK: - YouTube

/// Finds the video with YouTube's own Data API (the user's key). The video is played by YouTube's own
/// embedded player, ads included; only videos YouTube marks as embeddable are considered.
final class YouTubeProvider: SourceProvider {
    let id = AudioSourceID.youtube
    private let session: URLSession
    private let apiKey: () -> String?

    init(session: URLSession? = nil, apiKey: @escaping () -> String?) {
        self.session = session ?? makeSession()
        self.apiKey = apiKey
    }

    func availability() async -> SourceAvailability {
        (apiKey() ?? "").isEmpty ? .needsSetup("Add a YouTube Data API key in Settings") : .ready
    }

    /// "PT3M33S" -> 213000 ms. Live streams ("P0D") give nil.
    static func parseDuration(_ iso: String?) -> Int64? {
        guard let iso = iso, iso.hasPrefix("P") else { return nil }
        var total: Int64 = 0
        var number = ""
        var inTime = false
        for ch in iso.dropFirst() {
            if ch == "T" { inTime = true; continue }
            if ch.isNumber { number.append(ch); continue }
            let n = Int64(number) ?? 0
            number = ""
            switch (ch, inTime) {
            case ("D", false): total += n * 86_400
            case ("H", true): total += n * 3_600
            case ("M", true): total += n * 60
            case ("S", true): total += n
            default: break
            }
        }
        return total > 0 ? total * 1000 : nil
    }

    private func check(_ code: Int, _ json: JSON?) throws {
        if code == 200 { return }
        let reason = json?.list("error.errors").first?.str("reason") ?? json?.str("error.message") ?? "HTTP \(code)"
        if reason == "quotaExceeded" { throw SourceError.setup("YouTube's daily quota for your key is used up") }
        if reason.contains("keyInvalid") || reason.contains("API key") { throw SourceError.setup("YouTube rejected the API key") }
        throw SourceError.network("YouTube: \(reason)")
    }

    func find(_ q: TrackQuery, options: SourceOptions) async throws -> ResolvedAudio? {
        guard let key = apiKey(), !key.isEmpty else { throw SourceError.setup("Add a YouTube Data API key in Settings") }
        var search = URLComponents(string: "https://www.googleapis.com/youtube/v3/search")!
        search.queryItems = [
            URLQueryItem(name: "part", value: "snippet"),
            URLQueryItem(name: "type", value: "video"),
            URLQueryItem(name: "videoCategoryId", value: "10"),
            URLQueryItem(name: "videoEmbeddable", value: "true"),
            URLQueryItem(name: "maxResults", value: "8"),
            URLQueryItem(name: "q", value: "\(q.artist) \(q.title)"),
            URLQueryItem(name: "key", value: key),
        ]
        let (code1, found) = try await getJSON(session, search)
        try check(code1, found)
        let items = found?.list("items") ?? []
        let ids = items.compactMap { $0.str("id.videoId") }
        if ids.isEmpty { return nil }

        var details = URLComponents(string: "https://www.googleapis.com/youtube/v3/videos")!
        details.queryItems = [
            URLQueryItem(name: "part", value: "contentDetails,status"),
            URLQueryItem(name: "id", value: ids.joined(separator: ",")),
            URLQueryItem(name: "key", value: key),
        ]
        let (code2, info) = try await getJSON(session, details)
        try check(code2, info)
        var meta: [String: (duration: Int64?, embeddable: Bool)] = [:]
        for v in info?.list("items") ?? [] {
            guard let id = v.str("id") else { continue }
            let ok = (v.bool("status.embeddable") ?? false) && (v.str("status.privacyStatus") ?? "public") == "public"
            meta[id] = (YouTubeProvider.parseDuration(v.str("contentDetails.duration")), ok)
        }
        struct Hit { var id: String; var title: String; var channel: String; var duration: Int64?; var thumb: String? }
        let hits: [Hit] = items.compactMap { it in
            guard let id = it.str("id.videoId"), let m = meta[id], m.embeddable else { return nil }
            return Hit(id: id, title: it.str("snippet.title") ?? "", channel: it.str("snippet.channelTitle") ?? "",
                       duration: m.duration, thumb: it.str("snippet.thumbnails.high.url") ?? it.str("snippet.thumbnails.default.url"))
        }
        let best = TrackMatcher.best(q, hits, threshold: 0.6) { h in
            let topic = h.channel.hasSuffix(" - Topic")
            var artist = h.channel
            if topic { artist = String(artist.dropLast(" - Topic".count)) }
            artist = artist.replacingOccurrences(of: "VEVO", with: "", options: .caseInsensitive)
            return TrackMatcher.Candidate(title: h.title, artist: artist, durationMs: h.duration, artistMayBeInTitle: true, isTopicChannel: topic)
        }
        guard let hit = best else { return nil }
        return ResolvedAudio(source: .youtube, target: .youtubeVideo(hit.item.id), title: hit.item.title, artist: hit.item.channel,
                             durationMs: hit.item.duration ?? q.durationMs, imageUrl: hit.item.thumb, isPreview: false, score: hit.score)
    }
}

// MARK: - Audius

/// Audius (https://audius.co): artist-uploaded music with a free public API. Tracks an artist put
/// behind a paywall or a follower gate are skipped.
final class AudiusProvider: SourceProvider {
    let id = AudioSourceID.audius
    private let session: URLSession
    private let appName = "OrpheonIOS"
    private let host: String

    init(session: URLSession? = nil, host: String = "https://api.audius.co") {
        self.session = session ?? makeSession()
        self.host = host
    }

    func availability() async -> SourceAvailability { .ready }

    func find(_ q: TrackQuery, options: SourceOptions) async throws -> ResolvedAudio? {
        var comps = URLComponents(string: "\(host)/v1/tracks/search")!
        comps.queryItems = [
            URLQueryItem(name: "query", value: "\(q.artist) \(q.title)"),
            URLQueryItem(name: "limit", value: "12"),
            URLQueryItem(name: "app_name", value: appName),
        ]
        let (code, json) = try await getJSON(session, comps)
        guard code == 200 else { throw SourceError.network("Audius answered \(code)") }
        let open = (json?.list("data") ?? []).filter { t in
            (t.bool("is_streamable") ?? true)
                && (t.bool("access.stream") ?? true)
                && t.at("stream_conditions") == nil
                && !(t.bool("is_delete") ?? false)
                && !(t.bool("is_unlisted") ?? false)
        }
        guard let hit = TrackMatcher.best(q, open, { t in
            TrackMatcher.Candidate(title: t.str("title") ?? "", artist: t.str("user.name") ?? "", durationMs: t.long("duration").map { $0 * 1000 })
        }), let id = hit.item.str("id"), let url = URL(string: "\(host)/v1/tracks/\(id)/stream?app_name=\(appName)") else { return nil }
        let t = hit.item
        return ResolvedAudio(source: .audius, target: .url(url), title: t.str("title") ?? q.title, artist: t.str("user.name") ?? q.artist,
                             durationMs: t.long("duration").map { $0 * 1000 } ?? q.durationMs,
                             imageUrl: t.str("artwork.480x480") ?? t.str("artwork.150x150"), isPreview: false, score: hit.score)
    }
}
