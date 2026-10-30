import Foundation

/// Files kept in a folder under a byte cap. When a new entry takes the total over the cap, the
/// least recently used entries go first (a file's modification date is its last use: every hit
/// sets it to now). The newest entry is never removed, even when it alone is over the cap.
/// Top level folders named in `excluded` are neither counted nor removed. Use from one thread.
public final class DiskCache {
    /// 200 MB.
    public static let defaultCapacity = 200 * 1024 * 1024

    public struct Entry: Equatable {
        public let key: String
        public let bytes: Int
        public let lastUsed: Date

        public init(key: String, bytes: Int, lastUsed: Date) {
            self.key = key
            self.bytes = bytes
            self.lastUsed = lastUsed
        }
    }

    public let folder: URL
    public let capacity: Int
    public let excluded: Set<String>
    /// Bytes per key, scanned from disk when the cache is made.
    private var sizes: [String: Int] = [:]

    public private(set) var totalBytes = 0

    public init(folder: URL, capacity: Int = DiskCache.defaultCapacity, excluded: Set<String> = []) {
        self.folder = folder
        self.capacity = capacity
        self.excluded = excluded
        scan()
    }

    /// The file for a key (a relative path). Empty, `.` and `..` components are dropped, so a
    /// key can never name a file outside the folder.
    public func url(for key: String) -> URL {
        let parts = Self.parts(key)
        return parts.reduce(folder) { $0.appendingPathComponent($1) }
    }

    private static func parts(_ key: String) -> [String] {
        let parts = key.split(separator: "/").map(String.init).filter { $0 != "." && $0 != ".." }
        return parts.isEmpty ? ["_"] : parts
    }

    private static func normalized(_ key: String) -> String { parts(key).joined(separator: "/") }

    public func contains(_ key: String) -> Bool {
        FileManager.default.fileExists(atPath: url(for: key).path)
    }

    /// The entry's bytes, marking it used; nil when it is not cached.
    public func data(for key: String) -> Data? {
        guard let data = try? Data(contentsOf: url(for: key)) else { return nil }
        touch(key)
        return data
    }

    /// Marks an entry used now.
    public func touch(_ key: String) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url(for: key).path)
    }

    @discardableResult
    public func store(_ data: Data, for key: String) throws -> URL {
        let destination = try prepare(key)
        try data.write(to: destination, options: .atomic)
        return added(key, bytes: data.count)
    }

    /// Moves a finished download into the cache.
    @discardableResult
    public func adopt(_ file: URL, for key: String) throws -> URL {
        let destination = try prepare(key)
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.moveItem(at: file, to: destination)
        let bytes = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return added(key, bytes: bytes)
    }

    private func prepare(_ key: String) throws -> URL {
        let destination = url(for: key)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        return destination
    }

    private func added(_ key: String, bytes: Int) -> URL {
        let key = Self.normalized(key)
        totalBytes += bytes - (sizes[key] ?? 0)
        sizes[key] = bytes
        touch(key)
        prune(keeping: key)
        return url(for: key)
    }

    /// Removes least recently used entries until the total fits the cap.
    public func prune(keeping: String?) {
        guard totalBytes > capacity else { return }
        let entries = sizes.map { key, bytes in
            let date = (try? url(for: key).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            return Entry(key: key, bytes: bytes, lastUsed: date ?? .distantPast)
        }
        for key in Self.evictions(entries, capacity: capacity, keeping: keeping.map(Self.normalized)) {
            try? FileManager.default.removeItem(at: url(for: key))
            totalBytes -= sizes.removeValue(forKey: key) ?? 0
        }
    }

    /// Which keys to remove, oldest use first, so the rest fit `capacity`.
    public static func evictions(_ entries: [Entry], capacity: Int, keeping: String?) -> [String] {
        var total = entries.reduce(0) { $0 + $1.bytes }
        var removed: [String] = []
        let oldestFirst = entries.sorted { $0.lastUsed != $1.lastUsed ? $0.lastUsed < $1.lastUsed : $0.key < $1.key }
        for entry in oldestFirst where total > capacity && entry.key != keeping {
            removed.append(entry.key)
            total -= entry.bytes
        }
        return removed
    }

    private func scan() {
        let base = folder.standardizedFileURL.resolvingSymlinksInPath().path
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else { return }
        for case let file as URL in walker {
            let path = file.standardizedFileURL.resolvingSymlinksInPath().path
            guard path.hasPrefix(base + "/") else { continue }
            let key = String(path.dropFirst(base.count + 1))
            if let top = key.split(separator: "/").first, excluded.contains(String(top)) {
                if key.split(separator: "/").count == 1 { walker.skipDescendants() }
                continue
            }
            let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { continue }
            let bytes = values?.fileSize ?? 0
            sizes[key] = bytes
            totalBytes += bytes
        }
    }
}
