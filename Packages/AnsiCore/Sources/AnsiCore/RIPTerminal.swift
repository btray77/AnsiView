import CoreGraphics

/// RIPscrip 1.54 command lines: `!|` at the start of a line, commands separated by `|`, numbers
/// in two digit base 36 ("MegaNums"), a trailing `\` continuing the line.
public enum RIPParser {
    /// A base 36 number (0-9, A-Z; lower case accepted); bad digits count as 0.
    public static func mega(_ text: Substring) -> Int {
        var value = 0
        for c in text.unicodeScalars {
            let v: Int
            switch c {
            case "0"..."9": v = Int(c.value) - 48
            case "A"..."Z": v = Int(c.value) - 55
            case "a"..."z": v = Int(c.value) - 87
            default: v = 0
            }
            value = value * 36 + v
        }
        return value
    }

    public static func mega(_ text: String) -> Int { mega(Substring(text)) }

    /// Splits a line (after `!|`) into commands at unescaped bars, removing the escapes.
    static func commands(_ line: [UInt8]) -> [[UInt8]] {
        var out: [[UInt8]] = []
        var current: [UInt8] = []
        var i = 0
        while i < line.count {
            let b = line[i]
            if b == UInt8(ascii: "\\"), i + 1 < line.count {
                current.append(line[i + 1])
                i += 2
                continue
            }
            if b == UInt8(ascii: "|") {
                out.append(current)
                current = []
            } else {
                current.append(b)
            }
            i += 1
        }
        out.append(current)
        return out.filter { !$0.isEmpty }
    }

    /// A host command from a button or mouse field: ^X and `X are control characters.
    static func hostCommand(_ text: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var i = 0
        while i < text.count {
            let b = text[i]
            if (b == UInt8(ascii: "^") || b == UInt8(ascii: "`")), i + 1 < text.count {
                let c = text[i + 1]
                let upper = (0x61...0x7A).contains(c) ? c - 0x20 : c
                if (0x40...0x5F).contains(upper) {
                    out.append(upper - 0x40)
                    i += 2
                    continue
                }
            }
            out.append(b)
            i += 1
        }
        return out
    }
}

/// A RIPscrip terminal (RIPterm 1.54 style): vector graphics on a 640x350 EGA screen under an
/// ANSI-BBS text layer, mouse fields and buttons that send their host commands when clicked.
/// Not covered: icon files (1I/1W), scene and file queries (1R/1F), block transfers (9), stroked
/// BGI fonts (drawn with AnsiView's 8x8 font scaled instead), button group and radio flags.
public struct RIPTerminal: TerminalEngine {
    public private(set) var ansi: TerminalEmulator
    public private(set) var canvas = RIPCanvas()

    struct MouseField {
        var x0: Int, y0: Int, x1: Int, y1: Int
        var command: [UInt8]
    }

    private var fields: [MouseField] = []
    private var buttonStyle = (width: 0, height: 0, bevel: 2, fore: UInt8(15), back: UInt8(0), bright: UInt8(15),
                               dark: UInt8(8), surface: UInt8(7))
    private var textBlock: (x0: Int, y0: Int, x1: Int, y1: Int, y: Int)?
    private var clipboard: (width: Int, height: Int, pixels: [UInt8])?

    // Line splitting state.
    private var atLineStart = true
    private var bangPending = false
    private var collecting = false
    private var line: [UInt8] = []
    private var swallowLF = false
    private var replies: [UInt8] = []
    /// Matches ESC [ ! (and ESC [ 0 !) in the text stream: the RIP version query.
    private var queryMatch: [UInt8] = []
    public var enabled = true
    private var graphicsChanges = 0

    public init(columns: Int = 80, rows: Int = 25, encoding: TextEncoding = .cp437) {
        ansi = TerminalEmulator(columns: columns, rows: rows, encoding: encoding)
    }

    public var font: BitmapFont? { BitmapFont.named("IBM EGA") }
    public var columns: Int { ansi.columns }
    public var rows: Int { ansi.rows }
    public var cursor: (row: Int, column: Int) { ansi.cursor }
    public var cursorVisible: Bool { ansi.cursorVisible }
    public var changeCount: Int { ansi.changeCount &+ canvas.changeCount &+ graphicsChanges }
    public var bells: Int { ansi.bells }
    public var scrollbackCount: Int { ansi.scrollback.count }
    public mutating func resize(columns: Int, rows: Int) { ansi.resize(columns: columns, rows: rows) }
    public mutating func clearScrollback() { ansi.clearScrollback() }
    public func screen(scrollOffset: Int) -> AnsiScreen { ansi.screen(scrollOffset: scrollOffset) }
    public func overlay() -> CGImage? { canvas.image() }

    public mutating func takeReplies() -> [UInt8] {
        let out = replies + ansi.takeReplies()
        replies.removeAll()
        return out
    }

    public mutating func click(x: Int, y: Int) -> [UInt8] {
        // Newest fields first.
        for field in fields.reversed() where x >= field.x0 && x <= field.x1 && y >= field.y0 && y <= field.y1 {
            return field.command
        }
        return []
    }

    // MARK: Stream

    public mutating func feed(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        var text: [UInt8] = []
        func flush(_ t: inout [UInt8], _ ansi: inout TerminalEmulator) {
            if !t.isEmpty { ansi.feed(t); t.removeAll() }
        }
        for b in bytes {
            if swallowLF {
                swallowLF = false
                if b == 0x0A { continue }
            }
            if collecting {
                if b == 0x0D || b == 0x0A {
                    if line.last == UInt8(ascii: "\\"), !(line.count >= 2 && line[line.count - 2] == UInt8(ascii: "\\")) {
                        line.removeLast()
                        swallowLF = b == 0x0D
                        continue
                    }
                    collecting = false
                    atLineStart = true
                    swallowLF = b == 0x0D
                    flush(&text, &ansi)
                    execute(line)
                    line.removeAll()
                } else if line.count < 16384 {
                    line.append(b)
                }
                continue
            }
            if bangPending {
                bangPending = false
                if b == UInt8(ascii: "|"), enabled {
                    collecting = true
                    line.removeAll()
                    continue
                }
                text.append(UInt8(ascii: "!"))
            }
            if atLineStart, b == UInt8(ascii: "!"), enabled {
                bangPending = true
                continue
            }
            atLineStart = b == 0x0D || b == 0x0A
            matchQuery(b)
            text.append(b)
        }
        flush(&text, &ansi)
    }

    private mutating func matchQuery(_ b: UInt8) {
        queryMatch.append(b)
        if queryMatch.count > 4 { queryMatch.removeFirst(queryMatch.count - 4) }
        let tail3 = Array(queryMatch.suffix(3)), tail4 = Array(queryMatch.suffix(4))
        if tail3 == [0x1B, 0x5B, 0x21] || tail4 == [0x1B, 0x5B, 0x30, 0x21] {
            replies += Array("RIPSCRIP015400".utf8)
        } else if tail4 == [0x1B, 0x5B, 0x31, 0x21] {
            enabled = false
        } else if tail4 == [0x1B, 0x5B, 0x32, 0x21] {
            enabled = true
        }
    }

    // MARK: Commands

    private mutating func execute(_ line: [UInt8]) {
        for command in RIPParser.commands(line) {
            run(command)
        }
    }

    private mutating func run(_ command: [UInt8]) {
        var i = 0
        var level = ""
        while i < command.count, (0x31...0x39).contains(command[i]) { level.append(Character(Unicode.Scalar(command[i]))); i += 1 }
        guard i < command.count else { return }
        let name = Character(Unicode.Scalar(command[i]))
        let args = Array(command[(i + 1)...])
        var cursor = 0
        func n(_ digits: Int = 2) -> Int {
            guard cursor + digits <= args.count else { cursor = args.count; return 0 }
            let text = String(decoding: args[cursor..<(cursor + digits)], as: UTF8.self)
            cursor += digits
            return RIPParser.mega(text)
        }
        func rest() -> [UInt8] { cursor < args.count ? Array(args[cursor...]) : [] }
        func point() -> (Int, Int) { (n(), n()) }
        let ry = { (r: Int) in Int((Double(r) * RIPCanvas.aspect).rounded()) }

        if level.isEmpty {
            switch name {
            case "w":
                let (_, y0) = point(), (_, y1) = point()
                if y1 > y0 { ansi.feed(Array("\u{1B}[\(y0 + 1);\(min(rows, y1 + 1))r".utf8)) }
            case "v": canvas.viewport = (min(639, n()), min(349, n()), min(639, n()), min(349, n()))
            case "*":
                canvas.reset()
                fields.removeAll()
                ansi.feed(Array("\u{1B}[r\u{1B}[0m\u{1B}[2J".utf8))
            case "e": ansi.feed(Array("\u{1B}[2J".utf8))
            case "E": canvas.erase(x0: canvas.viewport.x0, y0: canvas.viewport.y0, x1: canvas.viewport.x1, y1: canvas.viewport.y1)
            case "g": let (x, y) = point(); ansi.feed(Array("\u{1B}[\(y + 1);\(x + 1)H".utf8))
            case "H": ansi.feed(Array("\u{1B}[H".utf8))
            case ">": ansi.feed(Array("\u{1B}[K".utf8))
            case "c": canvas.color = UInt8(n() & 15)
            case "Q": for index in 0..<16 { canvas.setPalette(index, ega: n()) }
            case "a": let index = n(); canvas.setPalette(index, ega: n())
            case "W": canvas.xorMode = n() == 1
            case "m": canvas.position = point()
            case "T": canvas.text(rest(), x: canvas.position.x, y: canvas.position.y)
            case "@": let (x, y) = point(); canvas.text(rest(), x: x, y: y)
            case "Y": canvas.font = n(); canvas.direction = n(); canvas.size = max(1, n())
            case "X": let (x, y) = point(); canvas.plot(x, y, canvas.color); graphicsChanges &+= 1
            case "L": let (a, b) = point(), (c, d) = point(); canvas.line(a, b, c, d)
            case "R": let (a, b) = point(), (c, d) = point(); canvas.rectangle(a, b, c, d)
            case "B": let (a, b) = point(), (c, d) = point(); canvas.bar(a, b, c, d)
            case "C":
                let (x, y) = point(), r = n()
                canvas.ellipseArc(x, y, start: 0, end: 360, rx: r, ry: ry(r))
            case "O", "V":
                let (x, y) = point(), start = n(), end = n(), rx = n(), r2 = n()
                canvas.ellipseArc(x, y, start: start, end: end, rx: rx, ry: r2)
            case "o":
                let (x, y) = point(), rx = n(), r2 = n()
                canvas.fillPolygon(canvas.arcPoints(x, y, start: 0, end: 360, rx: rx, ry: r2))
                canvas.ellipseArc(x, y, start: 0, end: 360, rx: rx, ry: r2)
            case "A":
                let (x, y) = point(), start = n(), end = n(), r = n()
                canvas.ellipseArc(x, y, start: start, end: end, rx: r, ry: ry(r))
            case "I", "i":
                let (x, y) = point(), start = n(), end = n(), rx = n()
                let r2 = name == "I" ? ry(rx) : n()
                let arc = canvas.arcPoints(x, y, start: start, end: end, rx: rx, ry: r2)
                canvas.fillPolygon([(x, y)] + arc)
                canvas.polyline([(x, y)] + arc + [(x, y)])
            case "Z":
                let points = (0..<4).map { _ in point() }
                canvas.bezier(points, segments: n())
            case "P", "p", "l":
                let count = min(n(), 512)
                let points = (0..<count).map { _ in point() }
                if name == "p" { canvas.fillPolygon(points) }
                canvas.polyline(name == "l" ? points : points + Array(points.prefix(1)))
            case "F": let (x, y) = point(); canvas.floodFill(x, y, border: UInt8(n() & 15))
            case "=":
                let style = n(), user = n(4), thickness = n()
                canvas.lineStyle = style < 4 ? RIPCanvas.lineStyles[style] : UInt16(truncatingIfNeeded: user)
                if canvas.lineStyle == 0 { canvas.lineStyle = 0xFFFF }
                canvas.thick = thickness >= 3
            case "S":
                let pattern = n()
                canvas.fillPattern = RIPCanvas.patterns[min(pattern, RIPCanvas.patterns.count - 1)]
                canvas.fillColor = UInt8(n() & 15)
            case "s":
                canvas.fillPattern = (0..<8).map { _ in UInt8(n() & 0xFF) }
                canvas.fillColor = UInt8(n() & 15)
            default: break
            }
            return
        }
        guard level == "1" else { return }
        switch name {
        case "M":
            _ = n()
            let (x0, y0) = point(), (x1, y1) = point()
            _ = n(1); _ = n(1); _ = n(5)
            if fields.count < 128 { fields.append(MouseField(x0: x0, y0: y0, x1: x1, y1: y1, command: RIPParser.hostCommand(rest()))) }
        case "K": fields.removeAll()
        case "B":
            let width = n(), height = n()
            _ = n(); _ = n(4)
            let bevel = n(), fore = n(), back = n(), bright = n(), dark = n(), surface = n()
            buttonStyle = (width, height, bevel, UInt8(fore & 15), UInt8(back & 15), UInt8(bright & 15), UInt8(dark & 15), UInt8(surface & 15))
        case "U":
            var (x0, y0) = point(), (x1, y1) = point()
            _ = n(); _ = n(1); _ = n(1)
            if x1 <= x0 { x1 = x0 + max(8, buttonStyle.width) }
            if y1 <= y0 { y1 = y0 + max(8, buttonStyle.height) }
            let parts = split(rest())
            drawButton(x0: x0, y0: y0, x1: x1, y1: y1, label: parts.count > 1 ? parts[1] : [])
            if parts.count > 2, fields.count < 128 {
                fields.append(MouseField(x0: x0, y0: y0, x1: x1, y1: y1, command: RIPParser.hostCommand(parts[2])))
            }
        case "T":
            let (x0, y0) = point(), (x1, y1) = point()
            textBlock = (x0, y0, x1, y1, y0)
        case "t":
            _ = n(1)
            if var block = textBlock {
                canvas.text(Array(rest().prefix(max(0, (block.x1 - block.x0) / 8))), x: block.x0, y: block.y)
                block.y += 8 * max(1, canvas.size)
                textBlock = block
            }
        case "E": textBlock = nil
        case "C":
            let (x0, y0) = point(), (x1, y1) = point()
            guard x1 >= x0, y1 >= y0 else { return }
            var copied: [UInt8] = []
            for y in y0...y1 { for x in x0...x1 { copied.append(canvas.pixel(x, y)) } }
            clipboard = (x1 - x0 + 1, y1 - y0 + 1, copied)
        case "P":
            let (x, y) = point(), mode = n()
            guard let clip = clipboard else { return }
            let saved = canvas.xorMode
            canvas.xorMode = mode == 1
            for cy in 0..<clip.height { for cx in 0..<clip.width { canvas.plot(x + cx, y + cy, clip.pixels[cy * clip.width + cx]) } }
            canvas.xorMode = saved
            graphicsChanges &+= 1
        default:
            break
        }
    }

    /// Splits button text at `<>`: icon, label, host command.
    private func split(_ text: [UInt8]) -> [[UInt8]] {
        var parts: [[UInt8]] = [[]]
        var i = 0
        while i < text.count {
            if text[i] == UInt8(ascii: "<"), i + 1 < text.count, text[i + 1] == UInt8(ascii: ">") {
                parts.append([])
                i += 2
            } else {
                parts[parts.count - 1].append(text[i])
                i += 1
            }
        }
        return parts
    }

    private mutating func drawButton(x0: Int, y0: Int, x1: Int, y1: Int, label: [UInt8]) {
        let savedPattern = canvas.fillPattern, savedFill = canvas.fillColor, savedColor = canvas.color
        let savedStyle = canvas.lineStyle, savedThick = canvas.thick
        canvas.lineStyle = 0xFFFF
        canvas.thick = false
        canvas.fillPattern = RIPCanvas.patterns[1]
        canvas.fillColor = buttonStyle.surface
        canvas.bar(x0, y0, x1, y1)
        for b in 0..<max(0, min(buttonStyle.bevel, 8)) {
            canvas.color = buttonStyle.bright
            canvas.line(x0 + b, y0 + b, x1 - b, y0 + b)
            canvas.line(x0 + b, y0 + b, x0 + b, y1 - b)
            canvas.color = buttonStyle.dark
            canvas.line(x0 + b, y1 - b, x1 - b, y1 - b)
            canvas.line(x1 - b, y0 + b, x1 - b, y1 - b)
        }
        if !label.isEmpty {
            let savedFont = (canvas.font, canvas.size, canvas.direction)
            canvas.font = 0; canvas.size = 1; canvas.direction = 0
            let width = canvas.textWidth(label.count)
            let tx = x0 + max(0, (x1 - x0 + 1 - width) / 2), ty = y0 + max(0, (y1 - y0 + 1 - 8) / 2)
            canvas.color = buttonStyle.back
            canvas.text(label, x: tx + 1, y: ty + 1)
            canvas.color = buttonStyle.fore
            canvas.text(label, x: tx, y: ty)
            (canvas.font, canvas.size, canvas.direction) = savedFont
        }
        canvas.fillPattern = savedPattern
        canvas.fillColor = savedFill
        canvas.color = savedColor
        canvas.lineStyle = savedStyle
        canvas.thick = savedThick
    }
}
