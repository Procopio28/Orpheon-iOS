// Orpheon for iOS: a port of Orpheon (https://github.com/kota-zo/Orpheon, formerly Myspoti), GPL-3.0.
// Derived from the Kotlin sources by kota-zo and contributors. Keep these notices; if you ever
// distribute this, publish your complete source under GPL-3.0 (see LICENSE and NOTICE.md).
import Foundation

/// Decides whether a search hit on another service is the same recording as a Spotify track.
enum TrackMatcher {
    /// Words that make a different recording of the same song. A hit that has one the track lacks (or the
    /// other way round) is a different version, and is not used.
    static let hardVersionWords: Set<String> = [
        "live", "remix", "acoustic", "instrumental", "karaoke", "cover", "slowed", "sped", "reverb", "nightcore",
        "8d", "mashup", "demo", "unplugged", "rework", "bootleg", "tribute", "reaction",
    ]
    /// Words that usually mark the same audio with a different label: a small penalty only.
    static let softVersionWords: Set<String> = ["lyrics", "version", "edit"]
    static var versionWords: Set<String> { hardVersionWords.union(softVersionWords) }

    /// Noise that carries no identity: "feat. X", "(Remastered 2011)", "- Radio Edit", "[Official Video]".
    private static let bracketed = try! NSRegularExpression(pattern: "[\\(\\[\\{][^\\)\\]\\}]*[\\)\\]\\}]")
    private static let featuring = try! NSRegularExpression(pattern: "\\b(feat|ft|featuring|with)\\b\\.?.*$", options: [.caseInsensitive])
    private static let dashSuffix = try! NSRegularExpression(pattern: "\\s[-–—]\\s(.*(remaster|mono|stereo|edit|version|mix|single|explicit|clean|radio|bonus|deluxe).*)$", options: [.caseInsensitive])

    /// Lowercase, no accents, no brackets, no "feat." tail, punctuation as spaces.
    static func normalize(_ s: String) -> String {
        var t = s as NSString as String
        func strip(_ re: NSRegularExpression, _ text: String) -> String {
            re.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: " ")
        }
        t = strip(bracketed, t)
        t = strip(dashSuffix, t)
        t = strip(featuring, t)
        t = t.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        let allowed = CharacterSet.alphanumerics
        var out = ""
        for u in t.unicodeScalars { out.unicodeScalars.append(allowed.contains(u) ? u : " ") }
        return out.split(separator: " ").joined(separator: " ")
    }

    static func tokens(_ s: String) -> [String] {
        normalize(s).split(separator: " ").map(String.init)
    }

    /// 0...1: how much two titles or names share. Same tokens in any order count as equal.
    static func similarity(_ a: String, _ b: String) -> Double {
        let ta = Set(tokens(a)), tb = Set(tokens(b))
        if ta.isEmpty || tb.isEmpty { return 0 }
        if ta == tb { return 1 }
        let inter = Double(ta.intersection(tb).count)
        let dice = 2 * inter / Double(ta.count + tb.count)
        // One name inside the other ("Queen" in "Queen Official") is a strong sign, but not a perfect one.
        let contained = (ta.isSubset(of: tb) || tb.isSubset(of: ta)) ? 0.85 : 0
        return Swift.max(dice, contained)
    }

    /// The share of `needle`'s words found in `haystack` (for an artist's name inside a video title).
    static func coverage(of needle: String, in haystack: String) -> Double {
        let n = Set(tokens(needle)), h = Set(tokens(haystack))
        if n.isEmpty { return 0 }
        return Double(n.intersection(h).count) / Double(n.count)
    }

    /// Version words in the raw text, looking inside brackets too ("Song (Live at ...)").
    static func versionTags(_ raw: String) -> Set<String> {
        let all = raw.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        var words = Set<String>()
        var current = ""
        for ch in all.unicodeScalars {
            if CharacterSet.alphanumerics.contains(ch) { current.unicodeScalars.append(ch) }
            else { if !current.isEmpty { words.insert(current) }; current = "" }
        }
        if !current.isEmpty { words.insert(current) }
        return words.intersection(versionWords)
    }

    /// How close two lengths are, 0...1; nil when one is unknown.
    static func durationScore(_ wantedMs: Int64, _ foundMs: Int64?) -> Double? {
        guard wantedMs > 0, let found = foundMs, found > 0 else { return nil }
        let d = abs(wantedMs - found)
        if d <= 2_500 { return 1 }
        if d <= 6_000 { return 0.7 }
        if d <= 12_000 { return 0.35 }
        return 0
    }

    struct Candidate {
        var title: String
        /// The artist as the service names it (an uploader or channel for YouTube).
        var artist: String
        var durationMs: Int64?
        /// For uploads that put the artist in the title ("Artist - Song") rather than in the artist field.
        var artistMayBeInTitle = false
        var isTopicChannel = false
    }

    /// A match score from 0 to 1, or nil when the hit cannot be the track (wrong length, wrong artist).
    static func score(_ q: TrackQuery, _ c: Candidate) -> Double? {
        let titleSim = Swift.max(similarity(q.title, c.title),
                                 c.artistMayBeInTitle ? coverage(of: q.title, in: c.title) * 0.95 : 0)
        guard titleSim >= 0.5 else { return nil }

        var artistSim = similarity(q.artist, c.artist)
        artistSim = Swift.max(artistSim, coverage(of: q.artist, in: c.artist) * 0.9)
        if c.artistMayBeInTitle { artistSim = Swift.max(artistSim, coverage(of: q.artist, in: c.title)) }
        if c.isTopicChannel { artistSim = Swift.max(artistSim, similarity(q.artist, c.artist)) }
        if !q.artist.isEmpty && artistSim < 0.5 { return nil }

        let dur = durationScore(q.durationMs, c.durationMs)
        if let d = dur, d == 0, abs(q.durationMs - (c.durationMs ?? 0)) > 25_000 { return nil }

        var score = 0.5 * titleSim + 0.25 * artistSim + 0.25 * (dur ?? 0.55)

        let wanted = versionTags(q.title)
        let found = versionTags(c.title)
        // A different recording (live, remix, karaoke...) is no match, whatever else fits.
        if !found.intersection(hardVersionWords).subtracting(wanted).isEmpty { return nil }
        if !wanted.intersection(hardVersionWords).subtracting(found).isEmpty { return nil }
        let softDiff = found.symmetricDifference(wanted).intersection(softVersionWords)
        score -= Swift.min(0.3, 0.1 * Double(softDiff.count))
        if c.isTopicChannel { score += 0.05 }
        return Swift.max(0, Swift.min(1, score))
    }

    /// The best candidate at or above `threshold`.
    static func best<T>(_ q: TrackQuery, _ items: [T], threshold: Double = 0.62, _ candidate: (T) -> Candidate) -> (item: T, score: Double)? {
        var top: (T, Double)?
        for item in items {
            guard let s = score(q, candidate(item)), s >= threshold else { continue }
            if top == nil || s > top!.1 { top = (item, s) }
        }
        return top.map { (item: $0.0, score: $0.1) }
    }
}
