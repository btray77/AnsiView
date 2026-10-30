/// A teletext screen: Viewdata/Prestel (Telstar, NXtel and other videotex services, 40x24) or the
/// BBC Micro's Mode 7 (40x25). Screen memory holds characters and serial attribute codes; each row
/// is decoded left to right the way the SAA5050 did: set-at and set-after attributes, mosaics,
/// hold, double height, conceal and flash.
public struct TeletextTerminal: TerminalEngine {
    public enum Flavour: Equatable { case viewdata, mode7 }

    /// Black, red, green, yellow, blue, magenta, cyan, white.
    public static let colours: [RGB] = [0x000000, 0xFF0000, 0x00FF00, 0xFFFF00, 0x0000FF, 0xFF00FF, 0x00FFFF, 0xFFFFFF]
        .map(RGB.init(hex:))

    public let flavour: Flavour
    public private(set) var columns: Int
    public private(set) var rows: Int
    /// Character codes 0x20-0x7F, or attribute codes 0x00-0x1F (ESC x or 0x80-0x9F less 0x40/0x80).
    private var memory: [[UInt8]]
    private var scrollback: [[UInt8]] = []
    private var row = 0
    private var column = 0
    private var escape = false
    /// BBC VDU parameter bytes still to swallow, and the VDU 31 coordinates gathered so far.
    private var vduPending = 0
    private var vduCommand: UInt8 = 0
    private var vduBytes: [UInt8] = []
    /// Shows concealed text (the Reveal key).
    public var reveal = false
    public private(set) var cursorVisible = true
    public private(set) var changeCount = 0
    public private(set) var bells = 0

    public init(flavour: Flavour, columns: Int = 40, rows: Int? = nil) {
        self.flavour = flavour
        self.columns = max(1, min(255, columns))
        self.rows = max(1, min(255, rows ?? (flavour == .viewdata ? 24 : 25)))
        memory = Array(repeating: Array(repeating: 0x20, count: self.columns), count: self.rows)
    }

    public var font: BitmapFont? { PlatformFonts.teletext }
    public var cursor: (row: Int, column: Int) { (row, column) }
    public var scrollbackCount: Int { scrollback.count }
    public mutating func takeReplies() -> [UInt8] { [] }
    public mutating func clearScrollback() { scrollback.removeAll(); changeCount &+= 1 }

    public mutating func resize(columns c: Int, rows r: Int) {
        let c = max(1, min(255, c)), r = max(1, min(255, r))
        memory = (0..<r).map { i in
            let line = i < memory.count ? memory[i] : []
            return Array(line.prefix(c)) + Array(repeating: 0x20, count: max(0, c - line.count))
        }
        columns = c
        rows = r
        row = min(row, r - 1)
        column = min(column, c - 1)
        changeCount &+= 1
    }

    // MARK: Input bytes

    public mutating func feed(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        for b in bytes { flavour == .viewdata ? viewdataByte(b) : mode7Byte(b) }
        changeCount &+= 1
    }

    private mutating func viewdataByte(_ b: UInt8) {
        if escape {
            escape = false
            if (0x40...0x5F).contains(b) { put(b - 0x40); return }
        }
        switch b {
        case 0x1B: escape = true
        case 0x80...0x9F: put(b - 0x80)
        case 0x08:
            if column > 0 { column -= 1 } else { column = columns - 1; row = row == 0 ? rows - 1 : row - 1 }
        case 0x09: advance()
        case 0x0A: row = row == rows - 1 ? 0 : row + 1
        case 0x0B: row = row == 0 ? rows - 1 : row - 1
        case 0x0C: clear()
        case 0x0D: column = 0
        case 0x1E: row = 0; column = 0
        case 0x11: cursorVisible = true
        case 0x14: cursorVisible = false
        case 0x07: bells += 1
        case 0x20...0x7F: put(b)
        case 0xA0...0xFF: put(b & 0x7F)
        default: break
        }
    }

    private mutating func mode7Byte(_ b: UInt8) {
        if vduPending > 0 {
            vduBytes.append(b)
            vduPending -= 1
            if vduPending == 0, vduCommand == 31, vduBytes.count == 2 {
                column = min(columns - 1, Int(vduBytes[0]))
                row = min(rows - 1, Int(vduBytes[1]))
            }
            return
        }
        // Parameter counts of the BBC's VDU codes, so their bytes never print.
        let parameters: [UInt8: Int] = [1: 1, 17: 1, 18: 2, 19: 5, 22: 1, 23: 9, 24: 8, 25: 5, 28: 4, 29: 4, 31: 2]
        if let count = parameters[b] {
            vduCommand = b
            vduBytes = []
            vduPending = count
            return
        }
        switch b {
        case 0x07: bells += 1
        case 0x08:
            if column > 0 { column -= 1 } else if row > 0 { row -= 1; column = columns - 1 }
        case 0x09: advance(scrolls: true)
        case 0x0A: lineFeed()
        case 0x0B: if row > 0 { row -= 1 } else { memory.insert(Array(repeating: 0x20, count: columns), at: 0); memory.removeLast() }
        case 0x0C: clear()
        case 0x0D: column = 0
        case 0x1E: row = 0; column = 0
        case 0x7F:
            if column > 0 { column -= 1; memory[row][column] = 0x20 }
        case 0x80...0x9F: put(b - 0x80, scrolls: true)
        // The BBC's OS swaps these so that # shows as #, _ as a long dash and ` as a pound sign.
        case 0x23: put(0x5F, scrolls: true)
        case 0x5F: put(0x60, scrolls: true)
        case 0x60: put(0x23, scrolls: true)
        case 0x20...0x7E: put(b, scrolls: true)
        case 0xA0...0xFF: put(b & 0x7F, scrolls: true)
        default: break
        }
    }

    private mutating func clear() {
        memory = Array(repeating: Array(repeating: 0x20, count: columns), count: rows)
        row = 0
        column = 0
    }

    private mutating func lineFeed() {
        if row == rows - 1 {
            scrollback.append(memory.removeFirst())
            if scrollback.count > TerminalEmulator.maxScrollback { scrollback.removeFirst() }
            memory.append(Array(repeating: 0x20, count: columns))
        } else {
            row += 1
        }
    }

    private mutating func advance(scrolls: Bool = false) {
        if column < columns - 1 { column += 1; return }
        column = 0
        if scrolls { lineFeed() } else { row = row == rows - 1 ? 0 : row + 1 }
    }

    private mutating func put(_ code: UInt8, scrolls: Bool = false) {
        memory[row][column] = code
        advance(scrolls: scrolls)
    }

    // MARK: Display

    /// One decoded cell: its glyph, colours, flags.
    private struct Shown {
        var glyph: Int
        var text: UInt8
        var fg: RGB
        var bg: RGB
        var flash: Bool
        var double: Bool
    }

    private func decode(_ line: [UInt8]) -> [Shown] {
        var fg = 7, bg = 0, mosaic = false, separated = false, hold = false, flash = false
        var conceal = false, double = false
        var held = TeletextGlyphs.mosaic(0x20, separated: false)
        var out: [Shown] = []
        out.reserveCapacity(line.count)
        for code in line {
            if code < 0x20 {
                // Set-at attributes act on this cell.
                switch code {
                case 0x09: flash = false
                case 0x0C: double = false; hold = false
                case 0x18: conceal = true
                case 0x19: separated = false
                case 0x1A: separated = true
                case 0x1C: bg = 0
                case 0x1D: bg = fg
                case 0x1E: hold = true
                default: break
                }
                let glyph = hold && mosaic ? held : TeletextGlyphs.alpha(0x20)
                out.append(Shown(glyph: glyph, text: 0x20, fg: Self.colours[fg], bg: Self.colours[bg], flash: flash, double: double))
                // Set-after attributes act from the next cell.
                switch code {
                case 0x01...0x07: fg = Int(code); mosaic = false; conceal = false; hold = false
                case 0x08: flash = true
                case 0x0D: double = true; hold = false
                case 0x11...0x17: fg = Int(code - 0x10); mosaic = true; conceal = false
                case 0x1F: hold = false
                default: break
                }
                continue
            }
            var glyph: Int, text: UInt8
            if mosaic, code & 0x20 != 0 {
                glyph = TeletextGlyphs.mosaic(code, separated: separated)
                held = glyph
                text = 0x20
            } else {
                glyph = TeletextGlyphs.alpha(code)
                text = Self.text(code)
            }
            if conceal, !reveal { glyph = TeletextGlyphs.alpha(0x20); text = 0x20 }
            out.append(Shown(glyph: glyph, text: text, fg: Self.colours[fg], bg: Self.colours[bg], flash: flash, double: double))
        }
        return out
    }

    /// The character copied for a UK teletext code.
    static func text(_ code: UInt8) -> UInt8 {
        switch code {
        case 0x23: return 0x9C
        case 0x5B: return 0x1B
        case 0x5C: return 0xAB
        case 0x5D: return 0x1A
        case 0x5E: return 0x18
        case 0x5F: return 0x23
        case 0x60: return 0xC4
        case 0x7B: return 0xAC
        case 0x7C: return 0xBA
        case 0x7D: return 0x20
        case 0x7E: return 0xF6
        case 0x7F: return 0xDB
        default: return code
        }
    }

    public func screen(scrollOffset: Int) -> AnsiScreen {
        let offset = min(max(0, scrollOffset), scrollback.count)
        let start = scrollback.count - offset
        let lines = (start..<(start + rows)).map { $0 < scrollback.count ? scrollback[$0] : memory[$0 - scrollback.count] }
        var out: [[AnsiCell]] = []
        var above: [Shown]?
        for line in lines {
            let shown: [Shown]
            if let top = above {
                // The row under a double height row repeats its lower halves; its own text is not shown.
                shown = top.map { s in
                    s.double ? Shown(glyph: TeletextGlyphs.doubleBottom(s.glyph), text: 0x20, fg: s.fg, bg: s.bg,
                                     flash: s.flash, double: false)
                        : Shown(glyph: TeletextGlyphs.alpha(0x20), text: 0x20, fg: s.fg, bg: s.bg, flash: false, double: false)
                }
                above = nil
            } else {
                var decoded = decode(line)
                if decoded.contains(where: { $0.double }) {
                    above = decoded
                    decoded = decoded.map { s in
                        var s = s
                        if s.double { s.glyph = TeletextGlyphs.doubleTop(s.glyph) }
                        return s
                    }
                }
                shown = decoded
            }
            out.append(shown.map { s in
                var cell = AnsiCell(code: s.text, fg: s.fg, bg: s.bg, blink: s.flash)
                cell.glyph = UInt16(s.glyph)
                return cell
            })
        }
        return AnsiScreen(columns: columns, rows: out)
    }

    // MARK: Keyboard

    public func bytes(for key: TerminalKey, backspaceSendsDelete: Bool) -> [UInt8] {
        switch flavour {
        case .viewdata:
            switch key {
            case .returnKey: return [0x5F]
            case .backspace, .forwardDelete: return [0x7F]
            case .left: return [0x08]
            case .right: return [0x09]
            case .down: return [0x0A]
            case .up: return [0x0B]
            case .home: return [0x1E]
            case .escape: return [0x1B]
            default: return []
            }
        case .mode7:
            switch key {
            case .returnKey: return [0x0D]
            case .backspace, .forwardDelete: return [0x7F]
            case .left: return [0x88]
            case .right: return [0x89]
            case .down: return [0x8A]
            case .up: return [0x8B]
            case .escape: return [0x1B]
            case .tab: return [0x09]
            case .function(let n) where (1...10).contains(n): return [0x80 + UInt8(n % 10)]
            default: return []
            }
        }
    }

    public func text(_ text: String, encoding: TextEncoding) -> [UInt8] {
        var out: [UInt8] = []
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\n", "\r": out.append(flavour == .viewdata ? 0x5F : 0x0D)
            // Prestel's # key is code 0x5F.
            case "#" where flavour == .viewdata: out.append(0x5F)
            case "£": out.append(flavour == .viewdata ? 0x23 : 0x60)
            default:
                if scalar.value >= 0x20, scalar.value < 0x7F { out.append(UInt8(scalar.value)) }
            }
        }
        return out
    }
}
