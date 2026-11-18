// Orpheon for iOS: a port of Orpheon (https://github.com/kota-zo/Orpheon, formerly Myspoti), GPL-3.0.
// Derived from the Kotlin sources by kota-zo and contributors. Keep these notices; if you ever
// distribute this, publish your complete source under GPL-3.0 (see LICENSE and NOTICE.md).
import SwiftUI

@MainActor
struct RootView: View {
    @EnvironmentObject var env: AppEnvironment
    @EnvironmentObject var playback: PlaybackManager
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        content
            .background(Theme.bg.ignoresSafeArea())
            .preferredColorScheme(.dark)
            .task { await env.bootstrap() }
            .onChange(of: scenePhase) { phase in
                playback.setActive(phase == .active)
            }
            .alert("Orpheon", isPresented: messageBinding) {
                Button("OK") { playback.message = nil }
            } message: {
                Text(playback.message ?? "")
            }
            .alert("No Spotify device found", isPresented: $playback.needsDevice) {
                Button("Open Spotify") {
                    SpotifyLinks.open()
                }
                Button("Try again") {
                    Task { await playback.retryPending() }
                }
                Button("Cancel", role: .cancel) { playback.dismissNeedsDevice() }
            } message: {
                Text("Spotify's audio plays in an official Spotify app. Open Spotify on this phone (or another device), start any song once, then come back and try again.")
            }
    }

    @ViewBuilder
    private var content: some View {
        switch env.auth {
        case .checking: SplashView()
        case .signedOut: LoginView()
        case .signedIn: MainTabs()
        }
    }

    private var messageBinding: Binding<Bool> {
        Binding(get: { playback.message != nil }, set: { if !$0 { playback.message = nil } })
    }
}

@MainActor
struct SplashView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "music.note.house.fill").font(.system(size: 54)).foregroundColor(Theme.accent)
            Text("Orpheon").font(.largeTitle.bold()).foregroundColor(.white)
            ProgressView()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@MainActor
struct MainTabs: View {
    @EnvironmentObject var env: AppEnvironment
    @EnvironmentObject var playback: PlaybackManager
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            HomeView()
                .tabItem { Label("Home", systemImage: "house.fill") }
                .tag(0)
            SearchView()
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
                .tag(1)
            LibraryView()
                .tabItem { Label("Library", systemImage: "books.vertical.fill") }
                .tag(2)
            RadioView()
                .tabItem { Label("Radio", systemImage: "dot.radiowaves.left.and.right") }
                .tag(3)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(4)
        }
        .accentColor(Theme.accent)
        .sheet(item: $env.sheet) { sheet in
            AppSheetView(sheet: sheet)
                .environmentObject(env)
                .environmentObject(playback)
        }
        .fullScreenCover(isPresented: $env.showPlayer, onDismiss: { playback.playerScreenClosed() }) {
            PlayerView()
                .environmentObject(env)
                .environmentObject(playback)
        }
    }
}

/// The content of the app-wide sheet.
@MainActor
struct AppSheetView: View {
    @EnvironmentObject var env: AppEnvironment
    let sheet: AppSheet

    var body: some View {
        switch sheet {
        case .route(let route):
            NavigationView {
                RouteView(route: route)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarLeading) {
                            Button("Close") { env.sheet = nil }
                        }
                    }
            }
            .navigationViewStyle(.stack)
            .safeAreaInset(edge: .bottom) { MiniPlayer() }
        case .addToPlaylist(let uris):
            AddToPlaylistSheet(trackUris: uris, onClose: { env.sheet = nil })
        case .newPlaylist:
            NewPlaylistSheet()
        }
    }
}

/// The bar above the tab bar: what plays, and where.
@MainActor
struct MiniPlayer: View {
    @EnvironmentObject var env: AppEnvironment
    @EnvironmentObject var playback: PlaybackManager

    var body: some View {
        if let now = playback.now {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Artwork(url: now.imageUrl.flatMap { URL(string: $0) }, size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(now.name).font(.subheadline.weight(.semibold)).foregroundColor(.white).lineLimit(1)
                        HStack(spacing: 6) {
                            Text(subtitle(now)).font(.caption).foregroundColor(Theme.secondary).lineLimit(1)
                            if playback.showSourceLabel, let p = now.provider { SourceBadge(label: p) }
                        }
                    }
                    Spacer(minLength: 4)
                    Button {
                        playback.togglePlayPause()
                    } label: {
                        Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title3).foregroundColor(.white).frame(width: 44, height: 44)
                    }
                    Button {
                        playback.next()
                    } label: {
                        Image(systemName: "forward.fill")
                            .font(.body).foregroundColor(.white).frame(width: 40, height: 44)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 6)
                TimelineView(.periodic(from: Date(), by: 1)) { context in
                    ProgressLine(fraction: fraction(at: context.date))
                }
            }
            .background(Theme.elevated)
            .contentShape(Rectangle())
            .onTapGesture { env.showPlayer = true }
        }
    }

    private func subtitle(_ now: NowPlaying) -> String {
        if playback.source != .remote { return now.artistLine.isEmpty ? "This phone" : now.artistLine }
        let device = playback.device?.name ?? "Spotify"
        return now.artistLine.isEmpty ? device : "\(now.artistLine) · \(device)"
    }

    private func fraction(at date: Date) -> Double {
        guard playback.durationMs > 0 else { return 0 }
        return Swift.min(1, Swift.max(0, Double(playback.positionMs(at: date)) / Double(playback.durationMs)))
    }
}

@MainActor
struct ProgressLine: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(Theme.hairline)
                Rectangle().fill(Theme.accent).frame(width: geo.size.width * CGFloat(fraction))
            }
        }
        .frame(height: 2)
    }
}

/// The screen for a route, inside a navigation stack.
@MainActor
struct RouteView: View {
    let route: Route

    var body: some View {
        switch route {
        case .album(let uri): AlbumView(uri: uri)
        case .artist(let uri): ArtistView(uri: uri)
        case .playlist(let uri): PlaylistView(uri: uri)
        case .show(let uri): ShowView(uri: uri)
        case .episode(let uri): EpisodeView(uri: uri)
        case .audiobook(let uri): AudiobookView(uri: uri)
        case .user(let uri): UserView(uri: uri)
        case .category(let uri): CategoryView(uri: uri)
        case .likedSongs: LikedSongsView()
        case .folder(let uri, let title): FolderView(uri: uri, title: title)
        }
    }
}
