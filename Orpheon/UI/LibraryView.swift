// Orpheon for iOS: a port of Orpheon (https://github.com/kota-zo/Orpheon, formerly Myspoti), GPL-3.0.
// Derived from the Kotlin sources by kota-zo and contributors. Keep these notices; if you ever
// distribute this, publish your complete source under GPL-3.0 (see LICENSE and NOTICE.md).
import SwiftUI

@MainActor
struct LibraryRow: View {
    let item: LibraryItem

    var body: some View {
        HStack(spacing: 12) {
            Artwork(url: item.images.bestUrl(minPx: 120), size: 56, circle: item.kind == .artist)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).foregroundColor(.white).lineLimit(1)
                HStack(spacing: 4) {
                    if item.pinned {
                        Image(systemName: "pin.fill").font(.caption).foregroundColor(Theme.accent)
                    }
                    Text(subtitle).font(.caption).foregroundColor(Theme.secondary).lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        var parts: [String] = []
        switch item.kind {
        case .playlist: parts.append("Playlist")
        case .album: parts.append("Album")
        case .artist: parts.append("Artist")
        case .show: parts.append("Podcast")
        case .audiobook: parts.append("Audiobook")
        case .folder: parts.append("Folder")
        case .collection: parts.append("Playlist")
        default: break
        }
        if let s = item.subtitle, !s.isEmpty, item.kind != .artist, !parts.contains(s) {
            if !parts.isEmpty && s.hasPrefix(parts[0]) { parts = [s] } else { parts.append(s) }
        }
        return parts.joined(separator: " · ")
    }
}

@MainActor
struct LibraryView: View {
    @EnvironmentObject var env: AppEnvironment
    @State private var filter: LibraryFilter = .all
    @State private var sort: LibrarySort = .recents
    @State private var items: [LibraryItem] = []
    @State private var next: Int? = nil
    @State private var loading = false
    @State private var error: String?
    @State private var generation = 0

    var body: some View {
        NavigationView {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    filterBar
                    if let e = error, items.isEmpty {
                        ErrorView(message: e, retry: { Task { await reload() } })
                    } else if loading && items.isEmpty {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 240)
                    } else {
                        ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                            row(item)
                                .onAppear { loadMore(i) }
                        }
                    }
                }
                .padding(.vertical, 12)
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("Your Library")
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Menu {
                        ForEach(LibrarySort.allCases) { s in
                            Button {
                                sort = s
                                Task { await reload() }
                            } label: {
                                Text(s.label)
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                    Button {
                        env.sheet = .newPlaylist
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .refreshable { await reload() }
        }
        .navigationViewStyle(.stack)
        .miniPlayerInset()
        .task { await loadIfNeeded() }
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(LibraryFilter.allCases) { f in
                    PillButton(title: f.label, selected: filter == f) {
                        filter = f
                        Task { await reload() }
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    @ViewBuilder
    private func row(_ item: LibraryItem) -> some View {
        if let route = Route.from(uri: item.uri, kind: item.kind, title: item.name) {
            NavigationLink(destination: RouteView(route: route)) {
                LibraryRow(item: item)
            }
            .buttonStyle(.plain)
        } else {
            LibraryRow(item: item)
        }
    }

    private func loadIfNeeded() async {
        if items.isEmpty { await reload() }
    }

    private func reload() async {
        generation += 1
        let mine = generation
        loading = true
        error = nil
        defer { if mine == generation { loading = false } }
        do {
            let page = try await env.service.libraryItems(filter: filter, sort: sort, folderUri: nil, offset: 0, limit: 50)
            if mine == generation {
                items = page.items
                next = page.nextOffset
            }
        } catch {
            if mine == generation { self.error = describe(error) }
        }
    }

    private func loadMore(_ index: Int) {
        guard index >= items.count - 5, let offset = next, !loading else { return }
        let mine = generation
        loading = true
        Task {
            defer { loading = false }
            do {
                let page = try await env.service.libraryItems(filter: filter, sort: sort, folderUri: nil, offset: offset, limit: 50)
                if mine == generation {
                    items += page.items
                    next = page.nextOffset
                }
            } catch {
                next = nil
            }
        }
    }
}

@MainActor
struct FolderView: View {
    @EnvironmentObject var env: AppEnvironment
    let uri: Uri
    let title: String
    @State private var state: LoadState<[LibraryItem]> = .loading

    var body: some View {
        ScrollView {
            LoadView(state: state, retry: { Task { await load() } }) { items in
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(items) { item in
                        if let route = Route.from(uri: item.uri, kind: item.kind, title: item.name) {
                            NavigationLink(destination: RouteView(route: route)) { LibraryRow(item: item) }
                                .buttonStyle(.plain)
                        } else {
                            LibraryRow(item: item)
                        }
                    }
                }
            }
            .padding(.vertical, 12)
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle(title)
        .task { await load() }
    }

    private func load() async {
        do {
            var all: [LibraryItem] = []
            var offset: Int? = 0
            while let o = offset, all.count < 1000 {
                let page = try await env.service.libraryItems(filter: .all, sort: .recents, folderUri: uri, offset: o, limit: 50)
                all += page.items
                offset = page.nextOffset
            }
            state = .loaded(all)
        } catch {
            state = .failed(describe(error))
        }
    }
}
