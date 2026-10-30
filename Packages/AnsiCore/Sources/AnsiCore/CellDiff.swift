/// Which cells of two finished screens look different (plan 9 ruling 3). The grid is as wide and
/// tall as the larger screen; a cell only one screen has counts as different.
public struct CellDiff {
    public let columns: Int
    public let rows: Int
    /// Row major: `differing[y * columns + x]`.
    public let differing: [Bool]
    public let count: Int
    public var total: Int { columns * rows }

    public init(_ a: AnsiScreen, _ b: AnsiScreen) {
        columns = max(a.columns, b.columns)
        rows = max(a.rows.count, b.rows.count)
        var marks = [Bool](repeating: false, count: columns * rows)
        var count = 0
        func cell(_ screen: AnsiScreen, _ x: Int, _ y: Int) -> AnsiCell? {
            guard y < screen.rows.count, x < screen.columns, x < screen.rows[y].count else { return nil }
            return screen.rows[y][x]
        }
        for y in 0..<rows {
            for x in 0..<columns {
                let same: Bool
                switch (cell(a, x, y), cell(b, x, y)) {
                case let (p?, q?): same = Self.sameLook(p, q)
                default: same = false
                }
                if !same {
                    marks[y * columns + x] = true
                    count += 1
                }
            }
        }
        differing = marks
        self.count = count
    }

    public func differs(x: Int, y: Int) -> Bool {
        guard x >= 0, y >= 0, x < columns, y < rows else { return false }
        return differing[y * columns + x]
    }

    /// Rows with at least one differing cell, top to bottom.
    public var rowsWithDifferences: [Int] {
        (0..<rows).filter { y in differing[(y * columns)..<((y + 1) * columns)].contains(true) }
    }

    /// The next (or previous) row with a difference after `row`, wrapping; the first (or last)
    /// when `row` is nil; nil when nothing differs.
    public func nextRow(after row: Int?, forward: Bool) -> Int? {
        let found = rowsWithDifferences
        guard !found.isEmpty else { return nil }
        guard let row else { return forward ? found.first : found.last }
        if forward { return found.first { $0 > row } ?? found.first }
        return found.last { $0 < row } ?? found.last
    }

    /// True when the two cells draw the same pixels: NUL and 255 draw as spaces, and a blank
    /// cell's foreground cannot be seen.
    public static func sameLook(_ a: AnsiCell, _ b: AnsiCell) -> Bool {
        let blankA = isBlank(a), blankB = isBlank(b)
        if blankA || blankB { return blankA && blankB && a.bg == b.bg && a.blink == b.blink }
        return a.code == b.code && a.scalar == b.scalar && a.fg == b.fg && a.bg == b.bg && a.blink == b.blink
    }

    static func isBlank(_ cell: AnsiCell) -> Bool {
        cell.scalar == nil ? (cell.code == 0x20 || cell.code == 0x00 || cell.code == 0xFF) : cell.scalar == " "
    }
}
