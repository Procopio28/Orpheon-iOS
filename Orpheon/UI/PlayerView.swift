// Orpheon for iOS: a port of Orpheon (https://github.com/kota-zo/Orpheon, formerly Myspoti), GPL-3.0.
// Derived from the Kotlin sources by kota-zo and contributors. Keep these notices; if you ever
// distribute this, publish your complete source under GPL-3.0 (see LICENSE and NOTICE.md).
import SwiftUI
import WebKit

enum PlayerSheet: Identifiable {
    case devices
    case queue
    case addToPlaylist(Uri)

    var id: String {
        switch self {
        case .devices: return "devices"
        case .queue: return "queue"
        case .addToPlaylist(let u): return "add:" + u
        }
    }
}

@MainActor
struct PlayerView: View {
    @EnvironmentObject var env: AppEnvironment
    @EnvironmentObject var playback: PlaybackManager
    @State private var showLyrics = false
    @State private var sheet: PlayerSheet?

    var body: some View {
        NavigationView {
            ZStack {
                LinearGradient(colors: [Color(white: 0.24), Theme.bg], startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
                VStack(spacing: 16) {
                    topBar
                    if let now = playback.now {
                        if playback.source == .youtube {
                            Spacer(minLength: 0)
                            YouTubeVideoView(player: playback.engine.youtube)
                                .frame(width: 300, height: 300)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            Spacer(minLength: 0)
                        } else if showLyrics {
                            LyricsView(item: now)
                        } else {
                            Spacer(minLength: 0)
                            Artwork(url: now.imageUrl.flatMap { URL(string: $0) }, size: 300, corner: 10)
                                .shadow(color: .black, radius: 18, x: 0, y: 8)
                            Spacer(minLength: 0)
                        }
                        titleRow(now)
                        Scrubber()
                        controls
                        bottomRow(now)
                    } else {
                        Spacer()
                        Text("Nothing is playing").foregroundColor(Theme.secondary)
                        Spacer()
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
            }
            .navigationBarHidden(true)
        }
        .navigationViewStyle(.stack)
        .sheet(item: $sheet) { s in
            switch s {
            case .devices:
                DevicesSheet(onClose: { sheet = nil })
                    .environmentObject(env)
                    .environmentObject(playback)
            case .queue:
                QueueSheet(onClose: { sheet = nil })
                    .environmentObject(env)
                    .environmentObject(playback)
            case .addToPlaylist(let uri):
                AddToPlaylistSheet(trackUris: [uri], onClose: { sheet = nil })
                    .environmentObject(env)
                    .environmentObject(playback)
            }
        }
    }

    private var topBar: some View {
        HStack {
            Button {
                env.showPlayer = false
            } label: {
                Image(systemName: "chevron.down").font(.title3).foregroundColor(.white).frame(width: 44, height: 44)
            }
            Spacer()
            VStack(spacing: 2) {
                Text("PLAYING FROM").font(.system(size: 10, weight: .semibold)).foregroundColor(Theme.secondary)
                Text(sourceLine).font(.caption.weight(.semibold)).foregroundColor(.white).lineLimit(1)
            }
            Spacer()
            Color.clear.frame(width: 44, height: 44)
        }
    }

    private var sourceLine: String {
        switch playback.source {
        case .remote: return playback.device?.name ?? "Spotify"
        case .appleMusic, .youtube: return playback.engine.label ?? "Finding a source..."
        case .local: return playback.engine.engaged ? (playback.engine.label ?? "Finding a source...") : (playback.now?.provider ?? "This phone")
        case .none: return "Orpheon"
        }
    }

    private func titleRow(_ now: NowPlaying) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if now.explicit { ExplicitBadge() }
                    Text(now.name).font(.title3.weight(.bold)).foregroundColor(.white).lineLimit(1)
                }
                if let a = now.artists.first, !a.uri.isEmpty {
                    NavigationLink(destination: ArtistView(uri: a.uri)) {
                        Text(now.artistLine).font(.body).foregroundColor(Theme.secondary).lineLimit(1)
                    }
                } else {
                    Text(now.artistLine).font(.body).foregroundColor(Theme.secondary).lineLimit(1)
                }
                if playback.showSourceLabel, let p = now.provider {
                    SourceBadge(label: p)
                }
            }
            Spacer(minLength: 0)
            if now.kind == .track || now.kind == .episode {
                Button {
                    playback.toggleLiked()
                } label: {
                    Image(systemName: playback.liked ? "heart.fill" : "heart")
                        .font(.title2)
                        .foregroundColor(playback.liked ? Theme.accent : .white)
                }
            }
        }
    }

    private var controls: some View {
        HStack {
            Button {
                playback.setShuffle(!playback.shuffle)
            } label: {
                Image(systemName: "shuffle")
                    .font(.title3)
                    .foregroundColor(playback.shuffle ? Theme.accent : .white)
                    .frame(width: 48, height: 48)
            }
            .disabled(!playback.canShuffle)
            Spacer()
            Button {
                playback.previous()
            } label: {
                Image(systemName: "backward.fill").font(.title).foregroundColor(.white).frame(width: 56, height: 56)
            }
            Spacer()
            Button {
                playback.togglePlayPause()
            } label: {
                ZStack {
                    Circle().fill(Color.white).frame(width: 68, height: 68)
                    if playback.isBuffering {
                        ProgressView()
                    } else {
                        Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 28))
                            .foregroundColor(.black)
                    }
                }
            }
            Spacer()
            Button {
                playback.next()
            } label: {
                Image(systemName: "forward.fill").font(.title).foregroundColor(.white).frame(width: 56, height: 56)
            }
            Spacer()
            Button {
                playback.cycleRepeat()
            } label: {
                Image(systemName: playback.repeatMode == .track ? "repeat.1" : "repeat")
                    .font(.title3)
                    .foregroundColor(playback.repeatMode == .off ? .white : Theme.accent)
                    .frame(width: 48, height: 48)
            }
        }
    }

    private var speedLabel: String {
        let s = playback.speed
        return (s == s.rounded() ? String(Int(s)) : String(format: "%g", s)) + "x"
    }

    private func bottomRow(_ now: NowPlaying) -> some View {
        HStack(spacing: 28) {
            Button {
                sheet = .devices
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "hifispeaker.2.fill")
                    Text(playback.source == .remote ? (playback.device?.name ?? "Devices") : "This phone").lineLimit(1)
                }
                .font(.footnote.weight(.semibold))
                .foregroundColor(playback.source == .remote ? Theme.accent : .white)
            }
            .disabled(!playback.canChangeDevice)
            Spacer()
            Button {
                showLyrics.toggle()
            } label: {
                Image(systemName: "quote.bubble" + (showLyrics ? ".fill" : ""))
                    .font(.title3)
                    .foregroundColor(showLyrics ? Theme.accent : .white)
            }
            .disabled(playback.source == .youtube)
            if playback.supportsQueue {
                Button {
                    sheet = .queue
                } label: {
                    Image(systemName: "list.bullet").font(.title3).foregroundColor(.white)
                }
            }
            if playback.source == .local && playback.durationMs > 0 {
                Button {
                    playback.cycleSpeed()
                } label: {
                    Text(speedLabel).font(.footnote.weight(.bold)).foregroundColor(playback.speed == 1.0 ? .white : Theme.accent)
                }
            }
            Menu {
                if now.kind == .track {
                    Button {
                        sheet = .addToPlaylist(now.uri)
                    } label: {
                        Label("Add to playlist", systemImage: "plus.circle")
                    }
                }
                if now.uri.hasPrefix("spotify:") {
                    Button {
                        SpotifyLinks.open(now.uri)
                    } label: {
                        Label("Open in Spotify", systemImage: "arrow.up.right.square")
                    }
                }
                if let al = now.album, !al.uri.isEmpty {
                    Button {
                        env.present(.album(al.uri))
                    } label: {
                        Label("Go to album", systemImage: "square.stack")
                    }
                }
            } label: {
                Image(systemName: "ellipsis").font(.title3).foregroundColor(.white).frame(width: 36, height: 36)
            }
        }
    }
}

/// The progress slider. Between polls the position runs on the clock; dragging takes it over.
@MainActor
struct Scrubber: View {
    @EnvironmentObject var playback: PlaybackManager
    @State private var dragging = false
    @State private var dragValue: Double = 0

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 0.25)) { context in
            VStack(spacing: 2) {
                Slider(
                    value: Binding(
                        get: { dragging ? dragValue : fraction(playback.positionMs(at: context.date)) },
                        set: { dragValue = $0 }),
                    in: 0...1,
                    onEditingChanged: { editing in
                        if editing {
                            dragValue = fraction(playback.positionMs())
                            dragging = true
                        } else {
                            dragging = false
                            playback.seek(toMs: Int64(dragValue * Double(playback.durationMs)))
                        }
                    })
                    .accentColor(Theme.accent)
                    .disabled(!playback.restrictions.canSeek || playback.durationMs <= 0)
                HStack {
                    Text(formatDuration(ms: shownPosition(context.date)))
                    Spacer()
                    Text(remaining(context.date))
                }
                .font(.caption.monospacedDigit())
                .foregroundColor(Theme.secondary)
            }
        }
    }

    private func fraction(_ ms: Int64) -> Double {
        guard playback.durationMs > 0 else { return 0 }
        return Swift.min(1, Swift.max(0, Double(ms) / Double(playback.durationMs)))
    }

    private func shownPosition(_ date: Date) -> Int64 {
        dragging ? Int64(dragValue * Double(playback.durationMs)) : playback.positionMs(at: date)
    }

    private func remaining(_ date: Date) -> String {
        if playback.durationMs <= 0 { return "LIVE" }
        return "-" + formatDuration(ms: Swift.max(0, playback.durationMs - shownPosition(date)))
    }
}

// MARK: - Lyrics

@MainActor
struct LyricsView: View {
    @EnvironmentObject var env: AppEnvironment
    @EnvironmentObject var playback: PlaybackManager
    let item: NowPlaying
    @State private var state: LoadState<Lyrics?> = .loading

    var body: some View {
        Group {
            switch state {
            case .loading:
                VStack { Spacer(); ProgressView(); Spacer() }
            case .failed(let m):
                VStack { Spacer(); Text(m).foregroundColor(Theme.secondary); Spacer() }
            case .loaded(let lyrics):
                if let l = lyrics {
                    lines(l)
                } else {
                    VStack { Spacer(); Text("No lyrics for this song").foregroundColor(Theme.secondary); Spacer() }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: item.uri) { await load() }
    }

    private func load() async {
        state = .loading
        state = .loaded(await env.lyrics.lyrics(for: item))
    }

    /// A line of lyrics; the current one lights up word by word when the source has word timing.
    private func lineText(_ line: LyricsLine, isCurrent: Bool, synced: Bool, past: Bool, at date: Date) -> Text {
        let lit = Color.white
        let dim = Color(white: 1, opacity: past ? 0.45 : 0.3)
        if isCurrent, let words = line.words, !words.isEmpty {
            let pos = playback.positionMs(at: date)
            var out = Text("")
            for w in words {
                out = out + Text(w.text).foregroundColor(w.startMs <= pos ? lit : dim)
            }
            return out
        }
        return Text(line.text.isEmpty ? "♪" : line.text).foregroundColor(!synced || isCurrent ? lit : dim)
    }

    private func currentIndex(_ l: Lyrics, at ms: Int64) -> Int {
        guard l.synced else { return -1 }
        var idx = -1
        for (i, line) in l.lines.enumerated() where line.startMs <= ms + 150 { idx = i }
        return idx
    }

    private func lines(_ l: Lyrics) -> some View {
        TimelineView(.periodic(from: Date(), by: 0.25)) { context in
            let current = currentIndex(l, at: playback.positionMs(at: context.date))
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(l.lines.enumerated()), id: \.offset) { i, line in
                            lineText(line, isCurrent: i == current, synced: l.synced, past: i < current, at: context.date)
                                .font(.title2.weight(.bold))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(i)
                                .onTapGesture {
                                    if l.synced { playback.seek(toMs: line.startMs) }
                                }
                        }
                        if let p = l.provider {
                            Text("Lyrics: \(p)").font(.caption).foregroundColor(Theme.secondary).padding(.top, 12)
                        }
                    }
                    .padding(.vertical, 40)
                }
                .onChange(of: current) { c in
                    if c >= 0 { withAnimation { proxy.scrollTo(c, anchor: .center) } }
                }
            }
        }
    }
}

// MARK: - Devices and queue

@MainActor
struct DevicesSheet: View {
    @EnvironmentObject var env: AppEnvironment
    @EnvironmentObject var playback: PlaybackManager
    var onClose: () -> Void
    @State private var volume: Double = 50

    var body: some View {
        NavigationView {
            List {
                Section {
                    ForEach(playback.devices) { d in
                        Button {
                            Task {
                                await playback.transfer(to: d)
                                onClose()
                            }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: icon(d.type))
                                    .foregroundColor(d.active ? Theme.accent : .white)
                                    .frame(width: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(d.name).foregroundColor(d.active ? Theme.accent : .white)
                                    Text(d.type).font(.caption).foregroundColor(Theme.secondary)
                                }
                                Spacer()
                                if d.active { Image(systemName: "speaker.wave.2.fill").foregroundColor(Theme.accent) }
                            }
                        }
                    }
                    if playback.devices.isEmpty {
                        Text("No Spotify devices found. Open Spotify on this phone or another device.")
                            .foregroundColor(Theme.secondary)
                    }
                } header: {
                    Text("Spotify Connect devices")
                } footer: {
                    Text("Spotify's audio plays on the device you pick. This app controls it.")
                }
                if let d = playback.device, d.type.lowercased() != "smartphone" {
                    Section {
                        HStack(spacing: 10) {
                            Image(systemName: "speaker.fill").foregroundColor(Theme.secondary)
                            Slider(value: $volume, in: 0...100, onEditingChanged: { editing in
                                if !editing { playback.setVolume(percent: Int(volume)) }
                            })
                            .accentColor(Theme.accent)
                            Image(systemName: "speaker.wave.3.fill").foregroundColor(Theme.secondary)
                        }
                    } header: {
                        Text("Volume")
                    }
                }
                Section {
                    Button("Open the Spotify app") { SpotifyLinks.open() }
                    Button("Refresh") { Task { await playback.refreshDevices() } }
                }
            }
            .navigationTitle("Play on")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", action: onClose)
                }
            }
        }
        .navigationViewStyle(.stack)
        .task { await playback.refreshDevices() }
        .onAppear { volume = playback.device?.volume ?? 50 }
    }

    private func icon(_ type: String) -> String {
        switch type.lowercased() {
        case "smartphone": return "iphone"
        case "computer": return "desktopcomputer"
        case "speaker": return "hifispeaker.fill"
        case "tv": return "tv"
        case "castaudio", "castvideo": return "airplayaudio"
        case "automobile": return "car.fill"
        default: return "hifispeaker"
        }
    }
}

@MainActor
struct QueueSheet: View {
    @EnvironmentObject var playback: PlaybackManager
    var onClose: () -> Void

    var body: some View {
        NavigationView {
            List {
                if let q = playback.queue {
                    if let c = q.current {
                        Section {
                            queueRow(c, highlighted: true)
                        } header: {
                            Text("Now playing")
                        }
                    }
                    Section {
                        ForEach(Array(q.queued.enumerated()), id: \.offset) { _, n in
                            queueRow(n, highlighted: false)
                        }
                    } header: {
                        Text("Next in queue")
                    }
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Queue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", action: onClose)
                }
            }
        }
        .navigationViewStyle(.stack)
        .task { await playback.loadQueue() }
    }

    private func queueRow(_ n: NowPlaying, highlighted: Bool) -> some View {
        HStack(spacing: 12) {
            Artwork(url: n.imageUrl.flatMap { URL(string: $0) }, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(n.name).foregroundColor(highlighted ? Theme.accent : .white).lineLimit(1)
                Text(n.artistLine).font(.caption).foregroundColor(Theme.secondary).lineLimit(1)
            }
        }
    }
}

/// YouTube's own embedded player, shown where the artwork is (YouTube requires its player to be visible).
@MainActor
struct YouTubeVideoView: UIViewRepresentable {
    let player: YouTubePlayer

    func makeUIView(context: Context) -> WKWebView { player.webView }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
