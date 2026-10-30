import Foundation

// FIGlet fonts (.flf, and TOIlet .tlf read the same way): "The FIGfont Version 2 FIGfont and
// FIGdriver Standard" (Cowan and Burton). Horizontal fitting and smushing follow figlet 2.2.5's
// smushamt and smushem exactly (its reference output is in the tests). Rulings 12 and 13 of
// docs/superpowers/plans/2026-10-30-ansiview-2.0-fonts.md.

/// How a FIGlet font's characters (or lines) are put together.
public enum FIGletMode: Equatable {
    /// Each character at its full width (figlet -W).
    case fullWidth
    /// Moved together until they touch (figlet -k, "kerning").
    case fitting
    /// Moved one step further where a rule merges the touching characters; rules 0 is
    /// universal smushing (figlet -o).
    case smushing(rules: Int)
}

/// The layout a user picks; `fontDefault` uses the font's own.
public enum FIGletLayout: String, CaseIterable, Codable {
    case fontDefault, fullWidth, fitting, smushing, universal

    public var label: String {
        switch self {
        case .fontDefault: return "Font default"
        case .fullWidth: return "Full width"
        case .fitting: return "Fitted"
        case .smushing: return "Smushed"
        case .universal: return "Universal smush"
        }
    }

    func mode(fontMode: FIGletMode, fontRules: Int) -> FIGletMode {
        switch self {
        case .fontDefault: return fontMode
        case .fullWidth: return .fullWidth
        case .fitting: return .fitting
        case .smushing: return .smushing(rules: fontRules)
        case .universal: return .smushing(rules: 0)
        }
    }
}

public enum FIGletError: LocalizedError, Equatable {
    case notFIGlet, badHeader, noCharacters, tooLarge

    public var errorDescription: String? {
        switch self {
        case .notFIGlet: return "This file is not a FIGlet font (.flf)."
        case .badHeader: return "This FIGlet font's first line is damaged."
        case .noCharacters: return "This FIGlet font has no characters in it."
        case .tooLarge: return "This FIGlet font is larger than 4 MB, which no FIGlet font is."
        }
    }
}

public struct FIGletFont: Equatable {
    public static let maxFileSize = 4 << 20
    public static let maxHeight = 64
    public static let maxCharacters = 4096
    static let deutsch = [196, 214, 220, 228, 246, 252, 223]

    public var name: String
    public var hardblank: Unicode.Scalar
    public var height: Int
    public var baseline: Int
    public var oldLayout: Int
    public var fullLayout: Int?
    /// 0 left to right, 1 right to left.
    public var printDirection: Int
    public var comments: [String]
    /// Rows of each character, keyed by its code (Unicode for code tagged characters).
    public var glyphs: [Int: [[Unicode.Scalar]]]

    /// The font's horizontal layout (ruling 13).
    public var horizontalMode: FIGletMode {
        if let full = fullLayout {
            if full & 128 != 0 { return .smushing(rules: full & 63) }
            if full & 64 != 0 { return .fitting }
            return .fullWidth
        }
        if oldLayout < 0 { return .fullWidth }
        if oldLayout == 0 { return .fitting }
        return .smushing(rules: oldLayout & 63)
    }

    /// The horizontal rules a forced smush uses.
    public var horizontalRules: Int {
        if let full = fullLayout { return full & 63 }
        return oldLayout > 0 ? oldLayout & 63 : 0
    }

    /// The font's vertical layout; rules are bits 8 to 12 shifted down (1 equal, 2 underscore,
    /// 4 hierarchy, 8 horizontal line, 16 vertical line).
    public var verticalMode: FIGletMode {
        guard let full = fullLayout else { return .fullWidth }
        if full & 16384 != 0 { return .smushing(rules: (full >> 8) & 31) }
        if full & 8192 != 0 { return .fitting }
        return .fullWidth
    }

    public var verticalRules: Int { ((fullLayout ?? 0) >> 8) & 31 }

    /// FIGlet fonts bundled with AnsiView (the FIGlet 2.2.5 distribution, New BSD).
    public static var bundledURLs: [URL] {
        (Bundle.module.urls(forResourcesWithExtension: "flf", subdirectory: "FIGlet") ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    public static func isFIGlet(_ data: Data) -> Bool {
        let head = [UInt8](data.prefix(5))
        return head == Array("flf2a".utf8) || head == Array("tlf2a".utf8)
    }

    // MARK: Parsing (ruling 12)

    public static func parse(_ data: Data, name: String) throws -> FIGletFont {
        guard data.count <= maxFileSize else { throw FIGletError.tooLarge }
        guard isFIGlet(data) else { throw FIGletError.notFIGlet }
        let utf8 = data.prefix(1) == Data("t".utf8)
        // flf files are ISO Latin-1 (one byte, one character); tlf files are UTF-8.
        let scalars: [Unicode.Scalar] = utf8
            ? Array(String(decoding: data, as: UTF8.self).unicodeScalars)
            : data.map { Unicode.Scalar($0) }
        var lines: [[Unicode.Scalar]] = []
        var current: [Unicode.Scalar] = []
        var index = 0
        while index < scalars.count {
            let s = scalars[index]
            index += 1
            if s == "\n" || s == "\r" {
                if s == "\r", index < scalars.count, scalars[index] == "\n" { index += 1 }
                lines.append(current)
                current = []
            } else {
                current.append(s)
            }
        }
        if !current.isEmpty { lines.append(current) }

        guard let header = lines.first, header.count >= 6 else { throw FIGletError.badHeader }
        let hardblank = header[5]
        let fields = String(String.UnicodeScalarView(header.dropFirst(6))).split(separator: " ").map { Int($0) }
        guard fields.count >= 4, let height = fields[0], let baseline = fields[1], let old = fields[3],
              (1...maxHeight).contains(height) else { throw FIGletError.badHeader }
        let commentCount = fields.count > 4 ? (fields[4] ?? 0) : 0
        let direction = fields.count > 5 ? (fields[5] ?? 0) : 0
        let full = fields.count > 6 ? fields[6] : nil
        guard commentCount >= 0 else { throw FIGletError.badHeader }

        var font = FIGletFont(name: name, hardblank: hardblank, height: height, baseline: baseline,
                              oldLayout: old, fullLayout: full, printDirection: direction, comments: [], glyphs: [:])
        var line = 1
        font.comments = lines.dropFirst(1).prefix(commentCount).map { String(String.UnicodeScalarView($0)) }
        line += min(commentCount, max(0, lines.count - 1))

        /// Reads one character's rows; nil when the file ends first.
        func readCharacter() -> [[Unicode.Scalar]]? {
            guard line + height <= lines.count else { return nil }
            var rows: [[Unicode.Scalar]] = []
            for offset in 0..<height {
                var row = lines[line + offset]
                // figlet: drop trailing blanks, then the end mark and its repeats.
                while let last = row.last, last == " " { row.removeLast() }
                if let mark = row.last { while row.last == mark { row.removeLast() } }
                rows.append(row)
            }
            line += height
            return rows
        }

        let required = Array(32...126) + deutsch
        for code in required {
            guard let rows = readCharacter() else { break }
            font.glyphs[code] = rows
        }
        if font.glyphs.count == required.count {
            // Code tagged characters until the end.
            while line < lines.count, font.glyphs.count < maxCharacters {
                let tag = String(String.UnicodeScalarView(lines[line])).split(separator: " ").first.map(String.init) ?? ""
                line += 1
                guard let rows = readCharacter() else { break }
                if let code = parseCode(tag), code >= 0 { font.glyphs[code] = rows }
            }
        }
        guard !font.glyphs.isEmpty else { throw FIGletError.noCharacters }
        return font
    }

    static func parseCode(_ tag: String) -> Int? {
        var text = tag
        var negative = false
        if text.hasPrefix("-") { negative = true; text.removeFirst() }
        let value: Int?
        if text.lowercased().hasPrefix("0x") { value = Int(text.dropFirst(2), radix: 16) }
        else if text.hasPrefix("0"), text.count > 1 { value = Int(text.dropFirst(1), radix: 8) }
        else { value = Int(text) }
        guard let value else { return nil }
        return negative ? -value : value
    }

    // MARK: Rendering

    /// The rows of one character, padded to its width; nil when the font lacks it.
    func characterRows(_ code: Int) -> [[Unicode.Scalar]]? {
        guard let rows = glyphs[code] else { return nil }
        let width = rows.map(\.count).max() ?? 0
        return (0..<height).map { index in
            let row = index < rows.count ? rows[index] : []
            return row + Array(repeating: " ", count: width - row.count)
        }
    }

    /// The glyph used for `scalar` (ruling 13 and the missing character rule of plan ruling 20):
    /// the character, else the other case, else the font's character 0 (the FIGfont missing
    /// character). Nil means nothing is drawn.
    func glyphCode(for scalar: Unicode.Scalar) -> (code: Int, found: Bool)? {
        let code = Int(scalar.value)
        if glyphs[code] != nil { return (code, true) }
        let text = String(scalar)
        for other in [text.uppercased(), text.lowercased()] where other != text {
            if let s = other.unicodeScalars.first, other.unicodeScalars.count == 1, glyphs[Int(s.value)] != nil {
                return (Int(s.value), true)
            }
        }
        if glyphs[0] != nil { return (0, false) }
        return nil
    }

    /// One line of text as rows of characters (hardblanks still in), with the missing characters.
    func renderLine(_ text: String, mode: FIGletMode) -> (rows: [[Unicode.Scalar]], missing: [Character]) {
        var output = Array(repeating: [Unicode.Scalar](), count: height)
        var previousWidth = 0
        var missing: [Character] = []
        var scalars = Array(text.unicodeScalars)
        if printDirection == 1 { scalars.reverse() }
        for scalar in scalars {
            guard let found = glyphCode(for: scalar) else {
                missing.append(Character(scalar))
                continue
            }
            if !found.found { missing.append(Character(scalar)) }
            guard let char = characterRows(found.code) else { continue }
            let width = char.first?.count ?? 0
            let amount = smushAmount(output, char, mode: mode, previousWidth: previousWidth, width: width)
            let length = output[0].count
            for row in 0..<height {
                for k in 0..<amount where length - amount + k >= 0 {
                    let position = length - amount + k
                    let right = k < char[row].count ? char[row][k] : " "
                    output[row][position] = Self.smushHorizontal(output[row][position], right, mode: mode,
                                                                 hardblank: hardblank, leftWidth: previousWidth,
                                                                 rightWidth: width) ?? right
                }
                output[row] += char[row].dropFirst(amount)
            }
            previousWidth = width
        }
        return (output, missing)
    }

    /// The line as strings with hardblanks shown as spaces (tests and plain output).
    public func renderLine(_ text: String, horizontal: FIGletLayout) -> [[Unicode.Scalar]] {
        renderLine(text, mode: horizontal.mode(fontMode: horizontalMode, fontRules: horizontalRules)).rows
            .map { $0.map { $0 == hardblank ? " " : $0 } }
    }

    /// figlet's smushamt: how many columns the next character moves into the line.
    func smushAmount(_ line: [[Unicode.Scalar]], _ char: [[Unicode.Scalar]], mode: FIGletMode,
                     previousWidth: Int, width: Int) -> Int {
        if mode == .fullWidth { return 0 }
        var maximum = width
        let length = line.first?.count ?? 0
        for row in 0..<height {
            var lineEdge = length
            var left: Unicode.Scalar? = nil
            // The rightmost character that is not a space (figlet stops at column 0).
            while true {
                left = lineEdge < length ? line[row][lineEdge] : nil
                if lineEdge > 0, left == nil || left == " " { lineEdge -= 1 } else { break }
            }
            var charEdge = 0
            while charEdge < char[row].count, char[row][charEdge] == " " { charEdge += 1 }
            let right: Unicode.Scalar? = charEdge < char[row].count ? char[row][charEdge] : nil
            var amount = charEdge + length - 1 - lineEdge
            if left == nil || left == " " {
                amount += 1
            } else if let right, Self.smushHorizontal(left!, right, mode: mode, hardblank: hardblank,
                                                      leftWidth: previousWidth, rightWidth: width) != nil {
                amount += 1
            }
            maximum = min(maximum, amount)
        }
        return max(0, maximum)
    }

    /// figlet's smushem: the merged character, or nil when the two cannot merge.
    static func smushHorizontal(_ l: Unicode.Scalar, _ r: Unicode.Scalar, mode: FIGletMode, hardblank: Unicode.Scalar,
                                leftWidth: Int, rightWidth: Int) -> Unicode.Scalar? {
        if l == " " { return r }
        if r == " " { return l }
        if leftWidth < 2 || rightWidth < 2 { return nil }
        guard case .smushing(let rules) = mode else { return nil }
        if rules == 0 {
            if l == hardblank { return r }
            if r == hardblank { return l }
            return r
        }
        if rules & 32 != 0, l == hardblank, r == hardblank { return l }
        if l == hardblank || r == hardblank { return nil }
        if rules & 1 != 0, l == r { return l }
        if rules & 2 != 0 {
            if l == "_", "|/\\[]{}()<>".unicodeScalars.contains(r) { return r }
            if r == "_", "|/\\[]{}()<>".unicodeScalars.contains(l) { return l }
        }
        if rules & 4 != 0, let winner = hierarchy(l, r) { return winner }
        if rules & 8 != 0 {
            let pair = String(String.UnicodeScalarView([l, r]))
            if ["[]", "][", "{}", "}{", "()", ")("].contains(pair) { return "|" }
        }
        if rules & 16 != 0 {
            if l == "/", r == "\\" { return "|" }
            if l == "\\", r == "/" { return "Y" }
            if l == ">", r == "<" { return "X" }
        }
        return nil
    }

    /// Rule 3 (hierarchy): the character from the later class wins.
    static func hierarchy(_ l: Unicode.Scalar, _ r: Unicode.Scalar) -> Unicode.Scalar? {
        let classes = ["|", "/\\", "[]", "{}", "()", "<>"]
        guard let a = classes.firstIndex(where: { $0.unicodeScalars.contains(l) }),
              let b = classes.firstIndex(where: { $0.unicodeScalars.contains(r) }), a != b else { return nil }
        return a > b ? l : r
    }

    /// Vertical smushing of `top` over `bottom` (FIGfont standard vertical rules 1 to 5;
    /// rule 5 merges two vertical lines but does not supersmush further rows).
    static func smushVertical(_ top: Unicode.Scalar, _ bottom: Unicode.Scalar, mode: FIGletMode) -> Unicode.Scalar? {
        if top == " " { return bottom }
        if bottom == " " { return top }
        guard case .smushing(let rules) = mode else { return nil }
        if rules == 0 { return bottom }
        if rules & 1 != 0, top == bottom { return top }
        if rules & 2 != 0 {
            if top == "_", "|/\\[]{}()<>".unicodeScalars.contains(bottom) { return bottom }
            if bottom == "_", "|/\\[]{}()<>".unicodeScalars.contains(top) { return top }
        }
        if rules & 4 != 0, let winner = hierarchy(top, bottom) { return winner }
        if rules & 8 != 0, (top == "-" && bottom == "_") || (top == "_" && bottom == "-") { return "=" }
        if rules & 16 != 0, top == "|", bottom == "|" { return "|" }
        return nil
    }

    /// Stacks `bottom` under `top` (both padded to one width) with a vertical layout.
    static func stack(_ top: [[Unicode.Scalar]], _ bottom: [[Unicode.Scalar]], mode: FIGletMode) -> [[Unicode.Scalar]] {
        guard !top.isEmpty else { return bottom }
        guard !bottom.isEmpty else { return top }
        let width = max(top.map(\.count).max() ?? 0, bottom.map(\.count).max() ?? 0)
        func pad(_ rows: [[Unicode.Scalar]]) -> [[Unicode.Scalar]] {
            rows.map { $0 + Array(repeating: " ", count: width - $0.count) }
        }
        var upper = pad(top)
        let lower = pad(bottom)
        var amount = 0
        if mode != .fullWidth {
            amount = lower.count
            for column in 0..<width {
                var topEdge = upper.count - 1
                while topEdge > 0, upper[topEdge][column] == " " { topEdge -= 1 }
                let above = upper[topEdge][column]
                var bottomEdge = 0
                while bottomEdge < lower.count, lower[bottomEdge][column] == " " { bottomEdge += 1 }
                let below: Unicode.Scalar? = bottomEdge < lower.count ? lower[bottomEdge][column] : nil
                var columnAmount = bottomEdge + upper.count - 1 - topEdge
                if above == " " {
                    columnAmount += 1
                } else if let below, smushVertical(above, below, mode: mode) != nil {
                    columnAmount += 1
                }
                amount = min(amount, columnAmount)
            }
            amount = min(max(0, amount), upper.count)
        }
        let start = upper.count - amount
        for k in 0..<amount {
            for column in 0..<width {
                let b = lower[k][column]
                upper[start + k][column] = smushVertical(upper[start + k][column], b, mode: mode) ?? b
            }
        }
        return upper + lower.dropFirst(amount)
    }
}
