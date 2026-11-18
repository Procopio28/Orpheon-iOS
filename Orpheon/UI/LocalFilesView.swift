// Orpheon for iOS: a port of Orpheon (https://github.com/kota-zo/Orpheon, formerly Myspoti), GPL-3.0.
// Derived from the Kotlin sources by kota-zo and contributors. Keep these notices; if you ever
// distribute this, publish your complete source under GPL-3.0 (see LICENSE and NOTICE.md).
import SwiftUI
import UniformTypeIdentifiers

/// The user's own audio files (from the Files app), played inside the app.
@MainActor
struct LocalFilesView: View {
    @EnvironmentObject var env: AppEnvironment
    @EnvironmentObject var playback: PlaybackManager
    @ObservedObject var library: LocalLibrary
    @State private var showImporter = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                if library.tracks.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "folder.badge.plus").font(.largeTitle).foregroundColor(Theme.secondary)
                        Text("Add audio files from the Files app. They play inside Orpheon, with lock-screen controls.")
                            .font(.subheadline)
                            .foregroundColor(Theme.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(32)
                    .frame(maxWidth: .infinity)
                }
                ForEach(Array(library.tracks.enumerated()), id: \.offset) { i, t in
                    row(t, index: i)
                }
                if library.importing {
                    ProgressView().frame(maxWidth: .infinity).padding(16)
                }
                if let e = library.lastError {
                    Text(e).font(.footnote).foregroundColor(.red).padding(16)
                }
            }
            .padding(.vertical, 12)
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("Local files")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showImporter = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                Task { await library.add(urls) }
            }
        }
    }

    private func row(_ t: LocalTrack, index: Int) -> some View {
        HStack(spacing: 12) {
            Artwork(url: library.artworkURL(t), size: 48)
            VStack(alignment: .leading, spacing: 3) {
                Text(t.title)
                    .foregroundColor(playback.now?.uri == "orpheon:local:file-" + t.id ? Theme.accent : .white)
                    .lineLimit(1)
                Text([t.artist, t.album].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundColor(Theme.secondary).lineLimit(1)
            }
            Spacer()
            Menu {
                Button(role: .destructive) {
                    library.remove(t)
                } label: {
                    Label("Remove", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis").foregroundColor(Theme.secondary).frame(width: 36, height: 36)
            }
        }
        .padding(.horizontal, 16)
        .contentShape(Rectangle())
        .onTapGesture {
            playback.playLocal(library.tracks.map { library.item($0) }, startAt: index)
        }
    }
}
