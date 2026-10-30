/// The character screen the home computer engines share: cells with a platform glyph, colours,
/// a cursor and a scrollback, and the editing operations those machines had.
struct RetroGrid {
    struct Cell: Equatable {
        /// The platform glyph index (meaning depends on the engine).
        var glyph: UInt16 = 0
        /// The character copied as text.
        var text: UInt8 = 0x20
        var fg: RGB
        var bg: RGB
        var blink = false
        var concealed = false
    }

    private(set) var columns: Int
    private(set) var rows: Int
    var cells: [[Cell]]
    private(set) var scrollback: [[Cell]] = []
    var row = 0
    var column = 0
    let blank: Cell

    init(columns: Int, rows: Int, blank: Cell) {
        self.columns = max(1, min(255, columns))
        self.rows = max(1, min(255, rows))
        self.blank = blank
        cells = Array(repeating: Array(repeating: blank, count: self.columns), count: self.rows)
    }

    mutating func clear() {
        cells = Array(repeating: Array(repeating: blank, count: columns), count: rows)
        row = 0
        column = 0
    }

    mutating func scrollUp() {
        scrollback.append(cells.removeFirst())
        if scrollback.count > TerminalEmulator.maxScrollback { scrollback.removeFirst() }
        cells.append(Array(repeating: blank, count: columns))
    }

    mutating func clearScrollback() { scrollback.removeAll() }

    /// Down one row, scrolling at the bottom.
    mutating func lineFeed() {
        if row == rows - 1 { scrollUp() } else { row += 1 }
    }

    mutating func insertLine(at r: Int) {
        cells.remove(at: rows - 1)
        cells.insert(Array(repeating: blank, count: columns), at: r)
    }

    mutating func deleteLine(at r: Int) {
        cells.remove(at: r)
        cells.append(Array(repeating: blank, count: columns))
    }

    mutating func resize(columns c: Int, rows r: Int) {
        let c = max(1, min(255, c)), r = max(1, min(255, r))
        cells = (0..<r).map { i in
            let line = i < cells.count ? cells[i] : []
            return Array(line.prefix(c)) + Array(repeating: blank, count: max(0, c - line.count))
        }
        columns = c
        rows = r
        row = min(row, r - 1)
        column = min(column, c - 1)
    }

    func screen(scrollOffset: Int, show: (Cell) -> AnsiCell) -> AnsiScreen {
        let offset = min(max(0, scrollOffset), scrollback.count)
        let start = scrollback.count - offset
        let lines: [[AnsiCell]] = (start..<(start + rows)).map { index in
            let line = index < scrollback.count ? scrollback[index] : cells[index - scrollback.count]
            let fitted = Array(line.prefix(columns)) + Array(repeating: blank, count: max(0, columns - line.count))
            return fitted.map(show)
        }
        return AnsiScreen(columns: columns, rows: lines)
    }

    static func cell(_ c: Cell) -> AnsiCell {
        var cell = AnsiCell(code: c.text, fg: c.fg, bg: c.bg, blink: c.blink)
        cell.glyph = c.glyph
        return cell
    }
}

extension RGB {
    init(hex: UInt32) {
        self.init(r: UInt8(hex >> 16 & 0xFF), g: UInt8(hex >> 8 & 0xFF), b: UInt8(hex & 0xFF))
    }
}
