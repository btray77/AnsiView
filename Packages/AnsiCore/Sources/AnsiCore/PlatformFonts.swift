/// Bitmap fonts for the home computer terminals, all original work drawn for AnsiView in code
/// (see docs/FONTS.md): letters come from `GlyphsBase`, block and line graphics are built from
/// geometry, so no ROM character set or third party font is copied. Each has the platform's
/// metrics and character coverage: PETSCII screen codes in both C64 sets, ATASCII, the teletext
/// SAA5050 repertoire with mosaics and double height, Apple II text and ISO 8859-1 for the Amiga.
public enum PlatformFonts {
    /// C64 screen codes 0-127 in the upper case and graphics set, then 128-255 in the lower and upper case set.
    public static let petscii = BitmapFont(name: "AnsiView PETSCII", width: 8, height: 8, glyphs: PETSCIIGlyphs.make())
    /// ATASCII 0-127 (inverse video is drawn by swapping colours).
    public static let atascii = BitmapFont(name: "AnsiView ATASCII", width: 8, height: 8, glyphs: ATASCIIGlyphs.make())
    /// Teletext alphanumerics, contiguous and separated mosaics, and their double height halves (`TeletextGlyphs`).
    public static let teletext = BitmapFont(name: "AnsiView Teletext", width: 12, height: 20, glyphs: TeletextGlyphs.make())
    /// Apple II text: ASCII 0-127, single stroke.
    public static let appleII = BitmapFont(name: "AnsiView Apple II", width: 8, height: 8, glyphs: appleIIGlyphs())
    /// An Amiga Topaz style font: ISO 8859-1, thick strokes.
    public static let topaz = BitmapFont(name: "AnsiView Topaz", width: 8, height: 8, glyphs: topazGlyphs())

    // MARK: Building blocks (8x8)

    typealias Glyph = [Bool]
    static let blank = Glyph(repeating: false, count: 64)

    /// A base character in an 8 pixel cell, one column in; thick doubles every stroke to the right.
    static func letter(_ c: Character, thick: Bool, shiftDown: Int = 0) -> Glyph {
        let rows = GlyphsBase.rows(c)
        var g = blank
        for y in 0..<8 {
            let sy = y - shiftDown
            guard sy >= 0, sy < 8 else { continue }
            for x in 0..<5 where rows[sy][x] {
                g[y * 8 + x + 1] = true
                if thick { g[y * 8 + x + 2] = true }
            }
        }
        return g
    }

    static func shape(_ test: (Int, Int) -> Bool) -> Glyph {
        (0..<64).map { test($0 % 8, $0 / 8) }
    }

    static func block(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> Glyph {
        shape { x, y in x >= x0 && x <= x1 && y >= y0 && y <= y1 }
    }

    static func union(_ glyphs: Glyph...) -> Glyph {
        (0..<64).map { i in glyphs.contains { $0[i] } }
    }

    static func hline(_ row: Int) -> Glyph { block(0, row, 7, row) }
    static func vline(_ column: Int) -> Glyph { block(column, 0, column, 7) }

    /// Box drawing with two pixel centre lines (rows 3-4, columns 3-4): which arms are drawn.
    static func box(up: Bool = false, down: Bool = false, left: Bool = false, right: Bool = false) -> Glyph {
        shape { x, y in
            let inRow = y == 3 || y == 4, inColumn = x == 3 || x == 4
            if inRow, inColumn { return true }
            if inRow, left, x < 3 { return true }
            if inRow, right, x > 4 { return true }
            if inColumn, up, y < 3 { return true }
            if inColumn, down, y > 4 { return true }
            return false
        }
    }

    static let checker = shape { x, y in (x + y) % 2 == 0 }

    /// A quarter circle arc of two pixel width joining two edges at the centre lines.
    static func arc(centerX: Double, centerY: Double) -> Glyph {
        shape { x, y in
            let d = ((Double(x) + 0.5 - centerX) * (Double(x) + 0.5 - centerX)
                     + (Double(y) + 0.5 - centerY) * (Double(y) + 0.5 - centerY)).squareRoot()
            return d >= 3.0 && d <= 4.9
        }
    }

    static func rotated180(_ g: Glyph) -> Glyph { (0..<64).map { g[63 - $0] } }

    // MARK: Apple II and Topaz

    static func appleIIGlyphs() -> [Glyph] {
        (0..<128).map { code in
            switch code {
            case 0x20...0x7E: return letter(Character(Unicode.Scalar(UInt8(code))), thick: false)
            case 0x7F: return checker
            default: return blank
            }
        }
    }

    /// Accents for ISO 8859-1 letters: two rows above lower case, one row above capitals.
    private static let accentRows: [Character: (lower: [String], upper: String)] = [
        "`": ([".#...", "..#.."], ".#..."),
        "'": (["...#.", "..#.."], "...#."),
        "^": (["..#..", ".#.#."], "..#.."),
        "~": ([".#..#", "#.##."], ".##.#"),
        ":": ([".....", ".#.#."], ".#.#."),
        "o": (["..#..", ".#.#."], "..#.."),
    ]

    private static let latin1Letters: [UInt32: (Character, Character)] = {
        // code: (base letter, accent)
        var table: [UInt32: (Character, Character)] = [:]
        let upper: [(UInt32, Character, Character)] = [
            (0xC0, "A", "`"), (0xC1, "A", "'"), (0xC2, "A", "^"), (0xC3, "A", "~"), (0xC4, "A", ":"), (0xC5, "A", "o"),
            (0xC8, "E", "`"), (0xC9, "E", "'"), (0xCA, "E", "^"), (0xCB, "E", ":"), (0xCC, "I", "`"), (0xCD, "I", "'"),
            (0xCE, "I", "^"), (0xCF, "I", ":"), (0xD1, "N", "~"), (0xD2, "O", "`"), (0xD3, "O", "'"), (0xD4, "O", "^"),
            (0xD5, "O", "~"), (0xD6, "O", ":"), (0xD9, "U", "`"), (0xDA, "U", "'"), (0xDB, "U", "^"), (0xDC, "U", ":"),
            (0xDD, "Y", "'"),
        ]
        for (code, base, accent) in upper {
            table[code] = (base, accent)
            if let lower = base.lowercased().first { table[code + 0x20] = (lower, accent) }
        }
        table[0xFF] = ("y", ":")
        return table
    }()

    /// Latin-1 signs drawn from a related ASCII glyph when they have no design of their own.
    private static let latin1Fallback: [UInt32: Character] = [
        0xA4: "*", 0xA6: "|", 0xA8: "\"", 0xAA: "a", 0xAD: "-", 0xAE: "R", 0xAF: "-", 0xB4: "'", 0xB5: "u", 0xB6: "P",
        0xB8: ",", 0xB9: "1", 0xB2: "2", 0xB3: "3", 0xBA: "o", 0xA9: "C", 0xAC: "-", 0xD0: "D", 0xF0: "d", 0xDE: "P",
        0xFE: "p", 0xA5: "Y", 0xA2: "c", 0xA7: "S", 0xC6: "E", 0xE6: "e", 0xD8: "0", 0xF8: "o", 0xDF: "B", 0xD7: "x",
        0xF7: "+", 0xAB: "<", 0xBB: ">", 0xBC: "/", 0xBD: "/", 0xBE: "/", 0xB0: "o", 0xB1: "+", 0xB7: ".",
    ]

    static func topazGlyphs() -> [Glyph] {
        (0..<256).map { code -> Glyph in
            let value = UInt32(code)
            switch code {
            case 0x20...0x7E: return letter(Character(Unicode.Scalar(UInt8(code))), thick: true)
            case 0xA1: return rotated180(letter("!", thick: true))
            case 0xBF: return rotated180(letter("?", thick: true))
            case 0xA3: return letter("£", thick: true)
            case 0xC7: return union(letter("C", thick: true), block(3, 7, 4, 7))
            case 0xE7: return union(letter("c", thick: true), block(3, 7, 4, 7))
            default:
                if let (base, accent) = latin1Letters[value], let marks = accentRows[accent] {
                    let isUpper = base.isUppercase
                    var g = letter(base, thick: true, shiftDown: isUpper ? 1 : 0)
                    if isUpper {
                        for y in 0..<1 { for x in 0..<8 { g[y * 8 + x] = false } }
                        for (x, ch) in marks.upper.enumerated() where ch == "#" { g[x + 1] = true; g[x + 2] = true }
                    } else {
                        for y in 0..<2 { for x in 0..<8 { g[y * 8 + x] = false } }
                        for (row, line) in marks.lower.enumerated() {
                            for (x, ch) in line.enumerated() where ch == "#" { g[row * 8 + x + 1] = true; g[row * 8 + x + 2] = true }
                        }
                    }
                    return g
                }
                if let fallback = latin1Fallback[value] { return letter(fallback, thick: true) }
                return blank
            }
        }
    }
}

/// C64 screen code glyphs (both character sets).
enum PETSCIIGlyphs {
    typealias Glyph = PlatformFonts.Glyph
    private typealias F = PlatformFonts

    /// Screen codes 0x40-0x7F of the upper case and graphics set.
    static func graphics(_ code: Int) -> Glyph {
        switch code {
        case 0x40: return F.box(left: true, right: true)
        case 0x41: return F.letter("♠", thick: true)
        case 0x42, 0x5D: return F.box(up: true, down: true)
        case 0x43: return F.hline(3)
        case 0x44: return F.hline(2)
        case 0x45: return F.hline(1)
        case 0x46: return F.hline(5)
        case 0x47: return F.vline(2)
        case 0x48: return F.vline(5)
        case 0x49: return F.arc(centerX: 0, centerY: 8)
        case 0x4A: return F.arc(centerX: 8, centerY: 0)
        case 0x4B: return F.arc(centerX: 0, centerY: 0)
        case 0x4C: return F.union(F.vline(0), F.hline(7))
        case 0x4D: return F.shape { x, y in x == y }
        case 0x4E: return F.shape { x, y in x + y == 7 }
        case 0x4F: return F.union(F.vline(0), F.hline(0))
        case 0x50: return F.union(F.vline(7), F.hline(0))
        case 0x51: return F.letter("●", thick: true)
        case 0x52: return F.hline(6)
        case 0x53: return F.letter("♥", thick: true)
        case 0x54: return F.vline(1)
        case 0x55: return F.arc(centerX: 8, centerY: 8)
        case 0x56: return F.shape { x, y in x == y || x + y == 7 }
        case 0x57: return F.letter("○", thick: true)
        case 0x58: return F.letter("♣", thick: true)
        case 0x59: return F.vline(6)
        case 0x5A: return F.letter("♦", thick: true)
        case 0x5B: return F.box(up: true, down: true, left: true, right: true)
        case 0x5C: return F.shape { x, y in x < 4 && (x + y) % 2 == 0 }
        case 0x5E: return F.letter("π", thick: true)
        case 0x5F: return F.shape { x, y in x >= y }
        case 0x60: return F.blank
        case 0x61: return F.block(0, 0, 3, 7)
        case 0x62: return F.block(0, 4, 7, 7)
        case 0x63: return F.hline(0)
        case 0x64: return F.hline(7)
        case 0x65: return F.vline(0)
        case 0x66: return F.checker
        case 0x67: return F.vline(7)
        case 0x68: return F.shape { x, y in y >= 4 && (x + y) % 2 == 0 }
        case 0x69: return F.shape { x, y in x + y <= 7 }
        case 0x6A: return F.block(6, 0, 7, 7)
        case 0x6B: return F.box(up: true, down: true, right: true)
        case 0x6C: return F.block(4, 4, 7, 7)
        case 0x6D: return F.box(up: true, right: true)
        case 0x6E: return F.box(down: true, left: true)
        case 0x6F: return F.block(0, 6, 7, 7)
        case 0x70: return F.box(down: true, right: true)
        case 0x71: return F.box(up: true, left: true, right: true)
        case 0x72: return F.box(down: true, left: true, right: true)
        case 0x73: return F.box(up: true, down: true, left: true)
        case 0x74: return F.block(0, 0, 1, 7)
        case 0x75: return F.block(0, 0, 2, 7)
        case 0x76: return F.block(5, 0, 7, 7)
        case 0x77: return F.block(0, 0, 7, 1)
        case 0x78: return F.block(0, 0, 7, 2)
        case 0x79: return F.block(0, 5, 7, 7)
        case 0x7A: return F.union(F.vline(7), F.hline(7))
        case 0x7B: return F.block(0, 4, 3, 7)
        case 0x7C: return F.block(4, 0, 7, 3)
        case 0x7D: return F.box(up: true, left: true)
        case 0x7E: return F.block(0, 0, 3, 3)
        case 0x7F: return F.union(F.block(0, 0, 3, 3), F.block(4, 4, 7, 7))
        default: return F.blank
        }
    }

    static func glyph(screenCode code: Int, lowerCaseSet: Bool) -> Glyph {
        switch code {
        case 0x00: return F.letter("@", thick: true)
        case 0x01...0x1A:
            let letter = Character(Unicode.Scalar(UInt8((lowerCaseSet ? 0x60 : 0x40) + code)))
            return F.letter(letter, thick: true)
        case 0x1B: return F.letter("[", thick: true)
        case 0x1C: return F.letter("£", thick: true)
        case 0x1D: return F.letter("]", thick: true)
        case 0x1E: return F.letter("↑", thick: true)
        case 0x1F: return F.letter("←", thick: true)
        case 0x20...0x3F: return F.letter(Character(Unicode.Scalar(UInt8(code))), thick: true)
        case 0x41...0x5A where lowerCaseSet: return F.letter(Character(Unicode.Scalar(UInt8(code))), thick: true)
        case 0x5E where lowerCaseSet: return F.shape { x, y in (x / 2 + y / 2) % 2 == 0 }
        case 0x5F where lowerCaseSet: return F.shape { x, y in (x - y + 8) % 4 < 2 }
        case 0x69 where lowerCaseSet: return F.shape { x, y in (x + y) % 4 < 2 }
        case 0x7A where lowerCaseSet: return F.letter("✓", thick: true)
        default: return graphics(code)
        }
    }

    static func make() -> [Glyph] {
        (0..<128).map { glyph(screenCode: $0, lowerCaseSet: false) } + (0..<128).map { glyph(screenCode: $0, lowerCaseSet: true) }
    }
}

/// ATASCII glyphs 0-127.
enum ATASCIIGlyphs {
    typealias Glyph = PlatformFonts.Glyph
    private typealias F = PlatformFonts

    static func glyph(_ code: Int) -> Glyph {
        switch code {
        case 0x00: return F.letter("♥", thick: true)
        case 0x01: return F.box(up: true, down: true, right: true)
        case 0x02: return F.block(6, 0, 7, 7)
        case 0x03: return F.box(up: true, left: true)
        case 0x04: return F.box(up: true, down: true, left: true)
        case 0x05: return F.box(down: true, left: true)
        case 0x06: return F.shape { x, y in x + y == 7 || x + y == 8 }
        case 0x07: return F.shape { x, y in x == y || x == y + 1 }
        case 0x08: return F.shape { x, y in x + y >= 7 }
        case 0x09: return F.block(4, 4, 7, 7)
        case 0x0A: return F.shape { x, y in x <= y }
        case 0x0B: return F.block(4, 0, 7, 3)
        case 0x0C: return F.block(0, 0, 3, 3)
        case 0x0D: return F.block(0, 0, 7, 1)
        case 0x0E: return F.block(0, 6, 7, 7)
        case 0x0F: return F.block(0, 4, 3, 7)
        case 0x10: return F.letter("♣", thick: true)
        case 0x11: return F.box(down: true, right: true)
        case 0x12: return F.box(left: true, right: true)
        case 0x13: return F.box(up: true, down: true, left: true, right: true)
        case 0x14: return F.letter("●", thick: true)
        case 0x15: return F.block(0, 4, 7, 7)
        case 0x16: return F.block(0, 0, 1, 7)
        case 0x17: return F.box(down: true, left: true, right: true)
        case 0x18: return F.box(up: true, left: true, right: true)
        case 0x19: return F.block(0, 0, 3, 7)
        case 0x1A: return F.box(up: true, right: true)
        case 0x1B: return F.union(F.block(1, 1, 6, 1), F.block(1, 1, 1, 6), F.block(1, 6, 6, 6), F.block(1, 3, 4, 3))
        case 0x1C: return F.letter("↑", thick: true)
        case 0x1D: return F.letter("↓", thick: true)
        case 0x1E: return F.letter("←", thick: true)
        case 0x1F: return F.letter("→", thick: true)
        case 0x60: return F.letter("♦", thick: true)
        case 0x7B: return F.letter("♠", thick: true)
        case 0x7D: return F.union(F.block(1, 1, 4, 2), F.block(1, 1, 2, 4), F.shape { x, y in x == y && x > 1 && x < 7 })
        case 0x7E: return F.shape { x, y in x >= 1 && x <= 6 && abs(y - 3) * 2 <= x - 1 && y < 7 }
        case 0x7F: return F.shape { x, y in x >= 1 && x <= 6 && abs(y - 3) * 2 <= 6 - x && y < 7 }
        case 0x20...0x7F: return F.letter(Character(Unicode.Scalar(UInt8(code))), thick: true)
        default: return F.blank
        }
    }

    static func make() -> [Glyph] { (0..<128).map(glyph) }
}

/// The teletext font: 12x20 cells, the SAA5050 layout (a 5x9 character doubled with diagonal
/// rounding), the UK set, 2x3 mosaics and double height halves.
public enum TeletextGlyphs {
    public static let count = 224 * 3

    /// An alphanumeric character 0x20-0x7F.
    public static func alpha(_ code: UInt8) -> Int { Int(min(0x7F, max(0x20, code))) - 0x20 }
    /// A mosaic character (0x20-0x3F, 0x60-0x7F).
    public static func mosaic(_ code: UInt8, separated: Bool) -> Int {
        let bits = Int(code & 0x1F) | (code & 0x40 != 0 ? 0x20 : 0)
        return 96 + (separated ? 64 : 0) + bits
    }
    public static func doubleTop(_ glyph: Int) -> Int { 224 + glyph }
    public static func doubleBottom(_ glyph: Int) -> Int { 448 + glyph }

    /// The UK teletext set where it differs from ASCII.
    private static let uk: [UInt8: [String]] = [
        0x23: GlyphsBase.ascii["£"]!,
        0x5B: GlyphsBase.ascii["←"]!,
        0x5C: ["#....", "#....", "#....", "#.##.", "...#.", "..#..", "...##", "....."],
        0x5D: GlyphsBase.ascii["→"]!,
        0x5E: GlyphsBase.ascii["↑"]!,
        0x5F: GlyphsBase.ascii["#"]!,
        0x60: [".....", ".....", ".....", "#####", ".....", ".....", ".....", "....."],
        0x7B: ["#....", "#....", "#....", "#..#.", "..##.", ".#.#.", "...#.", "....."],
        0x7C: [".#.#.", ".#.#.", ".#.#.", ".#.#.", ".#.#.", ".#.#.", ".#.#.", "....."],
        0x7D: ["##...", ".#...", "##...", "#..#.", "..##.", ".#.#.", "...#.", "....."],
        0x7E: [".....", "..#..", ".....", "#####", ".....", "..#..", ".....", "....."],
    ]

    static func source(_ code: UInt8) -> [[Bool]] {
        if code == 0x7F { return Array(repeating: Array(repeating: true, count: 5), count: 9) }
        let rows = uk[code].map { $0.map { $0.map { $0 == "#" } } }
            ?? GlyphsBase.rows(Character(Unicode.Scalar(code)))
        return rows + [Array(repeating: false, count: 5)]
    }

    /// Doubles a 5x9 character into the 12x20 cell with the SAA5050's diagonal rounding.
    static func rounded(_ s: [[Bool]]) -> [Bool] {
        var out = [Bool](repeating: false, count: 12 * 20)
        func px(_ x: Int, _ y: Int) -> Bool { y >= 0 && y < 9 && x >= 0 && x < 5 && s[y][x] }
        func set(_ x: Int, _ y: Int) {
            let ox = x + 1, oy = y + 1
            if ox >= 0, ox < 12, oy >= 0, oy < 20 { out[oy * 12 + ox] = true }
        }
        for y in 0..<9 {
            for x in 0..<5 {
                if px(x, y) { set(2 * x, 2 * y); set(2 * x + 1, 2 * y); set(2 * x, 2 * y + 1); set(2 * x + 1, 2 * y + 1) }
                // Diagonal joins get the half pixels the doubled grid lost.
                if px(x, y), px(x + 1, y + 1), !px(x + 1, y), !px(x, y + 1) { set(2 * x + 2, 2 * y + 1); set(2 * x + 1, 2 * y + 2) }
                if px(x + 1, y), px(x, y + 1), !px(x, y), !px(x + 1, y + 1) { set(2 * x + 1, 2 * y + 1); set(2 * x + 2, 2 * y + 2) }
            }
        }
        return out
    }

    static func mosaicGlyph(bits: Int, separated: Bool) -> [Bool] {
        let columns = [(0, 5), (6, 11)], rowsBands = [(0, 5), (6, 13), (14, 19)]
        var out = [Bool](repeating: false, count: 12 * 20)
        for band in 0..<3 {
            for side in 0..<2 where bits & (1 << (band * 2 + side)) != 0 {
                var (x0, x1) = columns[side], (y0, y1) = rowsBands[band]
                if separated { x0 += 2; y1 -= 2 }
                for y in y0...y1 { for x in x0...x1 { out[y * 12 + x] = true } }
            }
        }
        return out
    }

    static func make() -> [[Bool]] {
        var base: [[Bool]] = (0x20...0x7F).map { rounded(source(UInt8($0))) }
        base += (0..<64).map { mosaicGlyph(bits: $0, separated: false) }
        base += (0..<64).map { mosaicGlyph(bits: $0, separated: true) }
        func half(_ g: [Bool], top: Bool) -> [Bool] {
            (0..<(12 * 20)).map { i in
                let y = i / 12, x = i % 12
                return g[((top ? 0 : 10) + y / 2) * 12 + x]
            }
        }
        return base + base.map { half($0, top: true) } + base.map { half($0, top: false) }
    }
}
