// Orpheon for iOS: a port of Orpheon (https://github.com/kota-zo/Orpheon, formerly Myspoti), GPL-3.0.
// Derived from the Kotlin sources by kota-zo and contributors. Keep these notices; if you ever
// distribute this, publish your complete source under GPL-3.0 (see LICENSE and NOTICE.md).
import SwiftUI
import WebKit

@MainActor
struct LoginView: View {
    @EnvironmentObject var env: AppEnvironment
    @State private var showWeb = false
    @State private var showManual = false

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "music.note.house.fill").font(.system(size: 64)).foregroundColor(Theme.accent)
            Text("Orpheon").font(.largeTitle.bold()).foregroundColor(.white)
            Text("An unofficial Spotify client. You sign in on Spotify's own login page; this app never sees your password.")
                .font(.subheadline)
                .foregroundColor(Theme.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            if let e = env.authError {
                Text(e).font(.footnote).foregroundColor(.red).multilineTextAlignment(.center).padding(.horizontal, 32)
            }
            Button {
                showWeb = true
            } label: {
                Text("Sign in with Spotify")
                    .font(.headline)
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Theme.accent)
                    .clipShape(Capsule())
            }
            .padding(.horizontal, 40)
            Button("I have an sp_dc cookie") { showManual = true }
                .font(.footnote)
                .foregroundColor(Theme.secondary)
            Spacer()
            Text("Spotify's audio is DRM-protected, so it plays in the official Spotify app. This app browses your library and remote-controls it.")
                .font(.caption)
                .foregroundColor(Theme.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .fullScreenCover(isPresented: $showWeb) {
            LoginWebScreen {
                showWeb = false
                Task { await env.completeSignIn() }
            } onCancel: {
                showWeb = false
            }
        }
        .sheet(isPresented: $showManual) {
            ManualCookieSheet {
                showManual = false
                Task { await env.completeSignIn() }
            }
        }
    }
}

@MainActor
struct LoginWebScreen: View {
    var onSignedIn: () -> Void
    var onCancel: () -> Void

    var body: some View {
        NavigationView {
            LoginWebView(onSignedIn: onSignedIn)
                .ignoresSafeArea()
                .navigationTitle("Spotify")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Cancel", action: onCancel)
                    }
                }
        }
        .navigationViewStyle(.stack)
    }
}

/// Spotify's own login page. The session cookie it sets (`sp_dc`) is what the app lives on.
@MainActor
struct LoginWebView: UIViewRepresentable {
    var onSignedIn: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSignedIn: onSignedIn) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore.default()
        // The phone's own browser identity: Spotify serves its mobile login page.
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        if let url = URL(string: "https://accounts.spotify.com/en/login?continue=https%3A%2F%2Fopen.spotify.com%2F") {
            web.load(URLRequest(url: url))
        }
        context.coordinator.startWatching()
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        let onSignedIn: () -> Void
        private var watcher: Task<Void, Never>?

        init(onSignedIn: @escaping () -> Void) {
            self.onSignedIn = onSignedIn
        }

        deinit { watcher?.cancel() }

        /// Polls for the session cookie: it appears when the login finished.
        func startWatching() {
            watcher?.cancel()
            watcher = Task { [weak self] in
                while !Task.isCancelled {
                    if await TokenBridge.hasSession() {
                        self?.onSignedIn()
                        return
                    }
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
        }
    }
}

@MainActor
struct ManualCookieSheet: View {
    var onSaved: () -> Void
    @State private var value = ""

    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextField("sp_dc value", text: $value)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                } header: {
                    Text("Session cookie")
                } footer: {
                    Text("Sign in at open.spotify.com in a browser, open its developer tools, and copy the value of the cookie named sp_dc.")
                }
                Section {
                    Button("Use this cookie") {
                        let v = value
                        Task {
                            await TokenBridge.setSpDc(v)
                            onSaved()
                        }
                    }
                    .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .navigationTitle("sp_dc cookie")
            .navigationBarTitleDisplayMode(.inline)
        }
        .navigationViewStyle(.stack)
    }
}
