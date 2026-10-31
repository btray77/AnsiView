/// An Apple II text terminal (GBBS, ProLine and Warp Six boards): 40x24 by default, high bit
/// ASCII accepted, and the 80 column firmware's control codes for inverse, clearing and cursor
/// addressing that Apple II terminal programs also honoured.
public struct AppleIITerminal: TerminalEngine {
    public static let foreground = RGB(hex: 0xF0_F0_F0)
    public static let background = RGB(hex: 0x00_00_00)

    private var grid: RetroGrid
    private var inverse = false
    /// MouseText (Ctrl-[ on, Ctrl-X off): inverse 0x40-0x5F show the MouseText pictures.
    private var mouseText = false
    private var afterCR = false
    /// A GotoXY (Ctrl-^) waiting for its column and row bytes.
    private var gotoBytes: [UInt8]?
    /// Shows lower case as capitals, as an Apple II or II+ without a lower case chip did.
    public var upperCaseOnly = false
    public private(set) var changeCount = 0
    public private(set) var bells = 0
    public var cursorVisible: Bool { true }

    public init(columns: Int = 40, rows: Int = 24) {
        grid = RetroGrid(columns: columns, rows: rows,
                         blank: RetroGrid.Cell(glyph: 0x20, text: 0x20, fg: Self.foreground, bg: Self.background))
    }

    public var font: BitmapFont? { PlatformFonts.appleII }
    public var columns: Int { grid.columns }
    public var rows: Int { grid.rows }
    public var cursor: (row: Int, column: Int) { (grid.row, grid.column) }
    public var scrollbackCount: Int { grid.scrollback.count }
    public mutating func takeReplies() -> [UInt8] { [] }
    public mutating func resize(columns: Int, rows: Int) { grid.resize(columns: columns, rows: rows); changeCount &+= 1 }
    public mutating func clearScrollback() { grid.clearScrollback(); changeCount &+= 1 }
    public func screen(scrollOffset: Int) -> AnsiScreen { grid.screen(scrollOffset: scrollOffset, show: RetroGrid.cell) }

    public mutating func feed(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        for b in bytes { consume(b & 0x7F) }
        changeCount &+= 1
    }

    private mutating func consume(_ b: UInt8) {
        if var pending = gotoBytes {
            pending.append(b)
            if pending.count == 2 {
                grid.column = min(columns - 1, max(0, Int(pending[0]) - 32))
                grid.row = min(rows - 1, max(0, Int(pending[1]) - 32))
                gotoBytes = nil
            } else {
                gotoBytes = pending
            }
            return
        }
        let wasCR = afterCR
        afterCR = b == 0x0D
        switch b {
        case 0x07: bells += 1
        case 0x08: grid.column = max(0, grid.column - 1)
        case 0x0A: if !wasCR { grid.lineFeed() }
        case 0x0B: clear(fromRow: grid.row, column: grid.column)
        case 0x0C: grid.clear()
        case 0x0D: grid.column = 0; grid.lineFeed()
        case 0x0E: inverse = false
        case 0x0F: inverse = true
        case 0x1B: mouseText = true
        case 0x18: mouseText = false
        case 0x15, 0x1C: grid.column = min(columns - 1, grid.column + 1)
        case 0x19: grid.row = 0; grid.column = 0
        case 0x1A: for c in 0..<columns { grid.cells[grid.row][c] = grid.blank }
        case 0x1D: for c in grid.column..<columns { grid.cells[grid.row][c] = grid.blank }
        case 0x1E: gotoBytes = []
        case 0x1F: grid.row = max(0, grid.row - 1)
        case 0x20...0x7E: put(b)
        default: break
        }
    }

    private mutating func clear(fromRow r: Int, column c: Int) {
        for x in c..<columns { grid.cells[r][x] = grid.blank }
        for y in (r + 1)..<max(r + 1, rows) { grid.cells[y] = Array(repeating: grid.blank, count: columns) }
    }

    private mutating func put(_ b: UInt8) {
        var code = b
        if upperCaseOnly, (0x61...0x7A).contains(code) { code -= 0x20 }
        let glyph = mouseText && inverse && (0x40...0x5F).contains(code) ? UInt16(128 + Int(code) - 0x40) : UInt16(code)
        grid.cells[grid.row][grid.column] = RetroGrid.Cell(glyph: glyph, text: code,
                                                           fg: inverse ? Self.background : Self.foreground,
                                                           bg: inverse ? Self.foreground : Self.background)
        if grid.column == columns - 1 {
            grid.column = 0
            grid.lineFeed()
        } else {
            grid.column += 1
        }
    }

    public func bytes(for key: TerminalKey, backspaceSendsDelete: Bool) -> [UInt8] {
        switch key {
        case .returnKey: return [0x0D]
        case .backspace: return [backspaceSendsDelete ? 0x7F : 0x08]
        case .forwardDelete: return [0x7F]
        case .tab: return [0x09]
        case .escape: return [0x1B]
        case .left: return [0x08]
        case .right: return [0x15]
        case .up: return [0x0B]
        case .down: return [0x0A]
        default: return []
        }
    }
}
