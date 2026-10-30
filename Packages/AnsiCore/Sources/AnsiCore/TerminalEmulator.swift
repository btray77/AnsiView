/// How a BBS's text bytes are read: DOS code page 437 (the BBS norm) or UTF-8.
public enum TextEncoding: String, Codable, CaseIterable {
    case cp437, utf8

    public var label: String { self == .cp437 ? "CP437" : "UTF-8" }
}

/// Which terminal the emulator behaves as. ANSI-BBS is the plan 7 behaviour (pinned by
/// `TerminalRegressionTests`); the others add what those terminals did on top of it.
public enum TerminalProfile: Equatable {
    /// PC ANSI.SYS with the SyncTERM/CTerm extensions. Character set designations are ignored
    /// (BBS text is always the PC set) and SO/SI are glyphs.
    case ansiBBS
    /// DEC VT100/VT102: G0/G1 character sets with DEC line drawing, application cursor keys, insert mode.
    case vt100
    /// DEC VT220: as VT100, with VT220 device attributes.
    case vt220
    /// The Amiga console: ISO 8859-1 text, 0x9B as CSI, LF also returns the carriage.
    case amiga

    var isDEC: Bool { self == .vt100 || self == .vt220 }
}

/// A G0 or G1 character set of a DEC terminal.
enum DECCharset: Equatable { case ascii, uk, graphics }

/// An interactive ANSI terminal screen for a live BBS session: a fixed grid with a scroll region,
/// a scrollback buffer and replies to device status requests. Unlike `AnsiTerminal` (which plays
/// a file onto a canvas that grows), text that reaches the bottom scrolls, and the parser keeps
/// its state between `feed` calls, so sequences split across network packets work.
public struct TerminalEmulator {
    public static let maxScrollback = 2000
    public static let sizeRange = 1...255
    /// Parameters kept per control sequence; more are ignored (a hostile server).
    private static let maxParameters = 32

    public private(set) var columns: Int
    public private(set) var rows: Int
    public var encoding: TextEncoding
    /// The visible screen, `rows` rows of `columns` cells.
    public private(set) var grid: [[AnsiCell]]
    /// Lines that scrolled off the top, oldest first.
    public private(set) var scrollback: [[AnsiCell]] = []
    public private(set) var cursorVisible = true
    /// Increases whenever anything visible may have changed.
    public private(set) var changeCount = 0
    /// BEL characters received.
    public private(set) var bells = 0

    /// The cursor, zero based.
    public var cursor: (row: Int, column: Int) { (row, column) }

    private var row = 0
    private var column = 0
    private var pendingWrap = false
    private var autowrap = true
    private var attributes = TextAttributes()
    /// iCE colours: the blink attribute gives a bright background instead of blinking text.
    public var iceColors = false
    public var profile = TerminalProfile.ansiBBS
    /// DECCKM: cursor keys send ESC O x instead of ESC [ x.
    public private(set) var applicationCursorKeys = false
    private var charsets: [DECCharset] = [.ascii, .ascii]
    private var shiftedOut = false
    private var designating = 0
    private var originMode = false
    private var insertMode = false
    private var intermediate: UInt8 = 0
    private var top = 0
    private var bottom: Int
    private var saved: (row: Int, column: Int, attributes: TextAttributes) = (0, 0, TextAttributes())
    private var replies: [UInt8] = []

    private enum ParseState { case ground, escape, charset, csi, controlString, controlStringEscape }
    private var state = ParseState.ground
    private var parameters: [Int?] = []
    private var currentParameter: Int?
    private var privateMarker: UInt8 = 0
    private var hasIntermediate = false
    private var utf8Pending: [UInt8] = []
    private var utf8Needed = 0

    public init(columns: Int = 80, rows: Int = 25, encoding: TextEncoding = .cp437) {
        let c = Self.clampSize(columns), r = Self.clampSize(rows)
        self.columns = c
        self.rows = r
        self.encoding = encoding
        self.bottom = r - 1
        self.grid = Array(repeating: Array(repeating: AnsiCell(), count: c), count: r)
    }

    private static func clampSize(_ value: Int) -> Int {
        min(sizeRange.upperBound, max(sizeRange.lowerBound, value))
    }

    // MARK: Public operations

    /// Interprets bytes received from the BBS.
    public mutating func feed(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        for byte in bytes { consume(byte) }
        changeCount &+= 1
    }

    /// Bytes the terminal must send back (status reports), cleared by the call.
    public mutating func takeReplies() -> [UInt8] {
        defer { replies.removeAll() }
        return replies
    }

    /// Changes the screen size, keeping the top left of the screen and clamping the cursor.
    public mutating func resize(columns newColumns: Int, rows newRows: Int) {
        let c = Self.clampSize(newColumns), r = Self.clampSize(newRows)
        grid = (0..<r).map { index in
            index < grid.count ? Self.fit(grid[index], to: c) : Array(repeating: AnsiCell(), count: c)
        }
        columns = c
        rows = r
        top = 0
        bottom = r - 1
        row = min(row, r - 1)
        column = min(column, c - 1)
        saved.row = min(saved.row, r - 1)
        saved.column = min(saved.column, c - 1)
        pendingWrap = false
        changeCount &+= 1
    }

    public mutating func clearScrollback() {
        scrollback.removeAll()
        changeCount &+= 1
    }

    /// Exactly `rows` rows: the live screen, or `scrollOffset` lines further back into the scrollback.
    public func screen(scrollOffset: Int = 0) -> AnsiScreen {
        let offset = min(max(0, scrollOffset), scrollback.count)
        var lines: [[AnsiCell]] = []
        lines.reserveCapacity(rows)
        let start = scrollback.count - offset
        for index in start..<(start + rows) {
            if index < scrollback.count {
                lines.append(Self.fit(scrollback[index], to: columns))
            } else {
                lines.append(grid[index - scrollback.count])
            }
        }
        return AnsiScreen(columns: columns, rows: lines)
    }

    private static func fit(_ line: [AnsiCell], to width: Int) -> [AnsiCell] {
        if line.count == width { return line }
        if line.count > width { return Array(line.prefix(width)) }
        return line + Array(repeating: AnsiCell(), count: width - line.count)
    }

    // MARK: Parser

    private mutating func consume(_ byte: UInt8) {
        switch state {
        case .ground:
            ground(byte)
        case .escape:
            escape(byte)
        case .charset:
            // ESC ( x and ESC ) x choose character sets; ANSI-BBS text is always the PC set.
            state = .ground
            if profile.isDEC {
                charsets[designating] = byte == UInt8(ascii: "0") ? .graphics : (byte == UInt8(ascii: "A") ? .uk : .ascii)
            }
        case .csi:
            csiByte(byte)
        case .controlString:
            // APC, OSC, DCS, PM and SOS strings (window titles, SyncTERM probes) are skipped,
            // up to ST (ESC \) or BEL. Nothing is kept, so a string that never ends costs nothing.
            switch byte {
            case 0x1B: state = .controlStringEscape
            case 0x07, 0x18, 0x1A: state = .ground
            default: break
            }
        case .controlStringEscape:
            if byte == UInt8(ascii: "\\") {
                state = .ground
            } else {
                escape(byte)
            }
        }
    }

    private mutating func ground(_ byte: UInt8) {
        if encoding == .utf8, utf8Needed > 0 {
            if byte & 0xC0 == 0x80 {
                utf8Pending.append(byte)
                utf8Needed -= 1
                if utf8Needed == 0 { finishUTF8() }
                return
            }
            flushUTF8()
        }
        switch byte {
        case 0x1B: state = .escape
        case 0x0D: column = 0; pendingWrap = false
        case 0x0A, 0x0B:
            pendingWrap = false
            if profile == .amiga { column = 0 }
            lineFeed()
        case 0x0C: eraseDisplay(2)
        case 0x08:
            column = max(0, column - 1)
            pendingWrap = false
        case 0x09:
            column = min(columns - 1, (column / 8 + 1) * 8)
            pendingWrap = false
        case 0x07: bells += 1
        case 0x00, 0x18: break
        case 0x0E where profile.isDEC: shiftedOut = true
        case 0x0F where profile.isDEC: shiftedOut = false
        case 0x9B where profile == .amiga && encoding != .utf8: startCSI()
        default:
            if encoding == .utf8, byte >= 0x80 {
                switch byte {
                case 0xC2...0xDF: utf8Needed = 1
                case 0xE0...0xEF: utf8Needed = 2
                case 0xF0...0xF4: utf8Needed = 3
                default:
                    put(byte)
                    return
                }
                utf8Pending = [byte]
            } else {
                put(byte)
            }
        }
    }

    /// A complete UTF-8 sequence: its CP437 glyph, or the scalar itself.
    private mutating func finishUTF8() {
        let length = utf8Pending.count
        var value = UInt32(utf8Pending[0]) & (0xFF >> (length + 1))
        for continuation in utf8Pending.dropFirst() { value = value << 6 | UInt32(continuation & 0x3F) }
        let minimum: UInt32 = length == 2 ? 0x80 : (length == 3 ? 0x800 : 0x10000)
        guard value >= minimum, let scalar = Unicode.Scalar(value) else { flushUTF8(); return }
        utf8Pending.removeAll()
        if let code = CP437.code(for: scalar) { put(code) } else { put(0x3F, scalar: scalar) }
    }

    /// An incomplete or invalid UTF-8 sequence: its bytes shown as CP437.
    private mutating func flushUTF8() {
        let pending = utf8Pending
        utf8Pending.removeAll()
        utf8Needed = 0
        for byte in pending { put(byte) }
    }

    private mutating func escape(_ byte: UInt8) {
        state = .ground
        switch byte {
        case UInt8(ascii: "["):
            startCSI()
        case UInt8(ascii: "("), UInt8(ascii: ")"):
            designating = byte == UInt8(ascii: "(") ? 0 : 1
            state = .charset
        case UInt8(ascii: "_"), UInt8(ascii: "]"), UInt8(ascii: "P"), UInt8(ascii: "^"), UInt8(ascii: "X"):
            state = .controlString
        case UInt8(ascii: "7"): saved = (row, column, attributes)
        case UInt8(ascii: "8"):
            row = saved.row; column = saved.column; attributes = saved.attributes
            pendingWrap = false
        case UInt8(ascii: "D"): pendingWrap = false; lineFeed()
        case UInt8(ascii: "E"): pendingWrap = false; column = 0; lineFeed()
        case UInt8(ascii: "M"): pendingWrap = false; reverseIndex()
        case UInt8(ascii: "c"): reset()
        case 0x1B: state = .escape
        default: break
        }
    }

    private mutating func startCSI() {
        parameters.removeAll(keepingCapacity: true)
        currentParameter = nil
        privateMarker = 0
        hasIntermediate = false
        intermediate = 0
        state = .csi
    }

    private mutating func csiByte(_ byte: UInt8) {
        switch byte {
        case 0x30...0x39:
            currentParameter = min(9999, (currentParameter ?? 0) * 10 + Int(byte - 0x30))
        case 0x3B:
            if parameters.count < Self.maxParameters { parameters.append(currentParameter) }
            currentParameter = nil
        case 0x3C...0x3F:
            if privateMarker == 0 { privateMarker = byte }
        case 0x20...0x2F:
            if !hasIntermediate { intermediate = byte }
            hasIntermediate = true
        case 0x40...0x7E:
            if currentParameter != nil || !parameters.isEmpty, parameters.count < Self.maxParameters {
                parameters.append(currentParameter)
            }
            state = .ground
            if !hasIntermediate { dispatch(byte) } else { dispatchIntermediate(byte) }
        case 0x1B:
            state = .escape
        case 0x18, 0x1A:
            state = .ground
        default:
            // Other control characters inside a sequence are ignored.
            break
        }
    }

    private func parameter(_ index: Int, _ fallback: Int) -> Int {
        guard index < parameters.count, let value = parameters[index] else { return fallback }
        return value
    }

    /// A count parameter: missing or 0 means 1.
    private func count(_ index: Int = 0) -> Int { max(1, parameter(index, 1)) }

    private mutating func dispatch(_ final: UInt8) {
        if privateMarker == UInt8(ascii: "?") {
            let on = final == UInt8(ascii: "h")
            guard on || final == UInt8(ascii: "l") else { return }
            for value in parameters.compactMap({ $0 }) {
                if value == 25 { cursorVisible = on }
                if value == 7 { autowrap = on; if !on { pendingWrap = false } }
                if value == 1 { applicationCursorKeys = on }
                if value == 6 {
                    originMode = on
                    row = on ? top : 0
                    column = 0
                    pendingWrap = false
                }
            }
            return
        }
        if privateMarker == UInt8(ascii: ">"), final == UInt8(ascii: "c"), profile == .vt220 {
            replies += Array("\u{1B}[>1;10;0c".utf8)
            return
        }
        guard privateMarker == 0 else { return }
        switch final {
        case UInt8(ascii: "m"), UInt8(ascii: "n"), UInt8(ascii: "c"), UInt8(ascii: "t"), UInt8(ascii: "s"): break
        default: pendingWrap = false
        }
        switch final {
        case UInt8(ascii: "A"):
            row = row >= top ? max(top, row - count()) : max(0, row - count())
        case UInt8(ascii: "B"):
            row = row <= bottom ? min(bottom, row + count()) : min(rows - 1, row + count())
        case UInt8(ascii: "C"): column = min(columns - 1, column + count())
        case UInt8(ascii: "D"): column = max(0, column - count())
        case UInt8(ascii: "E"):
            row = row <= bottom ? min(bottom, row + count()) : min(rows - 1, row + count())
            column = 0
        case UInt8(ascii: "F"):
            row = row >= top ? max(top, row - count()) : max(0, row - count())
            column = 0
        case UInt8(ascii: "G"), UInt8(ascii: "`"): column = min(columns - 1, count() - 1)
        case UInt8(ascii: "H"), UInt8(ascii: "f"):
            row = originMode ? min(bottom, top + count(0) - 1) : min(rows - 1, count(0) - 1)
            column = min(columns - 1, count(1) - 1)
        case UInt8(ascii: "d"): row = originMode ? min(bottom, top + count() - 1) : min(rows - 1, count() - 1)
        case UInt8(ascii: "h"), UInt8(ascii: "l"):
            if profile.isDEC, parameters.contains(4) { insertMode = final == UInt8(ascii: "h") }
        case UInt8(ascii: "J"): eraseDisplay(parameter(0, 0))
        case UInt8(ascii: "K"): eraseLine(parameter(0, 0))
        case UInt8(ascii: "L"):
            guard (top...bottom).contains(row) else { return }
            for _ in 0..<min(count(), bottom - row + 1) {
                grid.remove(at: bottom)
                grid.insert(blankRow, at: row)
            }
            column = 0
        case UInt8(ascii: "M"):
            guard (top...bottom).contains(row) else { return }
            for _ in 0..<min(count(), bottom - row + 1) {
                grid.remove(at: row)
                grid.insert(blankRow, at: bottom)
            }
            column = 0
        case UInt8(ascii: "@"):
            let n = min(count(), columns - column)
            grid[row].removeLast(n)
            grid[row].insert(contentsOf: Array(repeating: blankCell, count: n), at: column)
        case UInt8(ascii: "P"):
            let n = min(count(), columns - column)
            grid[row].removeSubrange(column..<(column + n))
            grid[row].append(contentsOf: Array(repeating: blankCell, count: n))
        case UInt8(ascii: "X"):
            let blank = blankCell
            for c in column..<min(columns, column + count()) { grid[row][c] = blank }
        case UInt8(ascii: "S"): scrollUp(count())
        case UInt8(ascii: "T"): scrollDown(count())
        case UInt8(ascii: "r"):
            let newTop = count(0) - 1
            let newBottom = min(rows, parameter(1, rows) == 0 ? rows : parameter(1, rows)) - 1
            guard newTop < newBottom else { return }
            top = newTop
            bottom = newBottom
            row = originMode ? top : 0
            column = 0
        case UInt8(ascii: "s"): saved.row = row; saved.column = column
        case UInt8(ascii: "u"): row = saved.row; column = saved.column; pendingWrap = false
        case UInt8(ascii: "m"):
            attributes.apply(parameters.isEmpty ? [0] : parameters.map { $0 ?? 0 })
        case UInt8(ascii: "t"):
            attributes.applyPabloDraw(parameters.map { $0 ?? 0 })
        case UInt8(ascii: "n"):
            switch parameter(0, 0) {
            case 5: replies += Array("\u{1B}[0n".utf8)
            case 6: replies += Array("\u{1B}[\(row + 1 - (originMode ? top : 0));\(column + 1)R".utf8)
            default: break
            }
        case UInt8(ascii: "c"):
            guard parameter(0, 0) == 0 else { break }
            switch profile {
            case .vt100: replies += Array("\u{1B}[?1;2c".utf8)
            case .vt220: replies += Array("\u{1B}[?62;1;6c".utf8)
            case .ansiBBS, .amiga: replies += Array("\u{1B}[?1;0c".utf8)
            }
        default:
            break
        }
    }

    /// Sequences with an intermediate byte (CSI ... SP x and the like).
    private mutating func dispatchIntermediate(_ final: UInt8) {
        guard privateMarker == 0 else { return }
        switch (intermediate, final) {
        case (0x20, UInt8(ascii: "q")) where profile == .amiga:
            // Window status request: the Amiga console answers with its bounds.
            replies += Array("\u{1B}[1;1;\(rows);\(columns) r".utf8)
        case (0x20, UInt8(ascii: "p")) where profile == .amiga:
            cursorVisible = parameter(0, 1) != 0
        default:
            break
        }
    }

    /// Cursor keys follow DECCKM; everything else is the ANSI-BBS keyboard.
    public func bytes(for key: TerminalKey, backspaceSendsDelete: Bool) -> [UInt8] {
        if applicationCursorKeys {
            switch key {
            case .up: return [0x1B, 0x4F, 0x41]
            case .down: return [0x1B, 0x4F, 0x42]
            case .right: return [0x1B, 0x4F, 0x43]
            case .left: return [0x1B, 0x4F, 0x44]
            default: break
            }
        }
        return TerminalInput.bytes(for: key, backspaceSendsDelete: backspaceSendsDelete)
    }

    // MARK: Avatar helpers

    /// Avatar insert mode (AVT/0+ ^V^I, ended by any other Avatar command).
    mutating func setInsertMode(_ on: Bool) { insertMode = on }

    /// Scrolls a rectangle (1 based, inclusive) up or down by `lines`, filling with blanks.
    mutating func scrollArea(up: Bool, lines: Int, top t: Int, left l: Int, bottom b: Int, right r: Int) {
        let top = max(0, t - 1), bottom = min(rows - 1, b - 1), left = max(0, l - 1), right = min(columns - 1, r - 1)
        guard top <= bottom, left <= right else { return }
        let height = bottom - top + 1
        let n = lines <= 0 || lines > height ? height : lines
        let blank = blankCell
        if up {
            for y in top...bottom {
                for x in left...right { grid[y][x] = y + n <= bottom ? grid[y + n][x] : blank }
            }
        } else {
            for y in stride(from: bottom, through: top, by: -1) {
                for x in left...right { grid[y][x] = y - n >= top ? grid[y - n][x] : blank }
            }
        }
        changeCount &+= 1
    }

    // MARK: Screen operations

    private var blankCell: AnsiCell {
        AnsiCell(code: 0x20, fg: Palette.vga[7], bg: attributes.colors(iceColors: iceColors).bg)
    }

    private var blankRow: [AnsiCell] { Array(repeating: blankCell, count: columns) }

    private mutating func put(_ code: UInt8, scalar: Unicode.Scalar? = nil) {
        if pendingWrap {
            pendingWrap = false
            column = 0
            lineFeed()
        }
        var code = code, scalar = scalar
        if profile.isDEC, scalar == nil {
            switch charsets[shiftedOut ? 1 : 0] {
            case .ascii: break
            case .uk: if code == 0x23 { code = 0x9C }
            case .graphics:
                if let mapped = DECGraphics.map(code) { (code, scalar) = mapped }
            }
        }
        if insertMode, column < columns - 1 {
            grid[row].removeLast()
            grid[row].insert(blankCell, at: column)
        }
        let colors = attributes.colors(iceColors: iceColors)
        grid[row][column] = AnsiCell(code: code, fg: colors.fg, bg: colors.bg, blink: attributes.blink && !iceColors,
                                     scalar: scalar)
        if column == columns - 1 {
            if autowrap { pendingWrap = true }
        } else {
            column += 1
        }
    }

    private mutating func lineFeed() {
        if row == bottom {
            scrollUp(1)
        } else if row < rows - 1 {
            row += 1
        }
    }

    private mutating func reverseIndex() {
        if row == top {
            scrollDown(1)
        } else if row > 0 {
            row -= 1
        }
    }

    /// Scrolls the region up; lines leaving a region that starts at the top go to the scrollback.
    private mutating func scrollUp(_ n: Int) {
        let blank = blankRow
        for _ in 0..<min(n, bottom - top + 1) {
            let line = grid.remove(at: top)
            if top == 0 {
                scrollback.append(line)
                if scrollback.count > Self.maxScrollback { scrollback.removeFirst(scrollback.count - Self.maxScrollback) }
            }
            grid.insert(blank, at: bottom)
        }
    }

    private mutating func scrollDown(_ n: Int) {
        let blank = blankRow
        for _ in 0..<min(n, bottom - top + 1) {
            grid.remove(at: bottom)
            grid.insert(blank, at: top)
        }
    }

    private mutating func eraseDisplay(_ mode: Int) {
        let blank = blankCell
        switch mode {
        case 0:
            for c in column..<columns { grid[row][c] = blank }
            for r in (row + 1)..<max(row + 1, rows) { grid[r] = blankRow }
        case 1:
            for r in 0..<row { grid[r] = blankRow }
            for c in 0...column { grid[row][c] = blank }
        case 2:
            // BBS terminals (like ANSI.SYS) also home the cursor.
            grid = Array(repeating: blankRow, count: rows)
            row = 0
            column = 0
            pendingWrap = false
        case 3:
            scrollback.removeAll()
        default:
            break
        }
    }

    private mutating func eraseLine(_ mode: Int) {
        let blank = blankCell
        let range: ClosedRange<Int>
        switch mode {
        case 0: range = column...(columns - 1)
        case 1: range = 0...column
        case 2: range = 0...(columns - 1)
        default: return
        }
        for c in range { grid[row][c] = blank }
    }

    private mutating func reset() {
        let kept = scrollback
        let changes = changeCount, bellCount = bells, keptProfile = profile, ice = iceColors
        self = TerminalEmulator(columns: columns, rows: rows, encoding: encoding)
        profile = keptProfile
        iceColors = ice
        scrollback = kept
        changeCount = changes
        bells = bellCount
    }
}
