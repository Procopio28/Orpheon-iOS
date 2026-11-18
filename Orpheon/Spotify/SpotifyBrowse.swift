// Orpheon for iOS: a port of Orpheon (https://github.com/kota-zo/Orpheon, formerly Myspoti), GPL-3.0.
// Derived from the Kotlin sources by kota-zo and contributors. Keep these notices; if you ever
// distribute this, publish your complete source under GPL-3.0 (see LICENSE and NOTICE.md).
import Foundation

extension SpotifyService {
    // MARK: - Home and browse

    func homeFeed(facet: String = "", itemsPerShelf: Int = 10) async throws -> HomeFeed {
        let r = try await gql.query("home", vars([
            "timeZone": TimeZone.current.identifier, "sp_t": "", "facet": facet,
            "sectionItemsLimit": itemsPerShelf, "homeEndUserIntegration": "INTEGRATION_WEB_PLAYER",
            "includeEpisodeContentRatingsV2": true, "includeHomeChapterVideoCards": false,
        ]))
        let home = try r.entity("data.home", "home")
        return HomeFeed(
            greeting: home.str("greeting.transformedLabel") ?? "",
            shelves: home.list("sectionContainer.sections.items").compactMap { mapShelf($0) },
            chips: home.list("homeChips").compactMap { mapHomeChip($0) })
    }

    func categories() async throws -> [Category] {
        let r = try await gql.query("browseAll", vars([
            "pagePagination": ["offset": 0, "limit": 10],
            "sectionPagination": ["offset": 0, "limit": 99],
            "browseEndUserIntegration": "INTEGRATION_WEB_PLAYER",
        ]))
        return r.list("data.browseStart.sections.items").flatMap { $0.list("sectionItems.items") }.compactMap { item in
            guard let c = item.obj("content.data.data.cardRepresentation") ?? item.obj("content.data.cardRepresentation"),
                  let uri = item.str("uri") else { return nil }
            return Category(uri: uri, title: c.str("title.transformedLabel") ?? "", images: mapImages(c.list("artwork.sources")), color: c.str("backgroundColor.hex"))
        }
    }

    func category(_ uri: Uri) async throws -> BrowsePage {
        let r = try await gql.query("browsePage", vars([
            "uri": uri, "pagePagination": ["offset": 0, "limit": 10], "sectionPagination": ["offset": 0, "limit": 20],
            "browseEndUserIntegration": "INTEGRATION_WEB_PLAYER", "includeEpisodeContentRatingsV2": true,
        ]))
        let page = try r.entity("data.browse", "browsePage")
        return BrowsePage(uri: uri, title: page.str("header.title.transformedLabel") ?? "", shelves: page.list("sections.items").compactMap { mapShelf($0) })
    }

    /// New releases from the artists the user follows, newest first.
    func whatsNew(offset: Int = 0, limit: Int = 50) async throws -> Page<Album> {
        let r = try await gql.query("queryWhatsNewFeed", vars(["offset": offset, "limit": limit, "onlyUnPlayedItems": false]))
        return mapPage(r.at("data.whatsNewFeedItems"), offset: offset) { item in
            let d = item.at("content.data")
            guard var a = mapAlbum(d) else { return nil }
            if a.type == "ALBUM", let t = d.str("albumType") { a.type = t }
            return a
        }
    }

    // MARK: - Podcasts and audiobooks

    private func showUnion(_ uri: Uri) async throws -> JSON {
        let r = try await gql.query("queryShowMetadataV2", vars([
            "uri": uri, "includeContentCapabilityTrait": true, "includeEpisodeContentRatingsV2": true,
        ]))
        return try r.entity("data.podcastUnionV2", "queryShowMetadataV2")
    }

    func show(_ uri: Uri) async throws -> Show {
        guard let s = mapShow(try await showUnion(uri)) else { throw SpotifyError.gql("queryShowMetadataV2", "bad show") }
        return s
    }

    func episodes(show uri: Uri, offset: Int = 0, limit: Int = 50) async throws -> Page<Episode> {
        let r = try await gql.query("queryPodcastEpisodes", vars(["uri": uri, "offset": offset, "limit": limit, "includeEpisodeContentRatingsV2": true]))
        let e = try r.entity("data.podcastUnionV2", "queryPodcastEpisodes").at("episodesV2")
        return mapPage(e, offset: offset) { mapEpisode($0.at("entity.data")) }
    }

    func episode(_ uri: Uri) async throws -> Episode {
        let r = try await gql.query("getEpisodeOrChapter", vars(["uri": uri, "includeEpisodeContentRatingsV2": true]))
        guard let e = mapEpisode(try r.entity("data.episodeUnionV2", "getEpisodeOrChapter")) else { throw SpotifyError.gql("getEpisodeOrChapter", "bad episode") }
        return e
    }

    func audiobook(_ uri: Uri) async throws -> Audiobook {
        let d = try await showUnion(uri)
        var authors = d.list("authorsV2").compactMap { $0.str("name") }
        if authors.isEmpty { authors = d.list("authors").compactMap { $0.str("name") } }
        return Audiobook(
            uri: d.str("uri") ?? uri, name: d.str("name") ?? "", authors: authors,
            narrators: d.list("narrators.items").compactMap { $0.str("name") },
            description: d.str("description"), images: mapImages(d.list("coverArt.sources")),
            chapterCount: d.int("chaptersV2.totalCount") ?? d.int("episodesV2.totalCount") ?? 0)
    }

    func chapters(_ uri: Uri, offset: Int = 0, limit: Int = 50) async throws -> Page<Episode> {
        let r = try await gql.query("queryBookChapters", vars(["uri": uri, "offset": offset, "limit": limit]))
        let d = try r.entity("data.podcastUnionV2", "queryBookChapters")
        let list = d.at("chaptersV2") ?? d.at("episodesV2")
        return mapPage(list, offset: offset) { mapEpisode($0.at("entity.data") ?? $0.at("data")) }
    }

    /// The audio of one episode from the Web Player's soundfinder endpoint. Only the publisher's own
    /// clear file (`passthroughUrl`) is usable: the other copy is Widevine-encrypted and never returned.
    func episodeAudio(_ uri: Uri) async throws -> EpisodeAudio {
        let url = "https://spclient.wg.spotify.com/soundfinder/v1/unauth/episode/\(idOf(uri))/com.widevine.alpha"
        guard let json = try await http.getJSON(url) else { return EpisodeAudio(url: nil, passthrough: "NONE", format: "") }
        let pass = (json.str("passthrough") ?? "").uppercased()
        let passUrl = json.str("passthroughUrl").flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        return EpisodeAudio(url: pass == "NONE" ? nil : passUrl, passthrough: pass.isEmpty ? "NONE" : pass, format: json.str("format") ?? "")
    }

    // MARK: - Users

    func me() async throws -> Account {
        async let profile = gql.query("profileAttributes", vars())
        async let account = gql.query("accountAttributes", vars())
        let p = try await profile.at("data.me.profile")
        let a = try await account.at("data.me.account")
        return Account(
            uri: p.str("uri") ?? "",
            username: p.str("username") ?? "",
            name: p.str("name") ?? p.str("username") ?? "",
            images: mapImages(p.list("avatar.sources")),
            premium: (a.str("product")?.uppercased() ?? "FREE") != "FREE",
            country: a.str("country"))
    }

    func profile(_ userUri: Uri) async throws -> UserProfile {
        let id = idOf(userUri).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? idOf(userUri)
        guard let p = try await http.getJSON("https://spclient.wg.spotify.com/user-profile-view/v3/profile/\(id)?playlist_limit=50&artist_limit=10&episode_limit=10&market=from_token") else {
            throw SpotifyError.gql("user-profile-view", "not found")
        }
        return UserProfile(
            uri: p.str("uri") ?? userUri,
            name: p.str("name") ?? idOf(userUri),
            images: p.str("image_url").map { [CoverImage(url: $0)] } ?? [],
            followers: p.int("followers_count"),
            following: p.int("following_count"),
            publicPlaylists: p.list("public_playlists").compactMap { pl in
                guard let uri = pl.str("uri") else { return nil }
                return Playlist(uri: canonicalUri(uri), name: pl.str("name") ?? "", description: nil, owner: pl.str("owner_name"),
                                images: pl.str("image_url").map { [CoverImage(url: $0)] } ?? [], trackCount: 0)
            })
    }

    func top(range: TimeRange = .short, limit: Int = 10) async throws -> TopContent {
        let input: [String: Any?] = ["offset": 0, "limit": limit, "sortBy": "AFFINITY", "timeRange": range.gqlName]
        let r = try await gql.query("userTopContent", vars([
            "includeTopArtists": true, "topArtistsInput": input, "includeTopTracks": true, "topTracksInput": input,
        ]))
        let profile = r.at("data.me.profile")
        return TopContent(
            artists: profile.list("topArtists.items").compactMap { mapArtist($0.at("data")) },
            tracks: profile.list("topTracks.items").compactMap { mapTrack($0.at("data")) },
            artistTotal: profile.int("topArtists.totalCount"),
            trackTotal: profile.int("topTracks.totalCount"))
    }

    func followUsers(_ userUris: [Uri]) async throws { _ = try await gql.query("followUsers", vars(["usernames": userUris.map { idOf($0) }])) }
    func unfollowUsers(_ userUris: [Uri]) async throws { _ = try await gql.query("unfollowUsers", vars(["usernames": userUris.map { idOf($0) }])) }

    func isFollowing(_ userUris: [Uri]) async throws -> [Bool] {
        let r = try await gql.query("isFollowingUsers", vars(["uris": userUris]))
        let list = r.list("data.users")
        return userUris.map { u in list.first(where: { $0.str("uri") == u })?.bool("following") ?? false }
    }

    // MARK: - Track extras

    /// Spotify's own lyrics (line or word synced), with the colours of its lyrics card.
    func spotifyLyrics(trackUri: Uri) async throws -> Lyrics? {
        let url = "https://spclient.wg.spotify.com/color-lyrics/v2/track/\(idOf(trackUri))?format=json&vocalRemoval=false&market=from_token"
        guard let r = try await http.getJSON(url), let l = r.obj("lyrics") else { return nil }
        let synced = l.str("syncType") != "UNSYNCED"
        let lines: [LyricsLine] = l.list("lines").map { line in
            let start = line.long("startTimeMs") ?? 0
            let words: [LyricsWord] = line.list("syllables").compactMap { s in
                guard let w = s.str("words") else { return nil }
                return LyricsWord(startMs: s.long("startTimeMs") ?? start, text: w)
            }
            return LyricsLine(startMs: start, endMs: line.long("endTimeMs").flatMap { $0 > 0 ? $0 : nil },
                              text: line.str("words") ?? "", words: words.isEmpty ? nil : words)
        }.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty || synced }
        return Lyrics(lines: lines, synced: synced, language: l.str("language"),
                      provider: l.str("providerDisplayName") ?? l.str("provider"),
                      background: r.int("colors.background"), text: r.int("colors.text"), highlight: r.int("colors.highlightText"))
    }

    func credits(trackUri: Uri) async throws -> Credits {
        let r = try await gql.query("queryTrackCreditsGroupedModal", vars(["trackUri": trackUri]))
        let contributors = r.list("data.trackUnion.creditsTrait.contributors.items")
        var order: [String] = []
        var groups: [String: [ArtistRef]] = [:]
        for c in contributors {
            let role = c.str("role") ?? c.str("roleGroup.name") ?? ""
            if groups[role] == nil { order.append(role) }
            groups[role, default: []].append(ArtistRef(uri: c.str("uri") ?? "", name: c.str("name") ?? ""))
        }
        return Credits(roles: order.map { CreditRole(role: $0, artists: groups[$0] ?? []) })
    }

    /// The track's (or artist's) radio, as a playlist uri to play.
    func radio(seedUri: Uri) async throws -> Uri? {
        let r = try await http.getJSON("https://spclient.wg.spotify.com/inspiredby-mix/v2/seed_to_playlist/\(seedUri)?response-format=json")
        return r.list("mediaItems").first?.str("uri")
    }
}
