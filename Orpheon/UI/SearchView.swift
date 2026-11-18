// Orpheon for iOS: a port of Orpheon (https://github.com/kota-zo/Orpheon, formerly Myspoti), GPL-3.0.
// Derived from the Kotlin sources by kota-zo and contributors. Keep these notices; if you ever
// distribute this, publish your complete source under GPL-3.0 (see LICENSE and NOTICE.md).
import SwiftUI

enum SearchScope: String, CaseIterable, Identifiable {
    case all = "All", songs = "Songs", artists = "Artists", albums = "Albums", playlists = "Playlists", podcasts = "Podcasts"
    var id: String { rawValue }
}

struct SearchPayload {
    var summary: SearchResults?
    var tracks: [Track] = []
    var artists: [Artist] = []
    var albums: [Album] = []
    var playlists: [Playlist] = []
    var shows: [MediaCard] = []
    var next: Int? = nil
}

@MainActor
struct SearchView: View {
    @EnvironmentObject var env: AppEnvironment
    @EnvironmentObject var playback: PlaybackManager
    @State private var query = ""
    @State private var scope: SearchScope = .all
    @State private var payload = SearchPayload()
    @State private var loading = false
    @State private var error: String?
    @State private var generation = 0
    @State private var categories: [Category] = []
    @State private var recents: [MediaCard] = []

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if query.trimmingCharacters(in: .whitespaces).isEmpty {
                        browse
                    } else {
                        scopeBar
                        results
                    }
                }
                .padding(.vertical, 12)
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("Search")
            .searchable(text: $query, prompt: "Artists, songs, podcasts")
            .onChange(of: query) { _ in scheduleSearch() }
            .onChange(of: scope) { _ in scheduleSearch(immediately: true) }
            .onSubmit(of: .search) { scheduleSearch(immediately: true) }
        }
        .navigationViewStyle(.stack)
        .miniPlayerInset()
        .task { await loadBrowse() }
    }

    // MARK: Empty state

    private var browse: some View {
        VStack(alignment: .leading, spacing: 20) {
            if !recents.isEmpty {
                SectionTitle(text: "Recent searches")
                ForEach(recents.prefix(8)) { card in
                    recentRow(card)
                }
            }
            if !categories.isEmpty {
                SectionTitle(text: "Browse all")
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    ForEach(categories) { c in
                        NavigationLink(destination: CategoryView(uri: c.uri)) {
                            categoryTile(c)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private func recentRow(_ card: MediaCard) -> some View {
        Group {
            if let route = Route.from(card: card) {
                NavigationLink(destination: RouteView(route: route)) { recentLabel(card) }
                    .buttonStyle(.plain)
            } else {
                Button {
                    Task { await playback.play(uris: [card.uri]) }
                } label: { recentLabel(card) }
                .buttonStyle(.plain)
            }
        }
    }

    private func recentLabel(_ card: MediaCard) -> some View {
        HStack(spacing: 12) {
            Artwork(url: card.images.bestUrl(minPx: 120), size: 48, circle: card.kind == .artist)
            VStack(alignment: .leading, spacing: 2) {
                Text(card.title).foregroundColor(.white).lineLimit(1)
                if let s = card.subtitle {
                    Text(s).font(.caption).foregroundColor(Theme.secondary).lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 16)
    }

    private func categoryTile(_ c: Category) -> some View {
        ZStack(alignment: .topLeading) {
            Theme.elevated
            Text(c.title)
                .font(.headline)
                .foregroundColor(.white)
                .padding(10)
        }
        .frame(height: 90)
        .cornerRadius(8)
    }

    // MARK: Results

    private var scopeBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(SearchScope.allCases) { s in
                    PillButton(title: s.rawValue, selected: scope == s) { scope = s }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    @ViewBuilder
    private var results: some View {
        if let e = error, payload.tracks.isEmpty && payload.summary == nil && payload.artists.isEmpty && payload.albums.isEmpty && payload.playlists.isEmpty && payload.shows.isEmpty {
            ErrorView(message: e, retry: { scheduleSearch(immediately: true) })
        } else if loading && isEmpty {
            ProgressView().frame(maxWidth: .infinity, minHeight: 200)
        } else {
            switch scope {
            case .all: allResults
            case .songs: songResults
            case .artists: artistResults
            case .albums: albumResults
            case .playlists: playlistResults
            case .podcasts: podcastResults
            }
        }
    }

    private var isEmpty: Bool {
        payload.summary == nil && payload.tracks.isEmpty && payload.artists.isEmpty && payload.albums.isEmpty && payload.playlists.isEmpty && payload.shows.isEmpty
    }

    @ViewBuilder
    private var allResults: some View {
        if let s = payload.summary {
            VStack(alignment: .leading, spacing: 22) {
                if !s.tracks.items.isEmpty {
                    SectionTitle(text: "Songs")
                    ForEach(Array(s.tracks.items.prefix(5).enumerated()), id: \.offset) { _, t in
                        TrackRow(track: t) { Task { await playback.play(track: t) } }
                            .padding(.horizontal, 16)
                    }
                }
                if !s.artists.items.isEmpty {
                    SectionTitle(text: "Artists")
                    cardRow(s.artists.items.map { MediaCard(uri: $0.uri, kind: .artist, title: $0.name, subtitle: "Artist", images: $0.images) })
                }
                if !s.albums.items.isEmpty {
                    SectionTitle(text: "Albums")
                    cardRow(s.albums.items.map { MediaCard(uri: $0.uri, kind: .album, title: $0.name, subtitle: $0.artistLine, images: $0.images) })
                }
                if !s.playlists.items.isEmpty {
                    SectionTitle(text: "Playlists")
                    cardRow(s.playlists.items.map { MediaCard(uri: $0.uri, kind: .playlist, title: $0.name, subtitle: $0.owner, images: $0.images) })
                }
            }
        } else {
            EmptyView()
        }
    }

    private func cardRow(_ cards: [MediaCard]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 14) {
                ForEach(cards) { c in CardLink(card: c) }
            }
            .padding(.horizontal, 16)
        }
    }

    private var songResults: some View {
        LazyVStack(alignment: .leading, spacing: 8) {
            ForEach(Array(payload.tracks.enumerated()), id: \.offset) { i, t in
                TrackRow(track: t) {
                    Task { await playback.play(tracks: payload.tracks, startIndex: i) }
                }
                .padding(.horizontal, 16)
                .onAppear { loadMoreIfNeeded(i, count: payload.tracks.count) }
            }
        }
    }

    private var artistResults: some View {
        LazyVStack(alignment: .leading, spacing: 8) {
            ForEach(Array(payload.artists.enumerated()), id: \.offset) { i, a in
                NavigationLink(destination: ArtistView(uri: a.uri)) {
                    HStack(spacing: 12) {
                        Artwork(url: a.images.bestUrl(minPx: 120), size: 56, circle: true)
                        Text(a.name).foregroundColor(.white).lineLimit(1)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                }
                .buttonStyle(.plain)
                .onAppear { loadMoreIfNeeded(i, count: payload.artists.count) }
            }
        }
    }

    private var albumResults: some View {
        LazyVStack(alignment: .leading, spacing: 8) {
            ForEach(Array(payload.albums.enumerated()), id: \.offset) { i, a in
                NavigationLink(destination: AlbumView(uri: a.uri)) {
                    HStack(spacing: 12) {
                        Artwork(url: a.images.bestUrl(minPx: 120), size: 56)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(a.name).foregroundColor(.white).lineLimit(1)
                            Text([a.year, a.artistLine].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundColor(Theme.secondary).lineLimit(1)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                }
                .buttonStyle(.plain)
                .onAppear { loadMoreIfNeeded(i, count: payload.albums.count) }
            }
        }
    }

    private var playlistResults: some View {
        LazyVStack(alignment: .leading, spacing: 8) {
            ForEach(Array(payload.playlists.enumerated()), id: \.offset) { i, p in
                NavigationLink(destination: PlaylistView(uri: p.uri)) {
                    HStack(spacing: 12) {
                        Artwork(url: p.images.bestUrl(minPx: 120), size: 56)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.name).foregroundColor(.white).lineLimit(1)
                            Text(p.owner ?? "Playlist").font(.caption).foregroundColor(Theme.secondary).lineLimit(1)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                }
                .buttonStyle(.plain)
                .onAppear { loadMoreIfNeeded(i, count: payload.playlists.count) }
            }
        }
    }

    private var podcastResults: some View {
        LazyVStack(alignment: .leading, spacing: 8) {
            ForEach(Array(payload.shows.enumerated()), id: \.offset) { i, c in
                NavigationLink(destination: ShowView(uri: c.uri)) {
                    HStack(spacing: 12) {
                        Artwork(url: c.images.bestUrl(minPx: 120), size: 56)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.title).foregroundColor(.white).lineLimit(1)
                            Text(c.subtitle ?? "Podcast").font(.caption).foregroundColor(Theme.secondary).lineLimit(1)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                }
                .buttonStyle(.plain)
                .onAppear { loadMoreIfNeeded(i, count: payload.shows.count) }
            }
        }
    }

    // MARK: Loading

    private func loadBrowse() async {
        if categories.isEmpty { categories = (try? await env.service.categories()) ?? [] }
        recents = (try? await env.service.recentSearches()) ?? []
    }

    private func scheduleSearch(immediately: Bool = false) {
        generation += 1
        let mine = generation
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty {
            payload = SearchPayload()
            error = nil
            return
        }
        Task {
            if !immediately { try? await Task.sleep(nanoseconds: 400_000_000) }
            if mine != generation { return }
            await run(q, generation: mine)
        }
    }

    private func run(_ q: String, generation mine: Int) async {
        loading = true
        error = nil
        defer { if mine == generation { loading = false } }
        do {
            var fresh = SearchPayload()
            switch scope {
            case .all:
                fresh.summary = try await env.service.searchAll(q, limit: 10)
            case .songs:
                let p = try await env.service.searchTracks(q, offset: 0, limit: 30)
                fresh.tracks = p.items; fresh.next = p.nextOffset
            case .artists:
                let p = try await env.service.searchArtists(q, offset: 0, limit: 30)
                fresh.artists = p.items; fresh.next = p.nextOffset
            case .albums:
                let p = try await env.service.searchAlbums(q, offset: 0, limit: 30)
                fresh.albums = p.items; fresh.next = p.nextOffset
            case .playlists:
                let p = try await env.service.searchPlaylists(q, offset: 0, limit: 30)
                fresh.playlists = p.items; fresh.next = p.nextOffset
            case .podcasts:
                let p = try await env.service.searchShows(q, offset: 0, limit: 30)
                fresh.shows = p.items; fresh.next = p.nextOffset
            }
            if mine == generation { payload = fresh }
        } catch {
            if mine == generation { self.error = describe(error) }
        }
    }

    private func loadMoreIfNeeded(_ index: Int, count: Int) {
        guard index >= count - 4, let offset = payload.next, !loading else { return }
        let q = query.trimmingCharacters(in: .whitespaces)
        let mine = generation
        loading = true
        Task {
            defer { loading = false }
            do {
                switch scope {
                case .songs:
                    let p = try await env.service.searchTracks(q, offset: offset, limit: 30)
                    if mine == generation { payload.tracks += p.items; payload.next = p.nextOffset }
                case .artists:
                    let p = try await env.service.searchArtists(q, offset: offset, limit: 30)
                    if mine == generation { payload.artists += p.items; payload.next = p.nextOffset }
                case .albums:
                    let p = try await env.service.searchAlbums(q, offset: offset, limit: 30)
                    if mine == generation { payload.albums += p.items; payload.next = p.nextOffset }
                case .playlists:
                    let p = try await env.service.searchPlaylists(q, offset: offset, limit: 30)
                    if mine == generation { payload.playlists += p.items; payload.next = p.nextOffset }
                case .podcasts:
                    let p = try await env.service.searchShows(q, offset: offset, limit: 30)
                    if mine == generation { payload.shows += p.items; payload.next = p.nextOffset }
                case .all:
                    break
                }
            } catch {
                payload.next = nil
            }
        }
    }
}
