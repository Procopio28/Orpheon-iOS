// Orpheon for iOS: a port of Orpheon (https://github.com/kota-zo/Orpheon, formerly Myspoti), GPL-3.0.
// Derived from the Kotlin sources by kota-zo and contributors. Keep these notices; if you ever
// distribute this, publish your complete source under GPL-3.0 (see LICENSE and NOTICE.md).
import Foundation
import Combine

/// Builds the app's services once and holds what the whole UI shares: who is signed in, and the
/// screens presented over everything else.
@MainActor
final class AppEnvironment: ObservableObject {
    enum Auth { case checking, signedOut, signedIn }

    @Published private(set) var auth: Auth = .checking
    @Published private(set) var account: Account?
    @Published var authError: String?

    /// What is shown in a sheet over the current screen (from a menu, where a push is not possible).
    @Published var sheet: AppSheet?
    @Published var showPlayer = false

    let store: KeyValueStore
    let bridge: TokenBridge
    let http: SpotifyHTTP
    let gql: GqlClient
    let service: SpotifyService
    let connect: ConnectAPI
    let playback: PlaybackManager
    let lyrics: LyricsService
    let radio = RadioBrowser()
    let localLibrary = LocalLibrary()

    init() {
        let store = KeyValueStore()
        let ops = OpsStore()
        let bridge = TokenBridge(fallbackVersion: ops.ops.clientVersion ?? "1.3.6.1874.g61b9bcdb1ef2")
        let http = SpotifyHTTP(tokens: bridge, store: store, language: Locale.current.languageCode ?? "en")
        let gql = GqlClient(http: http, store: ops)
        let service = SpotifyService(http: http, gql: gql)
        let connect = ConnectAPI(http: http)
        self.store = store
        self.bridge = bridge
        self.http = http
        self.gql = gql
        self.service = service
        self.connect = connect
        self.playback = PlaybackManager(service: service, connect: connect, store: store)
        self.lyrics = LyricsService(spotify: service)
        // YouTube's embedded player may play only while it is on screen: open the player for it.
        playback.requestPlayerScreen = { [weak self] in self?.showPlayer = true }
    }

    // MARK: Session

    /// On launch: signed in when the web view still holds the Spotify session cookie. A token kept from
    /// the last run is used as it is, so the page only loads when a new token is needed.
    func bootstrap() async {
        guard await TokenBridge.hasSession() else {
            auth = .signedOut
            return
        }
        if await http.hasToken() {
            await enter()
            // The hidden page warms up in the background, ready for the next token.
            Task { try? await bridge.reloadAndWait() }
        } else {
            await completeSignIn()
        }
    }

    /// Called when the login page set the session cookie (or one was pasted).
    func completeSignIn() async {
        auth = .checking
        authError = nil
        await http.forgetAccount()
        service.forgetAccount()
        do {
            try await bridge.reloadAndWait()
        } catch {
            // The page may still hand out a token below.
        }
        await enter()
    }

    private func enter() async {
        if await http.isSignedIn() {
            account = try? await service.me()
            auth = .signedIn
            playback.start()
            Task { await gql.refreshOpsIfDue() }
            Task { await playback.refreshDevices() }
        } else {
            authError = "Spotify did not give a session token. Sign in again."
            auth = .signedOut
        }
    }

    func signOut() async {
        playback.stop()
        playback.local.stop()
        await TokenBridge.clearSession()
        bridge.reset()
        await http.forgetAccount()
        service.forgetAccount()
        account = nil
        auth = .signedOut
    }

    /// Opens a screen over the current one; closes the player first when it is up.
    func present(_ route: Route) { show(.route(route)) }

    /// Asks which playlist to add these tracks to.
    func addToPlaylist(_ uris: [Uri]) { show(.addToPlaylist(uris)) }

    private func show(_ sheet: AppSheet) {
        if showPlayer {
            showPlayer = false
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 450_000_000)
                self?.sheet = sheet
            }
        } else {
            self.sheet = sheet
        }
    }
}

enum AppSheet: Identifiable {
    case route(Route)
    case addToPlaylist([Uri])
    case newPlaylist

    var id: String {
        switch self {
        case .route(let r): return "route:" + r.id
        case .addToPlaylist(let u): return "add:" + u.joined(separator: ",")
        case .newPlaylist: return "new"
        }
    }
}
