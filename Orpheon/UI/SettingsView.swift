// Orpheon for iOS: a port of Orpheon (https://github.com/kota-zo/Orpheon, formerly Myspoti), GPL-3.0.
// Derived from the Kotlin sources by kota-zo and contributors. Keep these notices; if you ever
// distribute this, publish your complete source under GPL-3.0 (see LICENSE and NOTICE.md).
import SwiftUI

@MainActor
struct SettingsView: View {
    @EnvironmentObject var env: AppEnvironment
    @EnvironmentObject var playback: PlaybackManager
    @State private var confirmSignOut = false
    @State private var opsStatus: String?
    @State private var refreshing = false

    var body: some View {
        NavigationView {
            List {
                accountSection
                sourceSection
                playbackSection
                dataSection
                aboutSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Settings")
            .confirmationDialog("Sign out of Spotify?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("Sign out", role: .destructive) { Task { await env.signOut() } }
                Button("Cancel", role: .cancel) {}
            }
        }
        .navigationViewStyle(.stack)
        .miniPlayerInset()
    }

    private var accountSection: some View {
        Section {
            if let a = env.account {
                HStack(spacing: 12) {
                    Artwork(url: a.images.bestUrl(minPx: 120), size: 52, circle: true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(a.name).font(.headline)
                        Text(a.premium ? "Spotify Premium" : "Spotify Free").font(.caption).foregroundColor(Theme.secondary)
                    }
                    Spacer()
                }
                if let c = a.country {
                    HStack { Text("Country"); Spacer(); Text(c).foregroundColor(Theme.secondary) }
                }
                if !a.premium {
                    Text("Spotify only allows Premium accounts to control playback from other apps. On a Free account, songs open in the Spotify app instead.")
                        .font(.footnote).foregroundColor(Theme.secondary)
                }
            } else {
                Text("Signed in")
            }
            Button("Sign out", role: .destructive) { confirmSignOut = true }
        } header: {
            Text("Account")
        }
    }

    private var sourceSection: some View {
        Section {
            Picker("Play songs from", selection: $playback.sourcePreference) {
                ForEach(SourcePreference.allCases) { p in
                    Text(p.label).tag(p)
                }
            }
            Toggle("Show the source under titles", isOn: $playback.showSourceLabel)
            Toggle("Allow 30-second previews", isOn: $playback.allowPreviews)
            NavigationLink(destination: SourcesSetupView()) {
                Text("Source setup")
            }
        } header: {
            Text("Playback source")
        } footer: {
            Text("Spotify's own audio cannot play in this app, so each Spotify song is matched to the same recording on the source you pick and played there. \"All sources\" tries Apple Music, then Audius, then YouTube. Music that needs a paid plan you do not have is skipped.")
        }
    }

    private var playbackSection: some View {
        Section {
            NavigationLink(destination: DevicePickerView()) {
                HStack {
                    Text("Spotify Connect devices")
                    Spacer()
                    Text(playback.device?.name ?? "").foregroundColor(Theme.secondary)
                }
            }
            Button("Open the Spotify app") { SpotifyLinks.open() }
        } header: {
            Text("Playback")
        } footer: {
            Text("Spotify's audio is DRM-protected (Widevine), which iOS cannot decode. Songs play in the official Spotify app, or on any Spotify Connect device, and this app shows and controls them. Radio and podcast files that are not protected play inside this app.")
        }
    }

    private var dataSection: some View {
        Section {
            HStack {
                Text("Known Spotify operations")
                Spacer()
                Text("\(env.gql.ops.hashes.count)").foregroundColor(Theme.secondary)
            }
            if let b = env.gql.ops.buildVersion {
                HStack {
                    Text("Web Player build")
                    Spacer()
                    Text(b).font(.caption).foregroundColor(Theme.secondary).lineLimit(1)
                }
            }
            Button {
                refreshOps()
            } label: {
                HStack {
                    Text("Update operations from Spotify")
                    if refreshing { Spacer(); ProgressView() }
                }
            }
            .disabled(refreshing)
            if let s = opsStatus {
                Text(s).font(.footnote).foregroundColor(Theme.secondary)
            }
        } header: {
            Text("Spotify data")
        } footer: {
            Text("Spotify's catalogue calls change with its Web Player. The app reads the new list by itself; this forces it.")
        }
    }

    private var aboutSection: some View {
        Section {
            HStack { Text("Version"); Spacer(); Text(appVersion).foregroundColor(Theme.secondary) }
            Text("An iOS port of Orpheon by kota-zo and contributors (GPL-3.0). Unofficial; not affiliated with Spotify.")
                .font(.footnote)
                .foregroundColor(Theme.secondary)
        } header: {
            Text("About")
        }
    }

    private var appVersion: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(v) (\(b))"
    }

    private func refreshOps() {
        refreshing = true
        opsStatus = nil
        Task {
            let changed = await env.gql.refreshOps()
            opsStatus = changed ? "Updated to Spotify's current build." : "Already up to date (or Spotify could not be reached)."
            refreshing = false
        }
    }
}

@MainActor
struct DevicePickerView: View {
    @EnvironmentObject var playback: PlaybackManager

    var body: some View {
        List {
            Section {
                ForEach(playback.devices) { d in
                    Button {
                        Task { await playback.transfer(to: d) }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(d.name)
                                Text(d.type).font(.caption).foregroundColor(Theme.secondary)
                            }
                            Spacer()
                            if d.active { Image(systemName: "checkmark").foregroundColor(Theme.accent) }
                        }
                    }
                }
                if playback.devices.isEmpty {
                    Text("No devices. Open Spotify on this phone or another device, then pull to refresh.")
                        .foregroundColor(Theme.secondary)
                }
            } footer: {
                Text("Choosing a device moves playback there.")
            }
        }
        .navigationTitle("Devices")
        .refreshable { await playback.refreshDevices() }
        .task { await playback.refreshDevices() }
    }
}

/// Where each source is set up: permissions, keys and what to expect.
@MainActor
struct SourcesSetupView: View {
    @EnvironmentObject var env: AppEnvironment
    @EnvironmentObject var playback: PlaybackManager
    @State private var appleStatus: AppleMusicStatus = .unknown
    @State private var key = ""
    @State private var keySaved = false

    var body: some View {
        List {
            Section {
                HStack {
                    Text("Status")
                    Spacer()
                    Text(appleStatus.text).font(.footnote).foregroundColor(Theme.secondary).multilineTextAlignment(.trailing)
                }
                Button("Check / allow access") {
                    Task { appleStatus = await playback.engine.apple.refreshStatus(request: true) }
                }
            } header: {
                Text("Apple Music")
            } footer: {
                Text("Songs play with Apple's own player and your own Apple Music subscription. Without a subscription only Apple's free 30-second previews exist (turn them on above if you want them).")
            }
            Section {
                SecureField("YouTube Data API key", text: $key)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                Button(keySaved ? "Saved" : "Save key") {
                    env.store.set("youtubeApiKey", key.trimmingCharacters(in: .whitespacesAndNewlines))
                    keySaved = true
                    Task { await playback.engine.resolver.forget() }
                }
                .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } header: {
                Text("YouTube")
            } footer: {
                Text("Create a free key for the YouTube Data API v3 in Google Cloud Console (about 100 song lookups a day). YouTube plays in its own player, with its ads, on the Now Playing screen: YouTube requires its player to be visible, so it pauses when you close that screen.")
            }
            Section {
                Text("Nothing to set up. Artist-uploaded music from audius.co; tracks behind a paywall or a follower gate are skipped.")
                    .font(.footnote).foregroundColor(Theme.secondary)
            } header: {
                Text("Audius")
            }
        }
        .navigationTitle("Source setup")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refresh() }
        .onAppear { key = env.store.get("youtubeApiKey") ?? "" }
    }

    private func refresh() async {
        appleStatus = await playback.engine.apple.refreshStatus(request: false)
    }
}
