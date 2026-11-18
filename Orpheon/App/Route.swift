// Orpheon for iOS: a port of Orpheon (https://github.com/kota-zo/Orpheon, formerly Myspoti), GPL-3.0.
// Derived from the Kotlin sources by kota-zo and contributors. Keep these notices; if you ever
// distribute this, publish your complete source under GPL-3.0 (see LICENSE and NOTICE.md).
import Foundation

/// A screen the app can open from a uri.
enum Route: Hashable, Identifiable {
    case album(Uri)
    case artist(Uri)
    case playlist(Uri)
    case show(Uri)
    case episode(Uri)
    case audiobook(Uri)
    case user(Uri)
    case category(Uri)
    case likedSongs
    case folder(Uri, String)

    var id: String {
        switch self {
        case .album(let u): return "album:" + u
        case .artist(let u): return "artist:" + u
        case .playlist(let u): return "playlist:" + u
        case .show(let u): return "show:" + u
        case .episode(let u): return "episode:" + u
        case .audiobook(let u): return "audiobook:" + u
        case .user(let u): return "user:" + u
        case .category(let u): return "category:" + u
        case .likedSongs: return "liked"
        case .folder(let u, _): return "folder:" + u
        }
    }

    /// The screen for a uri, or nil when the uri is something to play rather than open (a track).
    static func from(uri: Uri, kind: MediaKind, title: String = "") -> Route? {
        switch kind {
        case .album: return .album(uri)
        case .artist: return .artist(uri)
        case .playlist: return .playlist(canonicalUri(uri))
        case .show: return .show(uri)
        case .episode, .chapter: return .episode(uri)
        case .audiobook: return .audiobook(uri)
        case .user: return .user(uri)
        case .genre: return .category(uri)
        case .collection: return uri.contains("your-episodes") ? nil : .likedSongs
        case .folder: return .folder(uri, title)
        case .track, .unknown: return nil
        }
    }

    static func from(card: MediaCard) -> Route? { from(uri: card.uri, kind: card.kind, title: card.title) }
}
