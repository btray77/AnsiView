import CoreGraphics
import Foundation

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

/// A RIPscrip block transfer request (`!|9 ESC`): the BBS wants to send or receive files.
public struct RIPBlockTransfer: Equatable {
    public var upload: Bool
    /// 0 Xmodem checksum, 1 Xmodem CRC, 2 Xmodem-1K, 3 Xmodem-1K G, 4 Kermit, 5 Ymodem, 6 Ymodem-G, 7 Zmodem.
    public var protocolCode: Int
    /// 0 RIP to show, 1 RIP to store, 2 icons, 3 help, 4 and 5 dynamic batches.
    public var fileType: Int
    public var fileName: String?

    public var protocolName: String {
        ["Xmodem", "Xmodem-CRC", "Xmodem-1K", "Xmodem-1K-G", "Kermit", "Ymodem", "Ymodem-G", "Zmodem"][max(0, min(7, protocolCode))]
    }
}

/// A RIPscrip terminal (RIPterm 1.54 style): vector graphics on a 640x350 EGA screen under an
/// ANSI-BBS text layer drawn with the EGA 8x14 font, mouse fields and buttons (with radio and
/// check box groups, hotkeys and the button style effects), icons and scenes from the user's icon
/// folder (`files`), icons the BBS writes kept for the session, file and text variable queries,
/// and block transfer requests. Drawing is limited per `feed` (`drawingBudget`); the rest waits.
public struct RIPTerminal: TerminalEngine {
    public private(set) var ansi: TerminalEmulator
    public private(set) var canvas = RIPCanvas()
    /// The user's icon folder (icons, scenes, file queries); nil when none was chosen.
    public var files: RIPFileProvider?
    /// Pixels drawn per `feed` before the rest of the input waits for the next call.
    public var drawingBudget = 6_000_000

    struct MouseField {
        var x0: Int, y0: Int, x1: Int, y1: Int
        var command: [UInt8]
        var button: Int?
    }

    struct Button {
        var x0: Int, y0: Int, x1: Int, y1: Int
        var command: [UInt8]
        var hotkey: Int
        var group: Int
        var radio: Bool
        var checkbox: Bool
        var selected: Bool
        var resetAfter: Bool
        var isDefault: Bool
    }

    struct ButtonStyle {
        var width = 0, height = 0, orientation = 2, flags = 0, bevel = 2
        var fore: UInt8 = 15, back: UInt8 = 0, bright: UInt8 = 15, dark: UInt8 = 8, surface: UInt8 = 7
        var group = 0, flags2 = 0
        var underline: UInt8 = 14, corner: UInt8 = 7
        func has(_ flag: Int) -> Bool { flags & flag != 0 }
    }

    private var fields: [MouseField] = []
    private var buttons: [Button] = []
    private var style = ButtonStyle()
    private var textBlock: (x0: Int, y0: Int, x1: Int, y1: Int, y: Int)?
    private var clipboard: (width: Int, height: Int, pixels: [UInt8])?
    var clipboardSize: (width: Int, height: Int)? { clipboard.map { ($0.width, $0.height) } }
    /// Icons the BBS wrote with 1W: kept for this session only (a BBS never writes to the disk).
    private var sessionIcons: [String: RIPIcon] = [:]
    private var deferredQuery: (mode: Int, text: [UInt8])?
    private var blockTransfer: RIPBlockTransfer?
    private var lastClick = (x: 0, y: 0)

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
    /// Input not yet processed because the drawing budget ran out.
    private var pendingInput: [UInt8] = []
    private var sceneDepth = 0
    /// Past this much waiting input the budget is ignored (the BBS is far ahead of the screen).
    static let maxPendingInput = 8 * 1024 * 1024

    public init(columns: Int = 80, rows: Int = 25, encoding: TextEncoding = .cp437) {
        ansi = TerminalEmulator(columns: columns, rows: rows, encoding: encoding)
    }

    /// RIPterm's text window: 80x25 EGA 8x14 characters cover the 640x350 graphics screen.
    public var font: BitmapFont? { BitmapFont.named("IBM EGA") }
    /// 640x350 pixels filled a 4:3 monitor: each pixel is shown narrower than tall.
    public var horizontalStretch: Double { (4.0 / 3.0) / (640.0 / 350.0) }
    public var columns: Int { ansi.columns }
    public var rows: Int { ansi.rows }
    public var cursor: (row: Int, column: Int) { ansi.cursor }
    public var cursorVisible: Bool { ansi.cursorVisible }
    public var changeCount: Int { ansi.changeCount &+ canvas.changeCount &+ graphicsChanges }
    public var bells: Int { ansi.bells }
    public var scrollbackCount: Int { ansi.scrollback.count }
    public var hasPendingWork: Bool { !pendingInput.isEmpty }
    public mutating func resize(columns: Int, rows: Int) { ansi.resize(columns: columns, rows: rows) }
    public mutating func clearScrollback() { ansi.clearScrollback() }
    public func screen(scrollOffset: Int) -> AnsiScreen { ansi.screen(scrollOffset: scrollOffset) }
    public func images(scrollOffset: Int) -> [PlacedTerminalImage] { ansi.images(scrollOffset: scrollOffset) }
    public func overlay() -> CGImage? { canvas.image() }

    /// Indexes (in creation order) of the buttons drawn selected.
    var selectedButtons: [Int] { buttons.indices.filter { buttons[$0].selected } }

    public mutating func takeReplies() -> [UInt8] {
        let out = replies + ansi.takeReplies()
        replies.removeAll()
        return out
    }

    public var hasBlockTransfer: Bool { blockTransfer != nil }

    /// The block transfer the BBS asked for, once.
    public mutating func takeBlockTransfer() -> RIPBlockTransfer? {
        defer { blockTransfer = nil }
        return blockTransfer
    }

    public mutating func click(x: Int, y: Int) -> [UInt8] {
        lastClick = (x, y)
        // Newest fields first.
        for field in fields.reversed() where x >= field.x0 && x <= field.x1 && y >= field.y0 && y <= field.y1 {
            if let index = field.button { return press(index) }
            return expand(field.command)
        }
        if let query = deferredQuery, query.mode == 1 { return expand(query.text) }
        return []
    }

    /// A typed key that is a button's hotkey (or Return for the default button): the button's
    /// host command; nil when no button takes the key.
    public mutating func hotkey(_ byte: UInt8) -> [UInt8]? {
        let upper = (0x61...0x7A).contains(byte) ? byte - 0x20 : byte
        for index in buttons.indices.reversed() {
            let key = buttons[index].hotkey
            let keyUpper = (0x61...0x7A).contains(key) ? key - 0x20 : key
            if key != 0, key == 255 || keyUpper == Int(upper) { return press(index) }
            if byte == 0x0D, buttons[index].isDefault { return press(index) }
        }
        return nil
    }

    private mutating func press(_ index: Int) -> [UInt8] {
        let button = buttons[index]
        if button.radio {
            for other in buttons.indices where other != index && buttons[other].radio
                && buttons[other].group == button.group && buttons[other].selected {
                setSelected(other, false)
            }
            setSelected(index, true)
        } else if button.checkbox {
            setSelected(index, !button.selected)
        }
        if button.resetAfter { resetWindows() }
        graphicsChanges &+= 1
        return expand(button.command)
    }

    private mutating func setSelected(_ index: Int, _ on: Bool) {
        guard buttons[index].selected != on else { return }
        buttons[index].selected = on
        let b = buttons[index]
        canvas.invert(x0: b.x0, y0: b.y0, x1: b.x1, y1: b.y1)
    }

    /// A host command with its control characters and text variables.
    private func expand(_ text: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var i = 0
        while i < text.count {
            if text[i] == UInt8(ascii: "$"), let end = text[(i + 1)...].firstIndex(of: UInt8(ascii: "$")), end - i <= 24 {
                let name = String(decoding: text[(i + 1)..<end], as: UTF8.self).uppercased()
                out += Array(variable(name).utf8)
                i = end + 1
                continue
            }
            out.append(text[i])
            i += 1
        }
        return RIPParser.hostCommand(out)
    }

    /// Text variables a terminal can answer without personal data; others are blank.
    private func variable(_ name: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        switch name {
        case "DATE": formatter.dateFormat = "MM/dd/yy"; return formatter.string(from: Date())
        case "TIME": formatter.dateFormat = "HH:mm:ss"; return formatter.string(from: Date())
        case "X": return String(format: "%04d", lastClick.x)
        case "Y": return String(format: "%04d", lastClick.y)
        case "RIPVER": return "RIPSCRIP015400"
        default: return ""
        }
    }

    // MARK: Stream

    public mutating func feed(_ bytes: [UInt8]) {
        guard !bytes.isEmpty || !pendingInput.isEmpty else { return }
        var input = pendingInput
        input += bytes
        pendingInput.removeAll()
        canvas.resetWork()
        process(input, budgeted: true)
    }

    private mutating func process(_ input: [UInt8], budgeted: Bool) {
        var text: [UInt8] = []
        func flush(_ t: inout [UInt8], _ ansi: inout TerminalEmulator) {
            if !t.isEmpty { ansi.feed(t); t.removeAll() }
        }
        var index = 0
        while index < input.count {
            let b = input[index]
            index += 1
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
                    let command = line
                    line.removeAll()
                    execute(command)
                    if budgeted, canvas.work > drawingBudget, index < input.count,
                       input.count - index < Self.maxPendingInput {
                        pendingInput = Array(input[index...])
                        return
                    }
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
        // Block mode (9 ESC) must end its line; its file name may hold bars.
        if line.starts(with: [UInt8(ascii: "9"), 0x1B]) {
            blockMode(Array(line.dropFirst(2)))
            return
        }
        for command in RIPParser.commands(line) {
            run(command)
        }
    }

    private mutating func blockMode(_ args: [UInt8]) {
        guard args.count >= 8 else { return }
        let digits = args.prefix(8).map { (0x30...0x39).contains($0) ? Int($0 - 0x30) : 0 }
        var name = Array(args.dropFirst(8))
        if let end = name.indices.first(where: { name[$0] == UInt8(ascii: "<") && $0 + 1 < name.count && name[$0 + 1] == UInt8(ascii: ">") }) {
            name = Array(name[..<end])
        }
        blockTransfer = RIPBlockTransfer(upload: digits[0] == 1, protocolCode: digits[1], fileType: digits[2] * 10 + digits[3],
                                         fileName: RIPFileName.sanitize(name))
    }

    private mutating func resetWindows() {
        canvas.reset()
        fields.removeAll()
        buttons.removeAll()
        clipboard = nil
        deferredQuery = nil
        ansi.feed(Array("\u{1B}[r\u{1B}[0m\u{1B}[2J".utf8))
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
            case "*": resetWindows()
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
            // Sizes past 10 are not in RIPscrip; capping keeps a hostile size from drawing for minutes.
            case "Y": canvas.font = min(10, n()); canvas.direction = n(); canvas.size = max(1, min(10, n()))
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
            if fields.count < 256 { fields.append(MouseField(x0: x0, y0: y0, x1: x1, y1: y1, command: rest(), button: nil)) }
        case "K":
            fields.removeAll()
            buttons.removeAll()
        case "B":
            var s = ButtonStyle()
            s.width = n(); s.height = n(); s.orientation = n(); s.flags = n(4); s.bevel = n()
            s.fore = UInt8(n() & 15); s.back = UInt8(n() & 15); s.bright = UInt8(n() & 15); s.dark = UInt8(n() & 15)
            s.surface = UInt8(n() & 15); s.group = n(); s.flags2 = n(); s.underline = UInt8(n() & 15); s.corner = UInt8(n() & 15)
            style = s
        case "U":
            let (x0, y0) = point(), (x1, y1) = point()
            let hotkey = n(), flags = n(1)
            _ = n(1)
            button(x0: x0, y0: y0, x1: x1, y1: y1, hotkey: hotkey, flags: flags, text: rest())
        case "T":
            let (x0, y0) = point(), (x1, y1) = point()
            textBlock = (x0, y0, x1, y1, y0)
        case "t":
            _ = n(1)
            if var block = textBlock {
                let words = canvas.fittingPrefix(rest(), width: block.x1 - block.x0 + 1)
                canvas.text(words, x: block.x0, y: block.y)
                block.y += canvas.textHeight
                textBlock = block
            }
        case "E": textBlock = nil
        case "C":
            // Clamped to the screen: MegaNums reach 1295, which would copy (and paste) far more than exists.
            let (a, b) = point(), (c, d) = point()
            if let region = canvas.region(x0: a, y0: b, x1: c, y1: d) { clipboard = region }
        case "P":
            let (x, y) = point(), mode = n()
            guard let clip = clipboard else { return }
            canvas.put(clip.pixels, width: clip.width, height: clip.height, x: x, y: y, mode: mode)
            graphicsChanges &+= 1
        case "I":
            let (x, y) = point(), mode = n(), toClipboard = n(1)
            _ = n(2)
            loadIcon(rest(), x: x, y: y, mode: mode, toClipboard: toClipboard == 1)
        case "W":
            _ = n(1)
            guard let clip = clipboard, let name = RIPFileName.icon(rest()) else { return }
            if sessionIcons.count < 64 || sessionIcons[name.lowercased()] != nil {
                sessionIcons[name.lowercased()] = RIPIcon(width: clip.width, height: clip.height, pixels: clip.pixels)
            }
        case "G":
            let (x0, y0) = point(), (x1, y1) = point()
            _ = n()
            canvas.copyLines(x0: x0, y0: y0, x1: x1, y1: y1, destination: n())
        case "R":
            _ = n(8)
            readScene(rest())
        case "F":
            let mode = n()
            _ = n(4)
            fileQuery(rest(), mode: mode)
        case "\u{1B}":
            let mode = n(1)
            _ = n(3)
            let text = rest()
            if mode == 0 {
                replies += expand(text)
            } else {
                deferredQuery = String(decoding: text, as: UTF8.self) == "$OFF$" ? nil : (mode, text)
            }
        default:
            break
        }
    }

    // MARK: Files

    private func icon(named raw: [UInt8], extension ext: String = "ICN") -> RIPIcon? {
        guard let name = RIPFileName.icon(raw, defaultExtension: ext) else { return nil }
        if let kept = sessionIcons[name.lowercased()] { return kept }
        return files?.data(named: name).flatMap(RIPIcon.decode)
    }

    private mutating func loadIcon(_ raw: [UInt8], x: Int, y: Int, mode: Int, toClipboard: Bool) {
        guard let icon = icon(named: raw) else {
            // RIPscrip asks for a visible sign that an icon is missing: a crossed box.
            let saved = (canvas.color, canvas.lineStyle)
            canvas.color = 15
            canvas.lineStyle = 0xFFFF
            canvas.rectangle(x, y, x + 31, y + 19)
            canvas.line(x, y, x + 31, y + 19)
            canvas.line(x + 31, y, x, y + 19)
            (canvas.color, canvas.lineStyle) = saved
            return
        }
        guard x >= 0, x + icon.width <= canvas.width, y + icon.height <= canvas.height else { return }
        canvas.put(icon.pixels, width: icon.width, height: icon.height, x: x, y: y, mode: mode)
        if toClipboard { clipboard = (icon.width, icon.height, icon.pixels) }
        graphicsChanges &+= 1
    }

    private mutating func readScene(_ raw: [UInt8]) {
        // One level: a scene that loads a scene (or itself) does not recurse.
        guard sceneDepth == 0, let name = RIPFileName.sanitize(raw), let data = files?.data(named: name) else { return }
        let saved = (atLineStart, bangPending, collecting, line, swallowLF)
        atLineStart = true; bangPending = false; collecting = false; line = []; swallowLF = false
        sceneDepth += 1
        process(data + [0x0D], budgeted: false)
        sceneDepth -= 1
        (atLineStart, bangPending, collecting, line, swallowLF) = saved
    }

    private mutating func fileQuery(_ raw: [UInt8], mode: Int) {
        let name = RIPFileName.sanitize(raw)
        let info: (size: Int, date: Date)? = name.flatMap { n in
            if let kept = sessionIcons[n.lowercased()] { return (kept.encode().count, Date()) }
            return files?.info(named: n)
        }
        guard let info, let name else {
            replies += Array((mode == 0 ? "0" : "0\r").utf8)
            return
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM/dd/yy.HH:mm:ss"
        let stamp = formatter.string(from: info.date)
        switch mode {
        case 0: replies += Array("1".utf8)
        case 1: replies += Array("1\r".utf8)
        case 2: replies += Array("1.\(info.size)\r".utf8)
        case 3: replies += Array("1.\(info.size).\(stamp)\r".utf8)
        default: replies += Array("1.\(name.uppercased()).\(info.size).\(stamp)\r".utf8)
        }
    }

    // MARK: Buttons

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

    private mutating func button(x0: Int, y0: Int, x1 inX1: Int, y1 inY1: Int, hotkey: Int, flags: Int, text: [UInt8]) {
        let parts = split(text)
        let iconName = parts[0], label = parts.count > 1 ? parts[1] : [], command = parts.count > 2 ? parts[2] : []
        var s = style
        var x1 = inX1, y1 = inY1
        // The base image: icon, clipboard or a plain surface (a style with no type is drawn plain).
        if s.has(128) {
            guard let icon = icon(named: iconName) else { loadIcon(iconName, x: x0, y: y0, mode: 0, toClipboard: false); return }
            canvas.put(icon.pixels, width: icon.width, height: icon.height, x: x0, y: y0, mode: 0)
            x1 = x0 + icon.width - 1; y1 = y0 + icon.height - 1
        } else if s.has(1) {
            guard let clip = clipboard else { return }
            canvas.put(clip.pixels, width: clip.width, height: clip.height, x: x0, y: y0, mode: 0)
            x1 = x0 + clip.width - 1; y1 = y0 + clip.height - 1
        } else {
            if s.width > 0, s.height > 0 { x1 = x0 + s.width - 1; y1 = y0 + s.height - 1 }
            if x1 <= x0 { x1 = x0 + 8 }
            if y1 <= y0 { y1 = y0 + 8 }
            let saved = (canvas.fillPattern, canvas.fillColor)
            canvas.fillPattern = RIPCanvas.patterns[1]
            canvas.fillColor = s.surface
            canvas.bar(x0, y0, x1, y1)
            (canvas.fillPattern, canvas.fillColor) = saved
        }
        let savedColor = canvas.color, savedStyle = canvas.lineStyle, savedThick = canvas.thick, savedXor = canvas.xorMode
        canvas.lineStyle = 0xFFFF; canvas.thick = false; canvas.xorMode = false
        func frame(_ inset: Int, topLeft: UInt8, bottomRight: UInt8) {
            let a = x0 + inset, b = y0 + inset, c = x1 - inset, d = y1 - inset
            guard c > a, d > b else { return }
            canvas.color = topLeft
            canvas.line(a, b, c, b); canvas.line(a, b, a, d)
            canvas.color = bottomRight
            canvas.line(a, d, c, d); canvas.line(c, b, c, d)
        }
        if s.has(8) {
            // Chisel: an indented gutter, deeper on bigger buttons.
            let h = y1 - y0 + 1
            let inset = h < 12 ? 1 : h < 25 ? 3 : h < 40 ? 4 : h < 75 ? 5 : h < 150 ? 6 : 7
            frame(inset, topLeft: s.dark, bottomRight: s.bright)
            frame(inset + 1, topLeft: s.bright, bottomRight: s.dark)
        }
        if s.has(32768) { frame(1, topLeft: s.dark, bottomRight: s.bright) }
        var ox0 = x0, oy0 = y0, ox1 = x1, oy1 = y1
        if s.has(512) {
            let bevel = max(0, min(s.bevel, 16))
            for k in 1...max(1, bevel) where bevel > 0 {
                canvas.color = s.bright
                canvas.line(x0 - k, y0 - k, x1 + k, y0 - k); canvas.line(x0 - k, y0 - k, x0 - k, y1 + k)
                canvas.color = s.dark
                canvas.line(x0 - k, y1 + k, x1 + k, y1 + k); canvas.line(x1 + k, y0 - k, x1 + k, y1 + k)
            }
            if bevel > 0 {
                canvas.color = s.corner
                for k in 1...bevel {
                    canvas.plot(x1 + k, y0 - k, s.corner); canvas.plot(x0 - k, y1 + k, s.corner)
                }
            }
            ox0 -= bevel; oy0 -= bevel; ox1 += bevel; oy1 += bevel
        }
        if s.has(64) {
            // Auto-clip: the finished image becomes the clipboard and later buttons reuse it.
            if let region = canvas.region(x0: ox0, y0: oy0, x1: ox1, y1: oy1) { clipboard = region }
            style.flags = (style.flags & ~(128 | 256 | 8 | 512 | 64 | 32768)) | 1
            s = style
        }
        if s.has(16) {
            canvas.color = 0
            canvas.rectangle(ox0 - 1, oy0 - 1, ox1 + 1, oy1 + 1)
            canvas.color = s.dark
            canvas.line(ox0 - 2, oy0 - 2, ox1 + 2, oy0 - 2); canvas.line(ox0 - 2, oy0 - 2, ox0 - 2, oy1 + 2)
            canvas.color = s.bright
            canvas.line(ox0 - 2, oy1 + 2, ox1 + 2, oy1 + 2); canvas.line(ox1 + 2, oy0 - 2, ox1 + 2, oy1 + 2)
        }
        if !label.isEmpty { drawLabel(label, x0: ox0, y0: oy0, x1: ox1, y1: oy1, style: s, hotkey: hotkey) }
        canvas.color = savedColor; canvas.lineStyle = savedStyle; canvas.thick = savedThick; canvas.xorMode = savedXor
        graphicsChanges &+= 1

        let mouse = s.has(1024) || (!command.isEmpty && s.flags & (1024 | 128 | 1 | 256) == 0)
        let index = buttons.count
        buttons.append(Button(x0: ox0, y0: oy0, x1: ox1, y1: oy1, command: command, hotkey: mouse ? hotkey : 0,
                              group: s.group, radio: s.has(16384), checkbox: s.flags2 & 1 != 0, selected: false,
                              resetAfter: s.has(4), isDefault: flags & 2 != 0))
        if flags & 1 != 0, buttons[index].radio || buttons[index].checkbox { setSelected(index, true) }
        if mouse, fields.count < 256, fields.filter({ $0.button != nil }).count < 128 {
            fields.append(MouseField(x0: ox0, y0: oy0, x1: ox1, y1: oy1, command: command, button: index))
        }
        if buttons.count > 1024 { buttons.removeFirst(buttons.count - 1024); fields.removeAll { $0.button != nil } }
    }

    private mutating func drawLabel(_ label: [UInt8], x0: Int, y0: Int, x1: Int, y1: Int, style s: ButtonStyle, hotkey: Int) {
        let width = canvas.textWidth(label), height = canvas.font == 0 ? 8 * max(1, canvas.size)
            : RIPStrokeFont.metrics(font: canvas.font, size: canvas.size).base
        let indent = s.has(8) ? 20 : 10
        var tx: Int
        if s.flags2 & 8 != 0 { tx = x0 + indent } else if s.flags2 & 16 != 0 { tx = x1 - indent - width } else { tx = x0 + (x1 - x0 + 1 - width) / 2 }
        var ty = y0 + (y1 - y0 + 1 - height) / 2
        switch s.orientation {
        case 0: ty = y0 - height - 2
        case 1: tx = x0 - width - 4
        case 3: tx = x1 + 4
        case 4: ty = y1 + 3
        default: break
        }
        if s.has(32) {
            canvas.color = s.back
            canvas.text(label, x: tx + 1, y: ty + 1)
        }
        canvas.color = s.fore
        canvas.text(label, x: tx, y: ty)
        if s.has(2048) || s.flags2 & 2 != 0, hotkey > 0, hotkey < 255,
           let at = label.firstIndex(where: { Int($0) == hotkey || Int($0) ^ 0x20 == hotkey }) {
            let ux = tx + canvas.textWidth(Array(label[..<at])), uw = canvas.textWidth([label[at]])
            canvas.color = s.underline
            canvas.line(ux, ty + height + 1, ux + uw - 2, ty + height + 1)
        }
    }
}
