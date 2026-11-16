// Orpheon for iOS: a port of Orpheon (https://github.com/kota-zo/Orpheon, formerly Myspoti), GPL-3.0.
// Derived from the Kotlin sources by kota-zo and contributors. Keep these notices; if you ever
// distribute this, publish your complete source under GPL-3.0 (see LICENSE and NOTICE.md).
import SwiftUI
import UIKit

@MainActor
struct RenameSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let initial: String
    var onSave: (String) async throws -> Void
    @State private var text = ""
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextField("Name", text: $text)
                }
                if let e = error {
                    Section { Text(e).foregroundColor(.red) }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(saving || text.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .navigationViewStyle(.stack)
        .onAppear { text = initial }
    }

    private func save() {
        saving = true
        let name = text.trimmingCharacters(in: .whitespaces)
        Task {
            do {
                try await onSave(name)
                dismiss()
            } catch {
                self.error = describe(error)
                saving = false
            }
        }
    }
}

@MainActor
struct NewPlaylistSheet: View {
    @EnvironmentObject var env: AppEnvironment
    @State private var name = ""
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextField("Playlist name", text: $name)
                }
                if let e = error {
                    Section { Text(e).foregroundColor(.red) }
                }
            }
            .navigationTitle("New playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { env.sheet = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { create() }
                        .disabled(saving || name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func create() {
        saving = true
        let n = name.trimmingCharacters(in: .whitespaces)
        Task {
            do {
                _ = try await env.service.createPlaylist(name: n)
                env.sheet = nil
            } catch {
                self.error = describe(error)
                saving = false
            }
        }
    }
}

@MainActor
struct AddToPlaylistSheet: View {
    @EnvironmentObject var env: AppEnvironment
    @EnvironmentObject var playback: PlaybackManager
    let trackUris: [Uri]
    var onClose: () -> Void
    @State private var state: LoadState<[PlaylistChoice]> = .loading
    @State private var busy = false

    struct PlaylistChoice: Identifiable {
        var card: MediaCard
        var contains: Bool
        var id: String { card.uri }
    }

    var body: some View {
        NavigationView {
            ScrollView {
                LoadView(state: state, retry: { Task { await load() } }) { choices in
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if choices.isEmpty {
                            Text("You have no playlists you can add to yet.")
                                .foregroundColor(Theme.secondary)
                                .padding(16)
                        }
                        ForEach(choices) { c in
                            Button {
                                add(to: c)
                            } label: {
                                HStack(spacing: 12) {
                                    Artwork(url: c.card.images.bestUrl(minPx: 120), size: 48)
                                    Text(c.card.title).foregroundColor(.white).lineLimit(1)
                                    Spacer()
                                    if c.contains {
                                        Image(systemName: "checkmark.circle.fill").foregroundColor(Theme.accent)
                                    }
                                }
                                .padding(.horizontal, 16)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(busy)
                        }
                    }
                    .padding(.vertical, 12)
                }
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("Add to playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { onClose() }
                }
            }
        }
        .navigationViewStyle(.stack)
        .task { await load() }
    }

    private func load() async {
        do {
            let list = try await env.service.editablePlaylists(trackUri: trackUris.first)
            state = .loaded(list.map { PlaylistChoice(card: $0.playlist, contains: $0.contains) })
        } catch {
            state = .failed(describe(error))
        }
    }

    private func add(to choice: PlaylistChoice) {
        busy = true
        Task {
            defer { busy = false }
            do {
                try await env.service.addTracks(to: choice.card.uri, trackUris: trackUris)
                onClose()
            } catch {
                playback.message = describe(error)
            }
        }
    }
}

/// The system share sheet.
@MainActor
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
