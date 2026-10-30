import CryptoKit
import Foundation

/// Where an exported screen stands compared with its source and the BBS folder.
public enum ScreenSetStatus: Equatable {
    case notExported
    /// Exported, and neither the screen nor the file in the BBS folder changed since.
    case exported(Date)
    /// The screen changed after it was exported.
    case modifiedSince(Date)
    /// The file in the BBS folder is not the one AnsiView wrote (edited on the BBS side).
    case changedInFolder(Date)
    /// The exported file is gone from the BBS folder.
    case missingInFolder(Date)
    /// The screen's source file could not be read.
    case sourceMissing(Date)

    public var label: String {
        func when(_ date: Date) -> String {
            DateFormatter.localizedString(from: date, dateStyle: .short, timeStyle: .short)
        }
        switch self {
        case .notExported: return "Not exported"
        case .exported(let d): return "Exported \(when(d))"
        case .modifiedSince(let d): return "Modified since export (\(when(d)))"
        case .changedInFolder(let d): return "Changed in the BBS folder since \(when(d))"
        case .missingInFolder(let d): return "Missing from the BBS folder (exported \(when(d)))"
        case .sourceMissing(let d): return "Source file not found (exported \(when(d)))"
        }
    }

    /// True when exporting again would change the BBS folder.
    public var needsExport: Bool {
        switch self {
        case .exported, .sourceMissing: return false
        default: return true
        }
    }
}

/// One screen of a BBS screen set: which slot it fills, the file it was exported as and how to
/// find its source again.
public struct ScreenSetEntry: Codable, Equatable, Identifiable {
    public var id: UUID
    public var slot: ScreenSlot
    /// Path inside the profile's BBS folder.
    public var fileName: String
    /// The art or project file the screen came from (shown, and read when there is no bookmark).
    public var sourcePath: String?
    /// App scoped security bookmark of the source file.
    public var sourceBookmark: Data?
    /// SHA-256 of the whole file written to the BBS folder.
    public var exportedSHA256: String?
    /// SHA-256 of the screen without SAUCE (whose date changes daily), for "modified since".
    public var bodySHA256: String?
    public var exportedAt: Date?

    public init(id: UUID = UUID(), slot: ScreenSlot, fileName: String) {
        self.id = id
        self.slot = slot
        self.fileName = fileName
    }

    public mutating func recordExport(file: Data, body: Data, at date: Date) {
        exportedSHA256 = ScreenSet.sha256(file)
        bodySHA256 = ScreenSet.sha256(body)
        exportedAt = date
    }
}

/// The screens exported with one profile (screen designer ruling 7): kept with the profile so the
/// set always describes one BBS install.
public struct ScreenSet: Codable, Equatable {
    public var profileID: UUID
    public var entries: [ScreenSetEntry]

    public init(profileID: UUID, entries: [ScreenSetEntry] = []) {
        self.profileID = profileID
        self.entries = entries
    }

    public init(data: Data) throws {
        self = try JSONDecoder().decode(ScreenSet.self, from: data)
    }

    public func data() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    /// Replaces the entry with the same id or file name (case blind, as DOS BBSes are), or adds it.
    public mutating func upsert(_ entry: ScreenSetEntry) {
        if let i = entries.firstIndex(where: { $0.id == entry.id || $0.fileName.lowercased() == entry.fileName.lowercased() }) {
            entries[i] = entry
        } else {
            entries.append(entry)
        }
    }

    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// `current` is the body exporting the source now would write (nil when the source is gone);
    /// `inFolder` is the file in the BBS folder now (nil when there is none).
    public static func status(_ entry: ScreenSetEntry, current: Data?, inFolder: Data?) -> ScreenSetStatus {
        guard let hash = entry.exportedSHA256, let date = entry.exportedAt else { return .notExported }
        guard let inFolder else { return .missingInFolder(date) }
        if sha256(inFolder) != hash { return .changedInFolder(date) }
        // Exported from an unsaved editor: there is no source to compare with.
        guard let current else { return entry.sourcePath == nil ? .exported(date) : .sourceMissing(date) }
        return sha256(current) == (entry.bodySHA256 ?? hash) ? .exported(date) : .modifiedSince(date)
    }
}
