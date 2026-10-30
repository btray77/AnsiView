import Foundation

/// Text art fonts made for AnsiView (plan ruling 14). They are original work: a square pixel
/// alphabet drawn for AnsiView in this file, turned by code into a TheDraw outline font, block
/// font and colour font, and a FIGlet font. No third party font was used or copied.
public enum OriginalFonts {
    /// The pixel alphabet: `#` is a pixel. Five rows; widths vary.
    static let alphabetSource: [(Character, [String])] = [
        ("A", [".##.", "#..#", "####", "#..#", "#..#"]),
        ("B", ["###.", "#..#", "###.", "#..#", "###."]),
        ("C", [".###", "#...", "#...", "#...", ".###"]),
        ("D", ["###.", "#..#", "#..#", "#..#", "###."]),
        ("E", ["####", "#...", "###.", "#...", "####"]),
        ("F", ["####", "#...", "###.", "#...", "#..."]),
        ("G", [".###", "#...", "#.##", "#..#", ".###"]),
        ("H", ["#..#", "#..#", "####", "#..#", "#..#"]),
        ("I", ["###", ".#.", ".#.", ".#.", "###"]),
        ("J", ["...#", "...#", "...#", "#..#", ".##."]),
        ("K", ["#..#", "#.#.", "##..", "#.#.", "#..#"]),
        ("L", ["#...", "#...", "#...", "#...", "####"]),
        ("M", ["#...#", "##.##", "#.#.#", "#...#", "#...#"]),
        ("N", ["#..#", "##.#", "#.##", "#..#", "#..#"]),
        ("O", [".##.", "#..#", "#..#", "#..#", ".##."]),
        ("P", ["###.", "#..#", "###.", "#...", "#..."]),
        ("Q", [".##.", "#..#", "#..#", "#.##", ".###"]),
        ("R", ["###.", "#..#", "###.", "#.#.", "#..#"]),
        ("S", [".###", "#...", ".##.", "...#", "###."]),
        ("T", ["#####", "..#..", "..#..", "..#..", "..#.."]),
        ("U", ["#..#", "#..#", "#..#", "#..#", ".##."]),
        ("V", ["#...#", "#...#", "#...#", ".#.#.", "..#.."]),
        ("W", ["#...#", "#...#", "#.#.#", "##.##", "#...#"]),
        ("X", ["#...#", ".#.#.", "..#..", ".#.#.", "#...#"]),
        ("Y", ["#...#", ".#.#.", "..#..", "..#..", "..#.."]),
        ("Z", ["####", "...#", ".##.", "#...", "####"]),
        ("0", [".##.", "#.##", "#..#", "##.#", ".##."]),
        ("1", [".#.", "##.", ".#.", ".#.", "###"]),
        ("2", ["###.", "...#", ".##.", "#...", "####"]),
        ("3", ["###.", "...#", ".##.", "...#", "###."]),
        ("4", ["#..#", "#..#", "####", "...#", "...#"]),
        ("5", ["####", "#...", "###.", "...#", "###."]),
        ("6", [".##.", "#...", "###.", "#..#", ".##."]),
        ("7", ["####", "...#", "..#.", ".#..", ".#.."]),
        ("8", [".##.", "#..#", ".##.", "#..#", ".##."]),
        ("9", [".##.", "#..#", ".###", "...#", ".##."]),
        ("!", ["#", "#", "#", ".", "#"]),
        ("?", ["###.", "...#", ".##.", "....", ".#.."]),
        (".", [".", ".", ".", ".", "#"]),
        (",", ["..", "..", "..", ".#", "#."]),
        ("-", ["...", "...", "###", "...", "..."]),
        (":", [".", "#", ".", "#", "."]),
        ("'", ["#", "#", ".", ".", "."]),
        ("\"", ["#.#", "#.#", "...", "...", "..."]),
        ("(", [".#", "#.", "#.", "#.", ".#"]),
        (")", ["#.", ".#", ".#", ".#", "#."]),
        ("/", ["..#", "..#", ".#.", "#..", "#.."]),
        ("+", ["...", ".#.", "###", ".#.", "..."]),
        ("=", ["...", "###", "...", "###", "..."]),
        ("_", ["...", "...", "...", "...", "###"]),
        ("#", [".#.#.", "#####", ".#.#.", "#####", ".#.#."]),
        ("*", ["#.#", ".#.", "#.#", "...", "..."]),
    ]

    /// The alphabet as pixel grids.
    public static let alphabet: [(Character, [[Bool]])] = alphabetSource.map { ch, rows in
        (ch, rows.map { $0.map { $0 == "#" } })
    }

    /// Fills one empty pixel of every 2 x 2 window whose pixels touch only at a corner, so a
    /// traced contour never has to cross itself (the outline styles have no crossing piece).
    static func closeDiagonals(_ bitmap: [[Bool]]) -> [[Bool]] {
        var grid = bitmap
        var changed = true
        while changed {
            changed = false
            for y in 0..<max(0, grid.count - 1) {
                for x in 0..<max(0, (grid[y].count) - 1) {
                    let a = grid[y][x], b = grid[y][x + 1], c = grid[y + 1][x], d = grid[y + 1][x + 1]
                    if a && d && !b && !c { grid[y + 1][x] = true; changed = true }
                    if b && c && !a && !d { grid[y + 1][x + 1] = true; changed = true }
                }
            }
        }
        return grid
    }

    static func scaledHorizontally(_ bitmap: [[Bool]], by factor: Int) -> [[Bool]] {
        bitmap.map { row in row.flatMap { Array(repeating: $0, count: factor) } }
    }

    /// The contour letters (TheDraw outline placeholders) around a bitmap: one character per
    /// pixel corner, so the result is one column and one row larger than the bitmap.
    /// A top edge, B bottom edge, C left edge, D right edge, E to L corners, O inside, @ outside.
    static func contour(_ bitmap: [[Bool]]) -> [[UInt8]] {
        let h = bitmap.count, w = bitmap.first?.count ?? 0
        func at(_ x: Int, _ y: Int) -> Bool { y >= 0 && y < h && x >= 0 && x < w && bitmap[y][x] }
        var rows: [[UInt8]] = []
        for y in 0...h {
            var row: [UInt8] = []
            for x in 0...w {
                let ul = at(x - 1, y - 1), ur = at(x, y - 1), dl = at(x - 1, y), dr = at(x, y)
                let letter: Character
                switch (ul, ur, dl, dr) {
                case (false, false, false, false): letter = "@"
                case (true, true, true, true): letter = "O"
                case (false, false, false, true): letter = "E"
                case (false, false, true, false): letter = "F"
                case (false, true, false, false): letter = "K"
                case (true, false, false, false): letter = "L"
                case (false, false, true, true): letter = "A"
                case (true, true, false, false): letter = "B"
                case (false, true, false, true): letter = "C"
                case (true, false, true, false): letter = "D"
                case (false, true, true, true): letter = "J"
                case (true, false, true, true): letter = "I"
                case (true, true, false, true): letter = "H"
                case (true, true, true, false): letter = "G"
                default: letter = "O" // a diagonal; closeDiagonals removes them first
                }
                row.append(letter.asciiValue!)
            }
            // Trailing outside cells end the row (TheDraw leaves them transparent).
            while row.last == UInt8(ascii: "@") { row.removeLast() }
            rows.append(row)
        }
        return rows
    }

    // MARK: The fonts

    static func outlineFont() -> TDFFont {
        var glyphs: [UInt8: TDFGlyph] = [:]
        for (ch, bitmap) in alphabet {
            let rows = contour(closeDiagonals(scaledHorizontally(bitmap, by: 2)))
            glyphs[ch.asciiValue!] = TDFGlyph(rows: rows.map { TDFRow(cells: $0.map { TDFCell(code: $0) }) })
        }
        return TDFFont(name: "AV Outline", type: .outline, spacing: 1, glyphs: glyphs)
    }

    static func blockFont() -> TDFFont {
        var glyphs: [UInt8: TDFGlyph] = [:]
        for (ch, bitmap) in alphabet {
            let w = bitmap.first?.count ?? 0
            var rows: [TDFRow] = []
            for pair in stride(from: 0, to: bitmap.count, by: 2) {
                let cells = (0..<w).map { x -> TDFCell in
                    let top = bitmap[pair][x], bottom = pair + 1 < bitmap.count && bitmap[pair + 1][x]
                    let code: UInt8 = top && bottom ? 219 : top ? 223 : bottom ? 220 : 0x20
                    return TDFCell(code: code)
                }
                rows.append(TDFRow(cells: cells))
            }
            glyphs[ch.asciiValue!] = TDFGlyph(rows: rows)
        }
        return TDFFont(name: "AV Block", type: .block, spacing: 1, glyphs: glyphs)
    }

    /// Yellow to red fire from the top row down, with a dark grey shadow down and right.
    static func colorFont() -> TDFFont {
        let rowColors: [UInt8] = [0x0F, 0x0E, 0x0E, 0x0C, 0x04]
        var glyphs: [UInt8: TDFGlyph] = [:]
        for (ch, bitmap) in alphabet {
            let h = bitmap.count, w = bitmap.first?.count ?? 0
            func at(_ x: Int, _ y: Int) -> Bool { y >= 0 && y < h && x >= 0 && x < w && bitmap[y][x] }
            var rows: [TDFRow] = []
            for y in 0...h {
                var cells: [TDFCell] = []
                for x in 0...w {
                    if at(x, y) {
                        cells.append(TDFCell(code: 219, attribute: rowColors[y]))
                    } else if at(x - 1, y - 1) {
                        cells.append(TDFCell(code: 177, attribute: 0x08))
                    } else {
                        cells.append(TDFCell(code: 0x20, attribute: 0x07))
                    }
                }
                while let last = cells.last, last.code == 0x20 { cells.removeLast() }
                rows.append(TDFRow(cells: cells))
            }
            glyphs[ch.asciiValue!] = TDFGlyph(rows: rows)
        }
        return TDFFont(name: "AV Ember", type: .color, spacing: 1, glyphs: glyphs)
    }

    /// AV Outline (type 0), AV Block (type 1), AV Ember (type 2).
    public static let tdfFonts: [TDFFont] = [outlineFont(), blockFont(), colorFont()]

    /// The TheDraw file holding the three, for export.
    public static var tdfData: Data { (try? TDFFile.write(tdfFonts)) ?? Data() }

    /// "AV Contour": a FIGlet font tracing the same alphabet with ASCII, smushing rules 1 to 5.
    public static let figletData: Data = {
        let symbols: [Character: Character] = [
            "@": " ", "O": " ", "A": "-", "B": "-", "C": "|", "D": "|",
            "E": ".", "F": ".", "G": ".", "H": ".", "I": "'", "J": "'", "K": "'", "L": "'",
        ]
        var glyphRows: [Character: [String]] = [:]
        for (ch, bitmap) in alphabet {
            let rows = contour(closeDiagonals(scaledHorizontally(bitmap, by: 2)))
            let width = rows.map(\.count).max() ?? 0
            glyphRows[ch] = rows.map { row in
                String(row.map { symbols[Character(Unicode.Scalar($0))] ?? " " }) + String(repeating: " ", count: width - row.count)
            }
        }
        let height = 6
        // Full layout: smushing (128) with rules 1, 2, 4, 8 and 16, plus vertical fitting (8192).
        var lines = ["flf2a$ \(height) \(height) 12 31 3 0 \(128 + 31 + 8192) 0",
                     "AV Contour: an original FIGlet font made for AnsiView.",
                     "Traces AnsiView's own square pixel alphabet; free to use with AnsiView art.",
                     "Lower case uses the upper case letters."]
        func add(_ rows: [String]) {
            for (index, row) in rows.enumerated() { lines.append(row + (index == rows.count - 1 ? "@@" : "@")) }
        }
        for code in 32...126 {
            let ch = Character(Unicode.Scalar(UInt8(code)))
            if code == 32 {
                add(Array(repeating: "$$$", count: height))
            } else if let rows = glyphRows[ch] ?? glyphRows[Character(ch.uppercased())] {
                add(rows)
            } else {
                add(Array(repeating: "", count: height))
            }
        }
        for _ in FIGletFont.deutsch { add(Array(repeating: "", count: height)) }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }()

    public static var figletFont: FIGletFont? { try? FIGletFont.parse(figletData, name: "AV Contour") }
}
