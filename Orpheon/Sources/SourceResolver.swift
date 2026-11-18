// Orpheon for iOS: a port of Orpheon (https://github.com/kota-zo/Orpheon, formerly Myspoti), GPL-3.0.
// Derived from the Kotlin sources by kota-zo and contributors. Keep these notices; if you ever
// distribute this, publish your complete source under GPL-3.0 (see LICENSE and NOTICE.md).
import Foundation

/// Turns a Spotify track into something playable on the chosen source (or on each, in turn, for "All").
actor SourceResolver {
    private let providers: [AudioSourceID: SourceProvider]
    private var found: [String: ResolvedAudio] = [:]
    private var missed: Set<String> = []

    init(providers: [SourceProvider]) {
        var map: [AudioSourceID: SourceProvider] = [:]
        for p in providers { map[p.id] = p }
        self.providers = map
    }

    private func key(_ uri: Uri, _ pref: SourcePreference, _ options: SourceOptions) -> String {
        "\(uri)|\(pref.rawValue)|\(options.allowPreviews ? "p" : "f")"
    }

    func forget() {
        found.removeAll()
        missed.removeAll()
    }

    func availability(of id: AudioSourceID) async -> SourceAvailability? {
        guard let p = providers[id] else { return nil }
        return await p.availability()
    }

    func resolve(_ track: Track, preference: SourcePreference, options: SourceOptions) async -> Resolution {
        let k = key(track.uri, preference, options)
        if let hit = found[k] { return .found(hit) }
        if missed.contains(k) { return .notFound(["no match"]) }
        let query = TrackQuery(track)
        var reasons: [String] = []
        var onlyPlainMisses = true
        for id in preference.providers {
            guard let p = providers[id] else { continue }
            do {
                if let r = try await p.find(query, options: options) {
                    found[k] = r
                    return .found(r)
                }
                reasons.append("\(id.label): no match")
            } catch let e as SourceError {
                onlyPlainMisses = false
                reasons.append("\(id.label): \(e.message)")
            } catch {
                onlyPlainMisses = false
                reasons.append("\(id.label): \(error.localizedDescription)")
            }
        }
        // A real miss is remembered for the session; a setup problem or an outage is not (it may be fixed).
        if onlyPlainMisses { missed.insert(k) }
        return .notFound(reasons)
    }
}
