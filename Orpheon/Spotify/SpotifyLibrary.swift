// Orpheon for iOS: a port of Orpheon (https://github.com/kota-zo/Orpheon, formerly Myspoti), GPL-3.0.
// Derived from the Kotlin sources by kota-zo and contributors. Keep these notices; if you ever
// distribute this, publish your complete source under GPL-3.0 (see LICENSE and NOTICE.md).
import Foundation

private let containsBatch = 30
private let playlistCacheMs: Int64 = 60_000

extension JSON {
    /// This object with one more key (used to patch a row that lacks its uri).
    func with(_ key: String, _ value: JSON) -> JSON {
        guard case .object(var o) = self else { return self }
        o[key] = value
        return .object(o)
    }
}

/// The id of the shows filter among the `offered` ids of the library (the ids are fixed words, the
/// names are localised). "Podcasts" when none offered looks like one.
func podcastFilterId(_ offered: [String]) -> String {
    if let e = offered.first(where: { $0.lowercased() == "podcasts" }) { return e }
    if let e = offered.first(where: { id in ["podcast", "show"].contains { id.lowercased().contains($0) } }) { return e }
    return "Podcasts"
}

/// Folders have two uri forms: `...:folder:{hash}` (stable, used by the library list) and
/// `...:folder:{hash}:{name}` in the rootlist, which changes on rename.
func stableFolderUri(_ uri: Uri) -> Uri {
    guard let r = uri.range(of: ":folder:") else { return uri }
    let rest = uri[r.upperBound...]
    let hash = rest.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? String(rest)
    return String(uri[..<r.lowerBound]) + ":folder:" + hash
}

// MARK: - Library

extension SpotifyService {
    private func libraryV3(filters: [String], sort: LibrarySort, folderUri: Uri?, offset: Int, limit: Int, flatten: Bool = false) async throws -> JSON {
        let r = try await gql.query("libraryV3", vars([
            "filters": filters,
            "order": sort.gqlId,
            "textFilter": "",
            "features": ["LIKED_SONGS", "YOUR_EPISODES_V2", "PRERELEASES", "PRERELEASES_V2", "CLIPS", "EVENTS"],
            "limit": limit, "offset": offset,
            "flatten": flatten, "expandedFolders": [String](),
            "folderUri": folderUri, "includeFoldersWhenFlattening": true,
        ]))
        let lib = try r.entity("data.me.libraryV3", "libraryV3")
        offeredFilters = lib.list("availableFilters").compactMap { $0.str("id") }
        return lib
    }

    private func offeredFilterIds() async throws -> [String] {
        if let o = offeredFilters { return o }
        _ = try await libraryV3(filters: [], sort: .recents, folderUri: nil, offset: 0, limit: 1)
        return offeredFilters ?? []
    }

    /// The "Your Library" list, as the Web Player shows it. `folderUri` opens a folder.
    func libraryItems(filter: LibraryFilter = .all, sort: LibrarySort = .recents, folderUri: Uri? = nil,
                      offset: Int = 0, limit: Int = 50) async throws -> Page<LibraryItem> {
        var filterId = filter.gqlId
        if filter == .podcasts { filterId = podcastFilterId(try await offeredFilterIds()) }
        let lib = try await libraryV3(filters: filterId.map { [$0] } ?? [], sort: sort, folderUri: folderUri, offset: offset, limit: limit)
        let rows = lib.list("items")
        let items: [LibraryItem] = rows.compactMap { row in
            guard let c = mapCard(row.at("item")) else { return nil }
            let d = row.at("item.data")
            let kind: MediaKind = d.typename() == "Folder" ? .folder : c.kind
            var count = d.int("count")
            if let pc = d.int("playlistCount") { count = pc + (d.int("folderCount") ?? 0) }
            return LibraryItem(
                uri: kind == .folder ? stableFolderUri(c.uri) : c.uri,
                kind: kind, name: c.title, subtitle: c.subtitle, images: c.images,
                pinned: row.bool("pinned") ?? false, addedAt: row.str("addedAt.isoString"),
                count: count, ownerUri: d.str("ownerV2.data.uri"))
        }
        let total = lib.int("totalCount") ?? items.count
        let n = offset + rows.count
        return Page(items: items, offset: offset, total: total, nextOffset: (!rows.isEmpty && n < total) ? n : nil)
    }

    func likedTracks(offset: Int = 0, limit: Int = 50) async throws -> Page<SavedTrack> {
        let r = try await gql.query("fetchLibraryTracks", vars(["offset": offset, "limit": limit]))
        let page = r.at("data.me.library.tracks")
        let rows = page.list("items")
        let items: [SavedTrack] = rows.compactMap { row in
            var data = row.at("track.data")
            if data.str("uri") == nil, let u = row.str("track._uri"), let d = data {
                data = d.with("uri", .string(u))
            }
            guard let t = mapTrack(data) else { return nil }
            return SavedTrack(track: t, addedAt: row.str("addedAt.isoString"))
        }
        let total = page.int("totalCount") ?? items.count
        let n = offset + rows.count
        return Page(items: items, offset: offset, total: total, nextOffset: (!rows.isEmpty && n < total) ? n : nil)
    }

    func pin(_ uri: Uri) async throws { _ = try await gql.query("pinLibraryItem", vars(["pinnableItemUri": uri])) }
    func unpin(_ uri: Uri) async throws { _ = try await gql.query("unpinLibraryItem", vars(["pinnableItemUri": uri])) }

    /// Playlist uris in the library (followed and own), cached for a minute.
    func libraryPlaylistUris(force: Bool = false) async throws -> Set<String> {
        if !force, let c = playlistUriCache, nowMs() - c.at < playlistCacheMs { return c.uris }
        let list = try await myPlaylists()
        let set = Set(list.map { $0.uri })
        playlistUriCache = (nowMs(), set)
        return set
    }

    /// Whether each uri (track, album, artist, show, episode, playlist) is saved, in the same order.
    func contains(_ uris: [Uri]) async throws -> [Bool] {
        if uris.isEmpty { return [] }
        var out = [Bool](repeating: false, count: uris.count)
        var tracks: [(Int, Uri)] = []
        var others: [(Int, Uri)] = []
        var lists: [(Int, Uri)] = []
        for (i, u) in uris.enumerated() {
            if u.contains(":playlist:") { lists.append((i, u)) }
            else if u.hasPrefix("spotify:track:") { tracks.append((i, u)) }
            else { others.append((i, u)) }
        }
        // In batches: a long list is answered only in part, and a missing answer must not read as "not liked".
        var start = 0
        while start < tracks.count {
            let batch = Array(tracks[start..<Swift.min(start + containsBatch, tracks.count)])
            let r = try await gql.query("isCurated", vars(["uris": batch.map { $0.1 }]))
            let flags = r.list("data.lookup")
            for (k, item) in batch.enumerated() where k < flags.count {
                out[item.0] = flags[k].bool("data.isCurated") ?? false
            }
            start += containsBatch
        }
        start = 0
        while start < others.count {
            let batch = Array(others[start..<Swift.min(start + containsBatch, others.count)])
            let r = try await gql.query("areEntitiesInLibrary", vars(["uris": batch.map { $0.1 }]))
            let flags = r.list("data.lookup")
            for (k, item) in batch.enumerated() where k < flags.count {
                out[item.0] = flags[k].bool("data.saved") ?? false
            }
            start += containsBatch
        }
        if !lists.isEmpty {
            let set = try await libraryPlaylistUris()
            for (i, u) in lists { out[i] = set.contains(canonicalUri(u)) }
        }
        return out
    }

    func addToLibrary(_ uris: [Uri]) async throws {
        let plain = uris.filter { !$0.contains(":playlist:") }
        let lists = uris.filter { $0.contains(":playlist:") }
        if !plain.isEmpty {
            _ = try await gql.query("addToLibrary", vars(["libraryItemUris": plain, "interactionId": UUID().uuidString.lowercased()]))
        }
        for l in lists { try await followPlaylist(l) }
    }

    func removeFromLibrary(_ uris: [Uri]) async throws {
        let plain = uris.filter { !$0.contains(":playlist:") }
        let lists = uris.filter { $0.contains(":playlist:") }
        if !plain.isEmpty {
            _ = try await gql.query("removeFromLibrary", vars(["libraryItemUris": plain]))
        }
        for l in lists { try await unfollowPlaylist(l) }
    }

    // MARK: Playlists (reads)

    func playlist(_ uri: Uri) async throws -> Playlist {
        let r = try await gql.query("fetchPlaylist", vars([
            "uri": uri, "offset": 0, "limit": 1, "enableWatchFeedEntrypoint": false, "includeEpisodeContentRatingsV2": true,
        ]))
        guard let p = mapPlaylist(try r.entity("data.playlistV2", "fetchPlaylist")) else { throw SpotifyError.gql("fetchPlaylist", "bad playlist") }
        return p
    }

    func playlistTracks(_ uri: Uri, offset: Int = 0, limit: Int = 100) async throws -> Page<Track> {
        let r = try await gql.query("fetchPlaylistContents", vars([
            "uri": uri, "offset": offset, "limit": limit, "includeEpisodeContentRatingsV2": true,
        ]))
        let p = try r.entity("data.playlistV2", "fetchPlaylistContents")
        let content = p.at("content")
        let items: [Track] = content.list("items").compactMap { row in
            guard var t = mapPlaylistItem(row.at("itemV2.data"), uid: row.str("uid")) else { return nil }
            t.addedAt = row.str("addedAt.isoString")
            return t
        }
        let total = content.int("totalCount") ?? items.count
        let n = offset + limit
        return Page(items: items, offset: offset, total: total, nextOffset: n < total ? n : nil)
    }

    /// Pages through the whole playlist (100 rows a request); the caller sorts it.
    func allPlaylistTracks(_ uri: Uri, maxRows: Int = 5000) async throws -> [Track] {
        var all: [Track] = []
        var offset: Int? = 0
        while let o = offset, all.count < maxRows {
            let page = try await playlistTracks(uri, offset: o, limit: 100)
            if page.items.isEmpty { break }
            all += page.items
            offset = page.nextOffset
        }
        return all
    }

    /// The user's own playlists and the ones they follow, in library order, folders flattened.
    func myPlaylists() async throws -> [Playlist] {
        var out: [Playlist] = []
        var offset = 0
        var pages = 0
        let me = try? await ownUsername()
        while pages < 40 {
            let lib = try await libraryV3(filters: ["Playlists"], sort: .recents, folderUri: nil, offset: offset, limit: 50, flatten: true)
            let rows = lib.list("items")
            for row in rows {
                guard let c = mapCard(row.at("item")), c.uri.hasPrefix("spotify:playlist:") else { continue }
                let d = row.at("item.data")
                let ownerUri = d.str("ownerV2.data.uri")
                let mine = me != nil && ownerUri == "spotify:user:\(me!)"
                out.append(Playlist(
                    uri: c.uri, name: c.title, description: nil, owner: d.str("ownerV2.data.name") ?? c.subtitle,
                    images: c.images, trackCount: d.int("content.totalCount") ?? 0,
                    editable: mine || (d.bool("currentUserCapabilities.canEditItems") ?? false),
                    ownerUri: ownerUri))
            }
            let total = lib.int("totalCount") ?? out.count
            offset += rows.count
            pages += 1
            if rows.isEmpty || offset >= total { break }
        }
        return out
    }

    /// Playlists the user may add tracks to (the "Add to playlist" sheet). `curates` says the track is already in it.
    func editablePlaylists(trackUri: Uri? = nil) async throws -> [(playlist: MediaCard, contains: Bool)] {
        var out: [(playlist: MediaCard, contains: Bool)] = []
        var offset = 0
        for _ in 0..<10 {
            let r = try await gql.query("editablePlaylists", vars([
                "offset": offset, "limit": 50, "textFilter": "", "uris": trackUri.map { [$0] } ?? [String](),
            ]))
            let page = r.at("data.me.editablePlaylists")
            let rows = page.list("items")
            for row in rows {
                guard let c = mapCard(row.at("item")) else { continue }
                out.append((c, row.bool("curates") ?? false))
            }
            let total = page.int("totalCount") ?? out.count
            offset += rows.count
            if rows.isEmpty || offset >= total { break }
        }
        return out
    }

    /// Tracks Spotify suggests adding at the bottom of a playlist (playlistextender).
    func recommended(_ uri: Uri, limit: Int = 10, skip: [Uri] = []) async throws -> [Track] {
        let body = vars(["playlistURI": uri, "trackSkipIDs": skip.map { idOf($0) }, "numResults": limit])
        let (code, data) = try await http.send("POST", "https://spclient.wg.spotify.com/playlistextender/extendp/", body: body.jsonData(), contentType: "application/json")
        guard code == 200 else { throw SpotifyError.http(code, String(data: data.prefix(200), encoding: .utf8) ?? "") }
        let json = try JSON.parse(data)
        return json.list("recommendedTracks").compactMap { t in
            guard let u = t.str("originalId") ?? t.str("id").map({ "spotify:track:\($0)" }) else { return nil }
            let artists: [ArtistRef] = t.list("artists").compactMap { a in
                guard let id = a.str("id") else { return nil }
                return ArtistRef(uri: "spotify:artist:\(id)", name: a.str("name") ?? "")
            }
            var album: AlbumRef?
            if let a = t.obj("album") {
                var imgs: [CoverImage] = []
                if let l = a.str("largeImageUrl") { imgs.append(CoverImage(url: l, width: 640, height: 640)) }
                if let s = a.str("imageUrl") { imgs.append(CoverImage(url: s, width: 300, height: 300)) }
                album = AlbumRef(uri: "spotify:album:" + (a.str("id") ?? ""), name: a.str("name") ?? "", images: imgs)
            }
            return Track(uri: u, name: t.str("name") ?? "", durationMs: t.long("duration") ?? 0, artists: artists, album: album, explicit: t.bool("explicit") ?? false)
        }
    }

    // MARK: Playlists (writes)

    /// At most 100 songs a request, each at the bottom, so a whole album or playlist keeps its order.
    func addTracks(to playlist: Uri, trackUris: [Uri]) async throws {
        var i = 0
        while i < trackUris.count {
            let chunk = Array(trackUris[i..<Swift.min(i + 100, trackUris.count)])
            _ = try await gql.query("addToPlaylist", vars([
                "playlistItemUris": chunk, "playlistUri": playlist,
                "newPosition": ["moveType": "BOTTOM_OF_PLAYLIST", "fromUid": nil as String?],
                "interactionId": UUID().uuidString.lowercased(),
            ]))
            i += 100
        }
    }

    /// Rows are addressed by `Track.uid`.
    func removeTracks(from playlist: Uri, uids: [String]) async throws {
        _ = try await gql.query("removeFromPlaylist", vars(["playlistUri": playlist, "uids": uids]))
    }

    func moveTracks(in playlist: Uri, uids: [String], beforeUid: String?) async throws {
        let position: [String: Any?] = beforeUid == nil
            ? ["moveType": "BOTTOM_OF_PLAYLIST", "fromUid": nil as String?]
            : ["moveType": "BEFORE_UID", "fromUid": beforeUid]
        _ = try await gql.query("moveItemsInPlaylist", vars(["playlistUri": playlist, "uids": uids, "newPosition": position]))
    }

    private func spclientJSON(_ method: String, _ url: String, _ body: JSON) async throws -> JSON? {
        let (code, data) = try await http.send(method, url, body: body.jsonData(), contentType: "application/json")
        guard (200..<300).contains(code) else { throw SpotifyError.http(code, String(data: data.prefix(200), encoding: .utf8) ?? "") }
        return data.isEmpty ? nil : try? JSON.parse(data)
    }

    private func rootlistChanges(_ ops: JSON) async throws {
        let user = try await ownUsername()
        let enc = user.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? user
        let body: JSON = ["deltas": [["ops": [ops], "info": ["source": ["client": "WEBPLAYER"]]]]]
        _ = try await spclientJSON("POST", "https://spclient.wg.spotify.com/playlist/v2/user/\(enc)/rootlist/changes", body)
        playlistUriCache = nil
    }

    func followPlaylist(_ uri: Uri) async throws {
        try await rootlistChanges([
            "kind": "ADD",
            "add": ["items": [["uri": .string(uri), "attributes": ["timestamp": .string(String(nowMs()))]]], "addFirst": true],
        ])
    }

    func unfollowPlaylist(_ uri: Uri) async throws {
        try await rootlistChanges(["kind": "REM", "rem": ["items": [["uri": .string(uri)]], "itemsAsKey": true]])
    }

    /// A new playlist at the top of the library.
    func createPlaylist(name: String) async throws -> Uri {
        let body: JSON = ["ops": [["kind": "UPDATE_LIST_ATTRIBUTES", "updateListAttributes": ["newAttributes": ["values": ["name": .string(name)]]]]]]
        let r = try await spclientJSON("POST", "https://spclient.wg.spotify.com/playlist/v2/playlist", body)
        guard let uri = r.str("uri") else { throw SpotifyError.gql("createPlaylist", "no uri") }
        try await followPlaylist(uri)
        return uri
    }

    private func updateListAttributes(_ uri: Uri, _ values: [String: JSON]) async throws {
        let body: JSON = ["deltas": [["ops": [["kind": "UPDATE_LIST_ATTRIBUTES", "updateListAttributes": ["newAttributes": ["values": .object(values)]]]],
                                       "info": ["source": ["client": "WEBPLAYER"]]]]]
        _ = try await spclientJSON("POST", "https://spclient.wg.spotify.com/playlist/v2/playlist/\(idOf(uri))/changes", body)
    }

    func renamePlaylist(_ uri: Uri, name: String) async throws {
        try await updateListAttributes(uri, ["name": .string(name)])
    }

    func setPlaylistDescription(_ uri: Uri, description: String) async throws {
        try await updateListAttributes(uri, ["description": .string(description)])
    }

    func deletePlaylist(_ uri: Uri) async throws { try await unfollowPlaylist(uri) }
}
