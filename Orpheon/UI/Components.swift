// Orpheon for iOS: a port of Orpheon (https://github.com/kota-zo/Orpheon, formerly Myspoti), GPL-3.0.
// Derived from the Kotlin sources by kota-zo and contributors. Keep these notices; if you ever
// distribute this, publish your complete source under GPL-3.0 (see LICENSE and NOTICE.md).
import SwiftUI

// MARK: Artwork

@MainActor
struct Artwork: View {
    var url: URL?
    var size: CGFloat = 48
    var corner: CGFloat = 4
    var circle = false

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image.resizable().aspectRatio(contentMode: .fill)
            default:
                ZStack {
                    Theme.elevated
                    Image(systemName: "music.note").foregroundColor(Theme.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: circle ? size / 2 : corner))
    }
}

/// The small label that says which source a song's audio comes from.
@MainActor
struct SourceBadge: View {
    let label: String

    var body: some View {
        Text(label.uppercased())
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(Theme.accent)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.accent.opacity(0.6), lineWidth: 0.5))
    }
}

@MainActor
struct ExplicitBadge: View {
    var body: some View {
        Text("E")
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(.black)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Theme.secondary)
            .cornerRadius(2)
    }
}

// MARK: Loading and errors

@MainActor
struct ErrorView: View {
    let message: String
    var retry: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle").font(.title2).foregroundColor(Theme.secondary)
            Text(message).font(.subheadline).foregroundColor(Theme.secondary).multilineTextAlignment(.center)
            if let retry = retry {
                Button("Try again", action: retry)
                    .buttonStyle(.bordered)
                    .tint(Theme.accent)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }
}

@MainActor
struct LoadView<T, Content: View>: View {
    let state: LoadState<T>
    var retry: (() -> Void)? = nil
    @ViewBuilder let content: (T) -> Content

    var body: some View {
        switch state {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, minHeight: 240)
        case .failed(let message):
            ErrorView(message: message, retry: retry)
        case .loaded(let value):
            content(value)
        }
    }
}

@MainActor
struct SectionTitle: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.title3.weight(.bold))
            .foregroundColor(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
    }
}

// MARK: Cards

@MainActor
struct CardView: View {
    let card: MediaCard
    var width: CGFloat = 140

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Artwork(url: card.images.bestUrl(minPx: 300), size: width, corner: 6, circle: card.kind == .artist)
            Text(card.title)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.white)
                .lineLimit(1)
            if let s = card.subtitle, !s.isEmpty {
                Text(s).font(.caption).foregroundColor(Theme.secondary).lineLimit(2)
            }
        }
        .frame(width: width, alignment: .leading)
    }
}

/// A card that opens its page, or plays when it is a track.
@MainActor
struct CardLink: View {
    @EnvironmentObject var playback: PlaybackManager
    let card: MediaCard
    var width: CGFloat = 140

    var body: some View {
        if let route = Route.from(card: card) {
            NavigationLink(destination: RouteView(route: route)) {
                CardView(card: card, width: width)
            }
            .buttonStyle(.plain)
        } else {
            Button {
                Task { await playback.play(uris: [card.uri]) }
            } label: {
                CardView(card: card, width: width)
            }
            .buttonStyle(.plain)
        }
    }
}

@MainActor
struct ShelfView: View {
    let shelf: Shelf

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let t = shelf.title, !t.isEmpty { SectionTitle(text: t) }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(shelf.items) { card in
                        CardLink(card: card)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }
}

// MARK: Rows

@MainActor
struct TrackRow: View {
    @EnvironmentObject var env: AppEnvironment
    @EnvironmentObject var playback: PlaybackManager
    let track: Track
    var number: Int? = nil
    var showArt = true
    var onPlay: () -> Void
    var onRemove: (() -> Void)? = nil

    private var isCurrent: Bool { playback.now?.uri == track.uri }
    private var sourceLabel: String? { playback.showSourceLabel ? playback.resolvedLabels[track.uri] : nil }

    var body: some View {
        HStack(spacing: 12) {
            if let n = number {
                Text("\(n)").font(.subheadline).foregroundColor(Theme.secondary).frame(width: 26)
            }
            if showArt {
                Artwork(url: track.album?.images.bestUrl(minPx: 120), size: 48)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(track.name)
                    .font(.body)
                    .foregroundColor(isCurrent ? Theme.accent : (track.playable ? .white : Theme.secondary))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if track.explicit { ExplicitBadge() }
                    Text(track.artistLine).font(.subheadline).foregroundColor(Theme.secondary).lineLimit(1)
                    if let l = sourceLabel { SourceBadge(label: l) }
                }
            }
            Spacer(minLength: 8)
            TrackMenu(track: track, onRemove: onRemove)
        }
        .contentShape(Rectangle())
        .onTapGesture { onPlay() }
    }
}

@MainActor
struct TrackMenu: View {
    @EnvironmentObject var env: AppEnvironment
    @EnvironmentObject var playback: PlaybackManager
    let track: Track
    var onRemove: (() -> Void)? = nil

    var body: some View {
        Menu {
            Button {
                playback.addToQueue(track.uri)
            } label: {
                Label("Add to queue", systemImage: "text.badge.plus")
            }
            Button {
                env.addToPlaylist([track.uri])
            } label: {
                Label("Add to playlist", systemImage: "plus.circle")
            }
            if let a = track.artists.first, !a.uri.isEmpty {
                Button {
                    env.present(.artist(a.uri))
                } label: {
                    Label("Go to artist", systemImage: "person")
                }
            }
            if let al = track.album, !al.uri.isEmpty {
                Button {
                    env.present(.album(al.uri))
                } label: {
                    Label("Go to album", systemImage: "square.stack")
                }
            }
            Button {
                SpotifyLinks.open(track.uri)
            } label: {
                Label("Open in Spotify", systemImage: "arrow.up.right.square")
            }
            if let remove = onRemove {
                Button(role: .destructive) {
                    remove()
                } label: {
                    Label("Remove from playlist", systemImage: "trash")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .foregroundColor(Theme.secondary)
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
    }
}

@MainActor
struct EpisodeRow: View {
    @EnvironmentObject var playback: PlaybackManager
    let episode: Episode
    var onPlay: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 12) {
                Artwork(url: episode.images.bestUrl(minPx: 160), size: 56, corner: 6)
                VStack(alignment: .leading, spacing: 3) {
                    Text(episode.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(episode.played ? Theme.secondary : .white)
                        .lineLimit(2)
                    Text(subtitle).font(.caption).foregroundColor(Theme.secondary)
                }
                Spacer(minLength: 0)
            }
            if let d = episode.description, !d.isEmpty {
                Text(d).font(.caption).foregroundColor(Theme.secondary).lineLimit(3)
            }
            Button(action: onPlay) {
                Label(playback.now?.uri == episode.uri && playback.isPlaying ? "Playing" : "Play", systemImage: "play.fill")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .tint(Theme.accent)
        }
        .padding(.vertical, 6)
    }

    private var subtitle: String {
        var parts: [String] = []
        if let r = episode.releaseDate { parts.append(String(r.prefix(10))) }
        parts.append(formatDuration(ms: episode.durationMs))
        return parts.joined(separator: " · ")
    }
}

@MainActor
struct PillButton: View {
    let title: String
    var selected = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(selected ? .black : .white)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(selected ? Theme.accent : Theme.elevated)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

@MainActor
struct PlayShuffleBar: View {
    var onPlay: () -> Void
    var onShuffle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onPlay) {
                Label("Play", systemImage: "play.fill")
                    .font(.headline)
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Theme.accent)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            Button(action: onShuffle) {
                Label("Shuffle", systemImage: "shuffle")
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Theme.elevated)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
    }
}

extension View {
    /// Keeps the mini player above the tab bar and below the screen's own content.
    @MainActor
    func miniPlayerInset() -> some View {
        safeAreaInset(edge: .bottom) { MiniPlayer() }
    }
}
