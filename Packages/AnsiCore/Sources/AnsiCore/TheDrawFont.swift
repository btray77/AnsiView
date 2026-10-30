import Foundation

// TheDraw font files (.TDF): the text art font format of DOS BBS art tools (TheDraw, ACiDDraw,
// PabloDraw). Layout and rulings: docs/superpowers/plans/2026-10-30-ansiview-2.0-fonts.md
// (Roy/SAC's reverse engineered specification, tdfiglet and retrofont as references).

/// The three kinds of TheDraw font.
public enum TDFFontType: UInt8, CaseIterable {
    /// Letters drawn with placeholders that an outline style turns into box characters.
    case outline = 0
    /// CP437 characters drawn in the current colours.
    case block = 1
    /// CP437 characters with their own colour attributes.
    case color = 2

    public var label: String {
        switch self {
        case .outline: return "TDF outline"
        case .block: return "TDF block"
        case .color: return "TDF colour"
        }
    }
}

/// One cell of a glyph: a CP437 byte (an outline placeholder letter in outline fonts) and,
/// in colour fonts, its attribute (low nibble foreground, bits 4 to 6 background, bit 7 blink).
public struct TDFCell: Equatable, Hashable {
    public var code: UInt8
    public var attribute: UInt8

    public init(code: UInt8, attribute: UInt8 = 0) {
        self.code = code
        self.attribute = attribute
    }
}

/// A glyph row. `descender` marks rows that ended with `&` (below the baseline).
public struct TDFRow: Equatable, Hashable {
    public var cells: [TDFCell]
    public var descender: Bool

    public init(cells: [TDFCell], descender: Bool = false) {
        self.cells = cells
        self.descender = descender
    }
}

public struct TDFGlyph: Equatable, Hashable {
    /// The width and height bytes as stored (kept for writing; rendering uses `rows`).
    public var width: UInt8
    public var height: UInt8
    public var rows: [TDFRow]

    public init(width: UInt8, height: UInt8, rows: [TDFRow]) {
        self.width = width
        self.height = height
        self.rows = rows
    }

    /// A glyph whose width and height bytes are computed from its rows.
    public init(rows: [TDFRow]) {
        self.rows = rows
        width = UInt8(min(255, rows.map(\.cells.count).max() ?? 0))
        height = UInt8(min(255, rows.filter { !$0.descender }.count))
    }

    /// Columns the glyph covers (its widest row).
    public var columns: Int { rows.map(\.cells.count).max() ?? 0 }
}

public struct TDFFont: Equatable {
    public var name: String
    public var type: TDFFontType
    public var spacing: Int
    /// Glyphs keyed by character code, 33 (`!`) to 126 (`~`).
    public var glyphs: [UInt8: TDFGlyph]

    public init(name: String, type: TDFFontType, spacing: Int, glyphs: [UInt8: TDFGlyph]) {
        self.name = name
        self.type = type
        self.spacing = spacing
        self.glyphs = glyphs
    }
}

public enum TDFError: LocalizedError, Equatable {
    case notTDF
    case tooLarge
    case noFonts
    case blockTooLarge(String)
    case nameTooLong(String)

    public var errorDescription: String? {
        switch self {
        case .notTDF: return "This file is not a TheDraw font file (.TDF)."
        case .tooLarge: return "This font file is larger than 16 MB, which no TheDraw font file is."
        case .noFonts: return "This TheDraw font file has no readable font in it."
        case .blockTooLarge(let name):
            return "The font \"\(name)\" is too large for a TheDraw font file (its glyphs need more than 65,535 bytes)."
        case .nameTooLong(let name): return "The font name \"\(name)\" is longer than 12 characters."
        }
    }
}

public enum TDFFile {
    public static let signature: [UInt8] = [0x13] + Array("TheDraw FONTS file".utf8) + [0x1A]
    static let fontMarker: [UInt8] = [0x55, 0xAA, 0x00, 0xFF]
    public static let maxFileSize = 16 << 20
    public static let maxFonts = 2048
    public static let maxRows = 64
    public static let maxRowCells = 255
    static let headerSize = 213
    static let firstCode: UInt8 = 33
    static let glyphCount = 94

    public struct ParseResult {
        public var fonts: [TDFFont]
        /// Fonts that could not be read (truncated, unknown type), for the user.
        public var warnings: [String]
    }

    /// Whether `data` starts with the TDF signature.
    public static func isTDF(_ data: Data) -> Bool {
        data.count >= signature.count && [UInt8](data.prefix(signature.count)) == signature
    }

    /// Reads every font in a TDF file (rulings 1 to 5). Never traps on hostile input.
    public static func parse(_ data: Data) throws -> ParseResult {
        guard data.count <= maxFileSize else { throw TDFError.tooLarge }
        guard isTDF(data) else { throw TDFError.notTDF }
        let b = [UInt8](data)
        var fonts: [TDFFont] = []
        var warnings: [String] = []
        var o = signature.count
        while o < b.count, fonts.count < maxFonts {
            // NUL padding between fonts (some files) is skipped.
            while o < b.count, b[o] == 0 { o += 1 }
            guard o + 4 <= b.count, Array(b[o..<o + 4]) == fontMarker else { break }
            guard o + headerSize <= b.count else {
                warnings.append("A font header at byte \(o) is cut short.")
                break
            }
            let nameLength = min(12, Int(b[o + 4]))
            var nameBytes = Array(b[(o + 5)..<(o + 5 + nameLength)])
            if let nul = nameBytes.firstIndex(of: 0) { nameBytes.removeSubrange(nul...) }
            let name = String(String.UnicodeScalarView(nameBytes.map { CP437.unicode[Int($0)] }))
            let typeByte = b[o + 21]
            let spacing = Int(b[o + 22])
            let blockSize = Int(b[o + 23]) | Int(b[o + 24]) << 8
            let dataStart = o + headerSize
            guard dataStart + blockSize <= b.count else {
                warnings.append("The font \"\(name)\" is cut short (its glyphs run past the end of the file).")
                break
            }
            defer { o = dataStart + blockSize }
            guard let type = TDFFontType(rawValue: typeByte) else {
                warnings.append("The font \"\(name)\" has an unknown type (\(typeByte)).")
                continue
            }
            var glyphs: [UInt8: TDFGlyph] = [:]
            for index in 0..<glyphCount {
                let offset = Int(b[o + 25 + 2 * index]) | Int(b[o + 26 + 2 * index]) << 8
                guard offset != 0xFFFF, offset + 2 <= blockSize else { continue }
                glyphs[firstCode + UInt8(index)] = decodeGlyph(b, at: dataStart + offset, end: dataStart + blockSize, type: type)
            }
            fonts.append(TDFFont(name: name, type: type, spacing: spacing, glyphs: glyphs))
        }
        guard !fonts.isEmpty else { throw TDFError.noFonts }
        return ParseResult(fonts: fonts, warnings: warnings)
    }

    static func decodeGlyph(_ b: [UInt8], at start: Int, end: Int, type: TDFFontType) -> TDFGlyph {
        let width = b[start], height = b[start + 1]
        var rows: [TDFRow] = []
        var row = TDFRow(cells: [])
        var p = start + 2
        func endRow() {
            if rows.count < maxRows { rows.append(row) }
            row = TDFRow(cells: [])
        }
        while p < end {
            let code = b[p]
            p += 1
            if code == 0 { break }
            if code == 0x0D { endRow(); continue }
            // `&` before CR, NUL or the end of the block is the descender mark (ruling 5).
            if code == 0x26, p >= end || b[p] == 0 || b[p] == 0x0D {
                row.descender = true
                continue
            }
            var attribute: UInt8 = 0
            if type == .color {
                guard p < end else { break }
                attribute = b[p]
                p += 1
            }
            if row.cells.count < maxRowCells { row.cells.append(TDFCell(code: code, attribute: attribute)) }
        }
        endRow()
        return TDFGlyph(width: width, height: height, rows: rows)
    }

    /// Writes `fonts` as one TDF file (ruling 6).
    public static func write(_ fonts: [TDFFont]) throws -> Data {
        var out = signature
        for font in fonts {
            let nameCodes = font.name.unicodeScalars.map { CP437.code(for: $0) ?? 0x3F }
            guard nameCodes.count <= 12 else { throw TDFError.nameTooLong(font.name) }
            var block: [UInt8] = []
            var offsets = [UInt16](repeating: 0xFFFF, count: glyphCount)
            var shared: [[UInt8]: Int] = [:]
            for index in 0..<glyphCount {
                guard let glyph = font.glyphs[firstCode + UInt8(index)] else { continue }
                let bytes = encode(glyph, type: font.type)
                if let existing = shared[bytes] {
                    offsets[index] = UInt16(existing)
                    continue
                }
                guard block.count + bytes.count <= 0xFFFF, block.count < 0xFFFF else {
                    throw TDFError.blockTooLarge(font.name)
                }
                offsets[index] = UInt16(block.count)
                shared[bytes] = block.count
                block += bytes
            }
            out += fontMarker
            out.append(12)
            out += nameCodes + Array(repeating: 0, count: 12 - nameCodes.count)
            out += [0, 0, 0, 0, font.type.rawValue, UInt8(clamping: font.spacing)]
            out += [UInt8(block.count & 0xFF), UInt8(block.count >> 8)]
            for offset in offsets { out += [UInt8(offset & 0xFF), UInt8(offset >> 8)] }
            out += block
        }
        return Data(out)
    }

    static func encode(_ glyph: TDFGlyph, type: TDFFontType) -> [UInt8] {
        var out: [UInt8] = [glyph.width, glyph.height]
        for (index, row) in glyph.rows.enumerated() {
            if index > 0 { out.append(0x0D) }
            for cell in row.cells {
                // A NUL or CR character cannot be stored; it would end the glyph or the row.
                let code = cell.code == 0 || cell.code == 0x0D ? 0x20 : cell.code
                out.append(code)
                if type == .color { out.append(cell.attribute) }
            }
            if row.descender { out.append(0x26) }
        }
        out.append(0)
        return out
    }
}
