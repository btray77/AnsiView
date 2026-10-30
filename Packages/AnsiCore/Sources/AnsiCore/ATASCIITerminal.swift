/// An Atari 8-bit ATASCII terminal (40x24, as BBS Express and Phorem XE callers saw it with
/// Ice-T or AMODEM): the screen editor's control codes, inverse video in bit 7 and the Atari's
/// blue text screen.
public struct ATASCIITerminal: TerminalEngine {
    /// The GRAPHICS 0 screen: light text on the Atari's blue.
    public static let background = RGB(hex: 0x00_3C_8C)
    public static let foreground = RGB(hex: 0xA8_D8_FF)

    private var grid: RetroGrid
    private var escapeNext = false
    private var tabs: Set<Int>
    public private(set) var changeCount = 0
    public private(set) var bells = 0
    public var cursorVisible: Bool { true }
    /// The Atari's inverse video key: typed characters are sent with bit 7 set.
    public var inverseTyping = false

    public init(columns: Int = 40, rows: Int = 24) {
        grid = RetroGrid(columns: columns, rows: rows,
                         blank: RetroGrid.Cell(glyph: 0x20, text: 0x20, fg: Self.foreground, bg: Self.background))
        tabs = Set(stride(from: 8, to: 255, by: 8))
    }

    public var font: BitmapFont? { PlatformFonts.atascii }
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
        for b in bytes { consume(b) }
        changeCount &+= 1
    }

    private mutating func consume(_ b: UInt8) {
        if escapeNext {
            escapeNext = false
            put(b)
            return
        }
        switch b {
        case 0x1B: escapeNext = true
        case 0x9B: grid.column = 0; grid.lineFeed()
        case 0x1C: grid.row = grid.row == 0 ? rows - 1 : grid.row - 1
        case 0x1D: grid.row = grid.row == rows - 1 ? 0 : grid.row + 1
        case 0x1E: grid.column = grid.column == 0 ? columns - 1 : grid.column - 1
        case 0x1F: grid.column = grid.column == columns - 1 ? 0 : grid.column + 1
        case 0x7D: grid.clear()
        case 0x7E:
            guard grid.column > 0 else { return }
            grid.column -= 1
            grid.cells[grid.row][grid.column] = grid.blank
        case 0x7F: grid.column = tabs.filter { $0 > grid.column && $0 < columns }.min() ?? columns - 1
        case 0x9C: grid.deleteLine(at: grid.row); grid.column = 0
        case 0x9D: grid.insertLine(at: grid.row); grid.column = 0
        case 0x9E: tabs.remove(grid.column)
        case 0x9F: tabs.insert(grid.column)
        case 0xFD: bells += 1
        case 0xFE:
            grid.cells[grid.row].remove(at: grid.column)
            grid.cells[grid.row].append(grid.blank)
        case 0xFF:
            grid.cells[grid.row].removeLast()
            grid.cells[grid.row].insert(grid.blank, at: grid.column)
        default: put(b)
        }
    }

    private mutating func put(_ b: UInt8) {
        let code = b & 0x7F
        let inverse = b & 0x80 != 0
        let text: UInt8 = (0x20...0x7C).contains(code) && code != 0x60 ? code : 0x20
        grid.cells[grid.row][grid.column] = RetroGrid.Cell(glyph: UInt16(code), text: text,
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
        case .returnKey: return [0x9B]
        case .backspace: return [0x7E]
        case .forwardDelete: return [0xFE]
        case .insert: return [0xFF]
        case .tab: return [0x7F]
        case .escape: return [0x1B]
        case .up: return [0x1C]
        case .down: return [0x1D]
        case .left: return [0x1E]
        case .right: return [0x1F]
        case .end: return [0x7D]
        case .home, .pageUp, .pageDown, .function: return []
        }
    }

    public func text(_ text: String, encoding: TextEncoding) -> [UInt8] {
        var out: [UInt8] = []
        var previousCR = false
        for scalar in text.unicodeScalars {
            defer { previousCR = scalar == "\r" }
            if scalar == "\n" { if !previousCR { out.append(0x9B) }; continue }
            if scalar == "\r" { out.append(0x9B); continue }
            if scalar.value >= 0x20, scalar.value < 0x7F { out.append(UInt8(scalar.value) | (inverseTyping ? 0x80 : 0)) }
        }
        return out
    }
}
