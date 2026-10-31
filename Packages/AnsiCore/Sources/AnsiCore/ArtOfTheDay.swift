import Foundation

/// The menu bar's piece of the day (plan 10 ruling 10): the same pick all day, a new one tomorrow.
public enum ArtOfTheDay {
    /// The local calendar day as yyyy-MM-dd.
    public static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// The day's piece from the library: among favourites and pieces rated 4 or more when there
    /// are any, else among all; the order of `records` does not matter.
    public static func pick(_ records: [IndexRecord], notes: [String: PieceNotes], day: String) -> IndexRecord? {
        let liked = records.filter { record in
            let note = notes[record.identity]
            return note?.favourite == true || (note?.rating ?? 0) >= 4
        }
        let pool = (liked.isEmpty ? records : liked).sorted { $0.key < $1.key }
        guard !pool.isEmpty else { return nil }
        return pool[Int(fnv1a(day + "#library") % UInt64(pool.count))]
    }

    /// One of `names` for the day; `salt` keeps different choices (year, pack, file) independent.
    public static func choose<T>(from items: [T], day: String, salt: String) -> T? {
        guard !items.isEmpty else { return nil }
        return items[Int(fnv1a(day + "#" + salt) % UInt64(items.count))]
    }

    /// 64 bit FNV-1a of the UTF-8 bytes.
    public static func fnv1a(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }
}
