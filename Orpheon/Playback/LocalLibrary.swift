// Orpheon for iOS: a port of Orpheon (https://github.com/kota-zo/Orpheon, formerly Myspoti), GPL-3.0.
// Derived from the Kotlin sources by kota-zo and contributors. Keep these notices; if you ever
// distribute this, publish your complete source under GPL-3.0 (see LICENSE and NOTICE.md).
import Foundation
import Combine
import AVFoundation

/// An audio file the user added from the Files app. Orpheon's "local files".
struct LocalTrack: Codable, Identifiable, Hashable {
    var id: String
    var fileName: String
    var title: String
    var artist: String?
    var album: String?
    var durationMs: Int64
    var hasArtwork: Bool
}

/// The user's own audio files, copied into the app so they stay playable. Plays with `LocalPlayer`.
@MainActor
final class LocalLibrary: ObservableObject {
    @Published private(set) var tracks: [LocalTrack] = []
    @Published private(set) var importing = false
    @Published var lastError: String?

    private let folder: URL
    private let indexURL: URL

    init() {
        let dir = KeyValueStore.directory.appendingPathComponent("LocalMusic", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        folder = dir
        indexURL = dir.appendingPathComponent("index.json")
        if let data = try? Data(contentsOf: indexURL), let list = try? JSONDecoder().decode([LocalTrack].self, from: data) {
            tracks = list
        }
    }

    func fileURL(_ t: LocalTrack) -> URL { folder.appendingPathComponent(t.fileName) }
    func artworkURL(_ t: LocalTrack) -> URL? { t.hasArtwork ? folder.appendingPathComponent(t.id + ".jpg") : nil }

    func item(_ t: LocalTrack) -> LocalItem {
        LocalItem(id: "file-" + t.id, title: t.title, subtitle: t.artist, url: fileURL(t), artworkURL: artworkURL(t),
                  durationMs: t.durationMs > 0 ? t.durationMs : nil, isLive: false, uri: nil, showName: t.album)
    }

    private func saveIndex() {
        if let data = try? JSONEncoder().encode(tracks) { try? data.write(to: indexURL, options: .atomic) }
    }

    /// Copies the picked files in and reads their tags.
    func add(_ urls: [URL]) async {
        importing = true
        defer { importing = false }
        let folder = self.folder
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            let result = await Task.detached { LocalLibrary.copyAndRead(url, into: folder) }.value
            if scoped { url.stopAccessingSecurityScopedResource() }
            if let t = result { tracks.append(t) } else { lastError = "Could not read \(url.lastPathComponent)." }
        }
        saveIndex()
    }

    func remove(_ t: LocalTrack) {
        try? FileManager.default.removeItem(at: fileURL(t))
        if let a = artworkURL(t) { try? FileManager.default.removeItem(at: a) }
        tracks.removeAll { $0.id == t.id }
        saveIndex()
    }

    nonisolated private static func copyAndRead(_ url: URL, into folder: URL) -> LocalTrack? {
        let id = UUID().uuidString.lowercased()
        let ext = url.pathExtension.isEmpty ? "m4a" : url.pathExtension
        let name = "\(id).\(ext)"
        let dest = folder.appendingPathComponent(name)
        do { try FileManager.default.copyItem(at: url, to: dest) } catch { return nil }
        let asset = AVURLAsset(url: dest)
        var title: String?
        var artist: String?
        var album: String?
        var art: Data?
        for item in asset.commonMetadata {
            guard let key = item.commonKey?.rawValue else { continue }
            switch key {
            case "title": title = item.stringValue
            case "artist": artist = item.stringValue
            case "albumName": album = item.stringValue
            case "artwork": art = item.dataValue
            default: break
            }
        }
        var hasArt = false
        if let a = art, !a.isEmpty {
            hasArt = (try? a.write(to: folder.appendingPathComponent(id + ".jpg"), options: .atomic)) != nil
        }
        let seconds = asset.duration.seconds
        let fallbackTitle = url.deletingPathExtension().lastPathComponent
        return LocalTrack(
            id: id, fileName: name,
            title: (title?.isEmpty == false ? title : nil) ?? fallbackTitle,
            artist: artist, album: album,
            durationMs: seconds.isFinite && seconds > 0 ? Int64(seconds * 1000) : 0,
            hasArtwork: hasArt)
    }
}
