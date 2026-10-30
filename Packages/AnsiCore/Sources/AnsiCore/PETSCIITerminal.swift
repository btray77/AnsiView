/// A Commodore PETSCII terminal: the C64's 40x25 screen (as CCGMS and Novaterm users saw Color 64,
/// Image BBS and C*Base boards), or the C128's 80 column VDC screen. Control codes, colours and
/// the two character sets follow the KERNAL screen editor (docs/BBS-COMPAT.md, Terminal).
public struct PETSCIITerminal: TerminalEngine {
    public enum Model: Equatable { case c64, c128 }

    /// C64 colours 0-15 (black, white, red, cyan, purple, green, blue, yellow, orange, brown,
    /// light red, dark grey, grey, light green, light blue, light grey), measured values published by Philip Timmermann.
    public static let c64Palette: [RGB] = [0x000000, 0xFFFFFF, 0x68372B, 0x70A4B2, 0x6F3D86, 0x588D43, 0x352879, 0xB8C76F,
                                           0x6F4F25, 0x433900, 0x9A6759, 0x444444, 0x6C6C6C, 0x9AD284, 0x6C5EB5, 0x959595].map(RGB.init(hex:))
    /// C128 VDC (RGBI) colours: black, dark grey, blue, light blue, green, light green, dark cyan, cyan,
    /// red, light red, purple, light purple, brown, yellow, light grey, white.
    public static let c128Palette: [RGB] = [0x000000, 0x555555, 0x0000AA, 0x5555FF, 0x00AA00, 0x55FF55, 0x00AAAA, 0x55FFFF,
                                            0xAA0000, 0xFF5555, 0xAA00AA, 0xFF55FF, 0xAA5500, 0xFFFF55, 0xAAAAAA, 0xFFFFFF].map(RGB.init(hex:))

    /// The colour control codes in C64 palette order.
    static let c64ColourCodes: [UInt8: Int] = [0x90: 0, 0x05: 1, 0x1C: 2, 0x9F: 3, 0x9C: 4, 0x1E: 5, 0x1F: 6, 0x9E: 7,
                                                0x81: 8, 0x95: 9, 0x96: 10, 0x97: 11, 0x98: 12, 0x99: 13, 0x9A: 14, 0x9B: 15]
    /// The same codes on the C128's 80 column screen, as indexes into `c128Palette`.
    static let c128ColourCodes: [UInt8: Int] = [0x90: 0, 0x05: 15, 0x1C: 8, 0x9F: 7, 0x9C: 11, 0x1E: 4, 0x1F: 2, 0x9E: 13,
                                                 0x81: 10, 0x95: 12, 0x96: 9, 0x97: 1, 0x98: 6, 0x99: 5, 0x9A: 3, 0x9B: 14]

    public let model: Model
    private var grid: RetroGrid
    private var colour: Int
    private var reverse = false
    private var flash = false
    /// C128 80 column: underline (0x02 on, 0x82 off) and an ESC sequence waiting for its letter.
    private var underline = false
    private var escapePending = false
    /// C64 terminal programs (CCGMS, Novaterm) start in the lower and upper case set, and boards
    /// such as Synchronet's PETSCII port rely on it without sending 0x0E.
    public private(set) var lowerCaseSet = true
    public private(set) var changeCount = 0
    public private(set) var bells = 0
    public var cursorVisible: Bool { true }

    public init(model: Model = .c64, columns: Int? = nil, rows: Int? = nil) {
        self.model = model
        let palette = model == .c64 ? Self.c64Palette : Self.c128Palette
        colour = model == .c64 ? 14 : 7
        grid = RetroGrid(columns: columns ?? (model == .c64 ? 40 : 80), rows: rows ?? 25,
                         blank: RetroGrid.Cell(glyph: 0x20, text: 0x20, fg: palette[colour], bg: palette[0]))
    }

    private var palette: [RGB] { model == .c64 ? Self.c64Palette : Self.c128Palette }

    public var font: BitmapFont? { PlatformFonts.petscii }
    public var columns: Int { grid.columns }
    public var rows: Int { grid.rows }
    public var cursor: (row: Int, column: Int) { (grid.row, grid.column) }
    public var scrollbackCount: Int { grid.scrollback.count }
    public mutating func takeReplies() -> [UInt8] { [] }
    public mutating func resize(columns: Int, rows: Int) { grid.resize(columns: columns, rows: rows); changeCount &+= 1 }
    public mutating func clearScrollback() { grid.clearScrollback(); changeCount &+= 1 }

    public func screen(scrollOffset: Int) -> AnsiScreen {
        let lower = lowerCaseSet
        return grid.screen(scrollOffset: scrollOffset) { c in
            var cell = RetroGrid.cell(c)
            cell.glyph = c.glyph + (lower ? 128 : 0) + (c.underline ? 256 : 0)
            cell.code = Self.text(screenCode: Int(c.glyph), lowerCase: lower)
            return cell
        }
    }

    /// PETSCII to C64 screen code (the KERNAL's conversion).
    static func screenCode(_ b: UInt8) -> Int {
        switch b {
        case 0x20...0x3F: return Int(b)
        case 0x40...0x5F: return Int(b) - 0x40
        case 0x60...0x7F: return Int(b) - 0x20
        case 0xA0...0xBF: return Int(b) - 0x40
        case 0xC0...0xDF: return Int(b) - 0x80
        case 0xE0...0xFE: return Int(b) - 0x80
        case 0xFF: return 0x5E
        default: return 0x20
        }
    }

    /// The character copied for a screen code.
    static func text(screenCode s: Int, lowerCase: Bool) -> UInt8 {
        switch s {
        case 0x00: return 0x40
        case 0x01...0x1A: return UInt8((lowerCase ? 0x60 : 0x40) + s)
        case 0x1B, 0x1D: return UInt8(0x40 + s)
        case 0x1C: return 0x9C
        case 0x20...0x3F: return UInt8(s)
        case 0x41...0x5A where lowerCase: return UInt8(s)
        default: return 0x20
        }
    }

    public mutating func feed(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        for b in bytes { consume(b) }
        changeCount &+= 1
    }

    private mutating func consume(_ b: UInt8) {
        if escapePending {
            escapePending = false
            c128Escape(b)
            return
        }
        let colours = model == .c64 ? Self.c64ColourCodes : Self.c128ColourCodes
        if let index = colours[b] { colour = index; return }
        switch b {
        case 0x07: bells += 1
        case 0x0D, 0x8D:
            reverse = false
            grid.column = 0
            grid.lineFeed()
        case 0x0E: lowerCaseSet = true
        case 0x8E: lowerCaseSet = false
        case 0x1B where model == .c128: escapePending = true
        case 0x02 where model == .c128: underline = true
        case 0x82 where model == .c128: underline = false
        case 0x0F where model == .c128: flash = true
        case 0x8F where model == .c128: flash = false
        case 0x11: grid.lineFeed()
        case 0x91: grid.row = max(0, grid.row - 1)
        case 0x1D:
            if grid.column == columns - 1 { grid.column = 0; grid.lineFeed() } else { grid.column += 1 }
        case 0x9D:
            if grid.column > 0 { grid.column -= 1 } else if grid.row > 0 { grid.row -= 1; grid.column = columns - 1 }
        case 0x12: reverse = true
        case 0x92: reverse = false
        case 0x13: grid.row = 0; grid.column = 0
        case 0x93: grid.clear()
        case 0x14:
            // DEL: the character left of the cursor goes and the rest of the line closes up.
            guard grid.column > 0 else { return }
            grid.column -= 1
            grid.cells[grid.row].remove(at: grid.column)
            grid.cells[grid.row].append(blankCell)
        case 0x94:
            grid.cells[grid.row].removeLast()
            grid.cells[grid.row].insert(blankCell, at: grid.column)
        case 0x20...0x7F, 0xA0...0xFF: put(Self.screenCode(b))
        default: break
        }
    }

    /// The C128 screen editor's ESC sequences (80 column terminal programs pass them on).
    private mutating func c128Escape(_ b: UInt8) {
        let blankRow = Array(repeating: blankCell, count: columns)
        switch b {
        case 0x40: // @: clear to the end of the screen
            for c in grid.column..<columns { grid.cells[grid.row][c] = blankCell }
            for r in (grid.row + 1)..<max(grid.row + 1, rows) { grid.cells[r] = blankRow }
        case 0x4A: grid.column = 0                                   // J: start of line
        case 0x4B:                                                   // K: end of the line's text
            let last = grid.cells[grid.row].lastIndex { $0.glyph != 0x20 } ?? -1
            grid.column = min(columns - 1, last + 1)
        case 0x51: for c in grid.column..<columns { grid.cells[grid.row][c] = blankCell }   // Q: erase to end of line
        case 0x50: for c in 0...grid.column { grid.cells[grid.row][c] = blankCell }        // P: erase to start of line
        case 0x44:                                                   // D: delete the line
            grid.cells.remove(at: grid.row)
            grid.cells.append(blankRow)
        case 0x49:                                                   // I: insert a line
            grid.cells.insert(blankRow, at: grid.row)
            grid.cells.removeLast()
        case 0x56:                                                   // V: scroll up
            grid.cells.removeFirst()
            grid.cells.append(blankRow)
        case 0x57:                                                   // W: scroll down
            grid.cells.insert(blankRow, at: 0)
            grid.cells.removeLast()
        default: break                                               // O and the window codes: nothing to show
        }
    }

    private var blankCell: RetroGrid.Cell {
        RetroGrid.Cell(glyph: 0x20, text: 0x20, fg: palette[colour], bg: palette[0])
    }

    private mutating func put(_ code: Int) {
        var fg = palette[colour], bg = palette[0]
        if reverse { swap(&fg, &bg) }
        grid.cells[grid.row][grid.column] = RetroGrid.Cell(glyph: UInt16(code), text: 0x20, fg: fg, bg: bg, blink: flash,
                                                           underline: underline)
        if grid.column == columns - 1 {
            grid.column = 0
            grid.lineFeed()
        } else {
            grid.column += 1
        }
    }

    // MARK: Keyboard

    public func bytes(for key: TerminalKey, backspaceSendsDelete: Bool) -> [UInt8] {
        switch key {
        case .returnKey: return [0x0D]
        case .backspace, .forwardDelete: return [0x14]
        case .insert: return [0x94]
        case .tab: return []
        case .escape: return [0x03]
        case .up: return [0x91]
        case .down: return [0x11]
        case .left: return [0x9D]
        case .right: return [0x1D]
        case .home: return [0x13]
        case .end: return [0x93]
        case .pageUp, .pageDown: return []
        case .function(let n):
            let codes: [UInt8] = [0x85, 0x89, 0x86, 0x8A, 0x87, 0x8B, 0x88, 0x8C]
            return (1...8).contains(n) ? [codes[n - 1]] : []
        }
    }

    public func text(_ text: String, encoding: TextEncoding) -> [UInt8] {
        var out: [UInt8] = []
        var previousCR = false
        for scalar in text.unicodeScalars {
            defer { previousCR = scalar == "\r" }
            switch scalar {
            case "\n": if !previousCR { out.append(0x0D) }
            case "\r": out.append(0x0D)
            case "a"..."z": out.append(UInt8(scalar.value) - 0x20)
            case "A"..."Z": out.append(UInt8(scalar.value) + (lowerCaseSet ? 0x80 : 0))
            case " "..."@", "[", "]": out.append(UInt8(scalar.value))
            case "£": out.append(0x5C)
            case "↑": out.append(0x5E)
            case "←": out.append(0x5F)
            default: break
            }
        }
        return out
    }

    /// Control with 1-8 gives the colour keys, 9 and 0 reverse on and off, letters their control codes.
    public func control(_ character: Character) -> [UInt8]? {
        let colourKeys: [Character: UInt8] = ["1": 0x90, "2": 0x05, "3": 0x1C, "4": 0x9F, "5": 0x9C, "6": 0x1E, "7": 0x1F,
                                              "8": 0x9E, "9": 0x12, "0": 0x92]
        if let code = colourKeys[character] { return [code] }
        return TerminalInput.control(character)
    }
}
