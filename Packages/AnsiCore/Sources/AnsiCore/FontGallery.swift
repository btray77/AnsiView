import Foundation

/// The rendered size of a gallery card, for sorting by height or width.
public struct GallerySize: Equatable {
    public var columns: Int
    public var rows: Int

    public init(columns: Int, rows: Int) {
        self.columns = columns
        self.rows = rows
    }
}

/// What the Text to ASCII gallery shows (plan ruling 20).
public struct GalleryQuery: Equatable {
    public enum Sort: String, CaseIterable {
        case name, height, width

        public var label: String {
            switch self {
            case .name: return "Name"
            case .height: return "Height"
            case .width: return "Width"
            }
        }
    }

    public var search = ""
    /// Empty shows every category.
    public var categories: Set<TextArtCategory> = []
    public var favouritesOnly = false
    /// Only fonts whose rendering is at least this many rows (the "multi line height" filter).
    public var minimumRows: Int?
    public var sort = Sort.name

    public init() {}
}

public enum FontGallery {
    static func filter(_ entries: [FontEntry], search: String, categories: Set<TextArtCategory>,
                       favouritesOnly: Bool, favourites: Set<String>) -> [FontEntry] {
        let words = search.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(separator: " ").map(String.init)
        return entries.filter { entry in
            (categories.isEmpty || categories.contains(entry.category))
                && (!favouritesOnly || favourites.contains(entry.id))
                && words.allSatisfy { entry.searchText.contains($0) }
        }
    }

    /// Filters and orders the cards: favourites first, then recently used (newest first), then
    /// the rest in the chosen sort; unmeasured fonts sort after measured ones.
    public static func arrange(_ entries: [FontEntry], query: GalleryQuery, favourites: Set<String>,
                               recent: [String], sizes: [String: GallerySize]) -> [FontEntry] {
        var list = filter(entries, search: query.search, categories: query.categories,
                          favouritesOnly: query.favouritesOnly, favourites: favourites)
        if let minimum = query.minimumRows {
            list = list.filter { (sizes[$0.id]?.rows ?? 0) >= minimum }
        }
        func byName(_ a: FontEntry, _ b: FontEntry) -> Bool {
            let order = a.name.localizedStandardCompare(b.name)
            return order == .orderedSame ? a.id < b.id : order == .orderedAscending
        }
        func less(_ a: FontEntry, _ b: FontEntry) -> Bool {
            switch query.sort {
            case .name: return byName(a, b)
            case .height, .width:
                let key: (GallerySize) -> Int = query.sort == .height ? { $0.rows } : { $0.columns }
                switch (sizes[a.id].map(key), sizes[b.id].map(key)) {
                case let (x?, y?): return x == y ? byName(a, b) : x < y
                case (.some, nil): return true
                case (nil, .some): return false
                default: return byName(a, b)
                }
            }
        }
        let favourite = list.filter { favourites.contains($0.id) }.sorted(by: less)
        let recentList = recent.compactMap { id in list.first { $0.id == id && !favourites.contains(id) } }
        let shown = Set(favourite.map(\.id) + recentList.map(\.id))
        return favourite + recentList + list.filter { !shown.contains($0.id) }.sorted(by: less)
    }
}

/// Renders gallery cards on background threads, visible cards first; each `start` cancels the
/// previous run, so results of stale text never arrive (plan ruling 20).
public final class GalleryRenderer: @unchecked Sendable {
    private let queue = OperationQueue()
    private let lock = NSLock()
    private var generation = 0

    public init(concurrency: Int = max(2, ProcessInfo.processInfo.activeProcessorCount - 1)) {
        queue.maxConcurrentOperationCount = concurrency
        queue.qualityOfService = .userInitiated
    }

    private var current: Int { lock.lock(); defer { lock.unlock() }; return generation }

    /// Renders `text` in every entry. `priority` ids go first (the cards on screen); `deliver`
    /// is called on a background thread, once per entry, only while this run is current.
    public func start(text: String, entries: [FontEntry], options: TextArtOptions, priority: [String] = [],
                      deliver: @escaping @Sendable (String, TextArtResult) -> Void) {
        lock.lock()
        generation += 1
        let mine = generation
        lock.unlock()
        queue.cancelAllOperations()
        let wanted = Set(priority)
        let ordered = priority.compactMap { id in entries.first { $0.id == id } } + entries.filter { !wanted.contains($0.id) }
        for entry in ordered {
            let font = entry.font, id = entry.id
            queue.addOperation { [weak self] in
                guard let self, self.current == mine else { return }
                let result = TextArt.render(text, font: font, options: options)
                guard self.current == mine else { return }
                deliver(id, result)
            }
        }
    }

    public func cancel() {
        lock.lock()
        generation += 1
        lock.unlock()
        queue.cancelAllOperations()
    }

    /// Waits for the queue to drain (tests and measurements).
    public func waitUntilIdle() async throws {
        while queue.operationCount > 0 { try await Task.sleep(nanoseconds: 2_000_000) }
    }

    public func waitUntilIdleBlocking() { queue.waitUntilAllOperationsAreFinished() }
}
