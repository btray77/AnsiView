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
        /// The small preview 16colo.rs renders (`tn`, 160 pixels wide), when it has one.
        public let thumbnail: URL?
        /// The full size picture 16colo.rs renders (`x1`), when it has one.
        public let fullImage: URL?
        public var isViewable: Bool { SixteenColors.isViewable(name) }

        public init(name: String, artists: [String] = [], thumbnail: URL? = nil, fullImage: URL? = nil) {
            self.name = name
            self.artists = artists
            self.thumbnail = thumbnail
            self.fullImage = fullImage
        }
    }

    public struct PackDetail: Equatable {
        public let name: String
        public let year: Int?
        public let archive: String?
        public let download: URL?
        /// In Finder order by name.
        public let files: [PackFile]
        /// The pack's description file (usually FILE_ID.DIZ), when the API names one.
        public let fileID: String?

        /// The picture that stands for the pack (as on 16colo.rs's year pages): the description
        /// file when it has a thumbnail, else the first file that has one.
        public var cover: PackFile? {
            if let fileID, let file = files.first(where: { $0.name == fileID && $0.thumbnail != nil }) { return file }
            return files.first { $0.thumbnail != nil }
        }
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
        packURL(pack: pack, kind: "raw", file: file, suffix: "")
    }

    /// The 160 pixel wide preview 16colo.rs renders of a file (`/pack/<p>/tn/<f>.png`).
    public static func thumbnailURL(pack: String, file: String) -> URL? {
        packURL(pack: pack, kind: "tn", file: file, suffix: ".png")
    }

    /// The full size picture 16colo.rs renders of a file (`/pack/<p>/x1/<f>.png`).
    public static func fullImageURL(pack: String, file: String) -> URL? {
        packURL(pack: pack, kind: "x1", file: file, suffix: ".png")
    }

    private static func isUnsafeComponent(_ text: String) -> Bool { text.isEmpty || text == "." || text == ".." }

    private static func packURL(pack: String, kind: String, file: String, suffix: String) -> URL? {
        let parts = file.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !isUnsafeComponent(pack), !pack.contains("/"), !parts.contains(where: isUnsafeComponent) else { return nil }
        let path = "pack/" + component(pack) + "/" + kind + "/" + parts.map(component).joined(separator: "/") + suffix
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

    /// The relative path a downloaded file is saved under in the cache: each folder kept (so the
    /// same name in two folders gives two files), every component with `:` replaced and leading
    /// dots removed (so `..` disappears), plus `.ans` when AnsiView would not otherwise open the
    /// file (group extensions such as `.CIP` are ANSI). Nil when nothing usable is left.
    public static func cacheName(for file: String) -> String? {
        let parts = file.split(separator: "/").compactMap { safeName(String($0)) }
        guard let name = parts.last else { return nil }
        let ext = (name as NSString).pathExtension.lowercased()
        return (parts.dropLast() + [ArtFiles.extensions.contains(ext) ? name : name + ".ans"]).joined(separator: "/")
    }

    /// Where a downloaded file of a pack lives in the disk cache: `files/<pack>/<cacheName>`.
    public static func fileCacheName(pack: String, file: String) -> String? {
        guard !pack.contains("/"), let folder = safeName(pack), let name = cacheName(for: file) else { return nil }
        return "files/" + folder + "/" + name
    }

    /// Where a `tn` or `x1` picture lives in the disk cache: `images/<pack>/<tn|x1>/<file>.png`.
    /// Nil for anything that is not such a picture on 16colo.rs, or that steps outside its folder.
    public static func imageCacheName(for url: URL) -> String? {
        guard url.scheme == "https", url.host == site.host else { return nil }
        let parts = Array(url.pathComponents.drop { $0 == "/" })
        guard parts.count >= 4, parts[0] == "pack", ["tn", "x1"].contains(parts[2]),
              !parts.contains(where: isUnsafeComponent) else { return nil }
        let names = [parts[1]] + Array(parts[3...])
        let safe = names.compactMap(safeName)
        guard safe.count == names.count else { return nil }
        return (["images", safe[0], parts[2]] + safe.dropFirst()).joined(separator: "/")
    }

    /// Where an API response is kept on disk (read back only when offline): `api/<path>_<query>.json`.
    public static func apiCacheName(for url: URL) -> String {
        var parts = url.pathComponents.filter { $0 != "/" }
        if parts.first == "v1" { parts.removeFirst() }
        let safe = parts.compactMap(safeName)
        var name = safe.isEmpty ? "index" : safe.joined(separator: "/")
        if let query = url.query, !query.isEmpty {
            name += "_" + query.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        }
        return "api/" + name + ".json"
    }

    /// True when the data starts with the PNG signature (so an HTML error page is never kept as a picture).
    public static func isPNG(_ data: Data) -> Bool {
        data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    }

    /// The cache file name for a pack's ZIP.
    public static func packCacheName(_ pack: String) -> String? {
        safeName(pack).map { $0 + ".zip" }
    }

    /// The last path component with `:` replaced and leading dots removed; nil when empty.
    static func safeName(_ text: String) -> String? {
        var name = String(text.split(separator: "/").last ?? "")
        name = name.replacingOccurrences(of: ":", with: "_")
        while name.hasPrefix(".") { name.removeFirst() }
        return name.isEmpty ? nil : name
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
            func image(_ key: String) -> URL? { ((file[key] as? [String: Any])?["uri"] as? String).flatMap(downloadURL) }
            return PackFile(name: fileName, artists: entry["artists"] as? [String] ?? [], thumbnail: image("tn"),
                            fullImage: image("x1"))
        }
        let sorted = files.sorted { a, b in
            let order = a.name.localizedStandardCompare(b.name)
            return order == .orderedSame ? a.name < b.name : order == .orderedAscending
        }
        return PackDetail(name: name, year: int(result["year"]), archive: result["archive"] as? String,
                          download: (result["download"] as? String).flatMap(downloadURL), files: sorted,
                          fileID: (result["fileid"] as? String).flatMap { $0.isEmpty ? nil : $0 })
    }
}

/// Keeps API requests at least `interval` seconds apart. `delay` says how long to wait before a
/// request may start; `started` records one that did. A waiter that gives up books nothing.
public struct RequestSpacing {
    public let interval: TimeInterval
    private var lastStart: TimeInterval?

    public init(interval: TimeInterval) { self.interval = interval }

    public func delay(now: TimeInterval) -> TimeInterval {
        guard let lastStart else { return 0 }
        return max(0, lastStart + interval - now)
    }

    public mutating func started(at time: TimeInterval) { lastStart = time }
}

/// Requests waiting for their turn, in the order they may go: by priority, then first come first
/// served. One lane serves every request to 16colo.rs, so a selection never waits behind a grid
/// of thumbnails, and a cancelled waiter (the user moved on) never comes out.
public struct RequestLane {
    public enum Priority: Int, Comparable {
        /// Listings and the selected file (its art and its full size picture).
        case user
        /// Thumbnails of visible grid items.
        case grid
        /// Thumbnails of visible pack rows.
        case packRow

        public static func < (a: Priority, b: Priority) -> Bool { a.rawValue < b.rawValue }
    }

    private var waiting: [(ticket: Int, priority: Priority)] = []
    private var lastTicket = 0

    public init() {}

    public var count: Int { waiting.count }

    /// Joins the lane; the ticket identifies this waiter.
    public mutating func enqueue(_ priority: Priority) -> Int {
        lastTicket += 1
        waiting.append((lastTicket, priority))
        return lastTicket
    }

    /// Leaves the lane. Unknown or already finished tickets are ignored.
    public mutating func cancel(_ ticket: Int) {
        waiting.removeAll { $0.ticket == ticket }
    }

    /// The waiter that goes next (and leaves the lane), or nil when nobody waits.
    public mutating func next() -> Int? {
        guard let best = waiting.indices.min(by: { a, b in
            waiting[a].priority != waiting[b].priority ? waiting[a].priority < waiting[b].priority : waiting[a].ticket < waiting[b].ticket
        }) else { return nil }
        return waiting.remove(at: best).ticket
    }
}
