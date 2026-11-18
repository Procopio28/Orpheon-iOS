// Orpheon for iOS: a port of Orpheon (https://github.com/kota-zo/Orpheon, formerly Myspoti), GPL-3.0.
// Derived from the Kotlin sources by kota-zo and contributors. Keep these notices; if you ever
// distribute this, publish your complete source under GPL-3.0 (see LICENSE and NOTICE.md).
import Foundation
import AVFoundation
import MediaPlayer
import UIKit

/// Something this app plays itself: a radio stream, a podcast episode's own audio file, a local file.
struct LocalItem: Identifiable, Hashable {
    var id: String
    var title: String
    var subtitle: String?
    var url: URL
    var artworkURL: URL?
    var durationMs: Int64?
    var isLive: Bool = false
    /// The Spotify uri it stands for (podcast episodes), so the UI can open its page.
    var uri: Uri? = nil
    var showName: String? = nil
}

/// Plays `LocalItem`s with AVPlayer, as an iOS audio app does: background audio, lock-screen and
/// headset controls, interruptions. Spotify's own audio never goes through here (it is DRM-protected
/// and plays on a Spotify Connect device; see `ConnectAPI`).
@MainActor
final class LocalPlayer {
    private let player = AVPlayer()
    private(set) var queue: [LocalItem] = []
    private(set) var index = 0
    private(set) var current: LocalItem?
    private(set) var isPlaying = false
    private(set) var isBuffering = false
    private(set) var durationMs: Int64 = 0
    private(set) var failure: String?
    var repeatMode: Repeat = .off
    /// Playback speed (podcasts); 1.0 is normal.
    private(set) var speed: Double = 1.0

    var onUpdate: (() -> Void)?

    /// Set while the source engine owns the queue: next, previous and "ended" go to it instead of this
    /// player's own one-item list. Cleared for radio, podcasts and local files.
    var externalNext: (() -> Void)?
    var externalPrevious: (() -> Void)?
    var onItemEnded: (() -> Void)?

    private var timeObserver: Any?
    private var systemObservers: [NSObjectProtocol] = []
    private var endObserver: NSObjectProtocol?
    private var failObserver: NSObjectProtocol?
    private var artwork: MPMediaItemArtwork?
    private var artworkFor: URL?
    private var sessionReady = false
    private var resumeAfterInterruption = false

    init() {
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        let center = NotificationCenter.default
        systemObservers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
            let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let optRaw = n.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
            Task { @MainActor [weak self] in self?.interruption(typeRaw: raw, optionsRaw: optRaw) }
        })
        systemObservers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] n in
            let raw = n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor [weak self] in
                if let raw = raw, AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable { self?.pause() }
            }
        })
        installRemoteCommands()
    }

    var hasItem: Bool { current != nil }

    var positionMs: Int64 {
        let s = player.currentTime().seconds
        return s.isFinite ? Int64(s * 1000) : 0
    }

    // MARK: Playback

    func play(_ items: [LocalItem], startAt start: Int = 0) {
        guard !items.isEmpty else { return }
        queue = items
        index = Swift.max(0, Swift.min(start, items.count - 1))
        load(queue[index])
    }

    private func prepareSession() {
        guard !sessionReady else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
            sessionReady = true
        } catch {
            failure = "Audio session: \(error.localizedDescription)"
        }
    }

    private func load(_ item: LocalItem) {
        prepareSession()
        failure = nil
        current = item
        durationMs = item.durationMs ?? 0
        let playerItem = AVPlayerItem(url: item.url)
        // Speech at another speed keeps its pitch.
        playerItem.audioTimePitchAlgorithm = .timeDomain
        if let o = endObserver { NotificationCenter.default.removeObserver(o) }
        if let o = failObserver { NotificationCenter.default.removeObserver(o) }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: playerItem, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.itemEnded() }
        }
        failObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: playerItem, queue: .main) { [weak self] n in
            let text = (n.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?.localizedDescription
            Task { @MainActor [weak self] in self?.failed(text ?? "Playback failed") }
        }
        player.replaceCurrentItem(with: playerItem)
        player.play()
        player.rate = Float(speed)
        isPlaying = true
        isBuffering = true
        refreshArtwork(item)
        updateNowPlaying()
        onUpdate?()
    }

    func resume() {
        guard current != nil else { return }
        prepareSession()
        player.play()
        player.rate = Float(speed)
        isPlaying = true
        updateNowPlaying()
        onUpdate?()
    }

    func setSpeed(_ value: Double) {
        speed = value
        if isPlaying { player.rate = Float(value) }
        updateNowPlaying()
        onUpdate?()
    }

    func pause() {
        player.pause()
        isPlaying = false
        updateNowPlaying()
        onUpdate?()
    }

    func toggle() { isPlaying ? pause() : resume() }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        current = nil
        queue = []
        isPlaying = false
        isBuffering = false
        durationMs = 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        onUpdate?()
    }

    func next() {
        if let hook = externalNext { hook(); return }
        if index + 1 < queue.count {
            index += 1
            load(queue[index])
        } else if repeatMode == .context, !queue.isEmpty {
            index = 0
            load(queue[0])
        } else {
            pause()
            seek(toMs: 0)
        }
    }

    func previous() {
        if let hook = externalPrevious { hook(); return }
        if positionMs > 3000 || index == 0 {
            seek(toMs: 0)
        } else {
            index -= 1
            load(queue[index])
        }
    }

    func seek(toMs ms: Int64) {
        let t = CMTime(seconds: Double(Swift.max(0, ms)) / 1000, preferredTimescale: 600)
        player.seek(to: t) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateNowPlaying()
                self?.onUpdate?()
            }
        }
    }

    func skip(bySeconds s: Double) {
        seek(toMs: positionMs + Int64(s * 1000))
    }

    private func itemEnded() {
        if let hook = onItemEnded { hook(); return }
        if repeatMode == .track {
            seek(toMs: 0)
            player.play()
            return
        }
        next()
    }

    private func failed(_ message: String) {
        failure = message
        isPlaying = false
        isBuffering = false
        onUpdate?()
    }

    private func tick() {
        guard current != nil else { return }
        let status = player.timeControlStatus
        let buffering = status == .waitingToPlayAtSpecifiedRate
        let playing = status == .playing || buffering
        if let item = player.currentItem {
            let d = item.duration.seconds
            if d.isFinite, d > 0 { durationMs = Int64(d * 1000) }
            if item.status == .failed, failure == nil {
                failed(item.error?.localizedDescription ?? "Playback failed")
                return
            }
        }
        // A pause the system did (a call, another app) shows as a pause here too.
        let changed = playing != isPlaying || buffering != isBuffering
        isPlaying = playing
        isBuffering = buffering
        if changed { updateNowPlaying() }
        onUpdate?()
    }

    // MARK: System integration

    private func interruption(typeRaw: UInt?, optionsRaw: UInt?) {
        guard let raw = typeRaw, let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        if type == .began {
            resumeAfterInterruption = isPlaying
            isPlaying = false
            onUpdate?()
        } else {
            let opts = AVAudioSession.InterruptionOptions(rawValue: optionsRaw ?? 0)
            if resumeAfterInterruption && opts.contains(.shouldResume) { resume() }
            resumeAfterInterruption = false
        }
    }

    private func installRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.isEnabled = true
        c.pauseCommand.isEnabled = true
        c.togglePlayPauseCommand.isEnabled = true
        c.nextTrackCommand.isEnabled = true
        c.previousTrackCommand.isEnabled = true
        c.changePlaybackPositionCommand.isEnabled = true
        c.skipForwardCommand.preferredIntervals = [30]
        c.skipBackwardCommand.preferredIntervals = [15]
        c.playCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.resume() }
            return .success
        }
        c.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.pause() }
            return .success
        }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.toggle() }
            return .success
        }
        c.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.next() }
            return .success
        }
        c.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.previous() }
            return .success
        }
        c.skipForwardCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.skip(bySeconds: 30) }
            return .success
        }
        c.skipBackwardCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.skip(bySeconds: -15) }
            return .success
        }
        c.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let ms = Int64(e.positionTime * 1000)
            Task { @MainActor [weak self] in self?.seek(toMs: ms) }
            return .success
        }
    }

    private func refreshArtwork(_ item: LocalItem) {
        guard let url = item.artworkURL else { artwork = nil; artworkFor = nil; return }
        if artworkFor == url, artwork != nil { return }
        artwork = nil
        artworkFor = url
        Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: url), let image = UIImage(data: data) else { return }
            let art = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            await MainActor.run { [weak self] in
                guard let self = self, self.artworkFor == url else { return }
                self.artwork = art
                self.updateNowPlaying()
            }
        }
    }

    private func updateNowPlaying() {
        guard let item = current else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: item.title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: Double(positionMs) / 1000,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? speed : 0.0,
            MPNowPlayingInfoPropertyIsLiveStream: item.isLive,
        ]
        if let s = item.subtitle { info[MPMediaItemPropertyArtist] = s }
        if let show = item.showName { info[MPMediaItemPropertyAlbumTitle] = show }
        if durationMs > 0 && !item.isLive { info[MPMediaItemPropertyPlaybackDuration] = Double(durationMs) / 1000 }
        if let a = artwork { info[MPMediaItemPropertyArtwork] = a }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
