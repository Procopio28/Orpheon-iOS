// Orpheon for iOS: a port of Orpheon (https://github.com/kota-zo/Orpheon, formerly Myspoti), GPL-3.0.
// Derived from the Kotlin sources by kota-zo and contributors. Keep these notices; if you ever
// distribute this, publish your complete source under GPL-3.0 (see LICENSE and NOTICE.md).
import SwiftUI

@MainActor
struct ShowView: View {
    @EnvironmentObject var env: AppEnvironment
    @EnvironmentObject var playback: PlaybackManager
    let uri: Uri
    @State private var state: LoadState<Show> = .loading
    @State private var episodes: [Episode] = []
    @State private var next: Int? = 0
    @State private var loading = false
    @State private var saved = false

    var body: some View {
        ScrollView {
            LoadView(state: state, retry: { Task { await load() } }) { show in
                VStack(alignment: .leading, spacing: 16) {
                    VStack(spacing: 8) {
                        Artwork(url: show.images.bestUrl(minPx: 600), size: 220, corner: 10)
                        Text(show.name).font(.title2.weight(.bold)).foregroundColor(.white).multilineTextAlignment(.center)
                        Text(show.publisher).font(.subheadline).foregroundColor(Theme.accent)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 16)
                    HStack(spacing: 22) {
                        Button {
                            toggleSaved()
                        } label: {
                            Label(saved ? "Following" : "Follow", systemImage: saved ? "checkmark" : "plus")
                                .font(.subheadline.weight(.semibold))
                        }
                        .buttonStyle(.bordered)
                        .tint(Theme.accent)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    if let d = show.description, !d.isEmpty {
                        Text(stripHtml(d)).font(.footnote).foregroundColor(Theme.secondary).lineLimit(6).padding(.horizontal, 16)
                    }
                    SectionTitle(text: "Episodes")
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(episodes.enumerated()), id: \.offset) { i, e in
                            NavigationLink(destination: EpisodeView(uri: e.uri)) {
                                EpisodeRow(episode: e) {
                                    Task { await playback.play(episode: e, from: Array(episodes.dropFirst(i))) }
                                }
                                .padding(.horizontal, 16)
                            }
                            .buttonStyle(.plain)
                            .onAppear { if i >= episodes.count - 4 { loadMore() } }
                        }
                        if loading { ProgressView().frame(maxWidth: .infinity).padding(.vertical, 16) }
                    }
                }
                .padding(.vertical, 12)
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        do {
            let show = try await env.service.show(uri)
            state = .loaded(show)
            saved = show.saved
            loadMore()
        } catch {
            state = .failed(describe(error))
        }
    }

    private func loadMore() {
        guard let offset = next, !loading else { return }
        loading = true
        Task {
            defer { loading = false }
            do {
                let page = try await env.service.episodes(show: uri, offset: offset, limit: 30)
                episodes += page.items
                next = page.nextOffset
            } catch {
                next = nil
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
}

@MainActor
struct EpisodeView: View {
    @EnvironmentObject var env: AppEnvironment
    @EnvironmentObject var playback: PlaybackManager
    let uri: Uri
    @State private var state: LoadState<Episode> = .loading

    var body: some View {
        ScrollView {
            LoadView(state: state, retry: { Task { await load() } }) { e in
                VStack(alignment: .leading, spacing: 14) {
                    Artwork(url: (e.images.isEmpty ? (e.show?.images ?? []) : e.images).bestUrl(minPx: 600), size: 220, corner: 10)
                        .frame(maxWidth: .infinity)
                    Text(e.name).font(.title2.weight(.bold)).foregroundColor(.white).padding(.horizontal, 16)
                    if let s = e.show {
                        NavigationLink(destination: ShowView(uri: s.uri)) {
                            Text(s.name).font(.subheadline.weight(.semibold)).foregroundColor(Theme.accent)
                        }
                        .padding(.horizontal, 16)
                    }
                    Text([e.releaseDate.map { String($0.prefix(10)) }, formatDuration(ms: e.durationMs)].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundColor(Theme.secondary).padding(.horizontal, 16)
                    Button {
                        Task { await playback.play(episode: e) }
                    } label: {
                        Label("Play", systemImage: "play.fill")
                            .font(.headline).foregroundColor(.black)
                            .frame(maxWidth: .infinity).padding(.vertical, 12)
                            .background(Theme.accent).clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16)
                    if let d = e.description {
                        Text(stripHtml(d)).font(.subheadline).foregroundColor(Theme.secondary).padding(.horizontal, 16)
                    }
                }
                .padding(.vertical, 12)
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        do { state = .loaded(try await env.service.episode(uri)) }
        catch { state = .failed(describe(error)) }
    }
}

@MainActor
struct AudiobookView: View {
    @EnvironmentObject var env: AppEnvironment
    @EnvironmentObject var playback: PlaybackManager
    let uri: Uri
    @State private var state: LoadState<Audiobook> = .loading
    @State private var chapters: [Episode] = []

    var body: some View {
        ScrollView {
            LoadView(state: state, retry: { Task { await load() } }) { book in
                VStack(alignment: .leading, spacing: 14) {
                    VStack(spacing: 8) {
                        Artwork(url: book.images.bestUrl(minPx: 600), size: 220, corner: 8)
                        Text(book.name).font(.title2.weight(.bold)).foregroundColor(.white).multilineTextAlignment(.center)
                        if !book.authors.isEmpty {
                            Text(book.authors.joined(separator: ", ")).font(.subheadline).foregroundColor(Theme.accent)
                        }
                        if !book.narrators.isEmpty {
                            Text("Narrated by " + book.narrators.joined(separator: ", ")).font(.caption).foregroundColor(Theme.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 16)
                    if let d = book.description {
                        Text(stripHtml(d)).font(.footnote).foregroundColor(Theme.secondary).lineLimit(8).padding(.horizontal, 16)
                    }
                    SectionTitle(text: "Chapters")
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(chapters) { c in
                            EpisodeRow(episode: c) { Task { await playback.play(uris: [c.uri]) } }
                                .padding(.horizontal, 16)
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

    private func load() async {
        do {
            state = .loaded(try await env.service.audiobook(uri))
            chapters = (try? await env.service.chapters(uri).items) ?? []
        } catch {
            state = .failed(describe(error))
        }
    }
}
