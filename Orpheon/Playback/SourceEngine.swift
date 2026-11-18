// Orpheon for iOS: a port of Orpheon (https://github.com/kota-zo/Orpheon, formerly Myspoti), GPL-3.0.
// Derived from the Kotlin sources by kota-zo and contributors. Keep these notices; if you ever
// distribute this, publish your complete source under GPL-3.0 (see LICENSE and NOTICE.md).
import Foundation

/// Plays a list of Spotify tracks from other sources: for each track it finds the same recording on
/// the chosen source(s), then plays it with that source's own player (AVPlayer for plain audio files,
/// Apple's player for Apple Music, YouTube's embedded player for YouTube).
@MainActor
final class SourceEngine {
    enum Backend { case none, local, apple, youtube }

    private(set) var queue = SourceQueue()
    private(set) var resolved: ResolvedAudio?
    private(set) var backend: Backend = .none
    private(set) var isResolving = false
    /// True from the first play until stop: the engine owns playback, not the Spotify app or the radio.
    private(set) var engaged = false

    let local: LocalPlayer
    let apple: AppleMusicPlayer
    let youtube: YouTubePlayer
    let resolver: SourceResolver

    var preference: () -> SourcePreference = { .all }
    var options: () -> SourceOptions = { SourceOptions() }

    var onChange: (() -> Void)?
    var onMessage: ((String) -> Void)?
    var onNeedsVisiblePlayer: (() -> Void)?
    var onResolved: ((Uri, String) -> Void)?

    private var generation = 0
    private var failureStreak = 0
    private var lastReasons: [String] = []
    private var lastFailedTrack: Track?

    init(local: LocalPlayer, apple: AppleMusicPlayer, youtube: YouTubePlayer, resolver: SourceResolver) {
        self.local = local
        self.apple = apple
        self.youtube = youtube
        self.resolver = resolver
        apple.onUpdate = { [weak self] in if self?.backend == .apple { self?.onChange?() } }
        apple.onEnded = { [weak self] in self?.trackEnded() }
        apple.onFailed = { [weak self] m in self?.backendFailed(m) }
        youtube.onUpdate = { [weak self] in if self?.backend == .youtube { self?.onChange?() } }
        youtube.onEnded = { [weak self] in self?.trackEnded() }
        youtube.onFailed = { [weak self] m in self?.backendFailed(m) }
    }

    // MARK: State for the UI

    var currentTrack: Track? { queue.current }

    var isPlaying: Bool {
        switch backend {
        case .local: return local.isPlaying
        case .apple: return apple.isPlaying
        case .youtube: return youtube.isPlaying
        case .none: return false
        }
    }

    var isBuffering: Bool {
        if isResolving { return true }
        switch backend {
        case .local: return local.isBuffering
        case .apple: return apple.isBuffering
        case .youtube: return youtube.isBuffering
        case .none: return false
        }
    }

    var durationMs: Int64 {
        var d: Int64 = 0
        switch backend {
        case .local: d = local.durationMs
        case .apple: d = apple.durationMs
        case .youtube: d = youtube.durationMs
        case .none: d = 0
        }
        if d <= 0 { d = resolved?.durationMs ?? queue.current?.durationMs ?? 0 }
        return d
    }

    var positionMs: Int64 {
        switch backend {
        case .local: return local.positionMs
        case .apple: return apple.positionMs
        case .youtube: return youtube.positionMs
        case .none: return 0
        }
    }

    /// The label shown under the title once the source is known.
    var label: String? { resolved?.label }

    // MARK: Starting

    func start(tracks: [Track], at index: Int, shuffle: Bool, context: Uri?) async {
        engaged = true
        failureStreak = 0
        lastReasons = []
        queue.load(tracks, start: index, shuffle: shuffle, context: context)
        await playCurrent()
    }

    /// Finds and plays the track at the queue's cursor; tracks without a playable match are skipped.
    private func playCurrent() async {
        generation += 1
        let gen = generation
        guard let track = queue.current else {
            stop()
            return
        }
        isResolving = true
        resolved = nil
        // Whatever played before stops now: two sources must never play at once.
        stopBackends(except: .none)
        onChange?()
        let result = await resolver.resolve(track, preference: preference(), options: options())
        guard gen == generation else { return }
        isResolving = false
        switch result {
        case .found(let audio):
            failureStreak = 0
            resolved = audio
            onResolved?(track.uri, audio.label)
            begin(audio, for: track)
            prefetchNext()
        case .notFound(let reasons):
            failureStreak += 1
            lastReasons = reasons
            lastFailedTrack = track
            if failureStreak < 5, queue.advance(auto: false) != nil {
                await playCurrent()
            } else {
                let why = reasons.isEmpty ? "" : " (" + reasons.joined(separator: "; ") + ")"
                onMessage?("Could not play \"\(track.name)\" from \(preference().label)\(why).")
                stop()
            }
        }
    }

    private func begin(_ audio: ResolvedAudio, for track: Track) {
        switch audio.target {
        case .url(let url):
            backend = .local
            hookLocal()
            let item = LocalItem(
                id: "src-" + track.uri, title: track.name, subtitle: track.artistLine, url: url,
                artworkURL: track.album?.images.bestUrl(minPx: 600), durationMs: track.durationMs > 0 ? track.durationMs : audio.durationMs,
                isLive: false, uri: track.uri, showName: track.album?.name)
            local.play([item], startAt: 0)
        case .appleStoreID(let id):
            backend = .apple
            apple.play(storeID: id)
        case .youtubeVideo(let id):
            backend = .youtube
            youtube.play(videoID: id)
            onNeedsVisiblePlayer?()
        }
        onChange?()
    }

    /// The next track is looked up while this one plays, so it starts without a gap.
    private func prefetchNext() {
        guard let next = queue.next else { return }
        let pref = preference()
        let opts = options()
        let resolver = self.resolver
        Task { [weak self] in
            if case .found(let audio) = await resolver.resolve(next, preference: pref, options: opts) {
                self?.onResolved?(next.uri, audio.label)
            }
        }
    }

    // MARK: Local player hooks

    private func hookLocal() {
        local.repeatMode = .off
        local.externalNext = { [weak self] in self?.next() }
        local.externalPrevious = { [weak self] in self?.previous() }
        local.onItemEnded = { [weak self] in self?.trackEnded() }
    }

    private func unhookLocal() {
        local.externalNext = nil
        local.externalPrevious = nil
        local.onItemEnded = nil
    }

    // MARK: Transport

    private func trackEnded() {
        Task { await advance(auto: true) }
    }

    private func backendFailed(_ message: String) {
        // This match did not play (an embedding refused, a subscription lapsed): skip to the next track.
        failureStreak += 1
        if failureStreak < 5, queue.advance(auto: false) != nil {
            Task { await playCurrent() }
        } else {
            onMessage?(message)
            stop()
        }
    }

    private func advance(auto: Bool) async {
        if queue.advance(auto: auto) != nil {
            await playCurrent()
        } else {
            stop()
        }
    }

    func next() {
        Task { await advance(auto: false) }
    }

    func previous() {
        // Past the first seconds, previous restarts the track; at the start it goes back.
        if positionMs > 3000 || queue.cursor == 0 {
            seek(toMs: 0)
            return
        }
        _ = queue.back()
        Task { await playCurrent() }
    }

    func togglePlayPause() {
        switch backend {
        case .local: local.toggle()
        case .apple: apple.isPlaying ? apple.pause() : apple.resume()
        case .youtube: youtube.isPlaying ? youtube.pause() : youtube.resume()
        case .none: break
        }
        onChange?()
    }

    func seek(toMs ms: Int64) {
        switch backend {
        case .local: local.seek(toMs: ms)
        case .apple: apple.seek(toMs: ms)
        case .youtube: youtube.seek(toMs: ms)
        case .none: break
        }
        onChange?()
    }

    func setShuffle(_ on: Bool) {
        queue.setShuffle(on)
        onChange?()
    }

    func cycleRepeat() {
        queue.repeatMode = queue.repeatMode == .off ? .context : (queue.repeatMode == .context ? .track : .off)
        onChange?()
    }

    func insertNext(_ t: Track) {
        queue.insertNext(t)
        onChange?()
    }

    /// The YouTube player is only allowed to play while it is on screen: pause it when the screen closes.
    func pauseYouTubeIfPlaying() {
        if backend == .youtube && youtube.isPlaying { youtube.pause() }
    }

    func stop() {
        generation += 1
        stopBackends(except: .none)
        unhookLocal()
        backend = .none
        isResolving = false
        engaged = false
        resolved = nil
        onChange?()
    }

    private func stopBackends(except keep: Backend) {
        if keep != .local && (backend == .local || local.hasItem && engaged) { local.stop() }
        if keep != .apple { apple.stop() }
        if keep != .youtube { youtube.stop() }
    }
}
