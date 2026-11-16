// Orpheon for iOS: a port of Orpheon (https://github.com/kota-zo/Orpheon, formerly Myspoti), GPL-3.0.
// Derived from the Kotlin sources by kota-zo and contributors. Keep these notices; if you ever
// distribute this, publish your complete source under GPL-3.0 (see LICENSE and NOTICE.md).
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Lyrics for what is playing: Spotify's own (line or word synced, as the Web Player shows them),
/// then LRCLIB (https://lrclib.net, free, no key) when Spotify has none.
final class LyricsService {
    private let spotify: SpotifyService
    private let session: URLSession
    private var cache: [String: Lyrics] = [:]
    private var misses: Set<String> = []
    private let lock = NSLock()

    init(spotify: SpotifyService) {
        self.spotify = spotify
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 15
        self.session = URLSession(configuration: cfg)
    }

    private func cached(_ key: String) -> (hit: Lyrics?, miss: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (cache[key], misses.contains(key))
    }

    private func remember(_ key: String, _ l: Lyrics?) {
        lock.lock(); defer { lock.unlock() }
        if let l = l { cache[key] = l } else { misses.insert(key) }
    }

    func lyrics(for item: NowPlaying) async -> Lyrics? {
        let key = item.uri
        let c = cached(key)
        if let hit = c.hit { return hit }
        if c.miss { return nil }
        var found: Lyrics?
        if item.uri.hasPrefix("spotify:track:") {
            found = try? await spotify.spotifyLyrics(trackUri: item.uri)
            if let f = found, f.lines.isEmpty { found = nil }
        }
        if found == nil, item.kind != .local {
            found = await lrclib(title: item.name, artist: item.artists.first?.name ?? "", album: item.album?.name, durationMs: item.durationMs)
        }
        remember(key, found)
        return found
    }

    // MARK: LRCLIB

    private func get(_ url: URL) async -> JSON? {
        var req = URLRequest(url: url)
        req.setValue("Orpheon-iOS/1.0 (https://github.com/kota-zo/Orpheon)", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await session.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSON.parse(data)
    }

    func lrclib(title: String, artist: String, album: String?, durationMs: Int64) async -> Lyrics? {
        guard !title.isEmpty else { return nil }
        var comps = URLComponents(string: "https://lrclib.net/api/get")!
        var q = [URLQueryItem(name: "track_name", value: title), URLQueryItem(name: "artist_name", value: artist)]
        if let a = album, !a.isEmpty { q.append(URLQueryItem(name: "album_name", value: a)) }
        if durationMs > 0 { q.append(URLQueryItem(name: "duration", value: String(durationMs / 1000))) }
        comps.queryItems = q
        if let url = comps.url, let j = await get(url), let l = Self.fromLrclib(j) { return l }
        // The exact lookup missed: search, and take the closest length.
        var s = URLComponents(string: "https://lrclib.net/api/search")!
        s.queryItems = [URLQueryItem(name: "track_name", value: title), URLQueryItem(name: "artist_name", value: artist)]
        guard let url = s.url, let list = await get(url) else { return nil }
        let candidates = list.items.filter { ($0.str("syncedLyrics") ?? $0.str("plainLyrics")) != nil }
        let target = Double(durationMs) / 1000
        let best = candidates.min { a, b in
            abs((a.double("duration") ?? 0) - target) < abs((b.double("duration") ?? 0) - target)
        }
        if let b = best, durationMs <= 0 || abs((b.double("duration") ?? 0) - target) <= 5 { return Self.fromLrclib(b) }
        return nil
    }

    static func fromLrclib(_ j: JSON) -> Lyrics? {
        if j.bool("instrumental") == true { return nil }
        if let synced = j.str("syncedLyrics"), !synced.isEmpty {
            let lines = parseLrc(synced)
            if !lines.isEmpty { return Lyrics(lines: lines, synced: true, language: nil, provider: "LRCLIB", background: nil, text: nil, highlight: nil) }
        }
        if let plain = j.str("plainLyrics"), !plain.isEmpty {
            let lines = plain.split(separator: "\n", omittingEmptySubsequences: false).enumerated().map { i, t in
                LyricsLine(startMs: Int64(i), endMs: nil, text: String(t))
            }
            return Lyrics(lines: lines, synced: false, language: nil, provider: "LRCLIB", background: nil, text: nil, highlight: nil)
        }
        return nil
    }

    /// `[mm:ss.xx] text`, possibly with several time tags per line.
    static func parseLrc(_ text: String) -> [LyricsLine] {
        guard let tag = try? NSRegularExpression(pattern: "\\[(\\d{1,3}):(\\d{2})(?:[.:](\\d{1,3}))?\\]") else { return [] }
        var out: [LyricsLine] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(raw)
            let ns = line as NSString
            let matches = tag.matches(in: line, range: NSRange(location: 0, length: ns.length))
            guard let last = matches.last else { continue }
            let body = ns.substring(from: last.range.location + last.range.length).trimmingCharacters(in: .whitespaces)
            for m in matches {
                let min = Int64(ns.substring(with: m.range(at: 1))) ?? 0
                let sec = Int64(ns.substring(with: m.range(at: 2))) ?? 0
                var frac: Int64 = 0
                if m.range(at: 3).location != NSNotFound {
                    let f = ns.substring(with: m.range(at: 3))
                    let padded = (f + "00").prefix(3)
                    frac = Int64(padded) ?? 0
                }
                out.append(LyricsLine(startMs: (min * 60 + sec) * 1000 + frac, endMs: nil, text: body))
            }
        }
        out.sort { $0.startMs < $1.startMs }
        for i in 0..<out.count where i + 1 < out.count { out[i].endMs = out[i + 1].startMs }
        return out
    }
}
