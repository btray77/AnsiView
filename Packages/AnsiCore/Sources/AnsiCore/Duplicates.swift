import CryptoKit
import Foundation

/// SHA-256 of a file's bytes, as 64 hex digits: exact copies have the same one.
public enum ByteHash {
    public static func of(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// SHA-256 of what a finished screen looks like (plan 9 ruling 12): its width and every cell's
/// character, colours, blink and Unicode scalar, with trailing blank rows dropped, NUL and 255
/// drawn as space, and a blank cell's invisible foreground left out. The same art saved with
/// another SAUCE record, other line endings or redundant codes has the same hash.
public enum CellHash {
    /// Nil when nothing on the screen can be seen (empty art never counts as a duplicate).
    public static func of(_ screen: AnsiScreen) -> String? {
        let width = screen.columns
        func visible(_ cell: AnsiCell) -> Bool {
            !(CellDiff.isBlank(cell) && cell.bg == Palette.vga[0] && !cell.blink)
        }
        guard let last = screen.rows.lastIndex(where: { $0.prefix(width).contains(where: visible) }) else { return nil }
        var hasher = SHA256()
        var header = [UInt8]()
        withUnsafeBytes(of: UInt32(width).littleEndian) { header += $0 }
        hasher.update(data: header)
        var buffer = [UInt8]()
        buffer.reserveCapacity(width * 12)
        for row in screen.rows[...last] {
            buffer.removeAll(keepingCapacity: true)
            for x in 0..<width {
                let cell = x < row.count ? row[x] : AnsiCell()
                if CellDiff.isBlank(cell) {
                    buffer += [0x20, 0, 0, 0, cell.bg.r, cell.bg.g, cell.bg.b, cell.blink ? 1 : 0, 0, 0, 0, 0]
                } else {
                    let scalar = cell.scalar?.value ?? 0
                    buffer += [cell.code, cell.fg.r, cell.fg.g, cell.fg.b, cell.bg.r, cell.bg.g, cell.bg.b,
                               cell.blink ? 1 : 0, UInt8(scalar & 0xFF), UInt8(scalar >> 8 & 0xFF),
                               UInt8(scalar >> 16 & 0xFF), UInt8(scalar >> 24)]
                }
            }
            hasher.update(data: buffer)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Pieces that are copies of each other.
public struct DuplicateGroup: Equatable {
    public enum Kind: Equatable {
        /// The same bytes.
        case exact
        /// The same rendered cells from different bytes (SAUCE, line endings or codes differ).
        case sameArt
    }
    public let kind: Kind
    /// Indexes into the list given to `DuplicateFinder.groups`, ascending.
    public let members: [Int]
}

public enum DuplicateFinder {
    /// Exact copy groups first, then same art groups (only where the bytes differ somewhere in the
    /// group), each in order of their first member.
    public static func groups(_ items: [(byteHash: String, cellHash: String?)]) -> [DuplicateGroup] {
        var byBytes: [String: [Int]] = [:]
        var byCells: [String: [Int]] = [:]
        for (index, item) in items.enumerated() {
            byBytes[item.byteHash, default: []].append(index)
            if let cells = item.cellHash { byCells[cells, default: []].append(index) }
        }
        let exact = byBytes.values.filter { $0.count > 1 }.sorted { $0[0] < $1[0] }
            .map { DuplicateGroup(kind: .exact, members: $0) }
        let same = byCells.values.filter { members in
            members.count > 1 && Set(members.map { items[$0].byteHash }).count > 1
        }.sorted { $0[0] < $1[0] }.map { DuplicateGroup(kind: .sameArt, members: $0) }
        return exact + same
    }

    /// The copy to keep when ticking all but one: the shortest path, then the oldest, then the first.
    public static func keeper(paths: [String], dates: [Date]) -> Int? {
        guard !paths.isEmpty else { return nil }
        return paths.indices.min { a, b in
            if paths[a].count != paths[b].count { return paths[a].count < paths[b].count }
            let da = a < dates.count ? dates[a] : .distantFuture, db = b < dates.count ? dates[b] : .distantFuture
            if da != db { return da < db }
            return a < b
        }
    }
}
