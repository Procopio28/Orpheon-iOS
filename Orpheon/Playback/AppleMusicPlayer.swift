// Orpheon for iOS: a port of Orpheon (https://github.com/kota-zo/Orpheon, formerly Myspoti), GPL-3.0.
// Derived from the Kotlin sources by kota-zo and contributors. Keep these notices; if you ever
// distribute this, publish your complete source under GPL-3.0 (see LICENSE and NOTICE.md).
import Foundation
import MediaPlayer
import StoreKit

/// Plays Apple Music songs with Apple's own player, for a user with an Apple Music subscription.
/// Apple decrypts and plays; this class only queues one song id and watches the player.
@MainActor
final class AppleMusicPlayer {
    private let player = MPMusicPlayerController.applicationMusicPlayer
    private(set) var status: AppleMusicStatus = .unknown

    var onUpdate: (() -> Void)?
    var onEnded: (() -> Void)?
    var onFailed: ((String) -> Void)?

    private(set) var isPlaying = false
    private(set) var isBuffering = false
    private(set) var durationMs: Int64 = 0

    private var poll: Task<Void, Never>?
    private var started = false
    private var finished = true
    private var startedAt = Date()

    var positionMs: Int64 {
        let t = player.currentPlaybackTime
        return t.isFinite && t >= 0 ? Int64(t * 1000) : 0
    }

    // MARK: Permission and subscription

    /// The cached status, looked up once when it is not known yet.
    func currentStatus() async -> AppleMusicStatus {
        if status == .unknown || status == .noSubscription { return await refreshStatus(request: false) }
        return status
    }

    /// Checks the Media & Apple Music permission and the subscription. `request` shows the permission prompt.
    @discardableResult
    func refreshStatus(request: Bool) async -> AppleMusicStatus {
        var auth = SKCloudServiceController.authorizationStatus()
        if auth == .notDetermined && request {
            auth = await SKCloudServiceController.requestAuthorization()
        }
        switch auth {
        case .authorized: break
        case .notDetermined: status = .unknown; return status
        default: status = .denied; return status
        }
        if MPMediaLibrary.authorizationStatus() == .notDetermined && request {
            _ = await MPMediaLibrary.requestAuthorization()
        }
        do {
            let caps = try await SKCloudServiceController().requestCapabilities()
            status = caps.contains(.musicCatalogPlayback) ? .ready : .noSubscription
        } catch {
            status = .unknown
        }
        return status
    }

    // MARK: Playback

    func play(storeID: String) {
        player.stop()
        finished = false
        started = false
        startedAt = Date()
        isBuffering = true
        isPlaying = false
        durationMs = 0
        player.setQueue(with: MPMusicPlayerStoreQueueDescriptor(storeIDs: [storeID]))
        player.play()
        startPolling()
        onUpdate?()
    }

    func resume() {
        player.play()
        isPlaying = true
        onUpdate?()
    }

    func pause() {
        player.pause()
        isPlaying = false
        onUpdate?()
    }

    func seek(toMs ms: Int64) {
        player.currentPlaybackTime = Double(Swift.max(0, ms)) / 1000
        onUpdate?()
    }

    func stop() {
        finished = true
        poll?.cancel()
        poll = nil
        player.stop()
        isPlaying = false
        isBuffering = false
        onUpdate?()
    }

    private func startPolling() {
        poll?.cancel()
        poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                self?.tick()
            }
        }
    }

    private func tick() {
        guard !finished else { return }
        let state = player.playbackState
        let playing = state == .playing
        // The first moments can still report the previous song: a start counts after a short grace.
        let grace = Date().timeIntervalSince(startedAt) > 1.5
        if playing && grace { started = true }
        isPlaying = playing || state == .seekingForward || state == .seekingBackward
        isBuffering = !started
        if let item = player.nowPlayingItem {
            let d = item.playbackDuration
            if d > 0 { durationMs = Int64(d * 1000) }
        }
        if started && grace && (state == .stopped || (durationMs > 0 && positionMs >= durationMs - 400 && !playing)) {
            finished = true
            poll?.cancel()
            isPlaying = false
            onEnded?()
            return
        }
        if !started && Date().timeIntervalSince(startedAt) > 15 {
            finished = true
            poll?.cancel()
            isBuffering = false
            onFailed?("Apple Music could not start this song. Is your subscription active?")
            return
        }
        onUpdate?()
    }
}
