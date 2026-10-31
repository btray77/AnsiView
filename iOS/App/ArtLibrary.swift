import AnsiCore
import Foundation
import UniformTypeIdentifiers

/// One piece of art the app can show: a bundled sample, a file in the app's Documents folder
/// (which the Files app shows under On My iPhone or On My iPad), or a file opened from elsewhere.
struct ArtItem: Identifiable, Hashable {
    enum Source: Hashable { case sample, documents, opened }

    let url: URL
    let source: Source
    /// The bytes of a file opened from outside the app, read while its security scope was open.
    let data: Data?
    /// New for each opening of an outside file, so opening it again (perhaps changed) shows the
    /// new bytes instead of keeping the viewer of the old ones. Nil for samples and Documents,
    /// which keep their identity when the list is refreshed.
    let openingID: UUID?

    init(url: URL, source: Source, data: Data?) {
        self.url = url
        self.source = source
        self.data = data
        openingID = source == .opened ? UUID() : nil
    }

    var id: URL { url }
    var name: String { url.lastPathComponent }
    var title: String { url.deletingPathExtension().lastPathComponent }

    static func == (a: ArtItem, b: ArtItem) -> Bool {
        a.url == b.url && a.source == b.source && a.openingID == b.openingID
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(url)
        hasher.combine(source)
        hasher.combine(openingID)
    }
}

enum ArtLoadError: LocalizedError {
    case tooLarge(Int)
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .tooLarge(let bytes):
            return String(localized: "This file is too large to show (\(ArtInfo.formatSize(bytes))). The limit is 16 MB.")
        case .unreadable(let reason):
            return String(localized: "The file could not be read: \(reason)")
        }
    }
}

enum ArtLoader {
    /// No art format needs more: a 1,500 row XBin with its font is well under 1 MB.
    static let maximumBytes = 16 * 1024 * 1024

    /// Extensions the app lists and opens (the Mac app's set, plus plain .txt).
    static let extensions: Set<String> = ArtFiles.extensions.union(["txt"])

    /// What the Open from Files sheet offers.
    static var contentTypes: [UTType] {
        var types: [UTType] = [.plainText]
        for ext in extensions.sorted() {
            if let type = UTType(filenameExtension: ext), !types.contains(type) { types.append(type) }
        }
        return types
    }

    /// Reads a file the system handed the app (Files, Open In, the file importer). The security
    /// scope is open only while reading; the file is read through a file coordinator so an iCloud
    /// Drive file that is not downloaded yet is fetched first.
    static func read(_ url: URL) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var coordinatorError: NSError?
        var result: Result<Data, Error> = .failure(ArtLoadError.unreadable("no data"))
        NSFileCoordinator().coordinate(readingItemAt: url, options: [.withoutChanges], error: &coordinatorError) { readURL in
            result = Result { try readLimited(readURL) }
        }
        if let coordinatorError { throw ArtLoadError.unreadable(coordinatorError.localizedDescription) }
        return try result.get()
    }

    /// Reads a file the app may read directly (its bundle and its Documents folder).
    static func readLimited(_ url: URL) throws -> Data {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if size > maximumBytes { throw ArtLoadError.tooLarge(size) }
        do {
            return try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw ArtLoadError.unreadable(error.localizedDescription)
        }
    }

    static func load(_ item: ArtItem) throws -> ArtFile {
        let data = try item.data ?? readLimited(item.url)
        return ArtFile(data: data, fileExtension: item.url.pathExtension)
    }
}

/// The lists on the app's first screen.
@MainActor
final class ArtLibrary: ObservableObject {
    @Published private(set) var samples: [ArtItem] = []
    @Published private(set) var documents: [ArtItem] = []
    @Published private(set) var opened: [ArtItem] = []

    init() {
        samples = Self.samples()
        refresh()
    }

    static var documentsFolder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// Bundled original samples, Welcome first.
    static func samples(in bundle: Bundle = .main) -> [ArtItem] {
        guard let folder = bundle.resourceURL?.appendingPathComponent("Samples"),
              let files = try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return [] }
        return files.map { ArtItem(url: $0, source: .sample, data: nil) }.sorted { a, b in
            if (a.title == "Welcome") != (b.title == "Welcome") { return a.title == "Welcome" }
            return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
    }

    /// Re-reads the Documents folder (files may arrive through the Files app at any time).
    func refresh() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: Self.documentsFolder, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles])) ?? []
        documents = files
            .filter { ArtLoader.extensions.contains($0.pathExtension.lowercased()) }
            .map { ArtItem(url: $0, source: .documents, data: nil) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Reads a file from outside the app and lists it under Opened (most recent first).
    func open(_ url: URL) throws -> ArtItem {
        // Compared by path components after resolving /var and /private/var.
        let folder = Self.documentsFolder.resolvingSymlinksInPath().pathComponents
        let file = url.resolvingSymlinksInPath().pathComponents
        if file.count == folder.count + 1, Array(file.prefix(folder.count)) == folder {
            refresh()
            return ArtItem(url: url, source: .documents, data: nil)
        }
        let item = ArtItem(url: url, source: .opened, data: try ArtLoader.read(url))
        opened.removeAll { $0.url == url }
        opened.insert(item, at: 0)
        return item
    }

    /// Finds a sample or Documents file by name, with or without its extension (debug launch hooks).
    func item(named name: String) -> ArtItem? {
        let all = samples + documents
        return all.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            ?? all.first { $0.title.caseInsensitiveCompare(name) == .orderedSame }
    }
}
