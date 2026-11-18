// Orpheon for iOS: a port of Orpheon (https://github.com/kota-zo/Orpheon, formerly Myspoti), GPL-3.0.
// Derived from the Kotlin sources by kota-zo and contributors. Keep these notices; if you ever
// distribute this, publish your complete source under GPL-3.0 (see LICENSE and NOTICE.md).
import SwiftUI

// MARK: - Album

struct AlbumData {
    var album: Album
    var tracks: [Track]
}

@MainActor
struct AlbumView: View {
    @EnvironmentObject var env: AppEnvironment
    @EnvironmentObject var playback: PlaybackManager
    let uri: Uri
    @State private var state: LoadState<AlbumData> = .loading
    @State private var saved = false

    var body: some View {
        ScrollView {
            LoadView(state: state, retry: { Task { await load() } }) { data in
                content(data)
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func content(_ data: AlbumData) -> some View {
        let album = data.album
        return VStack(alignment: .leading, spacing: 16) {
            VStack(spacing: 8) {
                Artwork(url: album.images.bestUrl(minPx: 600), size: 240, corner: 8)
                Text(album.name)
                    .font(.title2.weight(.bold))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                if let a = album.artists.first {
                    NavigationLink(destination: ArtistView(uri: a.uri)) {
                        Text(album.artistLine).font(.subheadline.weight(.semibold)).foregroundColor(Theme.accent)
                    }
                }
                Text([album.typeLabel, album.year].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundColor(Theme.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            PlayShuffleBar(
                onPlay: { Task { await playback.play(context: uri) } },
                onShuffle: { Task { await playback.playShuffled(context: uri) } })
            HStack(spacing: 22) {
                Button {
                    toggleSaved()
                } label: {
                    Image(systemName: saved ? "heart.fill" : "heart")
                        .font(.title3)
                        .foregroundColor(saved ? Theme.accent : .white)
                }
                Button {
                    SpotifyLinks.open(uri)
                } label: {
                    Image(systemName: "arrow.up.right.square").font(.title3).foregroundColor(.white)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(Array(data.tracks.enumerated()), id: \.offset) { i, t in
                    TrackRow(track: t, number: i + 1, showArt: false) {
                        Task { await playback.play(context: uri, trackUri: t.uri) }
                    }
                    .padding(.horizontal, 16)
                }
            }
            if !album.copyrights.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(album.copyrights, id: \.self) { line in
                        Text(line).font(.caption2).foregroundColor(Theme.secondary)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .padding(.vertical, 12)
    }

    private func load() async {
        do {
            async let album = env.service.album(uri)
            var tracks: [Track] = []
            var offset: Int? = 0
            while let o = offset, tracks.count < 500 {
                let page = try await env.service.albumTracks(uri, offset: o, limit: 50)
                tracks += page.items
                offset = page.nextOffset
            }
            state = .loaded(AlbumData(album: try await album, tracks: tracks))
            if let flags = try? await env.service.contains([uri]) { saved = flags.first ?? false }
        } catch {
            state = .failed(describe(error))
        }
    }

    private func toggleSaved() {
        let target = !saved
        saved = target
        Task {
            do {
                if target { try await env.service.addToLibrary([uri]) } else { try await env.service.removeFromLibrary([uri]) }
            } catch {
                saved = !target
                playback.message = describe(error)
            }
        }
    }
}

// MARK: - Playlist

@MainActor
struct PlaylistView: View {
    @EnvironmentObject var env: AppEnvironment
    @EnvironmentObject var playback: PlaybackManager
    @Environment(\.dismiss) private var dismiss
    let uri: Uri
    @State private var state: LoadState<Playlist> = .loading
    @State private var tracks: [Track] = []
    @State private var loadingTracks = true
    @State private var sort: PlaylistSort = .custom
    @State private var descending = false
    @State private var saved = false
    @State private var renaming = false
    @State private var confirmDelete = false

    var body: some View {
        ScrollView {
            LoadView(state: state, retry: { Task { await load() } }) { playlist in
                content(playlist)
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if let p = state.value { menu(p) }
            }
        }
        .sheet(isPresented: $renaming) {
            if let p = state.value {
                RenameSheet(title: "Rename playlist", initial: p.name) { name in
                    try await env.service.renamePlaylist(uri, name: name)
                    var updated = p
                    updated.name = name
                    state = .loaded(updated)
                }
            }
        }
        .confirmationDialog("Delete this playlist?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { deleteOrLeave() }
            Button("Cancel", role: .cancel) {}
        }
        .task { await load() }
    }

    private var sortedTracks: [Track] { tracks.sortedFor(sort, descending: descending) }

    private func content(_ p: Playlist) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(spacing: 8) {
                Artwork(url: p.images.bestUrl(minPx: 600), size: 240, corner: 8)
                Text(p.name).font(.title2.weight(.bold)).foregroundColor(.white).multilineTextAlignment(.center)
                if let d = p.description {
                    Text(stripHtml(d)).font(.footnote).foregroundColor(Theme.secondary).multilineTextAlignment(.center).lineLimit(3)
                }
                Text(subtitle(p)).font(.caption).foregroundColor(Theme.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            PlayShuffleBar(
                onPlay: { play(from: 0, shuffled: false) },
                onShuffle: { play(from: 0, shuffled: true) })
            HStack(spacing: 22) {
                if !p.editable {
                    Button {
                        toggleSaved()
                    } label: {
                        Image(systemName: saved ? "heart.fill" : "heart")
                            .font(.title3)
                            .foregroundColor(saved ? Theme.accent : .white)
                    }
                }
                Menu {
                    ForEach(PlaylistSort.allCases) { s in
                        Button {
                            if sort == s { descending.toggle() } else { sort = s; descending = false }
                        } label: {
                            Label(s.label, systemImage: sort == s ? (descending ? "arrow.down" : "arrow.up") : "arrow.up.arrow.down")
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down").font(.title3).foregroundColor(.white)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(Array(sortedTracks.enumerated()), id: \.offset) { i, t in
                    TrackRow(track: t, number: nil, showArt: true, onPlay: { play(from: i, shuffled: false) },
                             onRemove: p.editable && t.uid != nil ? { remove(t) } : nil)
                        .padding(.horizontal, 16)
                }
                if loadingTracks {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 16)
                }
            }
        }
        .padding(.vertical, 12)
    }

    private func subtitle(_ p: Playlist) -> String {
        var parts: [String] = []
        if let o = p.owner { parts.append(o) }
        let count = tracks.isEmpty ? p.trackCount : Swift.max(p.trackCount, tracks.count)
        if count > 0 { parts.append("\(count) songs") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func menu(_ p: Playlist) -> some View {
        Menu {
            if p.editable {
                Button { renaming = true } label: { Label("Rename", systemImage: "pencil") }
                Button(role: .destructive) { confirmDelete = true } label: { Label("Delete playlist", systemImage: "trash") }
            } else if saved {
                Button(role: .destructive) { confirmDelete = true } label: { Label("Remove from library", systemImage: "minus.circle") }
            }
            Button { SpotifyLinks.open(uri) } label: { Label("Open in Spotify", systemImage: "arrow.up.right.square") }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }

    private func play(from index: Int, shuffled: Bool) {
        let list = sortedTracks
        Task {
            if shuffled {
                await playback.playShuffled(context: uri)
            } else if sort == .custom && !descending {
                if index == 0 { await playback.play(context: uri) }
                else if index < list.count { await playback.play(context: uri, trackUri: list[index].uri) }
            } else {
                await playback.play(tracks: list, startIndex: index)
            }
        }
    }

    private func remove(_ t: Track) {
        guard let uid = t.uid else { return }
        Task {
            do {
                try await env.service.removeTracks(from: uri, uids: [uid])
                tracks.removeAll { $0.uid == uid }
            } catch {
                playback.message = describe(error)
            }
        }
    }

    private func deleteOrLeave() {
        Task {
            do {
                try await env.service.deletePlaylist(uri)
                dismiss()
            } catch {
                playback.message = describe(error)
            }
        }
    }

    private func toggleSaved() {
        let target = !saved
        saved = target
        Task {
            do {
                if target { try await env.service.addToLibrary([uri]) } else { try await env.service.removeFromLibrary([uri]) }
            } catch {
                saved = !target
                playback.message = describe(error)
            }
        }
    }

    private func load() async {
        do {
            let p = try await env.service.playlist(uri)
            state = .loaded(p)
            if !p.editable, let flags = try? await env.service.contains([uri]) { saved = flags.first ?? false }
            var offset: Int? = 0
            var all: [Track] = []
            while let o = offset, all.count < 5000 {
                let page = try await env.service.playlistTracks(uri, offset: o, limit: 100)
                all += page.items
                tracks = all
                offset = page.nextOffset
                if page.items.isEmpty { break }
            }
            loadingTracks = false
        } catch {
            loadingTracks = false
            if state.value == nil { state = .failed(describe(error)) }
        }
    }
}

// MARK: - Liked Songs

@MainActor
struct LikedSongsView: View {
    @EnvironmentObject var env: AppEnvironment
    @EnvironmentObject var playback: PlaybackManager
    @State private var tracks: [SavedTrack] = []
    @State private var next: Int? = 0
    @State private var total = 0
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Liked Songs").font(.largeTitle.bold()).foregroundColor(.white)
                    Text("\(total) songs").font(.subheadline).foregroundColor(Theme.secondary)
                }
                .padding(.horizontal, 16)
                PlayShuffleBar(
                    onPlay: { playAll(shuffled: false) },
                    onShuffle: { playAll(shuffled: true) })
                    .padding(.vertical, 8)
                if let e = error, tracks.isEmpty {
                    ErrorView(message: e, retry: { loadMore() })
                }
                ForEach(Array(tracks.enumerated()), id: \.offset) { i, saved in
                    TrackRow(track: saved.track) {
                        Task { await playback.play(tracks: tracks.map { $0.track }, startIndex: i) }
                    }
                    .padding(.horizontal, 16)
                    .onAppear { if i >= tracks.count - 5 { loadMore() } }
                }
                if loading { ProgressView().frame(maxWidth: .infinity).padding(.vertical, 16) }
            }
            .padding(.vertical, 12)
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .task { await firstPage() }
    }

    private func firstPage() async {
        if tracks.isEmpty { loadMore() }
    }

    private func playAll(shuffled: Bool) {
        let list = tracks.map { $0.track }
        guard !list.isEmpty else { return }
        Task { await playback.play(tracks: shuffled ? list.shuffled() : list, startIndex: 0) }
    }

    private func loadMore() {
        guard let offset = next, !loading else { return }
        loading = true
        error = nil
        Task {
            defer { loading = false }
            do {
                let page = try await env.service.likedTracks(offset: offset, limit: 50)
                tracks += page.items
                total = page.total
                next = page.nextOffset
            } catch {
                self.error = describe(error)
            }
        }
    }
}
