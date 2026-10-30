import Foundation

/// One artist or group in the library, from SAUCE (plan 9 ruling 14).
public struct ArtistEntry: Equatable {
    /// Folded name: how spellings are merged.
    public let key: String
    /// The spelling used most (ties: the first seen).
    public let name: String
    /// Indexes of the records with this name.
    public let pieces: [Int]
    /// Years from SAUCE dates, ascending.
    public let years: [Int]
    /// For an artist the groups they appear with; for a group its artists.
    public let related: [String]
}

public enum ArtistDirectory {
    /// The folded name with runs of spaces collapsed; nil for a blank name.
    public static func key(_ name: String) -> String? {
        let words = ArtSearch.fold(name).split(whereSeparator: { $0.isWhitespace })
        return words.isEmpty ? nil : words.joined(separator: " ")
    }

    public static func artists(_ records: [IndexRecord]) -> [ArtistEntry] {
        entries(records, name: \.author, other: \.group)
    }

    public static func groups(_ records: [IndexRecord]) -> [ArtistEntry] {
        entries(records, name: \.group, other: \.author)
    }

    private static func entries(_ records: [IndexRecord], name: KeyPath<IndexRecord, String>,
                                other: KeyPath<IndexRecord, String>) -> [ArtistEntry] {
        struct Building { var spellings: [String: Int] = [:]; var order: [String] = []; var pieces: [Int] = [];
                          var years = Set<Int>(); var related: [String: [String: Int]] = [:] }
        var byKey: [String: Building] = [:]
        for (index, record) in records.enumerated() {
            let spelling = record[keyPath: name].split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            guard let key = Self.key(spelling) else { continue }
            var entry = byKey[key] ?? Building()
            if entry.spellings[spelling] == nil { entry.order.append(spelling) }
            entry.spellings[spelling, default: 0] += 1
            entry.pieces.append(index)
            if let year = record.year { entry.years.insert(year) }
            let otherName = record[keyPath: other].split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            if let otherKey = Self.key(otherName) { entry.related[otherKey, default: [:]][otherName, default: 0] += 1 }
            byKey[key] = entry
        }
        func mostUsed(_ counts: [String: Int], order: [String]) -> String {
            order.max { counts[$0, default: 0] < counts[$1, default: 0] } ?? order.first ?? ""
        }
        return byKey.map { key, entry in
            // `max(by:)` keeps the first of equal elements, so ties go to the first spelling seen.
            let name = mostUsed(entry.spellings, order: entry.order)
            let related = entry.related.values.map { counts in
                counts.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }?.key ?? ""
            }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            return ArtistEntry(key: key, name: name, pieces: entry.pieces, years: entry.years.sorted(), related: related)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

// MARK: 16colo.rs artists and groups

extension SixteenColors {
    /// A pack listed on an artist's or group's 16colo.rs page.
    public struct RemotePack: Equatable {
        public let year: Int?
        public let name: String
        public let group: String?
        /// The artist's files in it (artist pages only).
        public let files: [String]
    }

    /// A group 16colo.rs knows: its tag (what its URLs use) and long name.
    public struct GroupMatch: Equatable {
        public let tag: String
        public let longName: String?
        public let releases: Int
    }

    private static func apiURL(_ path: String, query: String? = nil) -> URL? {
        var components = URLComponents(url: apiBase, resolvingAgainstBaseURL: false)
        components?.percentEncodedPath = "/v1/" + path
        components?.percentEncodedQuery = query
        return components?.url
    }

    private static func pathName(_ name: String) -> String? {
        guard let key = ArtistDirectory.key(name), !key.contains("/"), !key.hasPrefix(".") else { return nil }
        return key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#")))
    }

    /// `/v1/artist/<name>`: the packs an artist appears in.
    public static func artistURL(_ name: String) -> URL? {
        pathName(name).flatMap { apiURL("artist/" + $0) }
    }

    /// `/v1/group/?filter=<first word>`: finds a group's tag from a SAUCE group name.
    public static func groupSearchURL(_ name: String) -> URL? {
        guard let first = ArtistDirectory.key(name)?.split(separator: " ").first,
              let word = String(first).addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return nil }
        return apiURL("group/", query: "filter=\(word)&pagesize=50")
    }

    /// `/v1/group/<tag>?packs=true`: the group's packs by year.
    public static func groupPacksURL(tag: String) -> URL? {
        pathName(tag).flatMap { apiURL("group/" + $0, query: "packs=true") }
    }

    /// Packs from `/v1/artist/<name>`, newest year first, then by name. An empty answer (16colo.rs
    /// sends nothing at all for some names) is an empty list.
    public static func decodeArtist(_ data: Data) throws -> [RemotePack] {
        guard !data.isEmpty else { return [] }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw DecodeError.unreadable }
        guard let years = object["results"] as? [String: Any] else { return [] }
        var packs: [RemotePack] = []
        for (yearKey, value) in years {
            guard let byPack = value as? [String: Any] else { continue }
            for (name, detail) in byPack {
                let info = detail as? [String: Any] ?? [:]
                let files = (info["files"] as? [[String: Any]] ?? []).compactMap { $0["file"] as? String }
                let group = (info["group"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                packs.append(RemotePack(year: Int(yearKey), name: name, group: group, files: files))
            }
        }
        return packs.sorted { a, b in
            if a.year != b.year { return (a.year ?? 0) > (b.year ?? 0) }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// Packs from `/v1/group/<tag>?packs=true`, newest year first, in the order listed.
    public static func decodeGroupPacks(_ data: Data) throws -> [RemotePack] {
        guard !data.isEmpty else { return [] }
        guard let object = try? JSONSerialization.jsonObject(with: data) else { throw DecodeError.unreadable }
        guard let results = (object as? [String: Any])?["results"] as? [String: Any],
              let byYear = results["packs"] as? [String: Any] else { return [] }
        return byYear.compactMap { key, value -> (Int?, [String])? in
            guard let names = value as? [Any] else { return nil }
            return (Int(key), names.compactMap { $0 as? String })
        }.sorted { ($0.0 ?? 0) > ($1.0 ?? 0) }.flatMap { year, names in
            names.map { RemotePack(year: year, name: $0, group: nil, files: []) }
        }
    }

    /// Groups from `/v1/group/?filter=...`, in the order listed.
    public static func decodeGroupSearch(_ data: Data) throws -> [GroupMatch] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw DecodeError.unreadable }
        return (object["results"] as? [[String: Any]] ?? []).flatMap { item in
            item.map { tag, value in
                let info = value as? [String: Any] ?? [:]
                return GroupMatch(tag: tag, longName: info["longname"] as? String,
                                  releases: (info["releases"] as? Int) ?? Int(info["releases"] as? String ?? "") ?? 0)
            }
        }
    }

    /// The group whose tag or long name is `name` (folded); nil when none is.
    public static func bestGroup(_ matches: [GroupMatch], for name: String) -> GroupMatch? {
        guard let key = ArtistDirectory.key(name) else { return nil }
        return matches.first { ArtistDirectory.key($0.tag) == key }
            ?? matches.first { $0.longName.flatMap(ArtistDirectory.key) == key }
    }
}
