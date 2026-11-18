// Orpheon for iOS: a port of Orpheon (https://github.com/kota-zo/Orpheon, formerly Myspoti), GPL-3.0.
// Derived from the Kotlin sources by kota-zo and contributors. Keep these notices; if you ever
// distribute this, publish your complete source under GPL-3.0 (see LICENSE and NOTICE.md).
import Foundation

/// A Spotify-style uri such as `spotify:track:{id}`. Kept as a string so every kind fits.
typealias Uri = String

struct CoverImage: Hashable {
    var url: String
    var width: Int? = nil
    var height: Int? = nil
}

extension Array where Element == CoverImage {
    /// Picks the smallest image at least `minPx` wide, or the largest one.
    func best(minPx: Int) -> CoverImage? {
        let big = filter { ($0.width ?? 0) >= minPx }.min { ($0.width ?? 0) < ($1.width ?? 0) }
        return big ?? self.max { ($0.width ?? 0) < ($1.width ?? 0) }
    }

    /// The URL of [best], the first image when none says its size.
    func bestUrl(minPx: Int = 300) -> URL? {
        guard let u = best(minPx: minPx)?.url ?? first?.url else { return nil }
        return URL(string: u)
    }
}

struct ArtistRef: Hashable {
    var uri: Uri
    var name: String
}

struct AlbumRef: Hashable {
    var uri: Uri
    var name: String
    var images: [CoverImage] = []
}

struct Track: Hashable, Identifiable {
    var uri: Uri
    var name: String
    var durationMs: Int64
    var artists: [ArtistRef]
    var album: AlbumRef?
    var explicit: Bool = false
    var playable: Bool = true
    /// Position in a playlist; needed to remove or move this exact row.
    var uid: String? = nil
    /// When it was added to the playlist (ISO 8601), for playlist rows.
    var addedAt: String? = nil
    var hasVideo: Bool = false

    var id: String { (uid ?? "") + uri }
    var artistLine: String { artists.map { $0.name }.joined(separator: ", ") }
    var kind: MediaKind { MediaKind.of(uri) }
}

struct Album: Hashable, Identifiable {
    var uri: Uri
    var name: String
    var artists: [ArtistRef]
    var images: [CoverImage]
    var type: String
    var releaseDate: String?
    var trackCount: Int
    var label: String? = nil
    var copyrights: [String] = []

    var id: String { uri }
    var artistLine: String { artists.map { $0.name }.joined(separator: ", ") }
    var year: String? { releaseDate.map { String($0.prefix(4)) } }
    /// "Album", "Single", "EP", "Compilation".
    var typeLabel: String { type.prefix(1).uppercased() + type.dropFirst().lowercased() }
}

struct Artist: Hashable, Identifiable {
    var uri: Uri
    var name: String
    var images: [CoverImage]
    var followers: Int64? = nil
    var monthlyListeners: Int64? = nil
    var verified: Bool = false

    var id: String { uri }
}

struct Playlist: Hashable, Identifiable {
    var uri: Uri
    var name: String
    var description: String?
    var owner: String?
    var images: [CoverImage]
    var trackCount: Int
    var editable: Bool = false
    var ownerUri: Uri? = nil
    var ownerImages: [CoverImage] = []
    var followers: Int64? = nil
    var isBlend: Bool = false
    var canLeave: Bool = false

    var id: String { uri }
}

enum PlaylistSort: String, CaseIterable, Identifiable {
    case custom, title, artist, album, addedAt, duration
    var id: String { rawValue }
    var label: String {
        switch self {
        case .custom: return "Custom order"
        case .title: return "Title"
        case .artist: return "Artist"
        case .album: return "Album"
        case .addedAt: return "Date added"
        case .duration: return "Duration"
        }
    }
}

extension Array where Element == Track {
    /// Sorts playlist rows the way the Web Player's sort menu does. Ties keep the playlist's own order.
    func sortedFor(_ sort: PlaylistSort, descending: Bool = false) -> [Track] {
        if sort == .custom { return descending ? self.reversed() : self }
        let indexed = self.enumerated().map { $0 }
        func key(_ t: Track) -> String {
            switch sort {
            case .title: return t.name.lowercased()
            case .artist: return t.artists.first?.name.lowercased() ?? ""
            case .album: return t.album?.name.lowercased() ?? ""
            case .addedAt: return t.addedAt ?? ""
            default: return ""
            }
        }
        let sorted = indexed.sorted { a, b in
            let c: Int
            if sort == .duration {
                c = a.element.durationMs < b.element.durationMs ? -1 : (a.element.durationMs > b.element.durationMs ? 1 : 0)
            } else {
                let ka = key(a.element), kb = key(b.element)
                c = ka < kb ? -1 : (ka > kb ? 1 : 0)
            }
            if c == 0 { return a.offset < b.offset }
            return descending ? c > 0 : c < 0
        }
        return sorted.map { $0.element }
    }
}

/// One page of a longer list. `nextOffset` is nil on the last page.
struct Page<T> {
    var items: [T]
    var offset: Int
    var total: Int
    var nextOffset: Int?

    static func empty() -> Page<T> { Page(items: [], offset: 0, total: 0, nextOffset: nil) }
}

struct SearchResults {
    var tracks: Page<Track>
    var artists: Page<Artist>
    var albums: Page<Album>
    var playlists: Page<Playlist>
}

enum Repeat: Int { case off = 0, context = 1, track = 2 }

enum ItemKind { case track, episode, ad, local }

/// What the player is on now. Ads never reach the UI as the current item.
struct NowPlaying: Hashable {
    var kind: ItemKind
    var uri: Uri
    var uid: String?
    var name: String
    var artists: [ArtistRef]
    var album: AlbumRef?
    var imageUrl: String?
    var durationMs: Int64
    var explicit: Bool = false
    var provider: String? = nil

    var artistLine: String { artists.map { $0.name }.joined(separator: ", ") }
}

struct PlayerRestrictions: Hashable {
    var canPause = true
    var canResume = true
    var canSeek = true
    var canSkipNext = true
    var canSkipPrevious = true
}

struct PlayerState {
    var item: NowPlaying?
    var contextUri: Uri?
    var contextName: String? = nil
    var isPaused: Bool
    var isBuffering: Bool = false
    /// Position at `timestampMs` (epoch). Use `positionAt` for a live value.
    var positionMs: Int64
    var timestampMs: Int64
    var speed: Double = 1.0
    var shuffle: Bool
    var repeatMode: Repeat
    var restrictions = PlayerRestrictions()

    func positionAt(nowMs: Int64) -> Int64 {
        guard let item = item, !isPaused else { return positionMs }
        let live = positionMs + Int64(Double(nowMs - timestampMs) * speed)
        return Swift.min(Swift.max(live, 0), item.durationMs)
    }
}

struct PlayQueue {
    var current: NowPlaying?
    var queued: [NowPlaying]
    var nextUp: [NowPlaying]
}

struct TopTrack: Hashable {
    var track: Track
    var playcount: Int64?
}

/// Everything the artist screen shows, in one call.
struct ArtistPage {
    var artist: Artist
    var biography: String?
    var headerImages: [CoverImage]
    var topTracks: [TopTrack]
    var popularReleases: [Album]
    var appearsOn: [Album]
    var related: [Artist]
}

// MARK: - Media cards, shelves, home

/// What a uri points to.
enum MediaKind: Hashable {
    case track, album, artist, playlist, show, episode, audiobook, chapter, user, genre
    /// Liked Songs, Your Episodes and other built-in collections.
    case collection
    case folder, unknown

    static func of(_ uri: Uri) -> MediaKind {
        if uri.hasPrefix("spotify:track:") { return .track }
        if uri.hasPrefix("spotify:album:") { return .album }
        if uri.hasPrefix("spotify:artist:") { return .artist }
        if uri.hasPrefix("spotify:playlist:") { return .playlist }
        if uri.hasPrefix("spotify:show:") { return .show }
        if uri.hasPrefix("spotify:episode:") { return .episode }
        if uri.hasPrefix("spotify:audiobook:") { return .audiobook }
        if uri.hasPrefix("spotify:chapter:") { return .chapter }
        if uri.hasPrefix("spotify:user:") && uri.contains(":collection") { return .collection }
        if uri.hasPrefix("spotify:user:") { return .user }
        if uri.hasPrefix("spotify:genre:") || uri.hasPrefix("spotify:page:") { return .genre }
        if uri.hasPrefix("spotify:collection:") { return .collection }
        if uri.hasPrefix("spotify:folder:") || uri.contains(":folder:") { return .folder }
        return .unknown
    }
}

/// A tile in a shelf: home, browse, search top results, "fans also like"...
struct MediaCard: Hashable, Identifiable {
    var uri: Uri
    var kind: MediaKind
    var title: String
    var subtitle: String?
    var images: [CoverImage]

    var id: String { uri }
}

struct Shelf: Hashable, Identifiable {
    var uri: Uri?
    var title: String?
    var items: [MediaCard]
    var total: Int

    var id: String { (uri ?? "") + (title ?? "") }
}

enum HomeFilter: String, CaseIterable {
    case all = "", music = "music-chip", podcasts = "podcasts-chip", audiobooks = "audiobooks-chip"
    var facet: String { rawValue }
    var label: String {
        switch self {
        case .all: return "All"
        case .music: return "Music"
        case .podcasts: return "Podcasts"
        case .audiobooks: return "Audiobooks"
        }
    }
}

struct HomeChip: Hashable {
    var id: String
    var label: String
    var subChips: [HomeChip] = []
}

struct HomeFeed {
    var greeting: String
    var shelves: [Shelf]
    var chips: [HomeChip] = []
}

struct Category: Hashable, Identifiable {
    var uri: Uri
    var title: String
    var images: [CoverImage]
    var color: String?
    var id: String { uri }
}

struct BrowsePage {
    var uri: Uri
    var title: String
    var shelves: [Shelf]
}

// MARK: - Library

enum LibraryFilter: String, CaseIterable, Identifiable {
    case all, playlists, artists, albums, podcasts, audiobooks
    var id: String { rawValue }
    var gqlId: String? {
        switch self {
        case .all: return nil
        case .playlists: return "Playlists"
        case .artists: return "Artists"
        case .albums: return "Albums"
        case .podcasts: return "Podcasts"
        case .audiobooks: return "Audiobooks"
        }
    }
    var label: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
}

enum LibrarySort: String, CaseIterable, Identifiable {
    case recents, recentlyAdded, alphabetical, creator
    var id: String { rawValue }
    var gqlId: String? {
        switch self {
        case .recents: return nil
        case .recentlyAdded: return "Recently Added"
        case .alphabetical: return "Alphabetical"
        case .creator: return "Creator"
        }
    }
    var label: String {
        switch self {
        case .recents: return "Recents"
        case .recentlyAdded: return "Recently added"
        case .alphabetical: return "Alphabetical"
        case .creator: return "Creator"
        }
    }
}

struct LibraryItem: Hashable, Identifiable {
    var uri: Uri
    var kind: MediaKind
    var name: String
    var subtitle: String?
    var images: [CoverImage]
    var pinned: Bool
    var addedAt: String?
    /// Items in a folder, tracks in Liked Songs.
    var count: Int? = nil
    var ownerUri: Uri? = nil

    var id: String { uri }
}

struct SavedTrack: Hashable {
    var track: Track
    var addedAt: String?
}

// MARK: - Users

struct Account: Hashable {
    var uri: Uri
    var username: String
    var name: String
    var images: [CoverImage]
    var premium: Bool
    var country: String?
}

struct UserProfile {
    var uri: Uri
    var name: String
    var images: [CoverImage]
    var followers: Int?
    var following: Int?
    var publicPlaylists: [Playlist]
}

enum TimeRange: String, CaseIterable, Identifiable {
    case short = "SHORT_TERM", medium = "MID_TERM", long = "LONG_TERM"
    var id: String { rawValue }
    var gqlName: String { rawValue }
    var label: String {
        switch self {
        case .short: return "Last 4 weeks"
        case .medium: return "Last 6 months"
        case .long: return "Last year"
        }
    }
}

struct TopContent {
    var artists: [Artist]
    var tracks: [Track]
    var artistTotal: Int?
    var trackTotal: Int?
}

struct UserRef: Hashable, Identifiable {
    var uri: Uri
    var name: String
    var imageUrl: String?
    var id: String { uri }
}

// MARK: - Podcasts and audiobooks

struct Show: Hashable {
    var uri: Uri
    var name: String
    var publisher: String
    var description: String?
    var images: [CoverImage]
    var saved: Bool
    var rating: Double?
    var topics: [String]
}

struct Episode: Hashable, Identifiable {
    var uri: Uri
    var name: String
    var description: String?
    var durationMs: Int64
    var releaseDate: String?
    var images: [CoverImage]
    var show: AlbumRef?
    /// Where the user stopped, and whether they finished it.
    var playedPositionMs: Int64
    var played: Bool
    var explicit: Bool
    var playable: Bool
    var previewUrl: String?

    var id: String { uri }
}

/// A podcast episode's audio as the Web Player resolves it (soundfinder). `url` is the publisher's
/// own clear file when Spotify exposes one; it is nil for Spotify-exclusive shows.
struct EpisodeAudio {
    var url: String?
    var passthrough: String
    var format: String
}

struct Audiobook: Hashable {
    var uri: Uri
    var name: String
    var authors: [String]
    var narrators: [String]
    var description: String?
    var images: [CoverImage]
    var chapterCount: Int
}

// MARK: - Lyrics and credits

struct LyricsWord: Hashable {
    var startMs: Int64
    var text: String
}

struct LyricsLine: Hashable, Identifiable {
    var startMs: Int64
    var endMs: Int64?
    var text: String
    var words: [LyricsWord]? = nil
    var id: Int64 { startMs &* 31 &+ Int64(text.hashValue & 0xffff) }
}

struct Lyrics {
    var lines: [LyricsLine]
    var synced: Bool
    var language: String?
    var provider: String?
    /// ARGB colours from Spotify's lyrics card.
    var background: Int?
    var text: Int?
    var highlight: Int?
}

struct CreditRole: Hashable {
    var role: String
    var artists: [ArtistRef]
}

struct Credits {
    var roles: [CreditRole]
}

// MARK: - Devices

struct Device: Hashable, Identifiable {
    var id: String
    var name: String
    var type: String
    var active: Bool
    var volume: Double?
}

// MARK: - Helpers

private let oldPlaylistUri = try! NSRegularExpression(pattern: "^spotify:user:[^:]+:playlist:([A-Za-z0-9]+)$")

/// `uri` in its current form. A playlist can still come as `spotify:user:<owner>:playlist:<id>`.
func canonicalUri(_ uri: Uri) -> Uri {
    let ns = uri as NSString
    if let m = oldPlaylistUri.firstMatch(in: uri, range: NSRange(location: 0, length: ns.length)), m.numberOfRanges > 1 {
        return "spotify:playlist:" + ns.substring(with: m.range(at: 1))
    }
    return uri
}

/// The id at the end of a uri.
func idOf(_ uri: Uri) -> String {
    uri.split(separator: ":").last.map(String.init) ?? uri
}

let base62Alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")

/// Spotify's base62 id -> the 32-char hex gid used by metadata/4.
func base62ToHex(_ id: String) -> String {
    var bytes = [UInt8](repeating: 0, count: 16)
    for ch in id {
        guard let idx = base62Alphabet.firstIndex(of: ch) else { continue }
        var carry = idx
        for i in stride(from: 15, through: 0, by: -1) {
            let v = Int(bytes[i]) * 62 + carry
            bytes[i] = UInt8(v & 0xff)
            carry = v >> 8
        }
    }
    return bytes.map { String(format: "%02x", $0) }.joined()
}

/// Strips tags and decodes the few entities Spotify's biographies use.
func stripHtml(_ html: String) -> String {
    var s = html.replacingOccurrences(of: "<br>", with: "\n").replacingOccurrences(of: "<br/>", with: "\n")
    if let re = try? NSRegularExpression(pattern: "<[^>]+>") {
        s = re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: "")
    }
    let entities = ["&amp;": "&", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&lt;": "<", "&gt;": ">", "&nbsp;": " "]
    for (k, v) in entities { s = s.replacingOccurrences(of: k, with: v) }
    return s.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// "3:07", or "1:02:03" for long ones.
func formatDuration(ms: Int64) -> String {
    let total = Swift.max(0, Int(ms / 1000))
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
    return String(format: "%d:%02d", m, s)
}

/// "1.2M", "34K".
func compactCount(_ n: Int64) -> String {
    let d = Double(n)
    if n >= 1_000_000_000 { return String(format: "%.1fB", d / 1_000_000_000) }
    if n >= 1_000_000 { return String(format: "%.1fM", d / 1_000_000) }
    if n >= 10_000 { return String(format: "%.0fK", d / 1_000) }
    if n >= 1_000 { return String(format: "%.1fK", d / 1_000) }
    return String(n)
}

func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
