import AnsiCore
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Thumbnails kept on disk (plan 9 ruling 10): `Caches/Thumbnails`, keyed by where a piece is and
/// its size and date, under a 300 MB cap with least recently used eviction. Galleries and the
/// library show a cached thumbnail without reading the art again. Safe to use from any thread.
final class ThumbnailStore {
    static let capacity = 300 * 1024 * 1024
    static let shared = ThumbnailStore(folder: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Thumbnails"))
    /// The pixel size thumbnails are drawn at (twice the gallery's point size, for Retina screens).
    static let pixels = CGSize(width: 384, height: 288)

    private let lock = NSLock()
    private let folder: URL
    private var cache: DiskCache?

    init(folder: URL) {
        self.folder = folder
    }

    /// Opened on first use: the cache scans its folder once.
    private var disk: DiskCache {
        if let cache { return cache }
        let made = DiskCache(folder: folder, capacity: Self.capacity)
        cache = made
        return made
    }

    /// The key for a piece: a file (`entry` nil) or an entry of a ZIP pack at `path`, with the size
    /// and date of the file or pack, so an edited file gets a new thumbnail.
    static func key(path: String, entry: String?, size: Int, modified: Date) -> String {
        let text = "\(path)\n\(entry ?? "")\n\(size)\n\(Int(modified.timeIntervalSince1970 * 1000))"
        let digest = SHA256.hash(data: Data(text.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
        return "t/\(digest.prefix(2))/\(digest).png"
    }

    func image(for key: String) -> CGImage? {
        lock.lock()
        let data = disk.data(for: key)
        lock.unlock()
        guard let data, let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    func contains(_ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return disk.contains(key)
    }

    func store(_ image: CGImage, for key: String) {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return }
        lock.lock()
        _ = try? disk.store(data as Data, for: key)
        lock.unlock()
    }
}
