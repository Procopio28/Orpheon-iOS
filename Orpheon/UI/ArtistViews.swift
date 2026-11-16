// Orpheon for iOS: a port of Orpheon (https://github.com/kota-zo/Orpheon, formerly Myspoti), GPL-3.0.
// Derived from the Kotlin sources by kota-zo and contributors. Keep these notices; if you ever
// distribute this, publish your complete source under GPL-3.0 (see LICENSE and NOTICE.md).
import SwiftUI

// MARK: - Artist

@MainActor
struct ArtistView: View {
    @EnvironmentObject var env: AppEnvironment
    @EnvironmentObject var playback: PlaybackManager
    let uri: Uri
    @State private var state: LoadState<ArtistPage> = .loading
    @State private var following = false
    @State private var showAllTracks = false
    @State private var showBio = false

    var body: some View {
        ScrollView {
            LoadView(state: state, retry: { Task { await load() } }) { page in
                content(page)
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func content(_ page: ArtistPage) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            header(page)
            topTracks(page)
            if !page.popularReleases.isEmpty {
                albumRow("Popular releases", page.popularReleases)
            }
            NavigationLink(destination: DiscographyView(uri: uri, name: page.artist.name)) {
                HStack {
                    Text("Full discography").foregroundColor(.white)
                    Spacer()
                    Image(systemName: "chevron.right").foregroundColor(Theme.secondary)
                }
                .padding(.horizontal, 16)
            }
            .buttonStyle(.plain)
            if !page.appearsOn.isEmpty {
                albumRow("Appears on", page.appearsOn)
            }
            if !page.related.isEmpty {
                SectionTitle(text: "Fans also like")
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(page.related) { a in
                            CardLink(card: MediaCard(uri: a.uri, kind: .artist, title: a.name, subtitle: nil, images: a.images), width: 120)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
            if let bio = page.biography, !bio.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    SectionTitle(text: "About")
                    Text(bio)
                        .font(.subheadline)
                        .foregroundColor(Theme.secondary)
                        .lineLimit(showBio ? nil : 5)
                        .padding(.horizontal, 16)
                        .onTapGesture { showBio.toggle() }
                }
            }
        }
        .padding(.vertical, 12)
    }

    private func header(_ page: ArtistPage) -> some View {
        VStack(spacing: 10) {
            Artwork(url: page.artist.images.bestUrl(minPx: 600), size: 200, circle: true)
            HStack(spacing: 6) {
                Text(page.artist.name).font(.title.weight(.bold)).foregroundColor(.white)
                if page.artist.verified {
                    Image(systemName: "checkmark.seal.fill").foregroundColor(Theme.accent)
                }
            }
            if let m = page.artist.monthlyListeners {
                Text("\(compactCount(m)) monthly listeners").font(.footnote).foregroundColor(Theme.secondary)
            }
            PlayShuffleBar(
                onPlay: { Task { await playback.play(context: uri) } },
                onShuffle: { Task { await playback.playShuffled(context: uri) } })
            Button {
                toggleFollow()
            } label: {
                Text(following ? "Following" : "Follow")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 6)
                    .overlay(Capsule().stroke(Theme.secondary, lineWidth: 1))
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func topTracks(_ page: ArtistPage) -> some View {
        if !page.topTracks.isEmpty {
            let shown = showAllTracks ? page.topTracks : Array(page.topTracks.prefix(5))
            VStack(alignment: .leading, spacing: 6) {
                SectionTitle(text: "Popular")
                ForEach(Array(shown.enumerated()), id: \.offset) { i, top in
                    TrackRow(track: top.track, number: i + 1) {
                        Task { await playback.play(uris: page.topTracks.map { $0.track.uri }, startIndex: i) }
                    }
                    .padding(.horizontal, 16)
                }
                if page.topTracks.count > 5 {
                    Button(showAllTracks ? "Show less" : "Show more") { showAllTracks.toggle() }
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(Theme.secondary)
                        .padding(.horizontal, 16)
                }
            }
        }
    }

    private func albumRow(_ title: String, _ albums: [Album]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(text: title)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(albums) { a in
                        CardLink(card: MediaCard(uri: a.uri, kind: .album, title: a.name,
                                                 subtitle: [a.year, a.typeLabel].compactMap { $0 }.joined(separator: " · "), images: a.images))
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private func load() async {
        do {
            state = .loaded(try await env.service.artistPage(uri))
            if let flags = try? await env.service.contains([uri]) { following = flags.first ?? false }
        } catch {
            state = .failed(describe(error))
        }
    }

    private func toggleFollow() {
        let target = !following
        following = target
        Task {
            do {
                if target { try await env.service.addToLibrary([uri]) } else { try await env.service.removeFromLibrary([uri]) }
            } catch {
                following = !target
                playback.message = describe(error)
            }
        }
    }
}

@MainActor
struct DiscographyView: View {
    @EnvironmentObject var env: AppEnvironment
    let uri: Uri
    let name: String
    @State private var albums: [Album] = []
    @State private var next: Int? = 0
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if let e = error, albums.isEmpty { ErrorView(message: e, retry: { loadMore() }) }
                ForEach(Array(albums.enumerated()), id: \.offset) { i, a in
                    NavigationLink(destination: AlbumView(uri: a.uri)) {
                        HStack(spacing: 12) {
                            Artwork(url: a.images.bestUrl(minPx: 120), size: 56)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(a.name).foregroundColor(.white).lineLimit(1)
                                Text([a.year, a.typeLabel].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption).foregroundColor(Theme.secondary)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                    }
                    .buttonStyle(.plain)
                    .onAppear { if i >= albums.count - 5 { loadMore() } }
                }
                if loading { ProgressView().frame(maxWidth: .infinity).padding(.vertical, 16) }
            }
            .padding(.vertical, 12)
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await firstPage() }
    }

    private func firstPage() async {
        if albums.isEmpty { loadMore() }
    }

    private func loadMore() {
        guard let offset = next, !loading else { return }
        loading = true
        Task {
            defer { loading = false }
            do {
                let page = try await env.service.discography(uri, offset: offset, limit: 50)
                albums += page.items
                next = page.nextOffset
            } catch {
                self.error = describe(error)
                next = nil
            }
        }
    }
}

// MARK: - User

@MainActor
struct UserView: View {
    @EnvironmentObject var env: AppEnvironment
    @EnvironmentObject var playback: PlaybackManager
    let uri: Uri
    @State private var state: LoadState<UserProfile> = .loading
    @State private var following = false

    var body: some View {
        ScrollView {
            LoadView(state: state, retry: { Task { await load() } }) { profile in
                VStack(alignment: .leading, spacing: 18) {
                    VStack(spacing: 8) {
                        Artwork(url: profile.images.bestUrl(minPx: 300), size: 140, circle: true)
                        Text(profile.name).font(.title.weight(.bold)).foregroundColor(.white)
                        Text(counts(profile)).font(.footnote).foregroundColor(Theme.secondary)
                        Button {
                            toggleFollow()
                        } label: {
                            Text(following ? "Following" : "Follow")
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 18)
                                .padding(.vertical, 6)
                                .overlay(Capsule().stroke(Theme.secondary, lineWidth: 1))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    if !profile.publicPlaylists.isEmpty {
                        SectionTitle(text: "Public playlists")
                        ForEach(profile.publicPlaylists) { p in
                            NavigationLink(destination: PlaylistView(uri: p.uri)) {
                                HStack(spacing: 12) {
                                    Artwork(url: p.images.bestUrl(minPx: 120), size: 56)
                                    Text(p.name).foregroundColor(.white).lineLimit(1)
                                    Spacer()
                                }
                                .padding(.horizontal, 16)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.vertical, 12)
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func counts(_ p: UserProfile) -> String {
        var parts: [String] = []
        if let f = p.followers { parts.append("\(f) followers") }
        if let f = p.following { parts.append("\(f) following") }
        return parts.joined(separator: " · ")
    }

    private func load() async {
        do {
            state = .loaded(try await env.service.profile(uri))
            if let flags = try? await env.service.isFollowing([uri]) { following = flags.first ?? false }
        } catch {
            state = .failed(describe(error))
        }
    }

    private func toggleFollow() {
        let target = !following
        following = target
        Task {
            do {
                if target { try await env.service.followUsers([uri]) } else { try await env.service.unfollowUsers([uri]) }
            } catch {
                following = !target
                playback.message = describe(error)
            }
        }
    }
}

// MARK: - Browse category

@MainActor
struct CategoryView: View {
    @EnvironmentObject var env: AppEnvironment
    let uri: Uri
    @State private var state: LoadState<BrowsePage> = .loading

    var body: some View {
        ScrollView {
            LoadView(state: state, retry: { Task { await load() } }) { page in
                LazyVStack(alignment: .leading, spacing: 26) {
                    ForEach(page.shelves) { shelf in ShelfView(shelf: shelf) }
                }
                .padding(.vertical, 12)
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle(state.value?.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        do {
            state = .loaded(try await env.service.category(uri))
        } catch {
            state = .failed(describe(error))
        }
    }
}
