// Orpheon for iOS: a port of Orpheon (https://github.com/kota-zo/Orpheon, formerly Myspoti), GPL-3.0.
// Derived from the Kotlin sources by kota-zo and contributors. Keep these notices; if you ever
// distribute this, publish your complete source under GPL-3.0 (see LICENSE and NOTICE.md).
import Foundation

// GraphQL entities (search, catalog, playlists) -> app models.

func mapImages(_ sources: [JSON]) -> [CoverImage] {
    sources.compactMap { s in
        guard let url = s.str("url") else { return nil }
        let w = s.int("width") ?? s.int("maxWidth").flatMap { $0 > 0 ? $0 : nil }
        let h = s.int("height") ?? s.int("maxHeight").flatMap { $0 > 0 ? $0 : nil }
        return CoverImage(url: url, width: w, height: h)
    }
}

func mapArtistRefs(_ node: JSON?) -> [ArtistRef] {
    node.list("items").compactMap { a in
        guard let uri = a.str("uri") else { return nil }
        return ArtistRef(uri: uri, name: a.str("profile.name") ?? a.str("name") ?? "")
    }
}

/// A local file of a Spotify playlist: a song the user's desktop app added from its own disk.
/// Spotify keeps only its tags, in the uri: `spotify:local:{artist}:{album}:{title}:{seconds}`.
enum LocalFile {
    static let prefix = "spotify:local:"

    static func isLocal(_ uri: Uri) -> Bool { uri.hasPrefix(prefix) }

    static func track(_ uri: Uri, uid: String? = nil) -> Track? {
        guard isLocal(uri) else { return nil }
        let rest = String(uri.dropFirst(prefix.count))
        let parts = rest.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        func decode(_ s: String) -> String {
            s.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? s
        }
        func part(_ i: Int) -> String { i < parts.count ? decode(parts[i]) : "" }
        let artist = part(0)
        let album = part(1)
        let seconds = parts.last.flatMap { Int64($0) }
        let title: String
        if parts.count >= 4, seconds != nil {
            title = parts[2..<(parts.count - 1)].map(decode).joined(separator: ":")
        } else {
            title = part(2)
        }
        return Track(
            uri: uri, name: title, durationMs: (seconds ?? 0) * 1000,
            artists: artist.trimmingCharacters(in: .whitespaces).isEmpty ? [] : [ArtistRef(uri: "", name: artist)],
            album: album.trimmingCharacters(in: .whitespaces).isEmpty ? nil : AlbumRef(uri: "", name: album),
            playable: false, uid: uid)
    }
}

/// A `Track` entity from search, getTrack or a playlist row (`itemV2.data`).
func mapTrack(_ d: JSON?, uid: String? = nil) -> Track? {
    guard let uri = d.str("uri"), uri.hasPrefix("spotify:track:") else { return nil }
    let album = d.obj("albumOfTrack")
    var artists = mapArtistRefs(d.obj("artists"))
    if artists.isEmpty { artists = mapArtistRefs(d.obj("firstArtist")) + mapArtistRefs(d.obj("otherArtists")) }
    return Track(
        uri: uri,
        name: d.str("name") ?? "",
        durationMs: d.long("duration.totalMilliseconds") ?? d.long("trackDuration.totalMilliseconds") ?? 0,
        artists: artists,
        album: album.map { a in
            AlbumRef(uri: a.str("uri") ?? "", name: a.str("name") ?? "", images: mapImages(a.list("coverArt.sources")))
        },
        explicit: d.str("contentRating.label") == "EXPLICIT",
        playable: d.bool("playability.playable") ?? true,
        uid: uid,
        hasVideo: (d.long("associationsV3.videoAssociations.totalCount") ?? 0) > 0)
}

/// A playlist row: a track, or an episode shaped as a `Track` (show name as the artist, show art as the album).
func mapPlaylistItem(_ d: JSON?, uid: String? = nil) -> Track? {
    let uri = d.str("uri")
    if let uri = uri, LocalFile.isLocal(uri) {
        guard var local = LocalFile.track(uri, uid: uid) else { return nil }
        if let n = d.str("name"), !n.trimmingCharacters(in: .whitespaces).isEmpty { local.name = n }
        local.durationMs = d.long("trackDuration.totalMilliseconds") ?? d.long("duration.totalMilliseconds") ?? local.durationMs
        return local
    }
    guard let u = uri, u.hasPrefix("spotify:episode:") else { return mapTrack(d, uid: uid) }
    guard let e = mapEpisode(d) else { return nil }
    let cover = e.images.isEmpty ? (e.show?.images ?? []) : e.images
    return Track(
        uri: e.uri, name: e.name, durationMs: e.durationMs,
        artists: e.show.map { [ArtistRef(uri: $0.uri, name: $0.name)] } ?? [],
        album: AlbumRef(uri: "", name: e.show?.name ?? "", images: cover),
        explicit: e.explicit, playable: e.playable, uid: uid)
}

func mapArtist(_ d: JSON?) -> Artist? {
    guard let uri = d.str("uri") else { return nil }
    return Artist(
        uri: uri,
        name: d.str("profile.name") ?? "",
        images: mapImages(d.list("visuals.avatarImage.sources")),
        followers: d.long("stats.followers"),
        monthlyListeners: d.long("stats.monthlyListeners"),
        verified: d.bool("profile.verified") ?? false)
}

func mapAlbum(_ d: JSON?) -> Album? {
    guard let uri = d.str("uri") else { return nil }
    var copyrights: [String] = []
    for c in d.list("copyright.items") {
        guard let raw = c.str("text")?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { continue }
        // "C" is the copyright, "P" the sound recording's; the text often carries its sign already.
        var sign: String? = nil
        switch c.str("type") {
        case "P": sign = "℗"
        case "C": sign = "©"
        default: break
        }
        let line: String
        if let s = sign, !(raw.hasPrefix("©") || raw.hasPrefix("℗") || raw.hasPrefix("(C)") || raw.hasPrefix("(P)")) {
            line = "\(s) \(raw)"
        } else {
            line = raw
        }
        if !copyrights.contains(line) { copyrights.append(line) }
    }
    return Album(
        uri: uri,
        name: d.str("name") ?? "",
        artists: mapArtistRefs(d.obj("artists")),
        images: mapImages(d.list("coverArt.sources")),
        type: d.str("type") ?? "ALBUM",
        releaseDate: d.str("date.isoString") ?? d.long("date.year").map { String($0) },
        trackCount: d.int("tracksV2.totalCount") ?? d.int("tracks.totalCount") ?? 0,
        label: d.str("label"),
        copyrights: copyrights)
}

func mapPlaylist(_ d: JSON?) -> Playlist? {
    guard let raw = d.str("uri") else { return nil }
    let uri = canonicalUri(raw)
    return Playlist(
        uri: uri,
        name: d.str("name") ?? "",
        description: d.str("description").flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 },
        owner: d.str("ownerV2.data.name"),
        images: d.list("images.items").flatMap { mapImages($0.list("sources")) },
        trackCount: d.int("content.totalCount") ?? 0,
        editable: d.bool("currentUserCapabilities.canEditItems") ?? false,
        ownerUri: d.str("ownerV2.data.uri"),
        ownerImages: mapImages(d.list("ownerV2.data.avatar.sources")),
        followers: d.long("followers"),
        isBlend: d.str("format") == "blend",
        canLeave: d.bool("currentUserCapabilities.canCancelMembership") ?? false)
}

/// Search tab pages: `{items[], totalCount, pagingInfo{nextOffset}}`.
func mapPage<T>(_ node: JSON?, offset: Int, _ map: (JSON) -> T?) -> Page<T> {
    let rows = node.list("items")
    let items = rows.compactMap(map)
    let total = node.int("totalCount") ?? items.count
    // Raw row count, as in the library: unmappable rows still occupy positions.
    var next = node.int("pagingInfo.nextOffset")
    if next == nil {
        let n = offset + rows.count
        if !rows.isEmpty && n < total { next = n }
    }
    return Page(items: items, offset: offset, total: total, nextOffset: next)
}

// MARK: - Cards and podcast entities

/// Any `*ResponseWrapper` (or its `data`) -> a card for shelves and search tabs.
func mapCard(_ wrapper: JSON?) -> MediaCard? {
    let d = wrapper.obj("data") ?? wrapper
    guard let rawUri = d.str("uri") ?? wrapper.str("_uri") ?? wrapper.str("uri") else { return nil }
    let uri = canonicalUri(rawUri)
    let type = d.typename()
    var kind = MediaKind.of(uri)
    if type == "Audiobook" { kind = .audiobook }
    guard let title = d.str("name") ?? d.str("profile.name") ?? d.str("displayName")
            ?? d.str("title.transformedLabel") ?? d.str("title") else { return nil }
    func joined(_ refs: [ArtistRef]) -> String? {
        let s = refs.map { $0.name }.joined(separator: ", ")
        return s.trimmingCharacters(in: .whitespaces).isEmpty ? nil : s
    }
    var subtitle: String?
    switch type {
    case "Playlist": subtitle = d.str("ownerV2.data.name") ?? d.str("description")
    case "Album", "Track": subtitle = joined(mapArtistRefs(d.obj("artists")))
    case "Podcast": subtitle = d.str("publisher.name")
    case "Audiobook":
        let s = d.list("authorsV2").compactMap { $0.str("name") }.joined(separator: ", ")
        subtitle = s.isEmpty ? nil : s
    case "Episode", "Chapter": subtitle = d.str("podcastV2.data.name")
    case "PseudoPlaylist": subtitle = d.int("count").map { String($0) }
    default: subtitle = nil
    }
    var sources = d.list("coverArt.sources")
    if sources.isEmpty { sources = d.list("visuals.avatarImage.sources") }
    if sources.isEmpty { sources = d.list("images.items").flatMap { $0.list("sources") } }
    if sources.isEmpty { sources = d.list("avatar.sources") }
    if sources.isEmpty { sources = d.list("image.sources") }
    if sources.isEmpty { sources = d.list("albumOfTrack.coverArt.sources") }
    return MediaCard(uri: uri, kind: kind, title: title, subtitle: subtitle, images: mapImages(sources))
}

func mapEpisode(_ d: JSON?) -> Episode? {
    guard let uri = d.str("uri") else { return nil }
    let show = d.obj("podcastV2.data")
    return Episode(
        uri: uri,
        name: d.str("name") ?? "",
        description: d.str("description"),
        durationMs: d.long("duration.totalMilliseconds") ?? 0,
        releaseDate: d.str("releaseDate.isoString"),
        images: mapImages(d.list("coverArt.sources")),
        show: show.map { AlbumRef(uri: $0.str("uri") ?? "", name: $0.str("name") ?? "", images: mapImages($0.list("coverArt.sources"))) },
        playedPositionMs: d.long("playedState.playPositionMilliseconds") ?? 0,
        played: d.str("playedState.state") == "COMPLETED",
        explicit: d.str("contentRating.label") == "EXPLICIT",
        playable: d.bool("playability.playable") ?? true,
        previewUrl: d.str("previewPlayback.audioPreview.cdnUrl"))
}

func mapShow(_ d: JSON?) -> Show? {
    guard let uri = d.str("uri") else { return nil }
    return Show(
        uri: uri,
        name: d.str("name") ?? "",
        publisher: d.str("publisher.name") ?? "",
        description: d.str("description"),
        images: mapImages(d.list("coverArt.sources")),
        saved: d.bool("saved") ?? false,
        rating: d.double("rating.averageRating.average"),
        topics: d.list("topics.items").compactMap { $0.str("title") })
}

/// Discography and "appears on" rows hold `releases.items[0]`.
func mapRelease(_ row: JSON?) -> Album? {
    mapAlbum(row.list("releases.items").first ?? row)
}

/// Promotions and ads (HomePromotionShelf, sponsored cards...): never shown as content.
func isPromotion(_ typename: String?) -> Bool {
    guard let t = typename else { return false }
    let re = try! NSRegularExpression(pattern: "Promotion|Sponsor|Advert|(^|[a-z])Ad([A-Z]|$)")
    return re.firstMatch(in: t, range: NSRange(location: 0, length: (t as NSString).length)) != nil
}

func mapShelf(_ section: JSON) -> Shelf? {
    if isPromotion(section.at("data").typename()) || isPromotion(section.typename()) { return nil }
    let items = section.list("sectionItems.items")
        .filter { !isPromotion($0.at("content").typename()) && !isPromotion($0.at("content.data").typename()) }
        .compactMap { mapCard($0.at("content")) }
    if items.isEmpty { return nil }
    return Shelf(
        uri: section.str("uri"),
        title: section.str("data.title.transformedLabel") ?? section.str("data.title.text"),
        items: items,
        total: section.int("sectionItems.totalCount") ?? items.count)
}

func mapHomeChip(_ c: JSON) -> HomeChip? {
    guard let id = c.str("id"), !id.trimmingCharacters(in: .whitespaces).isEmpty,
          let label = c.str("label.transformedLabel"), !label.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
    return HomeChip(id: id, label: label, subChips: c.list("subChips").compactMap(mapHomeChip))
}

/// The entity at `path`, or an error when the server says it does not exist.
extension JSON {
    func entity(_ path: String, _ op: String) throws -> JSON {
        guard let e = at(path) else { throw SpotifyError.gql(op, "no \(path)") }
        if e.typename() == "NotFound" { throw SpotifyError.gql(op, "not found") }
        return e
    }
}
