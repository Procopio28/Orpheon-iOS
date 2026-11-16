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
    enum Source { case none, remote, local }

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

    private let service: SpotifyService
    private let connect: ConnectAPI
    private let store: KeyValueStore
    let local = LocalPlayer()

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
        local.onUpdate = { [weak self] in self?.syncLocal() }
    }

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
        guard active, source != .local else { return 4 }
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
        guard let item = local.current else {
            if source == .local { source = .none; now = nil; isPlaying = false }
            return
        }
        source = .local
        isPlaying = local.isPlaying
        isBuffering = local.isBuffering
        durationMs = local.durationMs
        repeatMode = local.repeatMode
        speed = local.speed
        shuffle = false
        contextUri = nil
        restrictions = PlayerRestrictions(canPause: true, canResume: true, canSeek: !item.isLive, canSkipNext: true, canSkipPrevious: true)
        device = nil
        let n = NowPlaying(
            kind: .local, uri: item.uri ?? "orpheon:local:\(item.id)", uid: nil, name: item.title,
            artists: item.subtitle.map { [ArtistRef(uri: "", name: $0)] } ?? [],
            album: item.showName.map { AlbumRef(uri: "", name: $0) },
            imageUrl: item.artworkURL?.absoluteString, durationMs: local.durationMs, explicit: false, provider: item.isLive ? "Live radio" : nil)
        if now != n { now = n }
        if let f = local.failure { message = f }
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
            if source != .local, let r = try? await connect.state() { apply(r.state, device: r.device) }
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
        if local.hasItem { local.stop() }
        if source == .local { source = .remote }
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
        await startRemote(fallback: trackUri ?? uri) { [connect] dev in
            try await connect.play(contextUri: uri, offsetUri: trackUri, offsetIndex: trackUri == nil ? index : nil, deviceId: dev)
        }
    }

    /// Plays an album, playlist or artist in shuffle order.
    func playShuffled(context: Uri) async {
        await play(context: context)
        setShuffle(true)
    }

    /// Plays a list of tracks or episodes (a search result, Liked Songs) from `startIndex`.
    func play(uris: [Uri], startIndex: Int = 0) async {
        guard !uris.isEmpty else { return }
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
        isPlaying = false
        local.play(items, startAt: startAt)
        syncLocal()
    }

    func togglePlayPause() {
        switch source {
        case .local:
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
        switch source {
        case .local: local.next()
        default: Task { [self] in await run { [connect, device] in try await connect.next(deviceId: device?.id) } }
        }
    }

    func previous() {
        switch source {
        case .local: local.previous()
        default: Task { [self] in await run { [connect, device] in try await connect.previous(deviceId: device?.id) } }
        }
    }

    func seek(toMs ms: Int64) {
        switch source {
        case .local:
            local.seek(toMs: ms)
        default:
            baseMs = ms
            baseStamp = nowMs()
            Task { [self] in await run { [connect, device] in try await connect.seek(toMs: ms, deviceId: device?.id) } }
        }
    }

    func setShuffle(_ on: Bool) {
        guard source == .remote else { return }
        shuffle = on
        Task { [self] in await run { [connect, device] in try await connect.setShuffle(on, deviceId: device?.id) } }
    }

    func cycleRepeat() {
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
        Task { [self] in
            guard let t = await targetDevice() else { needsDevice = true; return }
            await run { [connect] in try await connect.addToQueue(uri, deviceId: t.id) }
        }
    }

    func loadQueue() async {
        queue = try? await connect.queue()
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
