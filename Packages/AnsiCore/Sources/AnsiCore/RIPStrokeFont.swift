/// RIPscrip's BGI stroke fonts (1 Triplex to 10 Bold), drawn with an original single stroke
/// alphabet made for AnsiView (no Borland .CHR data is used). Each font is that alphabet styled
/// (stroke weight, slant, doubling, width) and sized with the RIPscrip 1.54 font metric tables,
/// so labels and text blocks take the room a BBS laid out for them.
public enum RIPStrokeFont {
    /// Glyph coordinates: x 0-6, y 0 cap top, 3 x-height, 8 baseline, 11 descender bottom.
    /// Each glyph is strokes separated by spaces; each stroke is two character points ("xy"),
    /// digits 0-9 then a and b for 10 and 11.
    static let source: [Character: String] = [
        " ": "", "!": "0006 0708", "\"": "0002 2022", "#": "2028 4048 0363 0565",
        "$": "615010010314546567581807 3038", "%": "0860 0010110100 5767685857",
        "&": "681311203041420507183865", "'": "2022", "(": "302113152738", ")": "102133352718",
        "*": "3135 1155 1551", "+": "3236 0464", ",": "272819", "-": "0464", ".": "1718", "/": "0860",
        "0": "105061675818070110 6107", "1": "1130 3038 1858", "2": "01105061630868",
        "3": "01105061635424 546567581807", "4": "48400666", "5": "600004546567581807",
        "6": "50200207185867655404", "7": "006028", "8": "105061635414030110 1405071858676554",
        "9": "64140301105061664818", ":": "1213 1718", ";": "1213 171809", "<": "510457", "=": "0363 0565",
        ">": "116417", "?": "01105061633536 3738", "@": "4323254543 45566561501001071858",
        "A": "080220406268 0565", "B": "00085867655404 0040515344", "C": "6150100107185867",
        "D": "00084866624000", "E": "60000868 0444", "F": "600008 0444", "G": "61501001071858676434",
        "H": "0008 6068 0464", "I": "1050 3038 1858", "J": "606758180706", "K": "0008 6005 2368",
        "L": "000868", "M": "0800346068", "N": "08006860", "O": "105061675818070110",
        "P": "08005061635404", "Q": "105061675818070110 4668", "R": "08005061635404 3468",
        "S": "615010010314546567581807", "T": "0060 3038", "U": "000718586760", "V": "003860",
        "W": "0018345860", "X": "0068 6008", "Y": "003460 3438", "Z": "00600868", "[": "30101838",
        "\\": "0068", "]": "10303818", "^": "123052", "_": "0969", "`": "1021",
        "a": "13536468 65150607185867", "b": "0008 0413536467581807", "c": "6453130407185867",
        "d": "6068 6453130407185867", "e": "05656453130407185867", "f": "50302128 0343",
        "g": "636a5b1b0a 6453130406175766", "h": "0008 0413536468", "i": "3338 31",
        "j": "434a3b1b0a 41", "k": "0008 5306 2558", "l": "202738", "m": "0803 0413233438 3443536468",
        "n": "0803 0413536468", "o": "135364675818070413", "p": "030b 0413536467581807",
        "q": "636b 6453130407185867", "r": "0308 05235364", "s": "64531304155667581807",
        "t": "20273858 0343", "u": "0307185867 6368", "v": "033863", "w": "0318355863", "x": "0368 6308",
        "y": "0338 631b", "z": "03630868", "{": "403021231425273848", "|": "3038",
        "}": "203041435445473828", "~": "041323455564",
    ]

    /// Strokes of a character in glyph units; unknown characters draw as "?".
    public static func strokes(for byte: UInt8) -> [[(x: Int, y: Int)]] {
        if let cached = table[Int(byte & 0x7F)] { return cached }
        return table[Int(UInt8(ascii: "?"))] ?? []
    }

    /// Advance in glyph units (the widest point plus one unit of space).
    public static func advance(for byte: UInt8) -> Int {
        let points = strokes(for: byte).flatMap { $0 }
        if byte == 0x20 { return 5 }
        return (points.map(\.x).max() ?? 3) + 2
    }

    private static let table: [[[(x: Int, y: Int)]]?] = {
        var out = [[[(x: Int, y: Int)]]?](repeating: nil, count: 128)
        func value(_ c: Character) -> Int { c.isNumber ? Int(String(c))! : (c == "a" ? 10 : 11) }
        for (character, text) in source {
            let strokes: [[(x: Int, y: Int)]] = text.split(separator: " ").map { stroke in
                let chars = Array(stroke)
                return stride(from: 0, to: chars.count - 1, by: 2).map { (value(chars[$0]), value(chars[$0 + 1])) }
            }
            out[Int(character.asciiValue!)] = strokes
        }
        return out
    }()

    /// RIPscrip 1.54 font metrics (top, base, drop: scan lines from the top of the cell) for fonts
    /// 1 to 10, sizes 1 to 10.
    static let metricTable: [[(top: Int, base: Int, drop: Int)]] = [
        [(6, 18, 22), (6, 20, 24), (8, 23, 28), (10, 31, 38), (13, 41, 50), (16, 51, 62), (20, 62, 76), (25, 77, 94), (30, 93, 114), (40, 124, 152)],
        [(2, 5, 6), (2, 6, 7), (2, 6, 7), (3, 9, 11), (4, 12, 14), (5, 15, 18), (6, 13, 22), (7, 22, 27), (9, 27, 33), (12, 36, 44)],
        [(7, 19, 23), (7, 21, 25), (9, 24, 29), (11, 32, 39), (14, 42, 51), (18, 53, 64), (22, 64, 78), (28, 80, 97), (33, 96, 117), (74, 158, 186)],
        [(7, 19, 23), (7, 21, 25), (9, 24, 29), (11, 32, 39), (14, 42, 51), (18, 53, 64), (22, 64, 78), (28, 80, 97), (33, 96, 117), (44, 128, 156)],
        [(10, 22, 29), (10, 24, 32), (12, 27, 36), (16, 37, 49), (21, 49, 65), (26, 61, 80), (32, 74, 98), (40, 92, 122), (48, 111, 147), (63, 147, 195)],
        [(9, 21, 25), (9, 23, 27), (11, 26, 31), (14, 35, 42), (18, 46, 56), (23, 58, 69), (28, 70, 84), (35, 87, 104), (42, 105, 126), (56, 140, 168)],
        [(5, 17, 21), (5, 19, 23), (7, 22, 27), (9, 30, 37), (12, 40, 49), (15, 50, 61), (19, 61, 75), (24, 77, 93), (29, 92, 113), (39, 123, 151)],
        [(8, 20, 24), (8, 22, 26), (10, 25, 30), (13, 34, 41), (17, 45, 54), (22, 57, 68), (27, 69, 83), (34, 86, 103), (41, 104, 125), (54, 139, 167)],
        [(7, 32, 38), (7, 35, 41), (9, 40, 47), (12, 54, 64), (16, 72, 85), (20, 96, 106), (25, 109, 129), (31, 136, 161), (38, 164, 194), (51, 219, 259)],
        [(11, 35, 39), (13, 39, 43), (14, 44, 49), (19, 59, 66), (27, 79, 88), (33, 99, 110), (39, 119, 133), (49, 149, 166), (59, 179, 200), (79, 239, 267)],
    ]

    /// The metric row for a stroke font (1-10) and size (1-10), clamped.
    public static func metrics(font: Int, size: Int) -> (top: Int, base: Int, drop: Int) {
        metricTable[max(1, min(10, font)) - 1][max(1, min(10, size)) - 1]
    }

    /// How a font draws the shared alphabet.
    struct Style {
        var weight: Double   // brush size as a fraction of a glyph unit
        var slant: Double    // x shift per unit of height above the baseline
        var double: Bool     // a second stroke one pixel to the right
        var narrow: Double   // horizontal scale
    }

    static func style(font: Int) -> Style {
        switch font {
        case 1: return Style(weight: 0.6, slant: 0, double: false, narrow: 1)       // Triplex
        case 2: return Style(weight: 0, slant: 0, double: false, narrow: 0.9)       // Small
        case 3: return Style(weight: 0.35, slant: 0, double: false, narrow: 1)      // Sans Serif
        case 4: return Style(weight: 0.3, slant: 0, double: true, narrow: 1)        // Gothic
        case 5: return Style(weight: 0.15, slant: 0.3, double: false, narrow: 1)    // Script
        case 6: return Style(weight: 0, slant: 0, double: false, narrow: 1)         // Simplex
        case 7: return Style(weight: 0.6, slant: 0.25, double: false, narrow: 1)    // Triplex Script
        case 8: return Style(weight: 0.2, slant: 0, double: true, narrow: 1)        // Complex
        case 9: return Style(weight: 0.2, slant: 0, double: false, narrow: 0.75)    // European
        default: return Style(weight: 1.1, slant: 0, double: false, narrow: 1.1)    // Bold
        }
    }
}
