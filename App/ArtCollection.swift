import AnsiCore
import Foundation

/// The art files of a folder or a ZIP art pack, in slideshow order. Holds the folder's security
/// scoped access (when it was granted through an open panel) for as long as it lives.
final class ArtCollection {
    struct Item {
        let name: String
        /// The file on disk; nil for entries inside an art pack.
        let fileURL: URL?
        let load: () throws -> Data
        /// The path inside the pack, for entries of an art pack.
        var entry: String? = nil
    }

    let title: String
    let items: [Item]
    /// The ZIP file, its size and date, for a pack (thumbnail cache keys).
    private(set) var pack: (url: URL, size: Int, modified: Date)?
    /// Art entries in a pack that use a compression method AnsiView cannot read.
    let skipped: Int
    private let scopedURL: URL?
    /// The folder or pack this collection reads (standardized).
    private var rootURL: URL?
    /// A collection whose security scope covers this one's folder, kept alive while this one is.
    private var borrowed: ArtCollection?
    /// Collections opened through an open panel, for borrowing their scope.
    private static let scopedCollections = NSHashTable<ArtCollection>.weakObjects()

    private init(title: String, items: [Item], skipped: Int, scopedURL: URL?) {
        self.title = title
        self.items = items
        self.skipped = skipped
        self.scopedURL = scopedURL
    }

    deinit { scopedURL?.stopAccessingSecurityScopedResource() }

    /// A folder or a `.zip` art pack. `scoped` starts security scoped access to a URL that came
    /// from an open panel; it is stopped when the collection goes away.
    static func open(_ url: URL, scoped: Bool) throws -> ArtCollection {
        let started = scoped && url.startAccessingSecurityScopedResource()
        let scope = started ? url : nil
        do {
            let collection = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                ? try folder(url, scope: scope) : try pack(url, scope: scope)
            let root = url.standardizedFileURL
            collection.rootURL = root
            if scoped {
                scopedCollections.add(collection)
            } else {
                // Readable only because another window holds the folder's scope (a gallery, say):
                // keep that scope alive for as long as this collection needs it.
                collection.borrowed = scopedCollections.allObjects.first { other in
                    guard let otherRoot = other.rootURL else { return false }
                    return root.path == otherRoot.path || root.path.hasPrefix(otherRoot.path + "/")
                }
            }
            return collection
        } catch {
            if started { url.stopAccessingSecurityScopedResource() }
            throw error
        }
    }

    /// The art files directly inside `url` (subfolders are not searched).
    private static func folder(_ url: URL, scope: URL?) throws -> ArtCollection {
        let contents = try FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true }
        let byName = Dictionary(contents.map { ($0.lastPathComponent, $0) }, uniquingKeysWith: { a, _ in a })
        let items = ArtFiles.ordered(Array(byName.keys)).compactMap { name -> Item? in
            guard let file = byName[name] else { return nil }
            return Item(name: name, fileURL: file, load: { try Data(contentsOf: file) })
        }
        return ArtCollection(title: url.lastPathComponent, items: items, skipped: 0, scopedURL: scope)
    }

    private static func pack(_ url: URL, scope: URL?) throws -> ArtCollection {
        let archive = try ZipArchive(data: try Data(contentsOf: url, options: .mappedIfSafe))
        let items = archive.artEntries.map { entry in
            Item(name: entry.name, fileURL: nil, load: { try archive.data(for: entry) }, entry: entry.path)
        }
        let collection = ArtCollection(title: url.lastPathComponent, items: items, skipped: archive.skippedCount, scopedURL: scope)
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        collection.pack = (url.standardizedFileURL, values?.fileSize ?? 0, values?.contentModificationDate ?? .distantPast)
        return collection
    }

    func artFile(at index: Int) -> ArtFile {
        guard items.indices.contains(index) else { return ArtFile(data: Data()) }
        let item = items[index]
        do {
            return ArtFile(data: try item.load(), fileExtension: (item.name as NSString).pathExtension)
        } catch {
            // Say so on screen rather than showing an empty black piece.
            let message = "Could not read \(item.name): \(error.localizedDescription)"
            return ArtFile(data: Data(message.utf8), fileExtension: "ans")
        }
    }
}

extension ArtCollection {
    /// The disk thumbnail key for a piece (plan 9 ruling 10); nil when the file cannot be looked at.
    func thumbnailKey(at index: Int) -> String? {
        guard items.indices.contains(index) else { return nil }
        let item = items[index]
        if let pack, let entry = item.entry {
            return ThumbnailStore.key(path: pack.url.path, entry: entry, size: pack.size, modified: pack.modified)
        }
        guard let url = item.fileURL,
              let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
        return ThumbnailStore.key(path: url.standardizedFileURL.path, entry: nil, size: values.fileSize ?? 0,
                                  modified: values.contentModificationDate ?? .distantPast)
    }

    /// Paths of the pieces as the pack lists them (folders: the file names), for finding info files.
    var itemPaths: [String] { items.map { $0.entry ?? $0.name } }

    /// The pieces at `indexes` (all when nil) for a batch export.
    func batchItems(_ indexes: [Int]? = nil) -> [BatchItem] {
        (indexes ?? Array(items.indices)).filter { items.indices.contains($0) }.map { index in
            BatchItem(name: items[index].name, load: items[index].load)
        }
    }
}
