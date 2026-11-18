// Orpheon for iOS: a port of Orpheon (https://github.com/kota-zo/Orpheon, formerly Myspoti), GPL-3.0.
// Derived from the Kotlin sources by kota-zo and contributors. Keep these notices; if you ever
// distribute this, publish your complete source under GPL-3.0 (see LICENSE and NOTICE.md).
import SwiftUI

/// Live radio from the Radio Browser directory. These streams play inside the app.
@MainActor
struct RadioView: View {
    @EnvironmentObject var env: AppEnvironment
    @EnvironmentObject var playback: PlaybackManager
    @State private var query = ""
    @State private var tag = ""
    @State private var tags: [String] = []
    @State private var state: LoadState<[RadioStation]> = .loading

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    tagBar
                    LoadView(state: state, retry: { Task { await load() } }) { list in
                        LazyVStack(alignment: .leading, spacing: 4) {
                            if list.isEmpty {
                                Text("No stations found.").foregroundColor(Theme.secondary).padding(16)
                            }
                            ForEach(Array(list.enumerated()), id: \.offset) { i, s in
                                stationRow(s, index: i, list: list)
                            }
                        }
                    }
                }
                .padding(.vertical, 12)
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("Live Radio")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    NavigationLink(destination: LocalFilesView(library: env.localLibrary)) {
                        Image(systemName: "folder")
                    }
                }
            }
            .searchable(text: $query, prompt: "Search stations")
            .onSubmit(of: .search) { Task { await load() } }
        }
        .navigationViewStyle(.stack)
        .miniPlayerInset()
        .task { await loadInitial() }
    }

    private var tagBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                PillButton(title: "Top", selected: tag.isEmpty) {
                    tag = ""
                    Task { await load() }
                }
                ForEach(tags, id: \.self) { t in
                    PillButton(title: t.capitalized, selected: tag == t) {
                        tag = t
                        Task { await load() }
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func stationRow(_ s: RadioStation, index: Int, list: [RadioStation]) -> some View {
        Button {
            play(index, in: list)
        } label: {
            HStack(spacing: 12) {
                Artwork(url: s.favicon.flatMap { URL(string: $0) }, size: 52, corner: 6)
                VStack(alignment: .leading, spacing: 3) {
                    Text(s.name)
                        .foregroundColor(playback.now?.uri == "orpheon:local:\(s.id)" ? Theme.accent : .white)
                        .lineLimit(1)
                    Text(s.detail).font(.caption).foregroundColor(Theme.secondary).lineLimit(1)
                }
                Spacer()
                Image(systemName: "play.circle").font(.title2).foregroundColor(Theme.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func play(_ index: Int, in list: [RadioStation]) {
        let items: [LocalItem] = list.compactMap { s in
            guard let url = URL(string: s.streamUrl) else { return nil }
            return LocalItem(id: s.id, title: s.name, subtitle: s.detail, url: url,
                             artworkURL: s.favicon.flatMap { URL(string: $0) }, durationMs: nil, isLive: true)
        }
        guard let chosen = items.firstIndex(where: { $0.id == list[index].id }) else { return }
        playback.playLocal(items, startAt: chosen)
        env.radio.registerClick(list[index])
    }

    private func loadInitial() async {
        if state.value == nil { await load() }
        if tags.isEmpty { tags = (try? await env.radio.tags(limit: 24)) ?? [] }
    }

    private func load() async {
        state = .loading
        do {
            let q = query.trimmingCharacters(in: .whitespaces)
            let list = q.isEmpty && tag.isEmpty
                ? try await env.radio.topStations(limit: 60)
                : try await env.radio.search(name: q, tag: tag, limit: 60)
            state = .loaded(list)
        } catch {
            state = .failed(describe(error))
        }
    }
}
