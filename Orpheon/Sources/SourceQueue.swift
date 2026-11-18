// Orpheon for iOS: a port of Orpheon (https://github.com/kota-zo/Orpheon, formerly Myspoti), GPL-3.0.
// Derived from the Kotlin sources by kota-zo and contributors. Keep these notices; if you ever
// distribute this, publish your complete source under GPL-3.0 (see LICENSE and NOTICE.md).
import Foundation

/// The list of Spotify tracks being played from other sources: order, shuffle, repeat. Pure logic.
struct SourceQueue {
    private(set) var tracks: [Track] = []
    /// Play order: indices into `tracks`.
    private(set) var order: [Int] = []
    private(set) var cursor = 0
    private(set) var shuffle = false
    var repeatMode: Repeat = .off
    var contextUri: Uri?

    var isEmpty: Bool { order.isEmpty }

    var current: Track? {
        order.indices.contains(cursor) ? tracks[order[cursor]] : nil
    }

    /// What plays after the current track (the rest of this pass).
    var upcoming: [Track] {
        guard cursor + 1 < order.count else { return [] }
        return order[(cursor + 1)...].map { tracks[$0] }
    }

    var next: Track? {
        cursor + 1 < order.count ? tracks[order[cursor + 1]] : nil
    }

    /// Starts a list at `start`. In shuffle order the chosen track still plays first.
    mutating func load(_ list: [Track], start: Int, shuffle on: Bool, context: Uri? = nil) {
        tracks = list
        contextUri = context
        shuffle = on
        let i = list.isEmpty ? 0 : Swift.max(0, Swift.min(start, list.count - 1))
        if on {
            var rest = Array(list.indices).filter { $0 != i }
            rest.shuffle()
            order = list.isEmpty ? [] : [i] + rest
            cursor = 0
        } else {
            order = Array(list.indices)
            cursor = i
        }
    }

    /// Moves to the next track. `auto` is a track that ended by itself (repeat-one applies); returns nil at the end.
    mutating func advance(auto: Bool) -> Track? {
        guard !order.isEmpty else { return nil }
        if auto && repeatMode == .track { return current }
        if cursor + 1 < order.count {
            cursor += 1
            return current
        }
        if repeatMode == .context {
            if shuffle {
                let last = order[cursor]
                var all = Array(tracks.indices)
                all.shuffle()
                // The track that just played does not play again first.
                if all.count > 1, all.first == last { all.swapAt(0, all.count - 1) }
                order = all
            }
            cursor = 0
            return current
        }
        return nil
    }

    /// Moves to the previous track; at the start it stays (the caller restarts the track).
    mutating func back() -> Track? {
        guard !order.isEmpty else { return nil }
        if cursor > 0 { cursor -= 1 }
        return current
    }

    /// Puts a track right after the current one.
    mutating func insertNext(_ t: Track) {
        tracks.append(t)
        let idx = tracks.count - 1
        if order.isEmpty {
            order = [idx]
            cursor = 0
        } else {
            order.insert(idx, at: cursor + 1)
        }
    }

    /// Turns shuffle on or off without interrupting the current track.
    mutating func setShuffle(_ on: Bool) {
        guard on != shuffle, let cur = order.indices.contains(cursor) ? order[cursor] : nil else { shuffle = on; return }
        shuffle = on
        if on {
            var rest = order[(cursor + 1)...].map { $0 }
            rest.shuffle()
            order = Array(order[...cursor]) + rest
        } else {
            // Back to the list's own order, continuing after the current track.
            order = Array(tracks.indices)
            cursor = cur
        }
    }
}
