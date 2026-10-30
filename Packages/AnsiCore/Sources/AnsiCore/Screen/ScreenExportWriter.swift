import Foundation

/// Writes an exported screen into a BBS install folder: never over an existing file without
/// confirmation; the first replaced file is kept as `<name>.bak` and the previous version as `<name>.bak2`
/// (screen designer ruling 6).
public enum ScreenExportWriter {
    public struct Existing: Equatable {
        public let size: Int
        public let modified: Date?
    }

    public struct Result: Equatable {
        public let url: URL
        public let backupURL: URL?
        public let bytesWritten: Int
        public let replaced: Bool
    }

    public enum WriteError: Error, Equatable, LocalizedError {
        case wouldOverwrite(String)
        case unsafePath(String)

        public var errorDescription: String? {
            switch self {
            case .wouldOverwrite(let name):
                return "\(name) already exists in the BBS folder. Confirm replacing it (the old file is kept as \(name).bak, or .bak2 when a .bak exists)."
            case .unsafePath(let path):
                return "The file name \"\(path)\" would write outside the BBS folder."
            }
        }
    }

    public static let backupExtension = "bak"

    /// The file already at `url` (nil when there is none).
    public static func conflict(at url: URL) -> Existing? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return Existing(size: (attributes[.size] as? NSNumber)?.intValue ?? 0, modified: attributes[.modificationDate] as? Date)
    }

    /// A relative path with empty and "." parts removed; nil when absolute, empty or climbing out with "..".
    public static func safeRelativePath(_ path: String) -> String? {
        guard !path.hasPrefix("/") else { return nil }
        let parts = path.split(separator: "/").map(String.init).filter { !$0.isEmpty && $0 != "." }
        guard !parts.isEmpty, !parts.contains("..") else { return nil }
        return parts.joined(separator: "/")
    }

    /// Writes `data` at `url`, making missing folders. An existing file is replaced only when
    /// `replacing` is true, and is first copied to `<name>.bak` (or `.bak2`, see below).
    @discardableResult
    public static func write(_ data: Data, to url: URL, replacing: Bool) throws -> Result {
        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var backup: URL?
        let exists = conflict(at: url) != nil
        if exists {
            guard replacing else { throw WriteError.wouldOverwrite(url.lastPathComponent) }
            // `.bak` keeps the first file AnsiView replaced (often the SysOp's original) and is
            // never overwritten; later replacements keep the previous version in `.bak2`.
            var bak = url.appendingPathExtension(backupExtension)
            if manager.fileExists(atPath: bak.path) {
                bak = url.appendingPathExtension(backupExtension + "2")
                if manager.fileExists(atPath: bak.path) { try manager.removeItem(at: bak) }
            }
            try manager.copyItem(at: url, to: bak)
            backup = bak
        }
        try data.write(to: url, options: .atomic)
        return Result(url: url, backupURL: backup, bytesWritten: data.count, replaced: exists)
    }
}
