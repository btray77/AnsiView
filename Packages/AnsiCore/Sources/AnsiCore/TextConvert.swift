import Foundation

/// Text formats a screen can be converted to.
public enum TextFormat: String, CaseIterable {
    case html, ansi, ansi256, text, utf8

    public var fileExtension: String {
        switch self {
        case .html: return "html"
        case .ansi, .ansi256: return "ans"
        case .text, .utf8: return "txt"
        }
    }

    public var label: String {
        switch self {
        case .html: return "HTML"
        case .ansi: return "ANSI (24 bit)"
        case .ansi256: return "ANSI (256 colours)"
        case .text: return "CP437 Text"
        case .utf8: return "UTF-8 Text"
        }
    }
}

/// How modern ANSI output writes colours.
public enum ANSIColorMode {
    /// `38;2;r;g;b`: exact colours, for terminals with 24 bit colour.
    case trueColor
    /// `38;5;n`: VGA colours as indexes 0 to 15, others as the nearest of 16 to 255.
    case xterm256
}

/// Converts a screen to text for terminals and editors.
public enum TextConvert {
    /// UTF-8 text with SGR colours, one line per row and no cursor movement, for `cat` in a
    /// modern terminal. Reading it back gives the same cells.
    public static func modernANSI(_ screen: AnsiScreen, colors: ANSIColorMode) -> String {
        let blank = AnsiCell()
        var out = String.UnicodeScalarView()
        func append(_ text: String) { out.append(contentsOf: text.unicodeScalars) }
        for row in trimmedRows(screen) {
            var cells = Array(row.prefix(screen.columns))
            while let last = cells.last, isBlank(last, blank) { cells.removeLast() }
            var fg = blank.fg, bg = blank.bg, blink = false
            for cell in cells {
                var codes: [String] = []
                if cell.blink != blink { codes.append(cell.blink ? "5" : "25"); blink = cell.blink }
                if cell.fg != fg { codes.append(sgr(cell.fg, base: 38, colors)); fg = cell.fg }
                if cell.bg != bg { codes.append(sgr(cell.bg, base: 48, colors)); bg = cell.bg }
                if !codes.isEmpty { append("\u{1B}[" + codes.joined(separator: ";") + "m") }
                out.append(scalar(cell))
            }
            if fg != blank.fg || bg != blank.bg || blink { append("\u{1B}[0m") }
            out.append("\n")
        }
        return String(out)
    }

    /// CP437 bytes without escapes: trailing spaces trimmed, CRLF line ends. Codes that would be
    /// read as control characters become lookalikes.
    public static func cp437Text(_ screen: AnsiScreen) -> [UInt8] {
        var out: [UInt8] = []
        for row in trimmedRows(screen) {
            var line = row.prefix(screen.columns).map { lookalikes[$0.code] ?? $0.code }
            while line.last == 0x20 { line.removeLast() }
            out += line + [0x0D, 0x0A]
        }
        return out
    }

    /// The screen's characters as UTF-8 text: trailing spaces trimmed, LF line ends.
    public static func utf8Text(_ screen: AnsiScreen) -> String {
        var lines: [String] = []
        for row in trimmedRows(screen) {
            var scalars = String.UnicodeScalarView()
            for cell in row.prefix(screen.columns) { scalars.append(scalar(cell)) }
            var line = String(scalars)
            while line.last == " " { line.removeLast() }
            lines.append(line + "\n")
        }
        return lines.joined()
    }

    /// The xterm 256 colour index (16 to 255) nearest to `color`.
    public static func nearestXterm(_ color: RGB) -> Int {
        var best = 16, bestDistance = Int.max
        for index in 16..<256 {
            let distance = squaredDistance(Palette.xterm256[index], color)
            if distance < bestDistance { best = index; bestDistance = distance }
        }
        return best
    }

    static func squaredDistance(_ a: RGB, _ b: RGB) -> Int {
        let dr = Int(a.r) - Int(b.r), dg = Int(a.g) - Int(b.g), db = Int(a.b) - Int(b.b)
        return dr * dr + dg * dg + db * db
    }

    // MARK: Helpers

    /// Lookalikes for codes a DOS text file cannot hold (ruling 2 of plan 4).
    static let lookalikes: [UInt8: UInt8] = [
        0x00: 0x20, 0x07: 0xF9, 0x08: 0xDB, 0x09: 0x6F, 0x0A: 0xDB, 0x0D: 0x0E, 0x1A: 0x3E, 0x1B: 0x3C,
    ]

    /// Rows without trailing empty rows.
    public static func trimmedRows(_ screen: AnsiScreen) -> [[AnsiCell]] {
        var rows = screen.rows
        let blank = AnsiCell()
        while let last = rows.last, last.prefix(screen.columns).allSatisfy({ isBlank($0, blank) }) { rows.removeLast() }
        return rows
    }

    private static func isBlank(_ cell: AnsiCell, _ blank: AnsiCell) -> Bool {
        (cell.code == 0x20 || cell.code == 0) && cell.scalar == nil
            && cell.fg == blank.fg && cell.bg == blank.bg && !cell.blink
    }

    /// The Unicode character a cell shows (NUL shows as a space).
    static func scalar(_ cell: AnsiCell) -> Unicode.Scalar {
        cell.scalar ?? (cell.code == 0 ? " " : CP437.unicode[Int(cell.code)])
    }

    private static func sgr(_ color: RGB, base: Int, _ mode: ANSIColorMode) -> String {
        switch mode {
        case .trueColor:
            return "\(base);2;\(color.r);\(color.g);\(color.b)"
        case .xterm256:
            let index = Palette.xterm256.prefix(16).firstIndex(of: color) ?? nearestXterm(color)
            return "\(base);5;\(index)"
        }
    }
}
