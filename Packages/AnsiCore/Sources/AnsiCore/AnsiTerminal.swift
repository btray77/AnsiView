import Foundation

/// One character cell on the virtual DOS screen. Colors are VGA attribute indexes (0-15).
public struct AnsiCell: Equatable {
    public var code: UInt8 = 0x20
    public var fg: UInt8 = 7
    public var bg: UInt8 = 0
    public var blink = false

    public init(code: UInt8 = 0x20, fg: UInt8 = 7, bg: UInt8 = 0, blink: Bool = false) {
        self.code = code
        self.fg = fg
        self.bg = bg
        self.blink = blink
    }
}

/// A snapshot of the virtual screen.
public struct AnsiScreen {
    public var columns: Int
    public var rows: [[AnsiCell]]
    public var title: String?

    public var hasBlink: Bool { rows.contains { $0.contains { $0.blink } } }

    public init(columns: Int, rows: [[AnsiCell]], title: String? = nil) {
        self.columns = columns
        self.rows = rows
        self.title = title
    }
}

/// File contents with any SAUCE record removed, plus the display settings it implies.
public struct AnsiSource {
    public static let defaultColumns = 80

    public let bytes: [UInt8]
    public let columns: Int
    public let iceColors: Bool
    public let title: String?
    public let sauce: Sauce?

    public init(data: Data, fileExtension: String? = nil) {
        let (sauce, contentLength) = Sauce.read([UInt8](data))
        var bytes = Array([UInt8](data).prefix(contentLength))
        // DOS end of file marker; anything after it is padding.
        if let eof = bytes.firstIndex(of: 0x1A) { bytes.removeSubrange(eof...) }

        self.bytes = bytes
        self.sauce = sauce
        self.columns = sauce?.columns ?? Self.defaultColumns
        // iCE files use the blink bit for bright backgrounds instead of blinking.
        self.iceColors = fileExtension?.lowercased() == "ice" || sauce?.iceColors == true
        self.title = sauce.flatMap { $0.title.isEmpty ? nil : $0.title }
    }
}

/// Facts about a whole file, found by playing it through once.
public struct AnsiAnalysis {
    public let finalScreen: AnsiScreen
    /// Rows needed to show every frame without the canvas changing size.
    public let canvasRows: Int
    /// True when the file redraws over itself, so its last frame does not show everything.
    public let isAnimated: Bool

    public init(_ source: AnsiSource) {
        var terminal = AnsiTerminal(source)
        terminal.runToEnd()
        finalScreen = terminal.screen()
        isAnimated = terminal.clearsAfterDrawing > 0
            || terminal.overwrites > max(40, terminal.writes / 50)
        // Animations were made for a 25 line DOS screen.
        canvasRows = max(terminal.highestRow + 1, isAnimated ? 25 : 1)
    }
}

public enum AnsiParser {
    /// The final state of the screen after the whole file has been played.
    public static func parse(_ data: Data, fileExtension: String? = nil) -> AnsiScreen {
        AnsiAnalysis(AnsiSource(data: data, fileExtension: fileExtension)).finalScreen
    }
}

/// Plays an ANSI.SYS style byte stream (CP437 text plus CSI escape sequences) onto a cell grid.
/// Can be advanced a few bytes at a time to reproduce how the art drew over a modem.
public struct AnsiTerminal {
    public static let maxRows = 1500

    // ANSI color order (black, red, green, yellow, blue, magenta, cyan, white) to VGA attribute order.
    private static let ansiToVGA: [UInt8] = [0, 4, 2, 6, 1, 5, 3, 7]

    public let source: AnsiSource
    public private(set) var position = 0
    public private(set) var highestRow = -1
    public private(set) var writes = 0
    public private(set) var overwrites = 0
    public private(set) var clearsAfterDrawing = 0

    public var isFinished: Bool { position >= source.bytes.count }

    private var columns: Int { source.columns }
    private var rows: [[AnsiCell]] = []
    private var x = 0
    private var y = 0
    private var savedX = 0
    private var savedY = 0
    private var pendingWrap = false
    private var fg = 7          // ANSI color index 0-7
    private var bg = 0
    private var bold = false
    private var blink = false
    private var inverse = false
    private var brightFG = false
    private var brightBG = false

    public init(_ source: AnsiSource) {
        self.source = source
    }

    public mutating func runToEnd() {
        advance(byteCount: source.bytes.count)
    }

    /// Consumes at least `byteCount` bytes, finishing any escape sequence it starts.
    public mutating func advance(byteCount: Int) {
        let bytes = source.bytes
        let n = bytes.count
        let target = min(n, position + byteCount)
        var i = position
        while i < target {
            let b = bytes[i]
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
        return AnsiScreen(columns: columns, rows: result, title: source.title)
    }

    // MARK: Interpretation

    private var currentColors: (fg: UInt8, bg: UInt8) {
        var f = Self.ansiToVGA[fg] + (bold || brightFG ? 8 : 0)
        var b = Self.ansiToVGA[bg] + ((source.iceColors && blink) || brightBG ? 8 : 0)
        if inverse { swap(&f, &b) }
        return (f, b)
    }

    private var blankCell: AnsiCell { AnsiCell(code: 0x20, fg: 7, bg: currentColors.bg) }

    private mutating func ensureRow(_ row: Int) -> Bool {
        guard row < Self.maxRows else { return false }
        while rows.count <= row {
            rows.append(Array(repeating: AnsiCell(), count: columns))
        }
        return true
    }

    private mutating func put(_ code: UInt8) {
        if pendingWrap {
            x = 0
            y += 1
            pendingWrap = false
        }
        if ensureRow(y) {
            let colors = currentColors
            let cell = AnsiCell(code: code, fg: colors.fg, bg: colors.bg, blink: blink && !source.iceColors)
            let previous = rows[y][x]
            if previous.code != 0x20, previous.code != 0, previous != cell { overwrites += 1 }
            rows[y][x] = cell
            writes += 1
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
            sgr(params.isEmpty ? [0] : params.map { $0 ?? 0 })
        default:
            break
        }
    }

    private mutating func sgr(_ codes: [Int]) {
        for code in codes {
            switch code {
            case 0:
                fg = 7; bg = 0
                bold = false; blink = false; inverse = false
                brightFG = false; brightBG = false
            case 1: bold = true
            case 5, 6: blink = true
            case 7: inverse = true
            case 22: bold = false
            case 25: blink = false
            case 27: inverse = false
            case 30...37: fg = code - 30; brightFG = false
            case 39: fg = 7; brightFG = false
            case 40...47: bg = code - 40; brightBG = false
            case 49: bg = 0; brightBG = false
            case 90...97: fg = code - 90; brightFG = true
            case 100...107: bg = code - 100; brightBG = true
            default: break
            }
        }
    }
}
