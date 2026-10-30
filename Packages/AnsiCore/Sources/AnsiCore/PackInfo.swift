import Foundation

/// A pack's own description files (plan 9 ruling 13): its FILE_ID.DIZ and NFOs.
public enum PackInfo {
    /// Indexes into `names` (paths inside a pack or folder) of the files to show: the shallowest
    /// FILE_ID.DIZ first (any case), then every `.nfo` by name.
    public static func infoFiles(_ names: [String]) -> [Int] {
        func depth(_ path: String) -> Int { path.split(separator: "/").count }
        func file(_ path: String) -> String { (path as NSString).lastPathComponent }
        let diz = names.indices.filter { file(names[$0]).lowercased() == "file_id.diz" }
            .min { depth(names[$0]) < depth(names[$1]) }
        let nfos = names.indices.filter { (names[$0] as NSString).pathExtension.lowercased() == "nfo" }
            .sorted { file(names[$0]).localizedStandardCompare(file(names[$1])) == .orderedAscending }
        return (diz.map { [$0] } ?? []) + nfos
    }
}

/// The order background work (thumbnails) goes in: what is on screen first, then the rest from the
/// top (plan 9 ruling 11). Nothing comes out twice.
public struct WorkOrder {
    private var done: [Bool]
    private var urgent: [Int] = []
    private var cursor = 0
    public private(set) var remaining: Int

    public init(count: Int) {
        done = [Bool](repeating: false, count: max(0, count))
        remaining = max(0, count)
    }

    /// Puts these indexes (the visible ones) at the front, in the order given.
    public mutating func prioritize(_ indexes: [Int]) {
        urgent = indexes.filter { done.indices.contains($0) && !done[$0] }
    }

    /// Marks an index as handled elsewhere (a thumbnail found in the cache).
    public mutating func finish(_ index: Int) {
        guard done.indices.contains(index), !done[index] else { return }
        done[index] = true
        remaining -= 1
    }

    public mutating func next() -> Int? {
        while let index = urgent.first {
            urgent.removeFirst()
            if !done[index] { finish(index); return index }
        }
        while cursor < done.count {
            let index = cursor
            cursor += 1
            if !done[index] { finish(index); return index }
        }
        return nil
    }
}
