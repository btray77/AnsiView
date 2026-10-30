/// Avatar level 0 (FSC-0025) and AVT/0+ (FSC-0037), as RemoteAccess, ProBoard and Maximus send
/// it, in front of the ANSI-BBS emulator (Avatar terminals also understand ANSI). The translator
/// keeps an unfinished command between `feed` calls, so commands split across packets work.
public struct AvatarTerminal: TerminalEngine {
    /// Upper bound on one repeat command's output.
    static let maxRepeat = 4000

    public private(set) var ansi: TerminalEmulator
    private var pending: [UInt8] = []

    public init(columns: Int = 80, rows: Int = 25, encoding: TextEncoding = .cp437) {
        ansi = TerminalEmulator(columns: columns, rows: rows, encoding: encoding)
    }

    public var iceColors: Bool {
        get { ansi.iceColors }
        set { ansi.iceColors = newValue }
    }

    public var columns: Int { ansi.columns }
    public var rows: Int { ansi.rows }
    public var cursor: (row: Int, column: Int) { ansi.cursor }
    public var cursorVisible: Bool { ansi.cursorVisible }
    public var changeCount: Int { ansi.changeCount }
    public var bells: Int { ansi.bells }
    public var scrollbackCount: Int { ansi.scrollback.count }
    public mutating func takeReplies() -> [UInt8] { ansi.takeReplies() }
    public mutating func resize(columns: Int, rows: Int) { ansi.resize(columns: columns, rows: rows) }
    public mutating func clearScrollback() { ansi.clearScrollback() }
    public func screen(scrollOffset: Int) -> AnsiScreen { ansi.screen(scrollOffset: scrollOffset) }
    public func images(scrollOffset: Int) -> [PlacedTerminalImage] { ansi.images(scrollOffset: scrollOffset) }

    public mutating func feed(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        let data = pending + bytes
        pending.removeAll()
        var plain: [UInt8] = []
        var i = 0
        func flush() {
            if !plain.isEmpty { ansi.feed(plain); plain.removeAll() }
        }
        while i < data.count {
            let b = data[i]
            if b == 0x0C {
                flush()
                ansi.setInsertMode(false)
                ansi.feed([0x1B, 0x5B, 0x32, 0x4A] + BBSCodes.sgr(attribute: 0x03))
                i += 1
            } else if b == 0x19 {
                guard i + 2 < data.count else { pending = Array(data[i...]); break }
                flush()
                ansi.setInsertMode(false)
                ansi.feed(Array(repeating: data[i + 1], count: min(Int(data[i + 2]), Self.maxRepeat)))
                i += 3
            } else if b == 0x16 {
                guard i + 1 < data.count else { pending = Array(data[i...]); break }
                let needed = Self.length(command: data[i + 1], data: data, at: i)
                guard let needed else {
                    plain.append(b)
                    i += 1
                    continue
                }
                guard i + needed <= data.count else { pending = Array(data[i...]); break }
                flush()
                run(Array(data[i..<(i + needed)]))
                i += needed
            } else {
                plain.append(b)
                i += 1
            }
        }
        flush()
        // A hostile stream that never finishes a command cannot grow the buffer without bound.
        if pending.count > 300 { pending.removeAll() }
    }

    /// The whole length of a ^V command starting at `start`; nil for an unknown command, and a
    /// length past the end when the pattern length byte has not arrived yet.
    private static func length(command: UInt8, data: [UInt8], at start: Int) -> Int? {
        switch command {
        case 0x01: return 3
        case 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x09, 0x0E: return 2
        case 0x08: return 4
        case 0x0A, 0x0B: return 7
        case 0x0C: return 5
        case 0x0D: return 6
        case 0x19:
            guard start + 2 < data.count else { return Int.max / 2 }
            return 3 + Int(data[start + 2]) + 1
        default: return nil
        }
    }

    private mutating func run(_ c: [UInt8]) {
        let csi: [UInt8] = [0x1B, 0x5B]
        if c[1] != 0x09 { ansi.setInsertMode(false) }
        switch c[1] {
        case 0x01:
            attribute = c[2] & 0x7F
            ansi.feed(BBSCodes.sgr(attribute: attribute))
        case 0x02:
            attribute |= 0x80
            ansi.feed(BBSCodes.sgr(attribute: attribute))
        case 0x03: ansi.feed(csi + Array("A".utf8))
        case 0x04: ansi.feed(csi + Array("B".utf8))
        case 0x05: ansi.feed(csi + Array("D".utf8))
        case 0x06: ansi.feed(csi + Array("C".utf8))
        case 0x07: ansi.feed(csi + Array("K".utf8))
        case 0x08: ansi.feed(csi + Array("\(max(1, c[2]));\(max(1, c[3]))H".utf8))
        case 0x09: ansi.setInsertMode(true)
        case 0x0A, 0x0B:
            ansi.scrollArea(up: c[1] == 0x0A, lines: Int(c[2]), top: Int(c[3]), left: Int(c[4]), bottom: Int(c[5]),
                            right: Int(c[6]))
        case 0x0C: fill(attribute: c[2], code: 0x20, lines: Int(c[3]), columns: Int(c[4]))
        case 0x0D: fill(attribute: c[2], code: c[3], lines: Int(c[4]), columns: Int(c[5]))
        case 0x0E: ansi.feed(csi + Array("P".utf8))
        case 0x19:
            let pattern = Array(c[3..<(c.count - 1)])
            let times = Int(c[c.count - 1])
            guard !pattern.isEmpty else { return }
            var out: [UInt8] = []
            for _ in 0..<times where out.count < Self.maxRepeat { out += pattern }
            ansi.feed(out)
        default: break
        }
    }

    private var attribute: UInt8 = 0x07

    /// Fills `lines` x `columns` cells from the cursor with a character, leaving the cursor where it was.
    private mutating func fill(attribute fillAttribute: UInt8, code: UInt8, lines: Int, columns count: Int) {
        let start = ansi.cursor
        let width = min(count, columns - start.column)
        guard width > 0 else { return }
        attribute = fillAttribute & 0x7F
        var out = BBSCodes.sgr(attribute: attribute)
        for line in 0..<min(lines, rows - start.row) {
            out += Array("\u{1B}[\(start.row + line + 1);\(start.column + 1)H".utf8)
            out += Array(repeating: code, count: width)
        }
        out += Array("\u{1B}[\(start.row + 1);\(start.column + 1)H".utf8)
        // A fill that ends in the last column must not wrap and scroll.
        ansi.feed(Array("\u{1B}[?7l".utf8) + out + Array("\u{1B}[?7h".utf8))
    }
}
