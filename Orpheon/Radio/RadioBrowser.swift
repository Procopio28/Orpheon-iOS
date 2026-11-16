// Orpheon for iOS: a port of Orpheon (https://github.com/kota-zo/Orpheon, formerly Myspoti), GPL-3.0.
// Derived from the Kotlin sources by kota-zo and contributors. Keep these notices; if you ever
// distribute this, publish your complete source under GPL-3.0 (see LICENSE and NOTICE.md).
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct RadioStation: Identifiable, Hashable {
    var id: String
    var name: String
    var streamUrl: String
    var favicon: String?
    var country: String?
    var countryCode: String?
    var tags: [String]
    var codec: String?
    var bitrate: Int
    var votes: Int

    var detail: String {
        var parts: [String] = []
        if let c = country, !c.isEmpty { parts.append(c) }
        if let first = tags.first, !first.isEmpty { parts.append(first) }
        if bitrate > 0 { parts.append("\(bitrate) kbps") }
        return parts.joined(separator: " · ")
    }
}

/// Live radio from the community directory https://www.radio-browser.info (free, no key). The
/// streams are plain internet audio: they play in the app itself, with no Spotify involved.
final class RadioBrowser {
    private let session: URLSession
    private var hosts = ["https://de1.api.radio-browser.info", "https://at1.api.radio-browser.info", "https://nl1.api.radio-browser.info"]

    init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 15
        self.session = URLSession(configuration: cfg)
    }

    private func get(_ path: String, _ query: [String: String]) async throws -> JSON {
        var lastError: Error = SpotifyError.unavailable("Radio directory unreachable")
        for host in hosts {
            var comps = URLComponents(string: host + path)!
            comps.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            var req = URLRequest(url: comps.url!)
            req.setValue("Orpheon-iOS/1.0", forHTTPHeaderField: "User-Agent")
            do {
                let (data, resp) = try await session.data(for: req)
                if (resp as? HTTPURLResponse)?.statusCode == 200 {
                    // The host that answered goes first next time.
                    if let i = hosts.firstIndex(of: host), i > 0 { hosts.swapAt(0, i) }
                    return try JSON.parse(data)
                }
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private func map(_ j: JSON) -> RadioStation? {
        guard let id = j.str("stationuuid"), let name = j.str("name"),
              let url = j.str("url_resolved") ?? j.str("url"), !url.isEmpty else { return nil }
        let tags = (j.str("tags") ?? "").split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return RadioStation(
            id: id, name: name.trimmingCharacters(in: .whitespacesAndNewlines), streamUrl: url,
            favicon: j.str("favicon").flatMap { $0.isEmpty ? nil : $0 },
            country: j.str("country"), countryCode: j.str("countrycode"), tags: tags,
            codec: j.str("codec"), bitrate: j.int("bitrate") ?? 0, votes: j.int("votes") ?? 0)
    }

    func topStations(limit: Int = 50) async throws -> [RadioStation] {
        let j = try await get("/json/stations/search", ["limit": String(limit), "hidebroken": "true", "order": "clickcount", "reverse": "true"])
        return j.items.compactMap(map)
    }

    func search(name: String = "", tag: String = "", countryCode: String = "", limit: Int = 60) async throws -> [RadioStation] {
        var q = ["limit": String(limit), "hidebroken": "true", "order": "votes", "reverse": "true"]
        if !name.isEmpty { q["name"] = name }
        if !tag.isEmpty { q["tag"] = tag; q["tagExact"] = "true" }
        if !countryCode.isEmpty { q["countrycode"] = countryCode }
        let j = try await get("/json/stations/search", q)
        return j.items.compactMap(map)
    }

    func tags(limit: Int = 40) async throws -> [String] {
        let j = try await get("/json/tags", ["limit": String(limit), "order": "stationcount", "reverse": "true", "hidebroken": "true"])
        return j.items.compactMap { $0.str("name") }.filter { !$0.isEmpty }
    }

    /// Tells the directory a station was played (it ranks by this); best effort.
    func registerClick(_ station: RadioStation) {
        Task {
            _ = try? await get("/json/url/\(station.id)", [:])
        }
    }
}
