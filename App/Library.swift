import AnsiCore
import AppKit

/// What the library window lists.
enum LibrarySource: Equatable {
    case all
    case smart(SmartFolder)
    case tag(String)
    case artist(String)
    case group(String)
    case folder(UUID)
}

/// The library (plan 9 items 43, 44, 47; rulings 7 to 10): the folders the user added, an index of
/// every piece in them (packs included), and what the user said about each piece. Everything lives
/// in the app container's Application Support/Library; folders are reopened through app scoped
/// security bookmarks. Indexing runs on background threads, reading only new or changed files.
final class LibraryStore {
    static let shared = LibraryStore(folder: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Library"), thumbnails: .shared)
    /// Posted on the main thread whenever records or notes change.
    static let changed = Notification.Name("LibraryStoreChanged")

    let folder: URL
    let thumbnails: ThumbnailStore
    private(set) var data: LibraryData
    /// Every piece, in display order (by name, then path).
    private(set) var records: [IndexRecord] = []
    private(set) var haystacks: [SearchHaystack] = []
    private(set) var isIndexing = false
    /// Pieces read so far and to read in the scan running now.
    private(set) var progress = (done: 0, total: 0)
    /// The last scan: files read, records kept as they were, seconds taken.
    private(set) var lastScan = (read: 0, kept: 0, seconds: 0.0)
    /// For checks: true if any file was ever read on the main thread.
    private(set) var scannedOnMainThread = false
    /// Folders whose bookmark could not be resolved.
    private(set) var missingFolders: Set<UUID> = []
    private var scoped: [URL] = []
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = max(2, ProcessInfo.processInfo.activeProcessorCount - 1)
        return queue
    }()
    private var pendingScan = false

    init(folder: URL, thumbnails: ThumbnailStore) {
        self.folder = folder
        self.thumbnails = thumbnails
        data = LibraryFiles.load(LibraryData.self, from: folder.appendingPathComponent("library.json")) ?? LibraryData()
        let index = LibraryFiles.load(LibraryIndex.self, from: folder.appendingPathComponent("index.json"))
        setRecords(index?.version == LibraryIndex.currentVersion ? index!.records : [])
        openFolders()
    }

    deinit {
        queue.cancelAllOperations()
        scoped.forEach { $0.stopAccessingSecurityScopedResource() }
    }

    private func setRecords(_ new: [IndexRecord]) {
        records = new.sorted { a, b in
            let order = a.name.localizedStandardCompare(b.name)
            return order == .orderedSame ? a.key < b.key : order == .orderedAscending
        }
        haystacks = records.map(\.haystack)
    }

    private func notify() { NotificationCenter.default.post(name: Self.changed, object: self) }

    func saveData() {
        try? LibraryFiles.save(data, to: folder.appendingPathComponent("library.json"))
    }

    private func saveIndex() {
        try? LibraryFiles.save(LibraryIndex(records: records), to: folder.appendingPathComponent("index.json"))
    }

    // MARK: Folders and bookmarks

    /// Resolves every folder's bookmark and keeps its security scope open while the store lives.
    private func openFolders() {
        for (i, entry) in data.folders.enumerated() {
            guard let bookmark = entry.bookmark else { continue }
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope],
                                     relativeTo: nil, bookmarkDataIsStale: &stale) else {
                missingFolders.insert(entry.id)
                continue
            }
            if url.startAccessingSecurityScopedResource() { scoped.append(url) }
            if stale || url.standardizedFileURL.path != entry.path {
                data.folders[i].path = url.standardizedFileURL.path
                data.folders[i].bookmark = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil,
                                                                 relativeTo: nil)
            }
        }
    }

    /// Adds a folder (from an open panel, so it is readable now) and indexes it.
    func addFolder(_ url: URL) {
        let path = url.standardizedFileURL.path
        guard !data.folders.contains(where: { $0.path == path }) else { rescan(); return }
        let bookmark = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        if url.startAccessingSecurityScopedResource() { scoped.append(url) }
        data.folders.append(LibraryFolder(path: path, bookmark: bookmark))
        saveData()
        notify()
        rescan()
    }

    /// Forgets a folder and its pieces (the files are not touched).
    func removeFolder(_ id: UUID) {
        guard let entry = data.folders.first(where: { $0.id == id }) else { return }
        data.folders.removeAll { $0.id == id }
        setRecords(records.filter { !$0.path.hasPrefix(entry.path + "/") })
        saveData()
        saveIndex()
        notify()
    }

    /// File > Library > Add Folder...
    func chooseAndAddFolder(window: NSWindow?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add to Library"
        panel.message = "Choose folders of art. Subfolders and ZIP art packs inside them are included."
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { addFolder(url) }
    }

    // MARK: Indexing (ruling 10)

    /// Reads new and changed files in every folder in the background; unchanged files are kept.
    func rescan() {
        guard !isIndexing else { pendingScan = true; return }
        isIndexing = true
        progress = (0, 0)
        notify()
        let folders = data.folders.filter { !missingFolders.contains($0.id) }.map { URL(fileURLWithPath: $0.path) }
        let existing = records
        let thumbnails = self.thumbnails
        let started = ProcessInfo.processInfo.systemUptime
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let listed = folders.flatMap(LibraryScanner.listing(folder:))
            let underFolders = existing.filter { record in folders.contains { record.path.hasPrefix($0.path + "/") } }
            let plan = IndexPlanner.plan(existing: underFolders, listed: listed)
            let added = Dictionary(existing.map { ($0.key, $0.added) }, uniquingKeysWith: { a, _ in a })
            DispatchQueue.main.async {
                self?.scan(plan.scan, keep: plan.keep, added: added, thumbnails: thumbnails, started: started)
            }
        }
    }

    private func scan(_ files: [ListedFile], keep: [IndexRecord], added: [String: Date], thumbnails: ThumbnailStore,
                      started: TimeInterval) {
        progress = (0, files.count)
        var fresh: [IndexRecord] = []
        var remaining = files.count
        let now = Date()
        func finish() {
            var kept = keep
            kept += fresh
            setRecords(kept)
            saveIndex()
            lastScan = (files.count, keep.count, ProcessInfo.processInfo.systemUptime - started)
            isIndexing = false
            notify()
            if pendingScan { pendingScan = false; rescan() }
        }
        guard remaining > 0 else { finish(); return }
        for file in files {
            queue.addOperation { [weak self] in
                let onMain = Thread.isMainThread
                var scanned: [(record: IndexRecord, file: ArtFile, screen: AnsiScreen)] = []
                if file.isPack {
                    scanned = (try? LibraryScanner.scanPack(pack: file.url, size: file.size, modified: file.modified, now: now)) ?? []
                } else if let bytes = try? Data(contentsOf: file.url) {
                    scanned = [LibraryScanner.scan(data: bytes, path: file.url.path, entry: nil, size: file.size,
                                                   modified: file.modified, now: now)]
                }
                var records: [IndexRecord] = []
                for item in scanned {
                    var record = item.record
                    if let first = added[record.key] { record.added = first }
                    let key = ThumbnailStore.key(path: record.path, entry: record.entry, size: record.size, modified: record.modified)
                    if !thumbnails.contains(key),
                       let image = Thumbnail.render(item.file, screen: item.screen, maximum: ThumbnailStore.pixels) {
                        thumbnails.store(image, for: key)
                    }
                    records.append(record)
                }
                DispatchQueue.main.async {
                    guard let self else { return }
                    if onMain { self.scannedOnMainThread = true }
                    fresh += records
                    remaining -= 1
                    self.progress.done += 1
                    if remaining == 0 { finish() }
                    else if self.progress.done % 100 == 0 { self.notify() }
                }
            }
        }
    }

    /// Takes trashed (or otherwise gone) files out of the index.
    func forget(keys: Set<String>) {
        setRecords(records.filter { !keys.contains($0.key) })
        saveIndex()
        notify()
    }

    // MARK: Notes (ruling 9)

    func setRating(_ stars: Int, for identities: [String]) {
        for id in identities { data.setRating(stars, for: id) }
        saveData()
        notify()
    }

    func toggleFavourite(_ identities: [String]) {
        // All on unless every one already is.
        let on = !identities.allSatisfy { data.notes(for: $0).favourite }
        for id in identities { data.setFavourite(on, for: id) }
        saveData()
        notify()
    }

    func setTags(_ tags: [String], for identities: [String]) {
        for id in identities { data.setTags(tags, for: id) }
        saveData()
        notify()
    }

    func addSmartFolder(_ folder: SmartFolder) {
        data.smartFolders.removeAll { $0.id == folder.id }
        data.smartFolders.append(folder)
        saveData()
        notify()
    }

    func removeSmartFolder(_ id: UUID) {
        data.smartFolders.removeAll { $0.id == id }
        saveData()
        notify()
    }

    // MARK: Listing

    var artists: [ArtistEntry] { ArtistDirectory.artists(records) }
    var groups: [ArtistEntry] { ArtistDirectory.groups(records) }

    /// Indexes into `records` for a sidebar source, narrowed by a search.
    func matching(_ source: LibrarySource, query: String) -> [Int] {
        let words = ArtSearch.words(query)
        let now = Date()
        var base: [Int]
        switch source {
        case .all: base = Array(records.indices)
        case .smart(let folder):
            base = records.indices.filter { folder.matches(records[$0], notes: data.notes(for: records[$0].identity), now: now) }
        case .tag(let tag):
            base = records.indices.filter { SmartRule.tagIs(tag).matches(records[$0], notes: data.notes(for: records[$0].identity), now: now) }
        case .artist(let key): base = artists.first { $0.key == key }?.pieces ?? []
        case .group(let key): base = groups.first { $0.key == key }?.pieces ?? []
        case .folder(let id):
            let path = data.folders.first { $0.id == id }?.path ?? "\u{0}"
            base = records.indices.filter { records[$0].path.hasPrefix(path + "/") }
        }
        guard !words.isEmpty else { return base }
        return base.filter { haystacks[$0].matches(words: words) }
    }

    /// Opens a piece: a file as a document, a pack entry in a slideshow of its pack.
    func open(_ record: IndexRecord) {
        let url = URL(fileURLWithPath: record.path)
        guard let entry = record.entry else {
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
                if let error { NSAlert(error: error).runModal() }
            }
            return
        }
        do {
            let collection = try ArtCollection.open(url, scoped: false)
            let index = collection.items.firstIndex { $0.entry == entry } ?? 0
            SlideshowWindowController.open(collection: collection, index: index)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    /// The piece's bytes (for compare).
    func artFile(_ record: IndexRecord) -> ArtFile? {
        let url = URL(fileURLWithPath: record.path)
        if let entry = record.entry {
            guard let archive = try? ZipArchive(data: Data(contentsOf: url, options: .mappedIfSafe)),
                  let item = archive.entries.first(where: { $0.path == entry }),
                  let data = try? archive.data(for: item) else { return nil }
            return ArtFile(data: data, fileExtension: (entry as NSString).pathExtension)
        }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return ArtFile(data: data, fileExtension: url.pathExtension)
    }

    func thumbnail(for record: IndexRecord) -> NSImage? {
        let key = ThumbnailStore.key(path: record.path, entry: record.entry, size: record.size, modified: record.modified)
        guard let image = thumbnails.image(for: key) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width / 2, height: image.height / 2))
    }
}
