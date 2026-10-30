import Foundation

/// The dialing directory: saved BBSes with their call history, tags and settings, plus the
/// global macros and redial settings. Stored as JSON in the app's user defaults (ruling 2).
public struct DialingDirectory: Equatable {
    public static let defaultsKey = "dialingDirectory"
    public static let version = 1
    public static let exportFormat = "AnsiView Dialing Directory"
    public static let exampleHost = "bbs.example.com"

    public var entries: [BBSEntry]
    /// Option-1 ... Option-0 for every BBS; an entry's own non empty slot wins.
    public var globalMacros: [String]
    /// Shows the directory when the app launches.
    public var showAtLaunch: Bool
    /// Passes through the dial queue before giving up.
    public var redialAttempts: Int
    /// Seconds between failed attempts.
    public var redialDelay: Double

    public init(entries: [BBSEntry] = []) {
        self.entries = entries
        globalMacros = Array(repeating: "", count: MacroSet.slotCount)
        showAtLaunch = false
        redialAttempts = 3
        redialDelay = 10
    }

    /// The directory a first launch shows: one entry that is plainly an example.
    public static var example: DialingDirectory {
        var entry = BBSEntry(name: "Example BBS (edit me)", host: exampleHost)
        entry.notes = "A placeholder. Edit it with your BBS's address, or delete it."
        return DialingDirectory(entries: [entry])
    }

    /// Loads the stored directory; when there is none, migrates the plan 7 address book; when
    /// neither exists, the example. A stored directory that cannot be read gives an empty one.
    public init(stored: Data?, legacy: Data?) {
        if let stored {
            self = (try? Self.decoder.decode(Stored.self, from: stored))?.directory ?? DialingDirectory()
        } else if let legacy {
            self = DialingDirectory(entries: BBSAddressBook(data: legacy).entries)
        } else {
            self = .example
        }
    }

    public func encoded() -> Data {
        (try? Self.encoder.encode(Stored(self))) ?? Data("{}".utf8)
    }

    // MARK: Lists

    /// Every tag in use, case insensitively unique, sorted.
    public var allTags: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for tag in entries.flatMap(\.tags) {
            let trimmed = tag.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { continue }
            out.append(trimmed)
        }
        return out.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Entries in stored order whose name, address, notes or tags contain `search`, with `tag` if given.
    public func filtered(search: String, tag: String?) -> [BBSEntry] {
        let needle = search.trimmingCharacters(in: .whitespaces)
        return entries.filter { entry in
            if let tag, !entry.tags.contains(where: { $0.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(tag) == .orderedSame }) {
                return false
            }
            guard !needle.isEmpty else { return true }
            let fields = [entry.name, entry.address, entry.notes] + entry.tags
            return fields.contains { $0.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }

    public enum SortKey: String, CaseIterable {
        case name, address, lastCalled, totalCalls, notes
    }

    /// A sorted view (the stored order is unchanged). Never called sorts as the oldest call.
    public static func sorted(_ list: [BBSEntry], by key: SortKey, ascending: Bool) -> [BBSEntry] {
        func before(_ a: BBSEntry, _ b: BBSEntry) -> Bool {
            switch key {
            case .name: return a.name.localizedStandardCompare(b.name) == .orderedAscending
            case .address: return a.address.localizedStandardCompare(b.address) == .orderedAscending
            case .notes: return a.notes.localizedStandardCompare(b.notes) == .orderedAscending
            case .totalCalls: return a.totalCalls < b.totalCalls
            case .lastCalled: return (a.lastCalled ?? .distantPast) < (b.lastCalled ?? .distantPast)
            }
        }
        // Stable: ties keep the stored order.
        let indexed = list.enumerated().map { ($0.offset, $0.element) }
        return indexed.sorted { x, y in
            if before(x.1, y.1) { return ascending }
            if before(y.1, x.1) { return !ascending }
            return x.0 < y.0
        }.map(\.1)
    }

    // MARK: Editing

    /// Moves `ids` (kept in their stored order) to just before `target`, or to the end when nil.
    public mutating func move(_ ids: [UUID], before target: UUID?) {
        let moving = Set(ids)
        guard !moving.isEmpty else { return }
        if let target, moving.contains(target) {
            // Dropping onto one of the moved rows: insert before the first row after it that stays.
            guard let index = entries.firstIndex(where: { $0.id == target }) else { return }
            let next = entries[index...].first { !moving.contains($0.id) }?.id
            move(ids, before: next)
            return
        }
        let moved = entries.filter { moving.contains($0.id) }
        var rest = entries.filter { !moving.contains($0.id) }
        let insertAt = target.flatMap { t in rest.firstIndex { $0.id == t } } ?? rest.count
        rest.insert(contentsOf: moved, at: insertAt)
        entries = rest
    }

    /// A copy placed after the original, with a new id, " copy" added and no call history.
    @discardableResult
    public mutating func duplicate(_ id: UUID) -> BBSEntry? {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return nil }
        var copy = entries[index]
        copy.id = UUID()
        copy.name += " copy"
        copy.totalCalls = 0
        copy.lastCalled = nil
        entries.insert(copy, at: index + 1)
        return copy
    }

    /// The BBS answered: one more call, and now as the last call (whole seconds).
    public mutating func recordCall(_ id: UUID, at date: Date) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].totalCalls += 1
        entries[index].lastCalled = Date(timeIntervalSinceReferenceDate: date.timeIntervalSinceReferenceDate.rounded(.down))
    }

    /// True when an entry other than `id` uses the same Keychain item (so deleting `id` must keep it).
    public func sharesCredential(_ key: CredentialKey, excluding id: UUID) -> Bool {
        entries.contains { $0.id != id && $0.credentialKey == key }
    }

    // MARK: Export and import

    /// The export file for `ids` (all entries when nil): no passwords (the model has none) and
    /// no capture bookmarks (they only work on this Mac).
    public func exportData(ids: Set<UUID>?) -> Data {
        let chosen = entries.filter { ids?.contains($0.id) ?? true }.map { entry -> BBSEntry in
            var copy = entry
            copy.captureFolderBookmark = nil
            copy.captureFolderName = nil
            copy.captureOnConnect = false
            return copy
        }
        let file = ExportFile(format: Self.exportFormat, version: Self.version, entries: chosen)
        let encoder = Self.encoder
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(file)) ?? Data()
    }

    public enum ImportError: LocalizedError {
        case unreadable
        public var errorDescription: String? {
            "The file is not an AnsiView dialing directory export or address book."
        }
    }

    /// Reads an export file, a stored directory or a plan 7 address book array.
    public static func importEntries(from data: Data) throws -> [BBSEntry] {
        if let file = try? decoder.decode(ExportFile.self, from: data), file.format == exportFormat {
            return file.entries
        }
        if let stored = try? decoder.decode(Stored.self, from: data) { return stored.entries }
        if let array = try? decoder.decode([BBSEntry].self, from: data) { return array }
        if let array = try? JSONDecoder().decode([BBSEntry].self, from: data) { return array }
        throw ImportError.unreadable
    }

    /// Adds imported entries with fresh ids, skipping any with the same name, host, port and
    /// username as one already here (or earlier in the import).
    @discardableResult
    public mutating func merge(_ imported: [BBSEntry]) -> (added: [BBSEntry], skipped: Int) {
        func identity(_ e: BBSEntry) -> String {
            [e.name.lowercased(), e.host.lowercased(), String(e.port), e.username ?? ""].joined(separator: "\u{1F}")
        }
        var seen = Set(entries.map(identity))
        var added: [BBSEntry] = []
        var skipped = 0
        for var entry in imported {
            guard seen.insert(identity(entry)).inserted else { skipped += 1; continue }
            entry.id = UUID()
            added.append(entry)
        }
        entries += added
        return (added, skipped)
    }

    // MARK: Coding

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private struct ExportFile: Codable {
        var format: String
        var version: Int
        var entries: [BBSEntry]
    }

    private struct Stored: Codable {
        var version: Int
        var entries: [BBSEntry]
        var globalMacros: [String]?
        var showAtLaunch: Bool?
        var redialAttempts: Int?
        var redialDelay: Double?

        init(_ d: DialingDirectory) {
            version = DialingDirectory.version
            entries = d.entries
            globalMacros = d.globalMacros
            showAtLaunch = d.showAtLaunch
            redialAttempts = d.redialAttempts
            redialDelay = d.redialDelay
        }

        var directory: DialingDirectory {
            var d = DialingDirectory(entries: entries)
            if let globalMacros {
                d.globalMacros = Array((globalMacros + Array(repeating: "", count: MacroSet.slotCount)).prefix(MacroSet.slotCount))
            }
            d.showAtLaunch = showAtLaunch ?? false
            if let redialAttempts { d.redialAttempts = min(RedialQueue.passRange.upperBound, max(RedialQueue.passRange.lowerBound, redialAttempts)) }
            if let redialDelay { d.redialDelay = min(RedialQueue.delayRange.upperBound, max(RedialQueue.delayRange.lowerBound, redialDelay)) }
            return d
        }
    }
}
