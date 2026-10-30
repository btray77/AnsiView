import Foundation
import Testing
@testable import AnsiCore

/// The capped disk cache for 16colo.rs thumbnails, previews and listings.
struct DiskCacheTests {
    func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DiskCacheTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func entry(_ key: String, _ bytes: Int, _ seconds: TimeInterval) -> DiskCache.Entry {
        DiskCache.Entry(key: key, bytes: bytes, lastUsed: Date(timeIntervalSince1970: seconds))
    }

    @Test func evictionPlanOldestFirst() {
        let entries = [entry("b", 50, 2), entry("a", 50, 1), entry("c", 50, 3)]
        #expect(DiskCache.evictions(entries, capacity: 100, keeping: nil) == ["a"])
        #expect(DiskCache.evictions(entries, capacity: 150, keeping: nil) == [])
        #expect(DiskCache.evictions(entries, capacity: 0, keeping: nil) == ["a", "b", "c"])
    }

    @Test func evictionKeepsNewestEvenIfTooBig() {
        let entries = [entry("old", 10, 1), entry("big", 500, 2)]
        #expect(DiskCache.evictions(entries, capacity: 100, keeping: "big") == ["old"])
    }

    @Test func storeEvictsLeastRecentlyUsed() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = DiskCache(folder: folder, capacity: 300)
        let bytes = Data(repeating: 7, count: 100)
        for (index, key) in ["a", "images/p/tn/b.png", "c"].enumerated() {
            try cache.store(bytes, for: key)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1000 + Double(index))],
                                                  ofItemAtPath: cache.url(for: key).path)
        }
        #expect(cache.totalBytes == 300)
        #expect(cache.data(for: "a") == bytes)  // a is now the most recently used
        try cache.store(bytes, for: "d")
        #expect(!cache.contains("images/p/tn/b.png"))
        #expect(cache.contains("a") && cache.contains("c") && cache.contains("d"))
        #expect(cache.totalBytes == 300)
    }

    @Test func adoptMovesADownloadIn() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = DiskCache(folder: folder.appendingPathComponent("cache"), capacity: 1000)
        let download = folder.appendingPathComponent("download.tmp")
        try Data(repeating: 1, count: 40).write(to: download)
        let url = try cache.adopt(download, for: "files/p/A.ANS")
        #expect(url == cache.url(for: "files/p/A.ANS"))
        #expect(!FileManager.default.fileExists(atPath: download.path))
        #expect(cache.totalBytes == 40)
        // Replacing an entry counts it once.
        try cache.store(Data(repeating: 2, count: 10), for: "files/p/A.ANS")
        #expect(cache.totalBytes == 10)
    }

    @Test func excludedFolderIsNotCountedOrEvicted() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let packs = folder.appendingPathComponent("packs")
        try FileManager.default.createDirectory(at: packs, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 500).write(to: packs.appendingPathComponent("x.zip"))
        let cache = DiskCache(folder: folder, capacity: 100, excluded: ["packs"])
        #expect(cache.totalBytes == 0)
        try cache.store(Data(repeating: 1, count: 60), for: "a")
        try cache.store(Data(repeating: 1, count: 60), for: "b")
        #expect(FileManager.default.fileExists(atPath: packs.appendingPathComponent("x.zip").path))
        #expect(cache.totalBytes == 60)
    }

    @Test func totalsSurviveReopen() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = DiskCache(folder: folder, capacity: 1000)
        for key in ["a", "b/c", "b/d/e"] { try first.store(Data(repeating: 3, count: 100), for: key) }
        let second = DiskCache(folder: folder, capacity: 1000)
        #expect(second.totalBytes == 300)
        #expect(second.data(for: "b/d/e")?.count == 100)
    }

    @Test func keysStayInsideTheFolder() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = DiskCache(folder: folder, capacity: 1000)
        for key in ["../escape", "a/../../escape", "/etc/passwd", ""] {
            let url = cache.url(for: key)
            #expect(url.standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path + "/"), "\(key)")
        }
    }

    @Test func defaultCapacityIs200MB() {
        #expect(DiskCache.defaultCapacity == 209_715_200)
    }
}
