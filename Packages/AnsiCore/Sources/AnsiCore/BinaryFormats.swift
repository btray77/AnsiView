import Foundation

/// Loaders for formats that store finished screens as character and attribute pairs.
public enum BinaryFormats {
    public enum LoadError: Error { case truncated }

    /// BinaryText: char/attribute pairs, `columns` wide.
    public static func bin(_ bytes: [UInt8], columns: Int, ice: Bool) -> AnsiScreen {
        screen(pairs: bytes[...], columns: columns, palette: Palette.vga, ice: ice)
    }

    /// XBin: header, optional palette and font, then raw or run length encoded pairs.
    public static func xbin(_ bytes: [UInt8]) throws -> (AnsiScreen, BitmapFont?) {
        guard bytes.count >= 11 else { throw LoadError.truncated }
        let width = Int(bytes[5]) | Int(bytes[6]) << 8
        let height = Int(bytes[7]) | Int(bytes[8]) << 8
        let fontHeight = Int(bytes[9])
        let flags = bytes[10]
        // Same believable width range as SAUCE; a hostile header must not size the screen.
        guard (1...1000).contains(width), height > 0 else { throw LoadError.truncated }
        if flags & 0x02 != 0, !(1...32).contains(fontHeight) { throw LoadError.truncated }
        var offset = 11
        var palette = Palette.vga
        if flags & 0x01 != 0 {
            guard bytes.count >= offset + 48 else { throw LoadError.truncated }
            palette = sixBitPalette(bytes[offset..<offset + 48], indexes: Array(0..<16))
            offset += 48
        }
        var font: BitmapFont?
        if flags & 0x02 != 0 {
            let glyphs = flags & 0x10 != 0 ? 512 : 256
            let length = glyphs * fontHeight
            guard fontHeight > 0, bytes.count >= offset + length else { throw LoadError.truncated }
            // Only the first 256 glyphs are used; 512 character fonts are rare.
            font = BitmapFont(rawGlyphs: Array(bytes[offset..<offset + 256 * fontHeight]), height: fontHeight)
            offset += length
        }
        let ice = flags & 0x08 != 0
        let cellCount = width * min(height, AnsiTerminal.maxRows)
        var pairs: [UInt8]
        if flags & 0x04 != 0 {
            pairs = decompressXBin(bytes[offset...], cells: cellCount)
        } else {
            pairs = Array(bytes[offset..<min(bytes.count, offset + cellCount * 2)])
        }
        if pairs.count < cellCount * 2 { pairs += [UInt8](repeating: 0, count: cellCount * 2 - pairs.count) }
        var result = screen(pairs: pairs[...], columns: max(1, width), palette: palette, ice: ice)
        if let font { result.font = font }
        if flags & 0x01 != 0, palette != Palette.vga { result.palette = palette }
        return (result, font)
    }

    /// Artworx Data Format: version, 64 color palette, 8x16 font, then 80 column pairs.
    public static func adf(_ bytes: [UInt8]) throws -> (AnsiScreen, BitmapFont) {
        let paletteStart = 1, fontStart = 193, dataStart = 193 + 4096
        guard bytes.count >= dataStart else { throw LoadError.truncated }
        let palette = sixBitPalette(bytes[paletteStart..<fontStart],
                                    indexes: [0, 1, 2, 3, 4, 5, 20, 7, 56, 57, 58, 59, 60, 61, 62, 63])
        let font = BitmapFont(rawGlyphs: Array(bytes[fontStart..<dataStart]), height: 16)
        var result = screen(pairs: bytes[dataStart...], columns: 80, palette: palette, ice: true)
        result.font = font
        if palette != Palette.vga { result.palette = palette }
        return (result, font)
    }

    /// iCE Draw Format: header with the art's extent, run length encoded pairs, then a font and palette.
    public static func idf(_ bytes: [UInt8]) throws -> (AnsiScreen, BitmapFont?) {
        let trailer = 4096 + 48
        guard bytes.count >= 12 + trailer else { throw LoadError.truncated }
        let x2 = Int(bytes[8]) | Int(bytes[9]) << 8
        let columns = max(1, min(1000, x2 + 1))
        let dataEnd = bytes.count - trailer
        let font = BitmapFont(rawGlyphs: Array(bytes[dataEnd..<dataEnd + 4096]), height: 16)
        let palette = sixBitPalette(bytes[(dataEnd + 4096)...], indexes: Array(0..<16))

        var pairs: [UInt8] = []
        let limit = columns * AnsiTerminal.maxRows * 2
        var i = 12
        while i + 1 < dataEnd, pairs.count < limit {
            if bytes[i] == 0x01, bytes[i + 1] == 0x00, i + 5 < dataEnd {
                // Run: 01 00, count (low byte), unused, character, attribute.
                let count = Int(bytes[i + 2])
                for _ in 0..<count { pairs += [bytes[i + 4], bytes[i + 5]] }
                i += 6
            } else {
                pairs += [bytes[i], bytes[i + 1]]
                i += 2
            }
        }
        var result = screen(pairs: pairs[...], columns: columns, palette: palette, ice: true)
        result.font = font
        if palette != Palette.vga { result.palette = palette }
        return (result, font)
    }

    /// The 16 colours a file brings with it: XBin with its palette flag, ADF, IDF; nil otherwise.
    public static func embeddedPalette(_ bytes: [UInt8], format: ArtFormat) -> [RGB]? {
        switch format {
        case .xbin:
            guard bytes.count >= 11 + 48, bytes[10] & 0x01 != 0 else { return nil }
            return sixBitPalette(bytes[11..<59], indexes: Array(0..<16))
        case .adf:
            guard bytes.count >= 193 else { return nil }
            return sixBitPalette(bytes[1..<193], indexes: [0, 1, 2, 3, 4, 5, 20, 7, 56, 57, 58, 59, 60, 61, 62, 63])
        case .idf:
            let trailer = 4096 + 48
            guard bytes.count >= 12 + trailer else { return nil }
            return sixBitPalette(bytes[(bytes.count - 48)...], indexes: Array(0..<16))
        default:
            return nil
        }
    }

    // MARK: Helpers

    /// Builds rows from char/attribute pairs. Attribute: low nibble foreground, bits 4-6 background,
    /// bit 7 blink (or bright background with iCE colors).
    static func screen(pairs: ArraySlice<UInt8>, columns: Int, palette: [RGB], ice: Bool) -> AnsiScreen {
        let columns = max(1, columns)
        var rows: [[AnsiCell]] = []
        var row: [AnsiCell] = []
        row.reserveCapacity(columns)
        var i = pairs.startIndex
        while i + 1 < pairs.endIndex, rows.count < AnsiTerminal.maxRows {
            let code = pairs[i], attribute = pairs[i + 1]
            let blinkBit = attribute & 0x80 != 0
            let bgIndex = Int((attribute >> 4) & 0x07) + (ice && blinkBit ? 8 : 0)
            row.append(AnsiCell(code: code, fg: palette[Int(attribute & 0x0F)], bg: palette[bgIndex],
                                blink: blinkBit && !ice))
            if row.count == columns {
                rows.append(row)
                row.removeAll(keepingCapacity: true)
            }
            i += 2
        }
        if !row.isEmpty, rows.count < AnsiTerminal.maxRows {
            row += Array(repeating: AnsiCell(), count: columns - row.count)
            rows.append(row)
        }
        return AnsiScreen(columns: columns, rows: rows)
    }

    /// 6 bit RGB triplets; `indexes` selects which entries become the 16 colors.
    private static func sixBitPalette(_ bytes: ArraySlice<UInt8>, indexes: [Int]) -> [RGB] {
        let base = bytes.startIndex
        return indexes.map { index in
            let o = base + index * 3
            guard o + 2 < bytes.endIndex else { return Palette.vga[0] }
            func scale(_ v: UInt8) -> UInt8 { UInt8(min(255, Int(v & 0x3F) * 255 / 63)) }
            return RGB(r: scale(bytes[o]), g: scale(bytes[o + 1]), b: scale(bytes[o + 2]))
        }
    }

    /// XBin run length decoding. Each run byte: top 2 bits are the type (0 none, 1 character
    /// repeats, 2 attribute repeats, 3 both repeat), low 6 bits plus 1 the count.
    private static func decompressXBin(_ data: ArraySlice<UInt8>, cells: Int) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(cells * 2)
        var i = data.startIndex
        func next() -> UInt8? {
            guard i < data.endIndex else { return nil }
            defer { i += 1 }
            return data[i]
        }
        while out.count < cells * 2, let control = next() {
            let count = Int(control & 0x3F) + 1
            switch control >> 6 {
            case 0:
                for _ in 0..<count {
                    guard let c = next(), let a = next() else { return out }
                    out += [c, a]
                }
            case 1:
                guard let c = next() else { return out }
                for _ in 0..<count {
                    guard let a = next() else { return out }
                    out += [c, a]
                }
            case 2:
                guard let a = next() else { return out }
                for _ in 0..<count {
                    guard let c = next() else { return out }
                    out += [c, a]
                }
            default:
                guard let c = next(), let a = next() else { return out }
                for _ in 0..<count { out += [c, a] }
            }
        }
        return out
    }
}
