// Orpheon for iOS: a port of Orpheon (https://github.com/kota-zo/Orpheon, formerly Myspoti), GPL-3.0.
// Derived from the Kotlin sources by kota-zo and contributors. Keep these notices; if you ever
// distribute this, publish your complete source under GPL-3.0 (see LICENSE and NOTICE.md).
import Foundation

/// Everything the UI reads from Spotify: search, catalog, library, playlists, home, podcasts, users.
/// Reads go straight to Spotify over HTTP (GraphQL persisted queries and spclient); there is no
/// page behind them on iOS.
final class SpotifyService {
    let http: SpotifyHTTP
    let gql: GqlClient

    private var usernameCache: String?
    private let cacheLock = NSLock()
    var playlistUriCache: (at: Int64, uris: Set<String>)?
    /// The filter ids the account's library offers, from its last list answer (`availableFilters`).
    var offeredFilters: [String]?

    init(http: SpotifyHTTP, gql: GqlClient) {
        self.http = http
        self.gql = gql
    }

    func forgetAccount() {
        cacheLock.lock()
        usernameCache = nil
        playlistUriCache = nil
        cacheLock.unlock()
    }

    func cachedUsername() -> String? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return usernameCache
    }

    func setCachedUsername(_ name: String?) {
        cacheLock.lock(); usernameCache = name; cacheLock.unlock()
    }

    /// The account's own username (cached).
    func ownUsername() async throws -> String {
        if let u = cachedUsername(), !u.isEmpty { return u }
        let me = try await self.me()
        setCachedUsername(me.username)
        return me.username
    }

    // MARK: - Search

    private func tabVars(_ query: String, _ offset: Int, _ limit: Int) -> JSON {
        vars([
            "searchTerm": query, "offset": offset, "limit": limit, "numberOfTopResults": limit,
            "includeAudiobooks": true, "includeAuthors": true, "includePreReleases": false,
            "includeAlbumPreReleases": false, "includeEpisodeContentRatingsV2": true,
        ])
    }

    func searchTracks(_ query: String, offset: Int = 0, limit: Int = 30) async throws -> Page<Track> {
        let r = try await gql.query("searchTracks", tabVars(query, offset, limit))
        return mapPage(r.at("data.searchV2.tracksV2"), offset: offset) { mapTrack($0.at("item.data")) }
    }

    func searchArtists(_ query: String, offset: Int = 0, limit: Int = 30) async throws -> Page<Artist> {
        let r = try await gql.query("searchArtists", tabVars(query, offset, limit))
        return mapPage(r.at("data.searchV2.artists"), offset: offset) { mapArtist($0.at("data")) }
    }

    func searchAlbums(_ query: String, offset: Int = 0, limit: Int = 30) async throws -> Page<Album> {
        let r = try await gql.query("searchAlbums", tabVars(query, offset, limit))
        return mapPage(r.at("data.searchV2.albumsV2"), offset: offset) { mapAlbum($0.at("data")) }
    }

    func searchPlaylists(_ query: String, offset: Int = 0, limit: Int = 30) async throws -> Page<Playlist> {
        let r = try await gql.query("searchPlaylists", tabVars(query, offset, limit))
        return mapPage(r.at("data.searchV2.playlists"), offset: offset) { mapPlaylist($0.at("data")) }
    }

    func searchShows(_ query: String, offset: Int = 0, limit: Int = 30) async throws -> Page<MediaCard> {
        let r = try await gql.query("searchPodcasts", tabVars(query, offset, limit))
        return mapPage(r.at("data.searchV2.podcasts"), offset: offset) { mapCard($0) }
    }

    func searchEpisodes(_ query: String, offset: Int = 0, limit: Int = 30) async throws -> Page<Episode> {
        let r = try await gql.query("searchFullEpisodes", vars([
            "searchTerm": query, "offset": offset, "limit": limit, "includeEpisodeContentRatingsV2": true,
        ]))
        return mapPage(r.at("data.searchV2.episodes"), offset: offset) { mapEpisode($0.at("data")) }
    }

    func searchAudiobooks(_ query: String, offset: Int = 0, limit: Int = 30) async throws -> Page<MediaCard> {
        let r = try await gql.query("searchAudiobooks", tabVars(query, offset, limit))
        return mapPage(r.at("data.searchV2.audiobooks"), offset: offset) { mapCard($0) }
    }

    func searchUsers(_ query: String, offset: Int = 0, limit: Int = 30) async throws -> Page<MediaCard> {
        let r = try await gql.query("searchUsers", tabVars(query, offset, limit))
        return mapPage(r.at("data.searchV2.users"), offset: offset) { mapCard($0) }
    }

    /// The four music tabs in parallel: one round trip of wall time.
    func searchAll(_ query: String, limit: Int = 10) async throws -> SearchResults {
        async let t = searchTracks(query, offset: 0, limit: limit)
        async let ar = searchArtists(query, offset: 0, limit: limit)
        async let al = searchAlbums(query, offset: 0, limit: limit)
        async let p = searchPlaylists(query, offset: 0, limit: limit)
        return try await SearchResults(tracks: t, artists: ar, albums: al, playlists: p)
    }

    func suggestions(_ query: String, limit: Int = 10) async throws -> [String] {
        let r = try await gql.query("searchSuggestions", vars([
            "query": query, "limit": limit, "numberOfTopResults": limit, "offset": 0,
            "includeAuthors": true, "includeAlbumPreReleases": false, "includeEpisodeContentRatingsV2": true,
        ]))
        return r.list("data.searchV2.topResultsV2.itemsV2").compactMap { hit in
            let item = hit.at("item")
            if item.typename() == "SearchAutoCompleteEntity" { return item.str("text") ?? item.str("data.text") }
            return nil
        }
    }

    func recentSearches() async throws -> [MediaCard] {
        let r = try await gql.query("recentSearches", vars(["limit": 50, "includeAuthors": true, "includeEpisodeContentRatingsV2": true]))
        return r.list("data.recentSearches.recentSearchesItems.items").compactMap { mapCard($0) }
    }

    func clearRecentSearches() async throws {
        let uris = try await recentSearches().map { $0.uri }
        if !uris.isEmpty { _ = try await gql.query("removeRecentSearches", vars(["uris": uris])) }
    }

    // MARK: - Catalog

    /// The recording's ISRC, from spclient metadata/4.
    func isrc(trackUri: Uri) async throws -> String? {
        let hex = base62ToHex(idOf(trackUri))
        guard let meta = try await http.getJSON("https://spclient.wg.spotify.com/metadata/4/track/\(hex)?market=from_token") else { return nil }
        return meta.list("external_id").first(where: { $0.str("type") == "isrc" })?.str("id")
    }

    func track(_ uri: Uri) async throws -> Track {
        let r = try await gql.query("getTrack", vars(["uri": uri, "includeVideoAssociationItems": false]))
        guard let t = mapTrack(try r.entity("data.trackUnion", "getTrack")) else { throw SpotifyError.gql("getTrack", "bad track") }
        return t
    }

    private func albumUnion(_ uri: Uri, offset: Int, limit: Int) async throws -> JSON {
        let r = try await gql.query("getAlbum", vars(["uri": uri, "locale": "", "offset": offset, "limit": limit]))
        return try r.entity("data.albumUnion", "getAlbum")
    }

    func album(_ uri: Uri) async throws -> Album {
        guard let a = mapAlbum(try await albumUnion(uri, offset: 0, limit: 1)) else { throw SpotifyError.gql("getAlbum", "bad album") }
        return a
    }

    func albumTracks(_ uri: Uri, offset: Int = 0, limit: Int = 50) async throws -> Page<Track> {
        let a = try await albumUnion(uri, offset: offset, limit: limit)
        let cover = mapAlbum(a)
        return mapPage(a.at("tracksV2"), offset: offset) { row in
            guard var t = mapTrack(row.at("track"), uid: row.str("uid")) else { return nil }
            if t.album == nil, let c = cover { t.album = AlbumRef(uri: c.uri, name: c.name, images: c.images) }
            return t
        }
    }

    private func artistUnion(_ uri: Uri) async throws -> JSON {
        let r = try await gql.query("queryArtistOverview", vars(["uri": uri, "locale": "", "preReleaseV2": false]))
        return try r.entity("data.artistUnion", "queryArtistOverview")
    }

    func artist(_ uri: Uri) async throws -> Artist {
        let a = try await artistUnion(uri)
        guard var base = mapArtist(a) else { throw SpotifyError.gql("queryArtistOverview", "bad artist") }
        base.verified = a.bool("onPlatformReputationTrait.verification.isVerified") ?? false
        return base
    }

    func artistPage(_ uri: Uri) async throws -> ArtistPage {
        let a = try await artistUnion(uri)
        guard var base = mapArtist(a) else { throw SpotifyError.gql("queryArtistOverview", "bad artist") }
        base.verified = a.bool("onPlatformReputationTrait.verification.isVerified") ?? false
        return ArtistPage(
            artist: base,
            biography: a.str("profile.biography.text").map { stripHtml($0) },
            headerImages: mapImages(a.list("headerImage.data.sources")),
            topTracks: a.list("discography.topTracks.items").compactMap { row in
                guard let t = mapTrack(row.at("track"), uid: row.str("uid")) else { return nil }
                return TopTrack(track: t, playcount: row.long("track.playcount"))
            },
            popularReleases: a.list("discography.popularReleasesAlbums.items").compactMap { mapAlbum($0) },
            appearsOn: a.list("relatedContent.appearsOn.items").compactMap { mapRelease($0) },
            related: a.list("relatedContent.relatedArtists.items").compactMap { mapArtist($0) })
    }

    /// Albums, singles and compilations, newest first.
    func discography(_ uri: Uri, offset: Int = 0, limit: Int = 50) async throws -> Page<Album> {
        let r = try await gql.query("queryArtistDiscographyAll", vars(["uri": uri, "offset": offset, "limit": limit, "order": "DATE_DESC"]))
        let all = try r.entity("data.artistUnion", "queryArtistDiscographyAll").at("discography.all")
        return mapPage(all, offset: offset) { mapRelease($0) }
    }

    func relatedArtists(_ uri: Uri) async throws -> [Artist] {
        let r = try await gql.query("queryArtistRelated", vars(["uri": uri]))
        return try r.entity("data.artistUnion", "queryArtistRelated").list("relatedContent.relatedArtists.items").compactMap { mapArtist($0) }
    }

    func similarAlbums(trackUri: Uri, limit: Int = 20) async throws -> [Album] {
        let r = try await gql.query("similarAlbumsBasedOnThisTrack", vars(["uri": trackUri, "limit": limit, "albumsOnly": true]))
        return r.list("data.seoRecommendedTrackAlbum.items").compactMap { mapAlbum($0.at("data")) }
    }
}
