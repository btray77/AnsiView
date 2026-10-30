import Foundation

// MARK: Index (plan 9 rulings 7 and 10)

/// What the library knows about one piece: where it is, how to recognise it, its SAUCE, and its words.
public struct IndexRecord: Codable, Equatable {
    /// The file, or for a piece inside a ZIP art pack, the pack.
    public var path: String
    /// The piece's path inside the pack; nil for a plain file.
    public var entry: String?
    /// Size and modification date of `path` when it was read (a pack's, for its entries).
    public var size: Int
    public var modified: Date
    /// SHA-256 of the piece's bytes (64 hex digits).
    public var byteHash: String
    /// SHA-256 of the finished screen's cells; nil when nothing is visible.
    public var cellHash: String?
    public var title: String
    public var author: String
    public var group: String
    public var comments: String
    /// SAUCE date as yyyymmdd, when the file has one.
    public var date: String?
    /// Format name ("ANSI", "XBin", ...).
    public var format: String
    public var columns: Int
    public var rows: Int
    /// The art's words, at most `LibraryScanner.textLimit` characters.
    public var text: String
    /// When the piece first appeared in the library.
    public var added: Date

    /// Unique within the library: the path, plus `#entry` for a piece inside a pack.
    public var key: String { entry.map { path + "#" + $0 } ?? path }
    /// The piece's file name.
    public var name: String { ((entry ?? path) as NSString).lastPathComponent }
    /// The pack's file name for a piece inside one.
    public var packName: String? { entry == nil ? nil : (path as NSString).lastPathComponent }
    /// The same 16 digit identity `ArtFile.identity` gives (the start of the byte hash): what tags,
    /// ratings and favourites are kept under.
    public var identity: String { String(byteHash.prefix(16)) }
    public var year: Int? { date.flatMap { Int($0.prefix(4)) } }
    public var isInPack: Bool { entry != nil }

    public var haystack: SearchHaystack {
        SearchHaystack(name: name, title: title, author: author, group: group, comments: comments, text: text)
    }
}

/// The saved index: every record, with a version so a future layout can rebuild instead of misreading.
public struct LibraryIndex: Codable, Equatable {
    public static let currentVersion = 1
    public var version: Int
    public var records: [IndexRecord]

    public init(records: [IndexRecord]) {
        version = Self.currentVersion
        self.records = records
    }
}

/// A file found in a library folder.
public struct ListedFile: Equatable {
    public let url: URL
    public let size: Int
    public let modified: Date
    /// A `.zip` art pack (its art entries are indexed).
    public let isPack: Bool

    public init(url: URL, size: Int, modified: Date, isPack: Bool) {
        self.url = url
        self.size = size
        self.modified = modified
        self.isPack = isPack
    }
}

public enum LibraryScanner {
    /// The art text kept per piece, enough for searching any normal piece.
    public static let textLimit = 20_000

    /// Reads one piece. `size` and `modified` are the file's (or its pack's).
    public static func record(data: Data, path: String, entry: String?, size: Int, modified: Date, now: Date) -> IndexRecord {
        scan(data: data, path: path, entry: entry, size: size, modified: modified, now: now).record
    }

    /// The record plus the loaded file and its finished screen, so a thumbnail can be drawn without
    /// playing the file a second time.
    public static func scan(data: Data, path: String, entry: String?, size: Int, modified: Date,
                            now: Date) -> (record: IndexRecord, file: ArtFile, screen: AnsiScreen) {
        let name = ((entry ?? path) as NSString).lastPathComponent
        let file = ArtFile(data: data, fileExtension: (name as NSString).pathExtension)
        let analysis = AnsiAnalysis(file)
        let screen = analysis.finalScreen
        var text = ArtText.plainText(screen)
        if text.count > textLimit { text = String(text.prefix(textLimit)) }
        let sauce = file.sauce
        func trimmed(_ value: String?) -> String { (value ?? "").trimmingCharacters(in: .whitespaces) }
        var date: String?
        if let d = sauce?.date, let year = d.year, let month = d.month, let day = d.day {
            date = String(format: "%04d%02d%02d", year, month, day)
        }
        let record = IndexRecord(
            path: path, entry: entry, size: size, modified: modified, byteHash: ByteHash.of(data),
            cellHash: CellHash.of(screen), title: trimmed(sauce?.title), author: trimmed(sauce?.author),
            group: trimmed(sauce?.group),
            comments: (sauce?.comments ?? []).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                .joined(separator: "\n"),
            date: date, format: file.format.displayName, columns: screen.columns, rows: analysis.canvasRows,
            text: text, added: now)
        return (record, file, screen)
    }

    /// Art files and `.zip` packs under `folder`, at any depth, skipping hidden files and folders,
    /// `__MACOSX` and packages.
    public static func listing(folder: URL) -> [ListedFile] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .isDirectoryKey]
        guard let walker = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return [] }
        // The enumerator may answer with another spelling of the folder (/private/var for /var):
        // listed paths keep the folder's path as given, so rescans match what they read before.
        let base = folder.path.hasSuffix("/") ? String(folder.path.dropLast()) : folder.path
        let resolved = folder.resolvingSymlinksInPath().path
        let spellings = [base, "/private" + base, resolved, "/private" + resolved].sorted { $0.count > $1.count }
        func given(_ url: URL) -> URL {
            let path = url.path
            guard let prefix = spellings.first(where: { path.hasPrefix($0 + "/") }) else { return url }
            return URL(fileURLWithPath: base + path.dropFirst(prefix.count))
        }
        var found: [ListedFile] = []
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isDirectory == true {
                if url.lastPathComponent == "__MACOSX" { walker.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true else { continue }
            let ext = url.pathExtension.lowercased()
            let isPack = ext == "zip"
            guard isPack || ArtFiles.extensions.contains(ext) else { continue }
            found.append(ListedFile(url: given(url), size: values.fileSize ?? 0,
                                    modified: values.contentModificationDate ?? .distantPast, isPack: isPack))
        }
        return found
    }

    /// One record per art entry of a ZIP pack.
    public static func records(pack: URL, size: Int, modified: Date, now: Date) throws -> [IndexRecord] {
        try scanPack(pack: pack, size: size, modified: modified, now: now).map(\.record)
    }

    public static func scanPack(pack: URL, size: Int, modified: Date,
                                now: Date) throws -> [(record: IndexRecord, file: ArtFile, screen: AnsiScreen)] {
        let archive = try ZipArchive(data: try Data(contentsOf: pack, options: .mappedIfSafe))
        return archive.artEntries.compactMap { entry in
            guard let data = try? archive.data(for: entry) else { return nil }
            return scan(data: data, path: pack.path, entry: entry.path, size: size, modified: modified, now: now)
        }
    }
}

/// What a rescan has to read: files that are new or changed (by size or date), records still good,
/// and paths that went away.
public enum IndexPlanner {
    /// Dates in JSON lose a little precision; anything closer than this is the same date.
    static let dateTolerance: TimeInterval = 0.001

    public static func plan(existing: [IndexRecord], listed: [ListedFile]) -> (scan: [ListedFile], keep: [IndexRecord], removed: [String]) {
        var byPath: [String: [IndexRecord]] = [:]
        for record in existing { byPath[record.path, default: []].append(record) }
        var scan: [ListedFile] = []
        var keep: [IndexRecord] = []
        var seen = Set<String>()
        for file in listed {
            let path = file.url.path
            seen.insert(path)
            if let records = byPath[path], let first = records.first, first.size == file.size,
               abs(first.modified.timeIntervalSince(file.modified)) < dateTolerance {
                keep += records
            } else {
                scan.append(file)
            }
        }
        let removed = byPath.keys.filter { !seen.contains($0) }.sorted()
        return (scan, keep, removed)
    }
}

// MARK: User data (plan 9 rulings 7 and 8)

/// A folder the user added, with the bookmark that lets the sandboxed app open it in later launches.
public struct LibraryFolder: Codable, Equatable {
    public var id: UUID
    public var path: String
    public var bookmark: Data?

    public init(id: UUID = UUID(), path: String, bookmark: Data?) {
        self.id = id
        self.path = path
        self.bookmark = bookmark
    }
}

/// What the user said about a piece.
public struct PieceNotes: Codable, Equatable {
    public var tags: [String] = []
    public var favourite = false
    /// 0 (unrated) to 5 stars.
    public var rating = 0

    public init() {}

    var isEmpty: Bool { tags.isEmpty && !favourite && rating == 0 }
}

public enum SmartRule: Codable, Equatable {
    case tagIs(String)
    case tagIsNot(String)
    case untagged
    case ratingAtLeast(Int)
    case favourite
    case textContains(String)
    case titleContains(String)
    case authorContains(String)
    case groupContains(String)
    case formatIs(String)
    case yearFrom(Int)
    case yearTo(Int)
    case folderIs(String)
    case addedWithinDays(Int)

    public func matches(_ record: IndexRecord, notes: PieceNotes, now: Date) -> Bool {
        func has(_ field: String, _ value: String) -> Bool {
            let words = ArtSearch.words(value)
            let folded = ArtSearch.fold(field)
            return words.allSatisfy { ArtSearch.contains(folded, $0) }
        }
        func sameTag(_ a: String, _ b: String) -> Bool { a.compare(b, options: [.caseInsensitive]) == .orderedSame }
        switch self {
        case .tagIs(let tag): return notes.tags.contains { sameTag($0, tag) }
        case .tagIsNot(let tag): return !notes.tags.contains { sameTag($0, tag) }
        case .untagged: return notes.tags.isEmpty
        case .ratingAtLeast(let stars): return notes.rating >= stars
        case .favourite: return notes.favourite
        case .textContains(let value): return record.haystack.matches(words: ArtSearch.words(value))
        case .titleContains(let value): return has(record.title, value)
        case .authorContains(let value): return has(record.author, value)
        case .groupContains(let value): return has(record.group, value)
        case .formatIs(let value): return record.format.compare(value, options: .caseInsensitive) == .orderedSame
        case .yearFrom(let year): return record.year.map { $0 >= year } ?? false
        case .yearTo(let year): return record.year.map { $0 <= year } ?? false
        case .folderIs(let folder):
            let base = folder.hasSuffix("/") ? folder : folder + "/"
            return record.path.hasPrefix(base)
        case .addedWithinDays(let days): return now.timeIntervalSince(record.added) <= Double(days) * 86_400
        }
    }
}

/// A saved search: pieces matching all (or any) of its rules.
public struct SmartFolder: Codable, Equatable {
    public var id: UUID
    public var name: String
    public var matchAll: Bool
    public var rules: [SmartRule]

    public init(id: UUID = UUID(), name: String, matchAll: Bool, rules: [SmartRule]) {
        self.id = id
        self.name = name
        self.matchAll = matchAll
        self.rules = rules
    }

    public func matches(_ record: IndexRecord, notes: PieceNotes, now: Date) -> Bool {
        guard !rules.isEmpty else { return true }
        return matchAll ? rules.allSatisfy { $0.matches(record, notes: notes, now: now) }
            : rules.contains { $0.matches(record, notes: notes, now: now) }
    }

    /// Always in the sidebar; not saved, not editable.
    public static let builtIn: [SmartFolder] = [
        SmartFolder(id: UUID(uuidString: "6E3B4D10-0000-4000-8000-000000000001")!, name: "Favourites", matchAll: true, rules: [.favourite]),
        SmartFolder(id: UUID(uuidString: "6E3B4D10-0000-4000-8000-000000000002")!, name: "Rated 4 Stars or More", matchAll: true,
                    rules: [.ratingAtLeast(4)]),
        SmartFolder(id: UUID(uuidString: "6E3B4D10-0000-4000-8000-000000000003")!, name: "Untagged", matchAll: true, rules: [.untagged]),
        SmartFolder(id: UUID(uuidString: "6E3B4D10-0000-4000-8000-000000000004")!, name: "Recently Added", matchAll: true,
                    rules: [.addedWithinDays(30)]),
    ]
}

/// Everything the user made: folders, notes per piece (by identity) and smart folders.
public struct LibraryData: Codable, Equatable {
    public var folders: [LibraryFolder] = []
    public var notes: [String: PieceNotes] = [:]
    public var smartFolders: [SmartFolder] = []

    public init() {}

    public func notes(for identity: String) -> PieceNotes { notes[identity] ?? PieceNotes() }

    private mutating func change(_ identity: String, _ edit: (inout PieceNotes) -> Void) {
        var value = notes(for: identity)
        edit(&value)
        notes[identity] = value.isEmpty ? nil : value
    }

    public mutating func setRating(_ stars: Int, for identity: String) {
        change(identity) { $0.rating = min(5, max(0, stars)) }
    }

    public mutating func toggleFavourite(_ identity: String) {
        change(identity) { $0.favourite.toggle() }
    }

    public mutating func setFavourite(_ on: Bool, for identity: String) {
        change(identity) { $0.favourite = on }
    }

    /// Trimmed, blanks dropped, one of each regardless of case (the first spelling kept), sorted.
    public mutating func setTags(_ tags: [String], for identity: String) {
        var seen = Set<String>()
        var kept: [String] = []
        for tag in tags {
            let clean = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty, seen.insert(clean.lowercased()).inserted else { continue }
            kept.append(clean)
        }
        change(identity) { $0.tags = kept.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending } }
    }

    /// Every tag in use, sorted without regard to case.
    public var allTags: [String] {
        var seen = Set<String>()
        var tags: [String] = []
        for tag in notes.values.flatMap(\.tags) where seen.insert(tag.lowercased()).inserted { tags.append(tag) }
        return tags.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}

/// Reading and writing the library's JSON files.
public enum LibraryFiles {
    /// The value in `url`, or nil when there is none or it cannot be read; an unreadable file is
    /// moved aside to `<name>.broken` so a fresh start never overwrites what the user had.
    public static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        if let value = try? decoder.decode(type, from: data) { return value }
        let broken = URL(fileURLWithPath: url.path + ".broken")
        try? FileManager.default.removeItem(at: broken)
        try? FileManager.default.moveItem(at: url, to: broken)
        return nil
    }

    public static func save<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}
