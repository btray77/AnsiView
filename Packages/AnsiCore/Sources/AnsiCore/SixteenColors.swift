import Foundation

/// The public 16colo.rs archive API (https://16colo.rs/api/): URLs, response models and the
/// names AnsiView gives downloaded files. Read only, no account.
public enum SixteenColors {
    public static let apiBase = URL(string: "https://api.16colo.rs/v1/")!
    public static let site = URL(string: "https://16colo.rs/")!
    /// The API allows 1 to 500; one request covers any year (the largest has under 900 packs, two pages).
    public static let pageSize = 500

    public struct Year: Equatable {
        public let year: Int
        public let packs: Int
        public let mags: Int

        public init(year: Int, packs: Int, mags: Int) {
            self.year = year
            self.packs = packs
            self.mags = mags
        }
    }

    public struct Pack: Equatable {
        public let name: String
        public let year: Int?
        /// The ZIP archive's file name on 16colo.rs.
        public let archive: String?
        public let download: URL?
        public let groups: [String]
    }

    public struct PackPage: Equatable {
        public let page: Int
        public let pages: Int
        public let total: Int
        public let packs: [Pack]
    }

    public struct PackFile: Equatable {
        /// The file's path inside the pack.
        public let name: String
        public let artists: [String]
        /// The small preview 16colo.rs renders, when it has one.
        public let thumbnail: URL?
        public var isViewable: Bool { SixteenColors.isViewable(name) }
    }

    public struct PackDetail: Equatable {
        public let name: String
        public let year: Int?
        public let archive: String?
        public let download: URL?
        /// In Finder order by name.
        public let files: [PackFile]
    }

    public enum DecodeError: LocalizedError, Equatable {
        case unreadable
        public var errorDescription: String? { "16colo.rs sent something AnsiView could not read." }
    }

    // MARK: URLs

    /// One path component, percent encoded (so `/`, `#`, `?` and spaces cannot change the URL's shape).
    static func component(_ text: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#;%")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    public static func yearsURL() -> URL { URL(string: "year", relativeTo: apiBase)!.absoluteURL }

    public static func packsURL(year: Int, page: Int) -> URL {
        URL(string: "year/\(year)?pagesize=\(pageSize)&page=\(max(1, page))", relativeTo: apiBase)!.absoluteURL
    }

    public static func packURL(name: String) -> URL {
        URL(string: "pack/" + component(name), relativeTo: apiBase)!.absoluteURL
    }

    /// A single file of a pack. Nil for names that are empty or step outside the pack (`.` or `..`).
    public static func rawFileURL(pack: String, file: String) -> URL? {
        let parts = file.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let unsafe: (String) -> Bool = { $0.isEmpty || $0 == "." || $0 == ".." }
        guard !unsafe(pack), !pack.contains("/"), !parts.contains(where: unsafe) else { return nil }
        let path = "pack/" + component(pack) + "/raw/" + parts.map(component).joined(separator: "/")
        return URL(string: path, relativeTo: site)?.absoluteURL
    }

    /// A pack's ZIP from the API's `download` value, absolute or relative to the site. Only
    /// https URLs on 16colo.rs are accepted.
    public static func downloadURL(_ value: String) -> URL? {
        guard !value.isEmpty else { return nil }
        let url: URL?
        if value.hasPrefix("/") {
            url = URL(string: String(value.dropFirst()).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "",
                      relativeTo: site)?.absoluteURL
        } else {
            url = URL(string: value)
        }
        guard let url, url.scheme == "https", url.host == site.host else { return nil }
        return url
    }

    public static func userAgent(version: String, build: String) -> String {
        "AnsiView/\(version) (build \(build); macOS; +https://github.com/btray77/AnsiView)"
    }

    // MARK: Files

    /// Extensions that are not text art: pictures, programs, archives and music. Listed, not opened.
    static let notViewableExtensions: Set<String> = [
        "exe", "com", "bat", "sys", "dll", "ovl", "zip", "rar", "arj", "lha", "lzh", "7z", "gz",
        "png", "jpg", "jpeg", "gif", "bmp", "pcx", "lbm", "iff", "pdf",
        "mod", "xm", "s3m", "it", "mp3", "wav", "mid", "ogg", "flac",
    ]

    public static func isViewable(_ name: String) -> Bool {
        !notViewableExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    /// The name a downloaded file is saved under in the cache: its last path component with
    /// separators and leading dots removed, plus `.ans` when AnsiView would not otherwise open it
    /// (group extensions such as `.CIP` are ANSI). Nil when nothing usable is left.
    public static func cacheName(for file: String) -> String? {
        var name = String(file.split(separator: "/").last ?? "")
        name = name.replacingOccurrences(of: ":", with: "_")
        while name.hasPrefix(".") { name.removeFirst() }
        guard !name.isEmpty else { return nil }
        let ext = (name as NSString).pathExtension.lowercased()
        return ArtFiles.extensions.contains(ext) ? name : name + ".ans"
    }

    // MARK: Decoding

    private static func object(_ data: Data) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DecodeError.unreadable
        }
        return object
    }

    private static func int(_ value: Any?) -> Int? {
        if let number = value as? Int { return number }
        if let text = value as? String { return Int(text) }
        return nil
    }

    /// `/v1/year`: pack and magazine counts per year, oldest first.
    public static func decodeYears(_ data: Data) throws -> [Year] {
        let object = try object(data)
        let years = object.compactMap { key, value -> Year? in
            guard let year = Int(key), let counts = value as? [String: Any] else { return nil }
            return Year(year: year, packs: int(counts["packs"]) ?? 0, mags: int(counts["mags"]) ?? 0)
        }
        guard !years.isEmpty else { throw DecodeError.unreadable }
        return years.sorted { $0.year < $1.year }
    }

    /// `/v1/year/<year>` (and `/v1/pack/`): one page of packs.
    public static func decodePackPage(_ data: Data) throws -> PackPage {
        let object = try object(data)
        guard let results = object["results"] as? [[String: Any]] else { throw DecodeError.unreadable }
        let page = object["page"] as? [String: Any] ?? [:]
        let packs = results.compactMap { result -> Pack? in
            guard let name = result["name"] as? String, !name.isEmpty else { return nil }
            return Pack(name: name, year: int(result["year"]), archive: result["archive"] as? String,
                        download: (result["download"] as? String).flatMap(downloadURL),
                        groups: result["groups"] as? [String] ?? [])
        }
        return PackPage(page: int(page["page"]) ?? 1, pages: int(page["pages"]) ?? 1,
                        total: int(page["total"]) ?? packs.count, packs: packs)
    }

    /// `/v1/pack/<name>`: the pack's files.
    public static func decodePack(_ data: Data, name: String) throws -> PackDetail {
        let object = try object(data)
        guard let result = (object["results"] as? [[String: Any]])?.first else { throw DecodeError.unreadable }
        let files = (result["files"] as? [String: Any] ?? [:]).map { fileName, value -> PackFile in
            let entry = value as? [String: Any] ?? [:]
            let file = entry["file"] as? [String: Any] ?? [:]
            let thumbnail = ((file["tn"] as? [String: Any])?["uri"] as? String).flatMap(downloadURL)
            return PackFile(name: fileName, artists: entry["artists"] as? [String] ?? [], thumbnail: thumbnail)
        }
        let sorted = files.sorted { a, b in
            let order = a.name.localizedStandardCompare(b.name)
            return order == .orderedSame ? a.name < b.name : order == .orderedAscending
        }
        return PackDetail(name: name, year: int(result["year"]), archive: result["archive"] as? String,
                          download: (result["download"] as? String).flatMap(downloadURL), files: sorted)
    }
}

/// Keeps API requests at least `interval` seconds apart: each call says how long to wait before
/// starting the next request, counting requests already scheduled.
public struct RequestSpacing {
    public let interval: TimeInterval
    private var lastStart: TimeInterval?

    public init(interval: TimeInterval) { self.interval = interval }

    public mutating func delay(now: TimeInterval) -> TimeInterval {
        let start = max(now, (lastStart ?? -.infinity) + interval)
        lastStart = start
        return start - now
    }
}
