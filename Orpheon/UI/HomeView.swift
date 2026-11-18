// Orpheon for iOS: a port of Orpheon (https://github.com/kota-zo/Orpheon, formerly Myspoti), GPL-3.0.
// Derived from the Kotlin sources by kota-zo and contributors. Keep these notices; if you ever
// distribute this, publish your complete source under GPL-3.0 (see LICENSE and NOTICE.md).
import SwiftUI

@MainActor
struct HomeView: View {
    @EnvironmentObject var env: AppEnvironment
    @State private var state: LoadState<HomeFeed> = .loading
    @State private var filter: HomeFilter = .all

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    chips
                    LoadView(state: state, retry: { Task { await load() } }) { feed in
                        LazyVStack(alignment: .leading, spacing: 26) {
                            ForEach(feed.shelves) { shelf in
                                ShelfView(shelf: shelf)
                            }
                        }
                    }
                }
                .padding(.vertical, 12)
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle(title)
            .refreshable { await load() }
        }
        .navigationViewStyle(.stack)
        .miniPlayerInset()
        .task { await loadIfNeeded() }
    }

    private var title: String {
        if let g = state.value?.greeting, !g.isEmpty { return g }
        return "Home"
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(HomeFilter.allCases, id: \.self) { f in
                    PillButton(title: f.label, selected: filter == f) {
                        filter = f
                        Task { await load() }
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func loadIfNeeded() async {
        if state.value == nil { await load() }
    }

    private func load() async {
        let facet = filter.facet
        do {
            let feed = try await env.service.homeFeed(facet: facet)
            state = .loaded(feed)
        } catch {
            if state.value == nil { state = .failed(describe(error)) }
        }
    }
}
