// Orpheon for iOS: a port of Orpheon (https://github.com/kota-zo/Orpheon, formerly Myspoti), GPL-3.0.
// Derived from the Kotlin sources by kota-zo and contributors. Keep these notices; if you ever
// distribute this, publish your complete source under GPL-3.0 (see LICENSE and NOTICE.md).
import Foundation

/// Remote control of a Spotify Connect device (the Spotify app on this phone, a speaker, a computer)
/// over Spotify's Web API, with the Web Player's token.
///
/// This replaces Orpheon's in-app Web Player playback: Spotify's audio is Widevine-encrypted and
/// iOS has no Widevine, so the audio has to be decoded by an official Spotify client. This app
/// shows the catalogue and drives that client.
final class ConnectAPI {
    private let http: SpotifyHTTP
    private let base = "https://api.spotify.com/v1/me/player"

    init(http: SpotifyHTTP) {
        self.http = http
    }

    // MARK: Reading

    func devices() async throws -> [Device] {
        let (status, data, retry) = try await http.sendAPI("GET", "\(base)/devices")
        try Self.check(status, data, retry)
        let json = try JSON.parse(data)
        return json.list("devices").compactMap { d in
            guard let id = d.str("id") else { return nil }
            return Device(id: id, name: d.str("name") ?? "Device", type: d.str("type") ?? "Unknown",
                          active: d.bool("is_active") ?? false, volume: d.double("volume_percent"))
        }
    }

    /// The playback state of the account (nil when no device is active).
    func state() async throws -> (state: PlayerState, device: Device?)? {
        let (status, data, retry) = try await http.sendAPI("GET", "\(base)?additional_types=track,episode&market=from_token")
        if status == 204 { return nil }
        try Self.check(status, data, retry)
        let json = try JSON.parse(data)
        return Self.mapState(json)
    }

    func queue() async throws -> PlayQueue {
        let (status, data, retry) = try await http.sendAPI("GET", "\(base)/queue")
        try Self.check(status, data, retry)
        let json = try JSON.parse(data)
        return PlayQueue(
            current: Self.mapItem(json.at("currently_playing")),
            queued: json.list("queue").compactMap { Self.mapItem($0) },
            nextUp: [])
    }

    // MARK: Commands

    private func command(_ method: String, _ path: String, query: [String: String] = [:], body: JSON? = nil) async throws {
        var comps = URLComponents(string: "\(base)\(path)")!
        if !query.isEmpty { comps.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        let (status, data, retry) = try await http.sendAPI(method, comps.url!.absoluteString, body: body)
        try Self.check(status, data, retry)
    }

    private func deviceQuery(_ deviceId: String?) -> [String: String] {
        deviceId.map { ["device_id": $0] } ?? [:]
    }

    /// Starts something. `contextUri` is an album, playlist or artist; `uris` a list of tracks or episodes.
    func play(contextUri: Uri? = nil, uris: [Uri]? = nil, offsetUri: Uri? = nil, offsetIndex: Int? = nil,
              positionMs: Int64? = nil, deviceId: String? = nil) async throws {
        var body: [String: Any?] = [:]
        if let c = contextUri { body["context_uri"] = c }
        if let u = uris { body["uris"] = u }
        if let o = offsetUri { body["offset"] = ["uri": o] }
        else if let i = offsetIndex { body["offset"] = ["position": i] }
        if let p = positionMs, p > 0 { body["position_ms"] = p }
        try await command("PUT", "/play", query: deviceQuery(deviceId), body: vars(body))
    }

    func resume(deviceId: String? = nil) async throws { try await command("PUT", "/play", query: deviceQuery(deviceId), body: vars()) }
    func pause(deviceId: String? = nil) async throws { try await command("PUT", "/pause", query: deviceQuery(deviceId)) }
    func next(deviceId: String? = nil) async throws { try await command("POST", "/next", query: deviceQuery(deviceId)) }
    func previous(deviceId: String? = nil) async throws { try await command("POST", "/previous", query: deviceQuery(deviceId)) }

    func seek(toMs ms: Int64, deviceId: String? = nil) async throws {
        var q = deviceQuery(deviceId)
        q["position_ms"] = String(Swift.max(0, ms))
        try await command("PUT", "/seek", query: q)
    }

    func setShuffle(_ on: Bool, deviceId: String? = nil) async throws {
        var q = deviceQuery(deviceId)
        q["state"] = on ? "true" : "false"
        try await command("PUT", "/shuffle", query: q)
    }

    func setRepeat(_ mode: Repeat, deviceId: String? = nil) async throws {
        var q = deviceQuery(deviceId)
        q["state"] = mode == .off ? "off" : (mode == .context ? "context" : "track")
        try await command("PUT", "/repeat", query: q)
    }

    func setVolume(percent: Int, deviceId: String? = nil) async throws {
        var q = deviceQuery(deviceId)
        q["volume_percent"] = String(Swift.min(100, Swift.max(0, percent)))
        try await command("PUT", "/volume", query: q)
    }

    func addToQueue(_ uri: Uri, deviceId: String? = nil) async throws {
        var q = deviceQuery(deviceId)
        q["uri"] = uri
        try await command("POST", "/queue", query: q)
    }

    /// Moves playback to another device; `play` keeps it playing there.
    func transfer(to deviceId: String, play: Bool = true) async throws {
        try await command("PUT", "", body: vars(["device_ids": [deviceId], "play": play]))
    }

    // MARK: Mapping

    private static func check(_ status: Int, _ data: Data, _ retry: Double?) throws {
        if (200..<300).contains(status) { return }
        let text = String(data: data.prefix(300), encoding: .utf8) ?? ""
        if status == 403 && text.contains("PREMIUM_REQUIRED") { throw SpotifyError.premiumRequired }
        if status == 404 && (text.contains("NO_ACTIVE_DEVICE") || text.contains("Device not found")) { throw SpotifyError.noDevice }
        if status == 429 { throw SpotifyError.unavailable("Spotify asks to slow down (try again in \(Int(retry ?? 5)) s).") }
        let message = (try? JSON.parse(data))?.str("error.message") ?? text
        throw SpotifyError.http(status, message)
    }

    /// Web API track / episode object -> what the player shows.
    static func mapItem(_ d: JSON?) -> NowPlaying? {
        guard let d = d, let uri = d.str("uri") else { return nil }
        let isEpisode = d.str("type") == "episode" || uri.hasPrefix("spotify:episode:")
        func images(_ node: JSON?) -> [CoverImage] {
            node.list("images").compactMap { i in
                guard let u = i.str("url") else { return nil }
                return CoverImage(url: u, width: i.int("width"), height: i.int("height"))
            }
        }
        if isEpisode {
            let show = d.obj("show")
            let imgs = images(d).isEmpty ? images(show) : images(d)
            return NowPlaying(
                kind: .episode, uri: uri, uid: nil, name: d.str("name") ?? "",
                artists: show.map { [ArtistRef(uri: $0.str("uri") ?? "", name: $0.str("name") ?? "")] } ?? [],
                album: show.map { AlbumRef(uri: $0.str("uri") ?? "", name: $0.str("name") ?? "", images: images($0)) },
                imageUrl: imgs.best(minPx: 600)?.url, durationMs: d.long("duration_ms") ?? 0,
                explicit: d.bool("explicit") ?? false)
        }
        let album = d.obj("album")
        let imgs = images(album)
        return NowPlaying(
            kind: .track, uri: uri, uid: nil, name: d.str("name") ?? "",
            artists: d.list("artists").compactMap { a in
                guard let u = a.str("uri") else { return nil }
                return ArtistRef(uri: u, name: a.str("name") ?? "")
            },
            album: album.map { AlbumRef(uri: $0.str("uri") ?? "", name: $0.str("name") ?? "", images: imgs) },
            imageUrl: imgs.best(minPx: 600)?.url, durationMs: d.long("duration_ms") ?? 0,
            explicit: d.bool("explicit") ?? false)
    }

    static func mapState(_ j: JSON) -> (state: PlayerState, device: Device?) {
        let type = j.str("currently_playing_type") ?? "track"
        // An ad is never shown as the current item (a placeholder keeps the controls honest).
        let item: NowPlaying? = type == "ad" ? nil : mapItem(j.at("item"))
        var restrictions = PlayerRestrictions()
        let dis = j.obj("actions.disallows")
        restrictions.canPause = !(dis.bool("pausing") ?? false)
        restrictions.canResume = !(dis.bool("resuming") ?? false)
        restrictions.canSeek = !(dis.bool("seeking") ?? false)
        restrictions.canSkipNext = !(dis.bool("skipping_next") ?? false)
        restrictions.canSkipPrevious = !(dis.bool("skipping_prev") ?? false)
        let repeatMode: Repeat
        switch j.str("repeat_state") {
        case "context": repeatMode = .context
        case "track": repeatMode = .track
        default: repeatMode = .off
        }
        let state = PlayerState(
            item: item, contextUri: j.str("context.uri"), contextName: nil,
            isPaused: !(j.bool("is_playing") ?? false), isBuffering: false,
            positionMs: j.long("progress_ms") ?? 0, timestampMs: nowMs(), speed: 1.0,
            shuffle: j.bool("shuffle_state") ?? false, repeatMode: repeatMode, restrictions: restrictions)
        var device: Device?
        if let d = j.obj("device"), let id = d.str("id") {
            device = Device(id: id, name: d.str("name") ?? "Device", type: d.str("type") ?? "Unknown",
                            active: d.bool("is_active") ?? false, volume: d.double("volume_percent"))
        }
        return (state, device)
    }
}
