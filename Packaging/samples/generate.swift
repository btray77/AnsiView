// Generates AnsiView's bundled sample art. Every byte comes from this script: the pictures, the
// 5x7 letter shapes and the XBin font are drawn here, so the samples are original and MIT licensed
// like the rest of AnsiView. The output is the same on every run.
//
//   swift Packaging/samples/generate.swift Samples
//
// Writes Welcome.ans, Rocket Launch.ans, Sunset 24-bit.ans and Custom Font.xb into the folder.
import Foundation

// MARK: Bytes

/// Encodes text for a CP437 file: ASCII stays as is, a few Unicode drawing characters map to
/// their CP437 codes.
func cp437(_ text: String) -> [UInt8] {
    let table: [Character: UInt8] = [
        "░": 0xB0, "▒": 0xB1, "▓": 0xB2, "│": 0xB3, "┤": 0xB4, "╗": 0xBB, "╝": 0xBC, "┐": 0xBF,
        "└": 0xC0, "┴": 0xC1, "┬": 0xC2, "├": 0xC3, "─": 0xC4, "┼": 0xC5, "╚": 0xC8, "╔": 0xC9,
        "═": 0xCD, "║": 0xBA, "┘": 0xD9, "┌": 0xDA, "█": 0xDB, "▄": 0xDC, "▌": 0xDD, "▐": 0xDE,
        "▀": 0xDF, "·": 0xFA, "∙": 0xF9, "■": 0xFE, "☼": 0x0F, "♦": 0x04, "▲": 0x1E, "°": 0xF8,
    ]
    return text.map { character in
        if let code = table[character] { return code }
        let value = character.unicodeScalars.first!.value
        precondition(value < 0x80, "no CP437 code for \(character)")
        return UInt8(value)
    }
}

func escape(_ text: String) -> [UInt8] { [0x1B] + Array("[\(text)".utf8) }

/// A SAUCE record (with comment block and end of file marker), as at https://www.acid.org/info/sauce/sauce.htm
func sauce(title: String, author: String, group: String, date: String, fileSize: Int,
           dataType: UInt8, fileType: UInt8, width: Int, height: Int, flags: UInt8,
           font: String, comments: [String]) -> [UInt8] {
    func field(_ text: String, _ length: Int, pad: UInt8 = 0x20) -> [UInt8] {
        let bytes = cp437(text)
        precondition(bytes.count <= length, "\(text) is longer than \(length)")
        return bytes + [UInt8](repeating: pad, count: length - bytes.count)
    }
    func word(_ value: Int) -> [UInt8] { [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF)] }
    var result: [UInt8] = [0x1A]
    if !comments.isEmpty {
        result += Array("COMNT".utf8)
        for line in comments { result += field(line, 64) }
    }
    result += Array("SAUCE00".utf8)
    result += field(title, 35) + field(author, 20) + field(group, 20) + field(date, 8)
    result += word(fileSize & 0xFFFF) + word(fileSize >> 16)
    result += [dataType, fileType] + word(width) + word(height) + word(0) + word(0)
    result += [UInt8(comments.count), flags] + field(font, 22, pad: 0)
    precondition(result.count == 1 + (comments.isEmpty ? 0 : 5 + 64 * comments.count) + 128)
    return result
}

let sampleDate = "20261030"
let sampleAuthor = "AnsiView"
let sampleGroup = "AnsiView Samples"

// MARK: A 5x7 letter set drawn for these samples

let letters: [Character: [String]] = [
    "A": [" ### ", "#   #", "#   #", "#####", "#   #", "#   #", "#   #"],
    "B": ["#### ", "#   #", "#   #", "#### ", "#   #", "#   #", "#### "],
    "C": [" ####", "#    ", "#    ", "#    ", "#    ", "#    ", " ####"],
    "D": ["#### ", "#   #", "#   #", "#   #", "#   #", "#   #", "#### "],
    "E": ["#####", "#    ", "#    ", "#### ", "#    ", "#    ", "#####"],
    "F": ["#####", "#    ", "#    ", "#### ", "#    ", "#    ", "#    "],
    "G": [" ####", "#    ", "#    ", "#  ##", "#   #", "#   #", " ### "],
    "H": ["#   #", "#   #", "#   #", "#####", "#   #", "#   #", "#   #"],
    "I": ["#####", "  #  ", "  #  ", "  #  ", "  #  ", "  #  ", "#####"],
    "J": ["  ###", "    #", "    #", "    #", "    #", "#   #", " ### "],
    "K": ["#   #", "#  # ", "# #  ", "##   ", "# #  ", "#  # ", "#   #"],
    "L": ["#    ", "#    ", "#    ", "#    ", "#    ", "#    ", "#####"],
    "M": ["#   #", "## ##", "# # #", "# # #", "#   #", "#   #", "#   #"],
    "N": ["#   #", "##  #", "# # #", "#  ##", "#   #", "#   #", "#   #"],
    "O": [" ### ", "#   #", "#   #", "#   #", "#   #", "#   #", " ### "],
    "P": ["#### ", "#   #", "#   #", "#### ", "#    ", "#    ", "#    "],
    "Q": [" ### ", "#   #", "#   #", "#   #", "# # #", "#  # ", " ## #"],
    "R": ["#### ", "#   #", "#   #", "#### ", "# #  ", "#  # ", "#   #"],
    "S": [" ####", "#    ", "#    ", " ### ", "    #", "    #", "#### "],
    "T": ["#####", "  #  ", "  #  ", "  #  ", "  #  ", "  #  ", "  #  "],
    "U": ["#   #", "#   #", "#   #", "#   #", "#   #", "#   #", " ### "],
    "V": ["#   #", "#   #", "#   #", "#   #", " # # ", " # # ", "  #  "],
    "W": ["#   #", "#   #", "#   #", "# # #", "# # #", "## ##", "#   #"],
    "X": ["#   #", " # # ", " # # ", "  #  ", " # # ", " # # ", "#   #"],
    "Y": ["#   #", " # # ", " # # ", "  #  ", "  #  ", "  #  ", "  #  "],
    "Z": ["#####", "    #", "   # ", "  #  ", " #   ", "#    ", "#####"],
    "0": [" ### ", "#  ##", "# # #", "# # #", "# # #", "##  #", " ### "],
    "1": ["  #  ", " ##  ", "  #  ", "  #  ", "  #  ", "  #  ", " ### "],
    "2": [" ### ", "#   #", "    #", "   # ", "  #  ", " #   ", "#####"],
    "3": ["#### ", "    #", "    #", " ### ", "    #", "    #", "#### "],
    "4": ["   # ", "  ## ", " # # ", "#  # ", "#####", "   # ", "   # "],
    "5": ["#####", "#    ", "#### ", "    #", "    #", "#   #", " ### "],
    "6": [" ### ", "#    ", "#    ", "#### ", "#   #", "#   #", " ### "],
    "7": ["#####", "    #", "   # ", "  #  ", "  #  ", "  #  ", "  #  "],
    "8": [" ### ", "#   #", "#   #", " ### ", "#   #", "#   #", " ### "],
    "9": [" ### ", "#   #", "#   #", " ####", "    #", "    #", " ### "],
    ".": ["     ", "     ", "     ", "     ", "     ", " ##  ", " ##  "],
    ",": ["     ", "     ", "     ", "     ", " ##  ", "  #  ", " #   "],
    ":": ["     ", " ##  ", " ##  ", "     ", " ##  ", " ##  ", "     "],
    "!": ["  #  ", "  #  ", "  #  ", "  #  ", "  #  ", "     ", "  #  "],
    "?": [" ### ", "#   #", "    #", "   # ", "  #  ", "     ", "  #  "],
    "-": ["     ", "     ", "     ", "#####", "     ", "     ", "     "],
    "'": ["  #  ", "  #  ", " #   ", "     ", "     ", "     ", "     "],
    "(": ["   # ", "  #  ", " #   ", " #   ", " #   ", "  #  ", "   # "],
    ")": [" #   ", "  #  ", "   # ", "   # ", "   # ", "  #  ", " #   "],
    "/": ["    #", "    #", "   # ", "  #  ", " #   ", "#    ", "#    "],
    "+": ["     ", "  #  ", "  #  ", "#####", "  #  ", "  #  ", "     "],
    "=": ["     ", "     ", "#####", "     ", "#####", "     ", "     "],
    ">": [" #   ", "  #  ", "   # ", "    #", "   # ", "  #  ", " #   "],
    "<": ["   # ", "  #  ", " #   ", "#    ", " #   ", "  #  ", "   # "],
    " ": ["     ", "     ", "     ", "     ", "     ", "     ", "     "],
]

func letterPixels(_ character: Character) -> [[Bool]] {
    let rows = letters[Character(character.uppercased())] ?? letters["?"]!
    return rows.map { row in row.map { $0 == "#" } }
}

// MARK: Welcome.ans (static ANSI with SAUCE)

/// An ANSI writer that only emits SGR codes when the colour changes.
struct ANSIWriter {
    var bytes: [UInt8] = []
    private var fg = -1, bg = -1

    /// Classic 16 colour attributes: fg 0 to 15, bg 0 to 7.
    mutating func color(_ newFG: Int, _ newBG: Int) {
        guard newFG != fg || newBG != bg else { return }
        bytes += escape("0;\(newFG >= 8 ? "1;" : "")\(30 + newFG % 8);\(40 + newBG)m")
        fg = newFG
        bg = newBG
    }

    mutating func rgb(fg top: (Int, Int, Int), bg bottom: (Int, Int, Int)) {
        bytes += escape("38;2;\(top.0);\(top.1);\(top.2);48;2;\(bottom.0);\(bottom.1);\(bottom.2)m")
    }

    mutating func text(_ text: String) { bytes += cp437(text) }
    mutating func raw(_ value: [UInt8]) { bytes += value }
    mutating func newline() {
        bytes += escape("0m") + [0x0D, 0x0A]
        fg = -1
        bg = -1
    }
    mutating func move(row: Int, column: Int) { bytes += escape("\(row);\(column)H") }
}

/// One cell of a 16 colour picture.
struct Cell: Equatable {
    var character: Character = " "
    var fg = 7
    var bg = 0
}

/// A cell grid written out row by row, with trailing default cells left off.
struct Canvas {
    let width: Int
    let height: Int
    var cells: [[Cell]]

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        cells = Array(repeating: Array(repeating: Cell(), count: width), count: height)
    }

    mutating func put(_ text: String, row: Int, column: Int, fg: Int, bg: Int? = nil) {
        for (offset, character) in text.enumerated() where column + offset < width && column + offset >= 0 {
            cells[row][column + offset] = Cell(character: character, fg: fg, bg: bg ?? cells[row][column + offset].bg)
        }
    }

    func ansi() -> [UInt8] {
        var writer = ANSIWriter()
        writer.raw(escape("0m") + escape("2J"))
        for row in cells {
            var last = row.count
            while last > 0, row[last - 1] == Cell() { last -= 1 }
            for cell in row.prefix(last) {
                writer.color(cell.fg, cell.bg)
                writer.text(String(cell.character))
            }
            writer.newline()
        }
        return writer.bytes
    }
}

/// Draws `text` in the 5x7 letters with half blocks (one cell is one pixel wide and two tall),
/// with a dark drop shadow one pixel down and right. Each pixel row gets its colour from `shade`.
func drawLogo(_ text: String, on canvas: inout Canvas, row: Int, column: Int,
              shade: (Int) -> Int, shadow: Int) {
    let width = text.count * 6
    var pixels = Array(repeating: Array(repeating: 0, count: width + 1), count: 8)  // 0 none, 1 shadow, 2 letter
    for (index, character) in text.enumerated() {
        for (y, line) in letterPixels(character).enumerated() {
            for (x, on) in line.enumerated() where on {
                pixels[y][index * 6 + x] = 2
                if pixels[y + 1][index * 6 + x + 1] == 0 { pixels[y + 1][index * 6 + x + 1] = 1 }
            }
        }
    }
    for cellRow in 0..<4 {
        for x in 0...width {
            let top = pixels[cellRow * 2][x], bottom = pixels[cellRow * 2 + 1][x]
            func color(_ kind: Int, _ y: Int) -> Int { kind == 2 ? shade(y) : shadow }
            var cell = Cell()
            switch (top, bottom) {
            case (0, 0): continue
            case (_, 0): cell = Cell(character: "▀", fg: color(top, cellRow * 2), bg: 0)
            case (0, _): cell = Cell(character: "▄", fg: color(bottom, cellRow * 2 + 1), bg: 0)
            case (2, 2): cell = Cell(character: "█", fg: shade(cellRow * 2), bg: 0)
            case (2, 1): cell = Cell(character: "▀", fg: shade(cellRow * 2), bg: shadow)
            case (1, 2): cell = Cell(character: "▄", fg: shade(cellRow * 2 + 1), bg: shadow)
            default: cell = Cell(character: " ", fg: 7, bg: shadow)
            }
            canvas.cells[row + cellRow][column + x] = cell
        }
    }
}

func welcome() -> [UInt8] {
    var canvas = Canvas(width: 80, height: 25)
    // Shaded bands top and bottom.
    let band = String(repeating: "░", count: 26) + String(repeating: "▒", count: 14) + String(repeating: "▓", count: 40)
    canvas.put(String(band.prefix(80)), row: 0, column: 0, fg: 4)
    canvas.put(String(band.reversed()), row: 24, column: 0, fg: 4)
    // The logo, a warm gradient from yellow to red with a blue shadow (ANSI colour order:
    // 1 red, 3 yellow, 4 blue; plus 8 for bright).
    let shades = [15, 11, 11, 3, 3, 9, 9, 1]
    drawLogo("ANSIVIEW", on: &canvas, row: 2, column: 16, shade: { shades[$0] }, shadow: 4)
    canvas.put("·  2 . 0  ·", row: 7, column: 34, fg: 8)
    // A double line box with the notes.
    let left = 6, right = 73, top = 9, bottom = 21
    for row in top...bottom {
        for column in left...right {
            let edge: Character
            switch (row, column) {
            case (top, left): edge = "╔"
            case (top, right): edge = "╗"
            case (bottom, left): edge = "╚"
            case (bottom, right): edge = "╝"
            case (top, _), (bottom, _): edge = "═"
            case (_, left), (_, right): edge = "║"
            default: edge = " "
            }
            canvas.cells[row][column] = Cell(character: edge, fg: edge == " " ? 7 : 12, bg: 0)
        }
    }
    let notes: [(String, Int)] = [
        ("Welcome to AnsiView.", 15),
        ("", 7),
        ("This sample, and the others under File > Open Sample, were", 7),
        ("drawn by a script in AnsiView's source code", 7),
        ("(Packaging/samples/generate.swift), so they are free to share.", 7),
        ("", 7),
        ("Things to try:", 11),
        ("  Get Info (Command I) shows this file's SAUCE record.", 7),
        ("  View > CRT Effect adds scanlines and glow.", 7),
        ("  Command 0, 1, 2 and 3 change the zoom.", 7),
    ]
    for (index, note) in notes.enumerated() {
        canvas.put(note.0, row: top + 1 + index, column: left + 3, fg: note.1)
    }
    canvas.put("■", row: top, column: left + 3, fg: 14)
    canvas.put(" samples ", row: top, column: left + 4, fg: 15)
    canvas.put("■", row: top, column: left + 13, fg: 14)
    let art = canvas.ansi()
    return art + sauce(title: "Welcome to AnsiView", author: sampleAuthor, group: sampleGroup, date: sampleDate,
                       fileSize: art.count, dataType: 1, fileType: 1, width: 80, height: 25,
                       flags: 0x02 /* 8 pixel letter spacing */, font: "IBM VGA",
                       comments: ["Original sample made by Packaging/samples/generate.swift.",
                                  "Free to share under AnsiView's MIT license."])
}

// MARK: Rocket Launch.ans (animated ANSI)

func rocketLaunch() -> [UInt8] {
    var writer = ANSIWriter()
    /// Bytes that change nothing on screen, to hold a frame at modem speed (2400 baud is 240 bytes a second).
    func pause(_ seconds: Double) {
        let pairs = Int(seconds * 240 / 6)
        for _ in 0..<pairs { writer.raw(escape("s") + escape("u")) }
    }
    func put(_ text: String, row: Int, column: Int, fg: Int, bg: Int = 0) {
        writer.move(row: row, column: column)
        writer.color(fg, bg)
        writer.text(text)
    }
    writer.raw(escape("0m") + escape("2J"))
    // Night sky: a fixed scatter of stars (a simple linear congruential sequence keeps it the same every run).
    var seed: UInt32 = 2026
    func next(_ bound: Int) -> Int {
        seed = seed &* 1_103_515_245 &+ 12345
        return Int((seed >> 16) % UInt32(bound))
    }
    for _ in 0..<70 {
        let row = 1 + next(17), column = 1 + next(80)
        put([".", "·", "∙", "*"][next(4)], row: row, column: column, fg: [8, 7, 15][next(3)])
    }
    // Ground and launch tower.
    put(String(repeating: "▄", count: 80), row: 23, column: 1, fg: 2)
    put(String(repeating: "▓", count: 80), row: 24, column: 1, fg: 2, bg: 0)
    put(String(repeating: "░", count: 79), row: 25, column: 1, fg: 6)
    for row in 12...22 { put("║", row: row, column: 30, fg: 8) }
    for row in stride(from: 13, through: 21, by: 2) { put("─", row: row, column: 31, fg: 8) }
    // The rocket: 5 rows, drawn bottom row at `base`.
    let rocket: [(String, Int)] = [("▲", 15), ("█", 7), ("█", 7), ("▄█▄", 12), ("▀ ▀", 4)]
    func drawRocket(base: Int, flame: Bool) {
        for (index, part) in rocket.enumerated() {
            let row = base - (rocket.count - 1 - index)
            guard row >= 1 else { continue }
            let column = part.0.count == 1 ? 34 : 33
            put(part.0, row: row, column: column, fg: part.1)
        }
        if flame, base + 1 <= 22 { put(" ▓ ", row: base + 1, column: 33, fg: 14) }
        if flame, base + 2 <= 22 { put(" ░ ", row: base + 2, column: 33, fg: 12) }
    }
    func eraseRocket(base: Int) {
        for offset in -4...2 where base + offset >= 1 && base + offset <= 22 {
            put("   ", row: base + offset, column: 33, fg: 7)
        }
    }
    drawRocket(base: 22, flame: false)
    put("T MINUS", row: 3, column: 55, fg: 11)
    // Countdown from 10, overwriting the same spot.
    for count in stride(from: 10, through: 1, by: -1) {
        put(String(format: "%2d", count), row: 5, column: 57, fg: count <= 3 ? 12 : 15)
        pause(0.8)
    }
    put("IGNITION", row: 5, column: 55, fg: 14)
    for _ in 0..<4 {
        put(" ▓ ", row: 23, column: 33, fg: 14, bg: 0)
        pause(0.15)
        put(" ░ ", row: 23, column: 33, fg: 12, bg: 0)
        pause(0.15)
    }
    put(String(repeating: "▄", count: 3), row: 23, column: 33, fg: 2)
    // Liftoff: the rocket climbs, leaving smoke behind.
    for base in stride(from: 21, through: 6, by: -1) {
        eraseRocket(base: base + 1)
        drawRocket(base: base, flame: true)
        if base + 3 <= 22 { put(" ▒ ", row: base + 3, column: 33, fg: 8) }
        pause(0.12)
    }
    put("        ", row: 5, column: 55, fg: 7)
    put("LIFTOFF!", row: 5, column: 55, fg: 10)
    put("an AnsiView sample", row: 7, column: 52, fg: 8)
    writer.move(row: 25, column: 80)
    writer.raw(escape("0m"))
    let art = writer.bytes
    return art + sauce(title: "Rocket Launch", author: sampleAuthor, group: sampleGroup, date: sampleDate,
                       fileSize: art.count, dataType: 1, fileType: 1, width: 80, height: 25,
                       flags: 0x02, font: "IBM VGA",
                       comments: ["An original animated sample: it draws itself at modem speed.",
                                  "Generated by Packaging/samples/generate.swift (MIT license)."])
}

// MARK: Sunset 24-bit.ans (24 bit colour)

func sunsetPixel(x: Int, y: Int) -> (Int, Int, Int) {
    // 80 x 50 pixels; horizon at row 30.
    func mix(_ a: (Double, Double, Double), _ b: (Double, Double, Double), _ t: Double) -> (Double, Double, Double) {
        let t = min(1, max(0, t))
        return (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t, a.2 + (b.2 - a.2) * t)
    }
    let horizon = 30
    let fx = Double(x) + 0.5, fy = Double(y) + 0.5
    var color: (Double, Double, Double)
    if y < horizon {
        // Sky: deep violet at the top to orange at the horizon.
        let t = fy / Double(horizon)
        color = t < 0.6 ? mix((28, 10, 60), (150, 40, 110), t / 0.6) : mix((150, 40, 110), (255, 150, 60), (t - 0.6) / 0.4)
        // The sun, with the stripes of a retro sunset across its lower half.
        let dx = (fx - 40) / 1.0, dy = (fy - 24) * 1.0
        let distance = (dx * dx + dy * dy).squareRoot()
        if distance < 11 {
            let striped = fy > 22 && Int(fy) % 3 == 0
            if !striped { color = mix((255, 240, 120), (255, 90, 80), (fy - 13) / 17) }
        } else if distance < 14 {
            color = mix(color, (255, 200, 120), (14 - distance) / 3 * 0.35)
        }
        // Mountains: two overlapping ridges.
        let ridge1 = 25 + 3 * sin(fx / 7) + 2 * sin(fx / 3.1)
        let ridge2 = 27.5 + 1.5 * sin(fx / 5 + 2)
        if fy > ridge2 { color = (40, 14, 50) } else if fy > ridge1 && (x < 22 || x > 58) { color = (62, 22, 70) }
    } else {
        // Sea: a darker reflection of the sky, with shimmer under the sun.
        let depth = (fy - Double(horizon)) / 20
        color = mix((200, 90, 90), (20, 10, 50), depth)
        let shimmerWidth = 9 - depth * 4
        if abs(fx - 40) < shimmerWidth, (y + x / 3) % 3 == 0 {
            color = mix(color, (255, 210, 120), 0.75 - depth * 0.4)
        }
    }
    return (Int(color.0.rounded()), Int(color.1.rounded()), Int(color.2.rounded()))
}

func sunset() -> [UInt8] {
    var writer = ANSIWriter()
    writer.raw(escape("0m") + escape("2J"))
    for row in 0..<25 {
        for x in 0..<80 {
            writer.rgb(fg: sunsetPixel(x: x, y: row * 2), bg: sunsetPixel(x: x, y: row * 2 + 1))
            writer.text("▀")
        }
        writer.newline()
    }
    let art = writer.bytes
    return art + sauce(title: "Sunset in 24-bit Colour", author: sampleAuthor, group: sampleGroup, date: sampleDate,
                       fileSize: art.count, dataType: 1, fileType: 1, width: 80, height: 25,
                       flags: 0x02, font: "IBM VGA",
                       comments: ["Half block pixels in 24 bit colour (ESC[38;2 and ESC[48;2).",
                                  "Generated by Packaging/samples/generate.swift (MIT license)."])
}

// MARK: Custom Font.xb (XBin with its own font and palette)

/// An 8x16 font drawn here: the 5x7 letters made bold and twice as tall, block and shade
/// characters, and a row of picture glyphs (codes 1 to 15).
func customFont() -> [UInt8] {
    var glyphs = [[UInt8]](repeating: [UInt8](repeating: 0, count: 16), count: 256)
    func set(_ code: Int, _ rows: [UInt8]) { glyphs[code] = rows }
    // Letters, digits and punctuation: bold (each pixel also fills its right neighbour), rows doubled.
    for (character, _) in letters {
        let pixels = letterPixels(character)
        var rows = [UInt8](repeating: 0, count: 16)
        for (y, line) in pixels.enumerated() {
            var bits: UInt8 = 0
            for (x, on) in line.enumerated() where on { bits |= 0x80 >> UInt8(x) | 0x40 >> UInt8(x) }
            rows[1 + y * 2] = bits
            rows[2 + y * 2] = bits
        }
        let code = Int(character.unicodeScalars.first!.value)
        set(code, rows)
        if character.isLetter { set(code + 32, rows) }  // lower case looks the same
    }
    // Blocks and shades keep their meaning so the picture parts work.
    set(0xDB, [UInt8](repeating: 0xFF, count: 16))
    set(0xDC, [UInt8](repeating: 0, count: 8) + [UInt8](repeating: 0xFF, count: 8))
    set(0xDF, [UInt8](repeating: 0xFF, count: 8) + [UInt8](repeating: 0, count: 8))
    set(0xDD, [UInt8](repeating: 0xF0, count: 16))
    set(0xDE, [UInt8](repeating: 0x0F, count: 16))
    set(0xB0, (0..<16).map { $0 % 2 == 0 ? 0x88 : 0x22 })
    set(0xB1, (0..<16).map { $0 % 2 == 0 ? 0xAA : 0x55 })
    set(0xB2, (0..<16).map { $0 % 2 == 0 ? 0x77 : 0xDD })
    // Picture glyphs: diamond, circle, heart, star, wave, stripes, checks, arrow, house, note,
    // sun, moon, tree, cross stitch, spiral.
    let pictures: [[String]] = [
        ["   ##   ", "  ####  ", " ###### ", "########", " ###### ", "  ####  ", "   ##   "],
        ["  ####  ", " #    # ", "#      #", "#      #", "#      #", " #    # ", "  ####  "],
        [" ##  ## ", "########", "########", " ###### ", "  ####  ", "   ##   ", "        "],
        ["   #    ", "   #    ", "#######.", "  ###   ", " ## ##  ", "##   ## ", "        "],
        ["        ", " ##     ", "#  #   #", "    ###  ", "        ", " ##     ", "#  #   #"],
        ["#   #   ", " #   #  ", "  #   # ", "   #   #", "#   #   ", " #   #  ", "  #   # "],
        ["## ## ##", "## ## ##", "  ##  ##", "##  ##  ", "## ## ##", "  ##  ##", "##  ##  "],
        ["   #    ", "    #   ", "########", "    #   ", "   #    ", "        ", "        "],
        ["   ##   ", "  #  #  ", " #    # ", "########", " # ## # ", " # ## # ", " ###### "],
        ["    ### ", "    # # ", "    #   ", "    #   ", "  ###   ", " ####   ", "  ##    "],
        ["# # # # ", " ##### ", "## # ## ", " ##### ", "# # # # ", "        ", "        "],
        ["  ###   ", " ##     ", "##      ", "##      ", "##      ", " ##     ", "  ###   "],
        ["   #    ", "  ###   ", " #####  ", "  ###   ", " #####  ", "#######", "   #    "],
        ["#  #  # ", " #   #  ", "  # #   ", "   #    ", "  # #   ", " #   #  ", "#  #  # "],
        [" #####  ", "#     # ", "# ### # ", "# # # # ", "#   # # ", "##### # ", "      # "],
    ]
    for (index, picture) in pictures.enumerated() {
        var rows = [UInt8](repeating: 0, count: 16)
        for (y, line) in picture.enumerated() {
            var bits: UInt8 = 0
            for (x, character) in line.prefix(8).enumerated() where character == "#" { bits |= 0x80 >> UInt8(x) }
            rows[1 + y * 2] = bits
            rows[2 + y * 2] = bits
        }
        set(1 + index, rows)
    }
    return glyphs.flatMap { $0 }
}

func customFontXBin() -> [UInt8] {
    let width = 80, height = 25
    // A palette of its own (6 bit VGA DAC values): night blues, sea greens, sunset warms.
    let palette: [(Int, Int, Int)] = [
        (0, 0, 6), (4, 8, 24), (6, 22, 30), (10, 34, 40), (20, 46, 52), (40, 58, 62), (63, 63, 58), (34, 38, 46),
        (16, 18, 26), (63, 52, 20), (63, 38, 18), (60, 22, 26), (44, 12, 40), (24, 10, 44), (30, 50, 20), (63, 63, 63),
    ]
    var cells = [(UInt8, UInt8)](repeating: (0x20, 0x00), count: width * height)
    func put(_ text: String, row: Int, column: Int, fg: Int, bg: Int) {
        for (offset, character) in text.enumerated() where column + offset < width {
            let code: UInt8 = character.isASCII ? UInt8(character.asciiValue!) : cp437(String(character))[0]
            cells[row * width + column + offset] = (code, UInt8(bg << 4 | fg))
        }
    }
    func putCode(_ code: UInt8, row: Int, column: Int, fg: Int, bg: Int) {
        cells[row * width + column] = (code, UInt8(bg << 4 | fg))
    }
    // Background: bands from the palette's dark blues down to sea green.
    for row in 0..<height {
        let bg = row < 4 ? 0 : row < 9 ? 1 : row < 15 ? 8 : row < 20 ? 2 : 3
        for column in 0..<width { putCode(0x20, row: row, column: column, fg: 15, bg: bg) }
    }
    // A shaded transition between bands.
    for column in 0..<width {
        putCode(0xB1, row: 4, column: column, fg: 1, bg: 0)
        putCode(0xB1, row: 9, column: column, fg: 8, bg: 1)
        putCode(0xB1, row: 15, column: column, fg: 2, bg: 8)
        putCode(0xB1, row: 20, column: column, fg: 3, bg: 2)
    }
    put("CUSTOM FONT", row: 2, column: 34, fg: 9, bg: 0)
    put("THIS XBIN FILE CARRIES ITS OWN FONT AND PALETTE.", row: 6, column: 16, fg: 15, bg: 1)
    put("EVERY GLYPH WAS DRAWN BY ANSIVIEW'S SAMPLE SCRIPT.", row: 7, column: 15, fg: 5, bg: 1)
    put("PICTURE GLYPHS:", row: 11, column: 8, fg: 9, bg: 8)
    for index in 0..<15 {
        putCode(UInt8(1 + index), row: 11, column: 26 + index * 3, fg: [9, 10, 11, 12, 14, 5, 4, 6, 15, 13, 9, 7, 14, 10, 6][index], bg: 8)
    }
    put("0123456789 ABCDEFGHIJKLMNOPQRSTUVWXYZ", row: 13, column: 8, fg: 6, bg: 8)
    put("BLOCKS:", row: 17, column: 8, fg: 15, bg: 2)
    for (index, code) in [UInt8(0xB0), 0xB1, 0xB2, 0xDB, 0xDC, 0xDF, 0xDD, 0xDE].enumerated() {
        putCode(code, row: 17, column: 17 + index * 2, fg: 9 + index % 4, bg: 2)
    }
    put("OPEN IT IN ANSIVIEW: FILE > OPEN SAMPLE", row: 22, column: 20, fg: 15, bg: 3)
    var bytes: [UInt8] = Array("XBIN".utf8) + [0x1A]
    bytes += [UInt8(width & 0xFF), UInt8(width >> 8), UInt8(height & 0xFF), UInt8(height >> 8), 16]
    bytes += [0x01 | 0x02 | 0x08]  // palette, font, non blink (16 backgrounds)
    for color in palette { bytes += [UInt8(color.0), UInt8(color.1), UInt8(color.2)] }
    bytes += customFont()
    for cell in cells { bytes += [cell.0, cell.1] }
    let art = bytes
    return art + sauce(title: "Custom Font", author: sampleAuthor, group: sampleGroup, date: sampleDate,
                       fileSize: art.count, dataType: 6, fileType: 0, width: width, height: height,
                       flags: 0, font: "",
                       comments: ["An XBin with an embedded 8x16 font and palette, drawn by",
                                  "Packaging/samples/generate.swift (MIT license)."])
}

// MARK: Main

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write("usage: swift generate.swift <output-folder>\n".data(using: .utf8)!)
    exit(2)
}
let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
let samples: [(String, [UInt8])] = [
    ("Welcome.ans", welcome()),
    ("Rocket Launch.ans", rocketLaunch()),
    ("Sunset 24-bit.ans", sunset()),
    ("Custom Font.xb", customFontXBin()),
]
for (name, bytes) in samples {
    try Data(bytes).write(to: folder.appendingPathComponent(name))
    print("\(name): \(bytes.count) bytes")
}
