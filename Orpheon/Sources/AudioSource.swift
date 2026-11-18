// Orpheon for iOS: a port of Orpheon (https://github.com/kota-zo/Orpheon, formerly Myspoti), GPL-3.0.
// Derived from the Kotlin sources by kota-zo and contributors. Keep these notices; if you ever
// distribute this, publish your complete source under GPL-3.0 (see LICENSE and NOTICE.md).
import Foundation

/// Where the audio of a Spotify track can come from, now that Spotify's own audio cannot play in the app.
/// Each source is played the way its owner allows: Apple Music with the user's subscription through
/// Apple's player, YouTube through YouTube's own embedded player, Audius through its public API.
enum AudioSourceID: String, CaseIterable, Codable, Identifiable {
    case appleMusic, youtube, audius

    var id: String { rawValue }

    var label: String {
        switch self {
        case .appleMusic: return "Apple Music"
        case .youtube: return "YouTube"
        case .audius: return "Audius"
        }
    }
}

/// The "Playback source" setting.
enum SourcePreference: String, CaseIterable, Identifiable {
    /// The old behaviour: the official Spotify app plays, this app controls it.
    case spotifyApp
    case appleMusic
    case youtube
    case audius
    /// Tries every source in turn (Apple Music, Audius, YouTube) and uses the first good match.
    case all

    var id: String { rawValue }

    var label: String {
        switch self {
        case .spotifyApp: return "Spotify app (Connect)"
        case .appleMusic: return "Apple Music"
        case .youtube: return "YouTube"
        case .audius: return "Audius"
        case .all: return "All sources"
        }
    }

    /// The sources tried, in order. Empty for the Spotify app, which has no matching step.
    var providers: [AudioSourceID] {
        switch self {
        case .spotifyApp: return []
        case .appleMusic: return [.appleMusic]
        case .youtube: return [.youtube]
        case .audius: return [.audius]
        case .all: return [.appleMusic, .audius, .youtube]
        }
    }

    var usesSources: Bool { self != .spotifyApp }
}

/// What to look for: a Spotify track, described by its tags.
struct TrackQuery: Equatable {
    var title: String
    var artist: String
    var album: String?
    var durationMs: Int64
    var explicit: Bool = false

    init(title: String, artist: String, album: String? = nil, durationMs: Int64 = 0, explicit: Bool = false) {
        self.title = title
        self.artist = artist
        self.album = album
        self.durationMs = durationMs
        self.explicit = explicit
    }

    init(_ t: Track) {
        self.init(title: t.name, artist: t.artists.first?.name ?? "", album: t.album?.name, durationMs: t.durationMs, explicit: t.explicit)
    }
}

/// How a found item is played.
enum PlaybackTarget: Equatable {
    /// A plain audio URL, played by AVPlayer in the app.
    case url(URL)
    /// An Apple Music song id, played by Apple's player for a subscriber.
    case appleStoreID(String)
    /// A YouTube video, played by YouTube's own embedded player.
    case youtubeVideo(String)
}

struct ResolvedAudio: Equatable {
    var source: AudioSourceID
    var target: PlaybackTarget
    var title: String
    var artist: String
    var durationMs: Int64
    var imageUrl: String?
    /// A 30-second clip rather than the song.
    var isPreview: Bool = false
    /// How well it matches (0 to 1).
    var score: Double = 0

    /// The small label shown under the title.
    var label: String { isPreview ? source.label + " preview" : source.label }
}

enum SourceAvailability: Equatable {
    case ready
    /// Works once something is set up (a key, a permission, a subscription).
    case needsSetup(String)
}

struct SourceOptions: Equatable {
    /// Accept 30-second previews when the full song is not available to this user.
    var allowPreviews = false
}

protocol SourceProvider {
    var id: AudioSourceID { get }
    func availability() async -> SourceAvailability
    /// The best match for `query`, or nil. Content that needs a paid plan the user does not have is
    /// never returned: it is left out, not worked around.
    func find(_ query: TrackQuery, options: SourceOptions) async throws -> ResolvedAudio?
}

enum Resolution {
    case found(ResolvedAudio)
    /// Nothing playable; the reasons (a missing key, no subscription, no match) for the message.
    case notFound([String])
}

/// Whether this phone can play Apple Music songs for the signed-in user.
enum AppleMusicStatus: Equatable {
    case unknown
    /// The Media & Apple Music permission was refused.
    case denied
    /// Allowed, but no active Apple Music subscription: only 30-second previews exist.
    case noSubscription
    case ready

    var text: String {
        switch self {
        case .unknown: return "Not checked yet"
        case .denied: return "Permission denied (Settings > Orpheon > Media & Apple Music)"
        case .noSubscription: return "No Apple Music subscription: previews only"
        case .ready: return "Ready"
        }
    }
}

enum SourceError: Error, LocalizedError {
    /// Something to set up or fix (a key, a permission, a quota), not a plain "no match".
    case setup(String)
    case network(String)

    var message: String {
        switch self {
        case .setup(let m), .network(let m): return m
        }
    }

    var errorDescription: String? { message }
}
