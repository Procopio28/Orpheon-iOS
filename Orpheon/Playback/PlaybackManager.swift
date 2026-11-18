// Orpheon for iOS: a port of Orpheon (https://github.com/kota-zo/Orpheon, formerly Myspoti), GPL-3.0.
// Derived from the Kotlin sources by kota-zo and contributors. Keep these notices; if you ever
// distribute this, publish your complete source under GPL-3.0 (see LICENSE and NOTICE.md).
import Foundation
import UIKit
import Combine

/// The single place the UI asks to play something and reads what is playing.
///
/// Spotify's own audio plays on a Spotify Connect device (the official Spotify app on this phone, a
/// speaker, a computer): this manager sends it the commands and mirrors its state. Things the app
/// can decode itself (radio, a podcast episode's own file) play locally with `LocalPlayer`.
@MainActor
final class PlaybackManager: ObservableObject {
    enum Source { case none, remote, local, appleMusic, youtube }

    @Published private(set) var source: Source = .none
    @Published private(set) var now: NowPlaying?
    @Published private(set) var isPlaying = false
    @Published private(set) var isBuffering = false
    @Published private(set) var durationMs: Int64 = 0
    @Published private(set) var shuffle = false
    @Published private(set) var repeatMode: Repeat = .off
    @Published private(set) var contextUri: Uri?
    @Published private(set) var restrictions = PlayerRestrictions()
    @Published private(set) var device: Device?
    @Published private(set) var devices: [Device] = []
    @Published private(set) var liked = false
    /// Speed of what plays in this app (podcast files); Spotify devices keep their own.
    @Published private(set) var speed: Double = 1.0
    @Published private(set) var queue: PlayQueue?
    /// Shown as an alert by the root view.
    @Published var message: String?
    /// True when a command found no Spotify device to run on.
    @Published var needsDevice = false

    /// Where Spotify tracks get their audio from (the "Playback source" setting).
    @Published var sourcePreference: SourcePreference {
        didSet { store.set("sourcePreference", sourcePreference.rawValue) }
    }
    /// Shows the source ("Apple Music", "YouTube"...) in small type under the title.
    @Published var showSourceLabel: Bool {
        didSet { store.setBool("showSourceLabel", showSourceLabel); if engine.engaged { syncEngine() } }
    }
    /// Accepts 30-second previews when the full song is not available without a subscription.
    @Published var allowPreviews: Bool {
        didSet { store.setBool("allowPreviews", allowPreviews) }
    }
    /// The source each Spotify track was matched to in this session, for the small labels in lists.
    @Published private(set) var resolvedLabels: [Uri: String] = [:]
    /// Called when the YouTube player must be on screen to play (YouTube's rules for its embedded player).
    var requestPlayerScreen: (() -> Void)?

    private let service: SpotifyService
    private let connect: ConnectAPI
    private let store: KeyValueStore
    let local = LocalPlayer()
    let engine: SourceEngine

    private var baseMs: Int64 = 0
    private var baseStamp: Int64 = 0
    private var pollTask: Task<Void, Never>?
    private var active = true
    private var failures = 0
    private var likedFor: Uri?
    private var pending: (() async -> Void)?
    /// After a command, polls answer from before it for a moment: ignore them until then.
    private var holdUntilMs: Int64 = 0

    init(service: SpotifyService, connect: ConnectAPI, store: KeyValueStore) {
        self.service = service
        self.connect = connect
        self.store = store
        self.sourcePreference = SourcePreference(rawValue: store.get("sourcePreference") ?? "") ?? .all
        self.showSourceLabel = store.bool("showSourceLabel", default: true)
        self.allowPreviews = store.bool("allowPreviews", default: false)

        let apple = AppleMusicPlayer()
        let youtube = YouTubePlayer()
        let providers: [SourceProvider] = [
            AppleMusicProvider(status: { await apple.currentStatus() }),
            AudiusProvider(),
            YouTubeProvider(apiKey: { store.get("youtubeApiKey") }),
        ]
        self.engine = SourceEngine(local: local, apple: apple, youtube: youtube, resolver: SourceResolver(providers: providers))

        local.onUpdate = { [weak self] in self?.syncLocal() }
        engine.preference = { [weak self] in self?.sourcePreference ?? .all }
        engine.options = { [weak self] in SourceOptions(allowPreviews: self?.allowPreviews ?? false) }
        engine.onChange = { [weak self] in self?.syncEngine() }
        engine.onMessage = { [weak self] m in self?.message = m }
        engine.onNeedsVisiblePlayer = { [weak self] in self?.requestPlayerScreen?() }
        engine.onResolved = { [weak self] uri, label in self?.resolvedLabels[uri] = label }
    }

    /// True when Spotify tracks play from other sources instead of the Spotify app.
    var usesSources: Bool { sourcePreference.usesSources }
    /// Shuffle and repeat work for the Spotify app and for the source engine.
    var canShuffle: Bool { source == .remote || engine.engaged }
    var supportsQueue: Bool { source == .remote || engine.engaged }
    /// Moving playback to another device is a Spotify Connect thing.
    var canChangeDevice: Bool { source == .remote }

    // MARK: Lifecycle

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self = self else { return }
                let wait = await self.pollOnce()
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    func setActive(_ on: Bool) {
        active = on
        if on { Task { _ = await pollOnce() } }
    }

    /// Reads the account's playback state; returns the seconds to wait before the next read.
    private func pollOnce() async -> Double {
        guard active, !engine.engaged, source == .none || source == .remote else { return 4 }
        if nowMs() < holdUntilMs { return 1 }
        do {
            let result = try await connect.state()
            failures = 0
            if let r = result { apply(r.state, device: r.device) } else { applyNothing() }
            return isPlaying ? 3 : 6
        } catch let e as SpotifyError {
            failures += 1
            if case .notSignedIn = e { return 10 }
            return Double(Swift.min(30, 4 * (failures + 1)))
        } catch {
            failures += 1
            return Double(Swift.min(30, 4 * (failures + 1)))
        }
    }

    // MARK: Remote state

    private func apply(_ s: PlayerState, device d: Device?) {
        source = .remote
        now = s.item
        isPlaying = !s.isPaused && s.item != nil
        durationMs = s.item?.durationMs ?? 0
        shuffle = s.shuffle
        repeatMode = s.repeatMode
        contextUri = s.contextUri
        restrictions = s.restrictions
        device = d
        baseMs = s.positionMs
        baseStamp = s.timestampMs
        if let d = d { store.set("lastDeviceId", d.id) }
        refreshLikedIfNeeded()
    }

    private func applyNothing() {
        if source == .remote {
            isPlaying = false
            device = nil
        }
    }

    /// The position to show now (interpolated between polls).
    func positionMs(at date: Date = Date()) -> Int64 {
        switch source {
        case .local:
            return local.positionMs
        case .appleMusic:
            return engine.apple.positionMs
        case .youtube:
            return engine.youtube.positionMs
        case .remote:
            guard isPlaying else { return baseMs }
            let t = Int64(date.timeIntervalSince1970 * 1000)
            return Swift.min(Swift.max(baseMs + (t - baseStamp), 0), durationMs > 0 ? durationMs : Int64.max)
        case .none:
            return 0
        }
    }

    // MARK: Local state

    private func syncLocal() {
        if engine.engaged { syncEngine(); return }
        guard let item = local.current else {
            if source == .local { source = .none; now = nil; isPlaying = false }
            return
        }
        update(\.source, .local)
        update(\.isPlaying, local.isPlaying)
        update(\.isBuffering, local.isBuffering)
        update(\.durationMs, local.durationMs)
        update(\.repeatMode, local.repeatMode)
        update(\.speed, local.speed)
        update(\.shuffle, false)
        update(\.contextUri, nil)
        update(\.restrictions, PlayerRestrictions(canPause: true, canResume: true, canSeek: !item.isLive, canSkipNext: true, canSkipPrevious: true))
        update(\.device, nil)
        let n = NowPlaying(
            kind: .local, uri: item.uri ?? "orpheon:local:\(item.id)", uid: nil, name: item.title,
            artists: item.subtitle.map { [ArtistRef(uri: "", name: $0)] } ?? [],
            album: item.showName.map { AlbumRef(uri: "", name: $0) },
            imageUrl: item.artworkURL?.absoluteString, durationMs: local.durationMs, explicit: false, provider: item.isLive ? "Live radio" : nil)
        if now != n { now = n }
        if let f = local.failure { message = f }
    }

    /// Assigns a published property only when it changed: the players report twice a second, and every
    /// assignment would redraw the screens that watch this object.
    private func update<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<PlaybackManager, T>, _ value: T) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }

    // MARK: Source engine state

    private func nowPlaying(_ t: Track, label: String?) -> NowPlaying {
        NowPlaying(
            kind: .track, uri: t.uri, uid: nil, name: t.name, artists: t.artists, album: t.album,
            imageUrl: t.album?.images.bestUrl(minPx: 600)?.absoluteString, durationMs: t.durationMs,
            explicit: t.explicit, provider: label)
    }

    /// Mirrors the source engine: the Spotify track is what the UI shows, whatever source plays it.
    private func syncEngine() {
        guard engine.engaged, let track = engine.currentTrack else {
            if source == .local || source == .appleMusic || source == .youtube {
                source = .none
                now = nil
                isPlaying = false
                isBuffering = false
            }
            return
        }
        switch engine.backend {
        case .apple: update(\.source, .appleMusic)
        case .youtube: update(\.source, .youtube)
        default: update(\.source, .local)
        }
        var n = nowPlaying(track, label: showSourceLabel ? engine.label : nil)
        n.durationMs = engine.durationMs
        if now != n { now = n }
        update(\.isPlaying, engine.isPlaying)
        update(\.isBuffering, engine.isBuffering)
        update(\.durationMs, engine.durationMs)
        update(\.shuffle, engine.queue.shuffle)
        update(\.repeatMode, engine.queue.repeatMode)
        update(\.speed, 1.0)
        update(\.contextUri, engine.queue.contextUri)
        update(\.restrictions, PlayerRestrictions(canPause: true, canResume: true, canSeek: engine.backend != .none, canSkipNext: true, canSkipPrevious: true))
        update(\.device, nil)
        refreshLikedIfNeeded()
    }

    /// The YouTube player may play only while it is on screen: closing the player screen pauses it.
    func playerScreenClosed() {
        engine.pauseYouTubeIfPlaying()
    }

    // MARK: Devices

    func refreshDevices() async {
        do {
            devices = try await connect.devices()
        } catch {
            devices = []
        }
    }

    /// Picks where to run a command: the active device, the last one used, a phone, the first.
    private func targetDevice() async -> Device? {
        if let d = device, d.active { return d }
        await refreshDevices()
        if let a = devices.first(where: { $0.active }) { return a }
        if let last = store.get("lastDeviceId"), let d = devices.first(where: { $0.id == last }) { return d }
        let phoneName = UIDevice.current.name
        if let d = devices.first(where: { $0.type.lowercased() == "smartphone" && $0.name == phoneName }) { return d }
        if let d = devices.first(where: { $0.type.lowercased() == "smartphone" }) { return d }
        return devices.first
    }

    func transfer(to d: Device) async {
        await run { [self] in
            try await connect.transfer(to: d.id, play: isPlaying)
            store.set("lastDeviceId", d.id)
            await refreshDevices()
        }
    }

    // MARK: Commands (remote)

    /// Runs a remote command and reflects its outcome: the state is read again shortly after.
    /// A Free account cannot be remote-controlled: when `fallback` is given, it opens in the Spotify app instead.
    private func run(fallback: Uri? = nil, _ block: @escaping () async throws -> Void) async {
        do {
            try await block()
            holdUntilMs = nowMs() + 600
            try? await Task.sleep(nanoseconds: 700_000_000)
            holdUntilMs = 0
            if !engine.engaged, source == .none || source == .remote, let r = try? await connect.state() { apply(r.state, device: r.device) }
        } catch SpotifyError.noDevice {
            needsDevice = true
            pending = { [weak self] in await self?.run(fallback: fallback, block) }
        } catch SpotifyError.premiumRequired {
            if let u = fallback {
                message = "Spotify only lets Premium accounts be controlled from another app, so this opens in the Spotify app."
                SpotifyLinks.open(u)
            } else {
                message = SpotifyError.premiumRequired.errorDescription
            }
        } catch {
            message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Stops what this app plays itself before a Spotify device takes over.
    private func leaveLocal() {
        if engine.engaged { engine.stop() }
        if local.hasItem { local.stop() }
        if source == .local || source == .appleMusic || source == .youtube { source = .remote }
    }

    private func startRemote(fallback: Uri? = nil, _ build: @escaping (String?) async throws -> Void) async {
        leaveLocal()
        let target = await targetDevice()
        await run(fallback: fallback) { [self] in
            guard let t = target else { throw SpotifyError.noDevice }
            try await build(t.id)
            store.set("lastDeviceId", t.id)
        }
    }

    /// Plays an album, playlist or artist, from a given track when `trackUri` is set.
    func play(context: Uri, trackUri: Uri? = nil, index: Int? = nil) async {
        let uri = canonicalUri(context)
        if usesSources {
            await playContextFromSources(uri, trackUri: trackUri, shuffled: false)
            return
        }
        await startRemote(fallback: trackUri ?? uri) { [connect] dev in
            try await connect.play(contextUri: uri, offsetUri: trackUri, offsetIndex: trackUri == nil ? index : nil, deviceId: dev)
        }
    }

    /// Plays an album, playlist or artist in shuffle order.
    func playShuffled(context: Uri) async {
        if usesSources {
            await playContextFromSources(canonicalUri(context), trackUri: nil, shuffled: true)
            return
        }
        await play(context: context)
        setShuffle(true)
    }

    /// Plays tracks the UI already has (search results, Liked Songs, an artist's top tracks).
    func play(tracks: [Track], startIndex: Int = 0, shuffled: Bool = false) async {
        guard !tracks.isEmpty else { return }
        if usesSources {
            await startEngine(tracks, startIndex: startIndex, shuffled: shuffled, context: nil)
        } else {
            await play(uris: tracks.map { $0.uri }, startIndex: startIndex)
        }
    }

    /// Plays a list of tracks or episodes (a search result, Liked Songs) from `startIndex`.
    func play(uris: [Uri], startIndex: Int = 0) async {
        guard !uris.isEmpty else { return }
        if usesSources && uris.allSatisfy({ $0.hasPrefix("spotify:track:") }) {
            let tracks = await fetchTracks(uris, from: startIndex)
            await startEngine(tracks, startIndex: 0, shuffled: false, context: nil)
            return
        }
        // Spotify takes at most 100 uris; the window starts at the chosen one.
        let from = Swift.max(0, Swift.min(startIndex, uris.count - 1))
        let window = Array(uris[from..<Swift.min(from + 100, uris.count)])
        await startRemote(fallback: window.first) { [connect] dev in
            try await connect.play(uris: window, deviceId: dev)
        }
    }

    func play(track: Track, in context: Uri? = nil) async {
        if let c = context { await play(context: c, trackUri: track.uri) }
        else { await play(uris: [track.uri]) }
    }

    /// Spotify's own copy plays on a Connect device; the publisher's clear file, when there is one, plays here.
    func play(episode e: Episode, from episodes: [Episode] = []) async {
        if let audio = try? await service.episodeAudio(e.uri), let url = audio.url.flatMap({ URL(string: $0) }) {
            var items = [localItem(e, url: url)]
            // Following episodes of the same list play on after it when their file resolves.
            if let i = episodes.firstIndex(where: { $0.uri == e.uri }) {
                for next in episodes.dropFirst(i + 1).prefix(5) {
                    if let a = try? await service.episodeAudio(next.uri), let u = a.url.flatMap({ URL(string: $0) }) {
                        items.append(localItem(next, url: u))
                    } else { break }
                }
            }
            playLocal(items, startAt: 0)
            return
        }
        await play(uris: [e.uri])
    }

    private func localItem(_ e: Episode, url: URL) -> LocalItem {
        let art = (e.images.isEmpty ? (e.show?.images ?? []) : e.images).bestUrl(minPx: 600)
        return LocalItem(id: e.uri, title: e.name, subtitle: e.show?.name, url: url, artworkURL: art,
                         durationMs: e.durationMs, isLive: false, uri: e.uri, showName: e.show?.name)
    }

    func playLocal(_ items: [LocalItem], startAt: Int = 0) {
        // Pause the Spotify device first: two sources must not talk at once.
        if source == .remote && isPlaying {
            Task { [connect] in try? await connect.pause(deviceId: nil) }
        }
        if engine.engaged { engine.stop() }
        isPlaying = false
        local.play(items, startAt: startAt)
        syncLocal()
    }

    func togglePlayPause() {
        if engine.engaged { engine.togglePlayPause(); return }
        switch source {
        case .local, .appleMusic, .youtube:
            local.toggle()
        case .remote:
            let wasPlaying = isPlaying
            isPlaying.toggle()
            baseMs = positionMs()
            baseStamp = nowMs()
            Task { [self] in
                await run { [connect, device] in
                    if wasPlaying { try await connect.pause(deviceId: device?.id) }
                    else { try await connect.resume(deviceId: device?.id) }
                }
            }
        case .none:
            Task { [self] in
                await startRemote { [connect] dev in try await connect.resume(deviceId: dev) }
            }
        }
    }

    func next() {
        if engine.engaged { engine.next(); return }
        switch source {
        case .local, .appleMusic, .youtube: local.next()
        default: Task { [self] in await run { [connect, device] in try await connect.next(deviceId: device?.id) } }
        }
    }

    func previous() {
        if engine.engaged { engine.previous(); return }
        switch source {
        case .local, .appleMusic, .youtube: local.previous()
        default: Task { [self] in await run { [connect, device] in try await connect.previous(deviceId: device?.id) } }
        }
    }

    func seek(toMs ms: Int64) {
        if engine.engaged { engine.seek(toMs: ms); return }
        switch source {
        case .local, .appleMusic, .youtube:
            local.seek(toMs: ms)
        default:
            baseMs = ms
            baseStamp = nowMs()
            Task { [self] in await run { [connect, device] in try await connect.seek(toMs: ms, deviceId: device?.id) } }
        }
    }

    func setShuffle(_ on: Bool) {
        if engine.engaged { engine.setShuffle(on); return }
        guard source == .remote else { return }
        shuffle = on
        Task { [self] in await run { [connect, device] in try await connect.setShuffle(on, deviceId: device?.id) } }
    }

    func cycleRepeat() {
        if engine.engaged { engine.cycleRepeat(); return }
        let nextMode: Repeat = repeatMode == .off ? .context : (repeatMode == .context ? .track : .off)
        repeatMode = nextMode
        if source == .local { local.repeatMode = nextMode; return }
        Task { [self] in await run { [connect, device] in try await connect.setRepeat(nextMode, deviceId: device?.id) } }
    }

    /// Cycles 1x, 1.25x, 1.5x, 2x for what this app plays itself.
    func cycleSpeed() {
        guard source == .local else { return }
        let steps: [Double] = [1.0, 1.25, 1.5, 2.0]
        let i = steps.firstIndex(where: { abs($0 - speed) < 0.01 }) ?? 0
        local.setSpeed(steps[(i + 1) % steps.count])
    }

    func setVolume(percent: Int) {
        guard source == .remote else { return }
        Task { [self] in
            do { try await connect.setVolume(percent: percent, deviceId: device?.id) }
            catch { message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
        }
    }

    func addToQueue(_ uri: Uri) {
        if engine.engaged {
            Task { [self] in
                if let t = try? await service.track(uri) { engine.insertNext(t) }
            }
            return
        }
        Task { [self] in
            guard let t = await targetDevice() else { needsDevice = true; return }
            await run { [connect] in try await connect.addToQueue(uri, deviceId: t.id) }
        }
    }

    func loadQueue() async {
        if engine.engaged {
            queue = PlayQueue(
                current: engine.currentTrack.map { nowPlaying($0, label: engine.label) },
                queued: engine.queue.upcoming.prefix(50).map { nowPlaying($0, label: resolvedLabels[$0.uri]) },
                nextUp: [])
            return
        }
        queue = try? await connect.queue()
    }

    // MARK: Playing Spotify tracks from other sources

    private func startEngine(_ tracks: [Track], startIndex: Int, shuffled: Bool, context: Uri?) async {
        guard !tracks.isEmpty else {
            message = "There is nothing playable here."
            return
        }
        // The Spotify device stops first: two sources must not talk at once.
        if source == .remote && isPlaying {
            Task { [connect] in try? await connect.pause(deviceId: nil) }
        }
        if local.hasItem && !engine.engaged { local.stop() }
        isPlaying = false
        await engine.start(tracks: tracks, at: startIndex, shuffle: shuffled, context: context)
    }

    /// The tracks of an album, playlist or artist, played from the chosen sources.
    private func playContextFromSources(_ uri: Uri, trackUri: Uri?, shuffled: Bool) async {
        var tracks: [Track] = []
        do {
            switch MediaKind.of(uri) {
            case .album:
                var offset: Int? = 0
                while let o = offset, tracks.count < 500 {
                    let page = try await service.albumTracks(uri, offset: o, limit: 50)
                    tracks += page.items
                    offset = page.nextOffset
                }
            case .playlist:
                tracks = try await service.allPlaylistTracks(uri, maxRows: 500).filter { $0.uri.hasPrefix("spotify:track:") }
            case .artist:
                tracks = try await service.artistPage(uri).topTracks.map { $0.track }
            default:
                message = "This can only be played from the Spotify app."
                return
            }
        } catch {
            message = describe(error)
            return
        }
        let start = trackUri.flatMap { u in tracks.firstIndex(where: { $0.uri == u }) } ?? 0
        await startEngine(tracks, startIndex: start, shuffled: shuffled, context: uri)
    }

    /// Track details for a list of uris (when the caller has only uris): the first few, from `start`.
    private func fetchTracks(_ uris: [Uri], from start: Int) async -> [Track] {
        let from = Swift.max(0, Swift.min(start, uris.count - 1))
        let window = Array(uris[from..<Swift.min(from + 20, uris.count)])
        var out: [Track?] = Array(repeating: nil, count: window.count)
        await withTaskGroup(of: (Int, Track?).self) { group in
            for (i, u) in window.enumerated() {
                group.addTask { [service] in (i, try? await service.track(u)) }
            }
            for await (i, t) in group { out[i] = t }
        }
        return out.compactMap { $0 }
    }

    /// Runs again what failed for lack of a device, once the user has opened Spotify.
    func retryPending() async {
        needsDevice = false
        await refreshDevices()
        if let p = pending {
            pending = nil
            await p()
        }
    }

    func dismissNeedsDevice() {
        needsDevice = false
        pending = nil
    }

    // MARK: Liking

    private func refreshLikedIfNeeded() {
        guard let uri = now?.uri, now?.kind == .track || now?.kind == .episode, likedFor != uri else { return }
        likedFor = uri
        Task { [self] in
            if let flags = try? await service.contains([uri]), likedFor == uri { liked = flags.first ?? false }
        }
    }

    func toggleLiked() {
        guard let uri = now?.uri, now?.kind == .track || now?.kind == .episode else { return }
        let target = !liked
        liked = target
        Task { [self] in
            do {
                if target { try await service.addToLibrary([uri]) } else { try await service.removeFromLibrary([uri]) }
            } catch {
                liked = !target
                message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}

/// Opens the Spotify app on a uri: the way to play for a Free account, and a way to wake the app up.
@MainActor
enum SpotifyLinks {
    static func open(_ uri: Uri? = nil) {
        let target = uri.map { URL(string: $0) } ?? URL(string: "spotify:")
        guard let url = target ?? URL(string: "spotify:") else { return }
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }
}
