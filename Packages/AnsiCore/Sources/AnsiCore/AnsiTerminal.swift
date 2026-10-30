import Foundation

/// One character cell on the virtual DOS screen. Colors are VGA attribute indexes (0-15).
public struct AnsiCell: Equatable {
    public var code: UInt8 = 0x20
    public var fg: RGB = Palette.vga[7]
    public var bg: RGB = Palette.vga[0]
    public var blink = false
    /// Set only for UTF-8 characters with no CP437 equivalent; `code` is then "?".
    public var scalar: Unicode.Scalar?

    public init(code: UInt8 = 0x20, fg: RGB = Palette.vga[7], bg: RGB = Palette.vga[0], blink: Bool = false,
                scalar: Unicode.Scalar? = nil) {
        self.code = code
        self.fg = fg
        self.bg = bg
        self.blink = blink
        self.scalar = scalar
    }
}

/// A snapshot of the virtual screen.
public struct AnsiScreen {
    public var columns: Int
    public var rows: [[AnsiCell]]
    public var title: String?
    public var sauce: Sauce?
    public var font: BitmapFont = .vga
    /// An XBin file's own 16 colour palette (nil for VGA), kept so editing and saving keeps it.
    public var palette: [RGB]?

    public var hasBlink: Bool { rows.contains { $0.contains { $0.blink } } }

    public init(columns: Int, rows: [[AnsiCell]], title: String? = nil) {
        self.columns = columns
        self.rows = rows
        self.title = title
    }
}

/// Facts about a whole file, found by playing it through once.
public struct AnsiAnalysis {
    public let finalScreen: AnsiScreen
    /// Rows needed to show every frame without the canvas changing size.
    public let canvasRows: Int
    /// True when the file redraws over itself, so its last frame does not show everything.
    public let isAnimated: Bool

    public init(_ file: ArtFile) {
        if case .screen(let screen) = file.content {
            finalScreen = screen
            isAnimated = false
            canvasRows = max(1, screen.rows.count)
            return
        }
        var terminal = AnsiTerminal(file)
        terminal.runToEnd()
        finalScreen = terminal.screen()
        isAnimated = terminal.clearsAfterDrawing > 0 || terminal.pauses > 0
            || terminal.overwrites > max(40, terminal.writes / 50)
        // Animations were made for a 25 line DOS screen.
        canvasRows = max(terminal.highestRow + 1, isAnimated ? 25 : 1)
    }
}

public enum AnsiParser {
    /// The final state of the screen after the whole file has been played.
    public static func parse(_ data: Data, fileExtension: String? = nil) -> AnsiScreen {
        AnsiAnalysis(ArtFile(data: data, fileExtension: fileExtension)).finalScreen
    }
}

/// Plays an ANSI.SYS style byte stream (CP437 text plus CSI escape sequences) onto a cell grid.
/// Can be advanced a few bytes at a time to reproduce how the art drew over a modem.
public struct AnsiTerminal {
    public static let maxRows = 1500

    public let source: ArtFile
    /// Which escape sequences start ANSI music, whose bytes are skipped (not printed). Files use
    /// `.all` by default; `ESC[=Ps M` in the stream changes it unless it is `.off`.
    public private(set) var musicMode: MusicMode
    private let initialMusicMode: MusicMode
    public private(set) var position = 0
    public private(set) var highestRow = -1
    public private(set) var writes = 0
    public private(set) var overwrites = 0
    public private(set) var clearsAfterDrawing = 0
    /// Counts every change to the cells: character writes, line erases and screen erases.
    public private(set) var edits = 0
    /// Padding pauses: runs of `pauseLength` or more CRs after drawing (animation plan, ruling 8).
    public private(set) var pauses = 0
    public static let pauseLength = 8
    private var carriageReturns = 0
    /// The row the cursor is on (0 based, canvas coordinates).
    public var cursorRow: Int { y }

    public var isFinished: Bool { position >= bytes.count }

    private var columns: Int { source.columns }
    private var rows: [[AnsiCell]] = []
    private var x = 0
    private var y = 0
    private var savedX = 0
    private var savedY = 0
    private var pendingWrap = false
    private var attributes = TextAttributes()

    private let bytes: [UInt8]

    public init(_ source: ArtFile, musicMode: MusicMode = .all) {
        self.source = source
        self.bytes = source.stream
        self.musicMode = musicMode
        self.initialMusicMode = musicMode
    }

    public mutating func runToEnd() {
        advance(byteCount: bytes.count)
    }

    /// Moves playback to `position` (clamped to the stream). Moving back replays from the start.
    /// Like `advance`, it finishes any escape sequence the position falls inside.
    public mutating func seek(to position: Int) {
        let target = min(bytes.count, max(0, position))
        if target < self.position { self = AnsiTerminal(source, musicMode: initialMusicMode) }
        advance(byteCount: target - self.position)
    }

    /// Consumes at least `byteCount` bytes, finishing any escape sequence it starts.
    public mutating func advance(byteCount: Int) {
        let bytes = self.bytes
        let n = bytes.count
        let target = min(n, position + byteCount)
        var i = position
        while i < target {
            let b = bytes[i]
            if b == 0x0D {
                carriageReturns += 1
                if carriageReturns == Self.pauseLength, writes > 0 { pauses += 1 }
            } else {
                carriageReturns = 0
            }
            switch b {
            case 0x1B:
                guard i + 1 < n, bytes[i + 1] == 0x5B else { i += 2; continue }
                var j = i + 2
                var params: [Int?] = []
                var current: Int?
                var isPrivate = false
                while j < n {
                    let c = bytes[j]
                    if (0x30...0x39).contains(c) {
                        // Clamp so absurd parameters cannot overflow; no real sequence needs more.
                        current = min(9999, (current ?? 0) * 10 + Int(c - 0x30))
                    } else if c == 0x3B {
                        params.append(current)
                        current = nil
                    } else if (0x3C...0x3F).contains(c) {
                        isPrivate = true
                    } else if (0x40...0x7E).contains(c) {
                        break
                    }
                    j += 1
                }
                if current != nil || !params.isEmpty { params.append(current) }
                if j < n, j == i + 2, musicMode.introduces(bytes[j]) {
                    // ANSI music: the PLAY string up to 0x0E is sound, not text (AnsiMusic.swift).
                    i = AnsiMusic.skipBody(bytes, from: j + 1)
                    pendingWrap = false  // as for any other CSI (the file player used to ignore ESC[M as Delete Line)
                    continue
                }
                if j < n, isPrivate, bytes[i + 2] == UInt8(ascii: "="), bytes[j] == UInt8(ascii: "M"), musicMode != .off,
                   let selected = MusicMode.ctsam(params.first.flatMap { $0 } ?? 0) {
                    musicMode = selected
                }
                if j < n, !isPrivate { csi(bytes[j], params) }
                i = j + 1
                continue
            case 0x0D:
                x = 0
                pendingWrap = false
            case 0x0A:
                y += 1
                x = 0
                pendingWrap = false
            case 0x09:
                x = min(columns - 1, (x / 8 + 1) * 8)
                pendingWrap = false
            case 0x08:
                x = max(0, x - 1)
                pendingWrap = false
            case 0x07:
                break
            default:
                if source.format == .utf8Ansi, b >= 0x80, let (scalar, length) = Self.decodeUTF8(bytes, at: i) {
                    if let code = CP437.code(for: scalar) {
                        put(code)
                    } else {
                        put(0x3F, scalar: scalar)
                    }
                    i += length
                    continue
                }
                put(b)
            }
            i += 1
        }
        position = min(n, i)
    }

    /// The current screen with trailing empty rows removed, padded to at least `minimumRows`.
    public func screen(minimumRows: Int = 0) -> AnsiScreen {
        var result = rows
        let empty = AnsiCell()
        while let last = result.last, last.allSatisfy({ $0 == empty }) {
            result.removeLast()
        }
        while result.count < minimumRows {
            result.append(Array(repeating: empty, count: columns))
        }
        var screen = AnsiScreen(columns: columns, rows: result, title: source.title)
        screen.sauce = source.sauce
        screen.font = source.font
        return screen
    }

    // MARK: Interpretation

    private var currentColors: (fg: RGB, bg: RGB) { attributes.colors(iceColors: source.iceColors) }

    private var blankCell: AnsiCell { AnsiCell(code: 0x20, fg: Palette.vga[7], bg: currentColors.bg) }

    private mutating func ensureRow(_ row: Int) -> Bool {
        guard row < Self.maxRows else { return false }
        while rows.count <= row {
            rows.append(Array(repeating: AnsiCell(), count: columns))
        }
        return true
    }

    private mutating func put(_ code: UInt8, scalar: Unicode.Scalar? = nil) {
        if pendingWrap {
            x = 0
            y += 1
            pendingWrap = false
        }
        if ensureRow(y) {
            let colors = currentColors
            let cell = AnsiCell(code: code, fg: colors.fg, bg: colors.bg, blink: attributes.blink && !source.iceColors, scalar: scalar)
            let previous = rows[y][x]
            if previous.code != 0x20, previous.code != 0, previous != cell { overwrites += 1 }
            rows[y][x] = cell
            writes += 1
            edits += 1
            highestRow = max(highestRow, y)
        }
        if x == columns - 1 {
            pendingWrap = true
        } else {
            x += 1
        }
    }

    private mutating func csi(_ final: UInt8, _ params: [Int?]) {
        func p(_ index: Int, _ fallback: Int) -> Int {
            guard index < params.count, let value = params[index] else { return fallback }
            return value
        }
        pendingWrap = false
        switch final {
        case UInt8(ascii: "A"): y = max(0, y - max(1, p(0, 1)))
        case UInt8(ascii: "B"): y += max(1, p(0, 1))
        case UInt8(ascii: "C"): x = min(columns - 1, x + max(1, p(0, 1)))
        case UInt8(ascii: "D"): x = max(0, x - max(1, p(0, 1)))
        case UInt8(ascii: "H"), UInt8(ascii: "f"):
            y = max(0, p(0, 1) - 1)
            x = min(columns - 1, max(0, p(1, 1) - 1))
        case UInt8(ascii: "J"):
            edits += 1
            if p(0, 0) == 2 {
                if writes > 0 { clearsAfterDrawing += 1 }
                rows.removeAll()
                x = 0
                y = 0
            } else if p(0, 0) == 0, y < rows.count {
                let blank = blankCell
                for col in x..<columns { rows[y][col] = blank }
                rows.removeSubrange((y + 1)...)
            }
        case UInt8(ascii: "K"):
            if ensureRow(y) {
                edits += 1
                let blank = blankCell
                let range = p(0, 0) == 1 ? 0...x : (p(0, 0) == 2 ? 0...(columns - 1) : x...(columns - 1))
                for col in range { rows[y][col] = blank }
            }
        case UInt8(ascii: "s"):
            savedX = x
            savedY = y
        case UInt8(ascii: "u"):
            x = savedX
            y = savedY
        case UInt8(ascii: "m"):
            attributes.apply(params.isEmpty ? [0] : params.map { $0 ?? 0 })
        case UInt8(ascii: "t"):
            attributes.applyPabloDraw(params.map { $0 ?? 0 })
        default:
            break
        }
    }

    /// One UTF-8 encoded scalar starting at `index`, and its length in bytes.
    private static func decodeUTF8(_ bytes: [UInt8], at index: Int) -> (Unicode.Scalar, Int)? {
        let lead = bytes[index]
        let length: Int
        switch lead {
        case 0xC2...0xDF: length = 2
        case 0xE0...0xEF: length = 3
        case 0xF0...0xF4: length = 4
        default: return nil
        }
        guard index + length <= bytes.count else { return nil }
        var value = UInt32(lead) & (0xFF >> (length + 1))
        for offset in 1..<length {
            let continuation = bytes[index + offset]
            guard continuation & 0xC0 == 0x80 else { return nil }
            value = value << 6 | UInt32(continuation & 0x3F)
        }
        guard let scalar = Unicode.Scalar(value) else { return nil }
        return (scalar, length)
    }
}
