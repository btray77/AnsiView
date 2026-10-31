import Foundation

/// The writers for .ADF, .IDF, PCBoard, Wildcat and Avatar files (final gaps rulings 1 to 6).
/// Each one is read back by AnsiView's own reader (`BinaryFormats`, `BBSCodes`) as the same cells.
extension ArtWriter {
    // MARK: ADF and IDF

    /// ADF slots of the 16 text colours in its 64 entry EGA palette.
    static let adfSlots = [0, 1, 2, 3, 4, 5, 20, 7, 56, 57, 58, 59, 60, 61, 62, 63]

    /// Artworx Data Format: version 1, a 64 colour palette (the EGA one with the art's colours in
    /// their slots), an 8x16 font, then 80 columns of character and attribute pairs. Always iCE.
    static func adfBody(_ canvas: EditCanvas) throws -> [UInt8] {
        guard canvas.columns <= 80 else { throw WriteError.tooWideForADF(columns: canvas.columns) }
        let canvas = iced(canvas)
        var out: [UInt8] = [1]
        var sixty4 = (0..<64).flatMap { egaColour($0) }
        let colours = canvas.palette ?? Palette.vga
        for (index, slot) in adfSlots.enumerated() {
            let six = sixBits(colours[index])
            sixty4[slot * 3] = six[0]; sixty4[slot * 3 + 1] = six[1]; sixty4[slot * 3 + 2] = six[2]
        }
        out += sixty4
        out += fontBytes(canvas, height: 16)
        out += pairs(canvas, columns: 80, palette: canvas.palette)
        return out
    }

    /// iCE Draw Format 1.4: header with the art's extent, run length encoded pairs, then the 8x16
    /// font and the 16 colour palette. Always iCE.
    static func idfBody(_ canvas: EditCanvas) -> [UInt8] {
        let canvas = iced(canvas)
        var out: [UInt8] = [0x04] + Array("1.4".utf8)
        out += le16(0) + le16(0) + le16(canvas.columns - 1) + le16(canvas.height - 1)
        let flat = pairs(canvas, columns: canvas.columns, palette: canvas.palette)
        var i = 0
        while i < flat.count {
            let c = flat[i], a = flat[i + 1]
            var n = 1
            while n < 255, i + 2 * n + 1 < flat.count, flat[i + 2 * n] == c, flat[i + 2 * n + 1] == a { n += 1 }
            // A literal 01 00 pair would read as a run, so it is always written as one.
            if n >= 4 || (c == 0x01 && a == 0x00) {
                out += [0x01, 0x00, UInt8(n), 0x00, c, a]
            } else {
                for _ in 0..<n { out += [c, a] }
            }
            i += 2 * n
        }
        out += fontBytes(canvas, height: 16)
        for colour in canvas.palette ?? Palette.vga { out += sixBits(colour) }
        return out
    }

    /// The canvas's embedded font, else its named font, when it has this height and 8 pixel
    /// glyphs; IBM VGA otherwise.
    static func fontBytes(_ canvas: EditCanvas, height: Int) -> [UInt8] {
        for font in [canvas.embeddedFont, BitmapFont.named(canvas.fontName)].compactMap({ $0 }) where font.height == height {
            if let bytes = font.rawGlyphBytes { return bytes }
        }
        return BitmapFont.vga.rawGlyphBytes ?? [UInt8](repeating: 0, count: 256 * height)
    }

    /// The standard EGA palette entry `index` (bits: 0 blue, 1 green, 2 red at 2/3, 3 to 5 at 1/3), 6 bit.
    static func egaColour(_ index: Int) -> [UInt8] {
        func channel(_ high: Int, _ low: Int) -> UInt8 {
            let strong: Int = (index >> high) & 1
            let weak: Int = (index >> low) & 1
            return UInt8(strong * 42 + weak * 21)
        }
        return [channel(2, 5), channel(1, 4), channel(0, 3)]
    }

    static func sixBits(_ c: RGB) -> [UInt8] { [c.r, c.g, c.b].map { UInt8((Int($0) * 63 + 127) / 255) } }

    /// A copy with iCE colours on (blinking cells become bright backgrounds).
    static func iced(_ canvas: EditCanvas) -> EditCanvas {
        var copy = canvas
        copy.setIceColors(true)
        return copy
    }

    // MARK: PCBoard and Wildcat

    /// Text with colour codes: one at the start, one wherever the colour changes, and one after
    /// every literal "@" so text such as "@X1F" or "@1F@" is never read as a code (rulings 4, 5).
    static func colourCodeBody(_ canvas: EditCanvas, code: (UInt8) -> [UInt8], attribute adjust: (UInt8, AnsiCell) -> UInt8) -> [UInt8] {
        var current: UInt8 = 0x07
        var out = code(current)
        let blank = AnsiCell()
        for row in canvas.screen(trimmed: true).rows {
            var cells = row
            while let last = cells.last, last == blank { cells.removeLast() }
            for cell in cells {
                let attribute = adjust(attribute(cell, ice: canvas.iceColors), cell)
                if attribute != current {
                    out += code(attribute)
                    current = attribute
                }
                let byte = TextConvert.lookalikes[cell.code] ?? cell.code
                out.append(byte)
                if byte == 0x40 { out += code(current) }
            }
            out += [0x0D, 0x0A]
        }
        return out
    }

    static func hexDigit(_ value: UInt8) -> UInt8 { Array("0123456789ABCDEF".utf8)[Int(value & 15)] }

    /// PCBoard `@Xbf`. `@X00` and `@XFF` save and restore the colour on a real PCBoard, so black on
    /// black becomes grey (blanks) or dark grey (text) on black, and 0xFF becomes 0x7F.
    static func pcboardBody(_ canvas: EditCanvas) -> [UInt8] {
        colourCodeBody(canvas, code: { [0x40, 0x58, hexDigit($0 >> 4), hexDigit($0)] }) { attribute, cell in
            if attribute == 0x00 { return cell.code == 0x20 || cell.code == 0 ? 0x07 : 0x08 }
            if attribute == 0xFF { return 0x7F }
            return attribute
        }
    }

    /// Wildcat `@bf@`.
    static func wildcatBody(_ canvas: EditCanvas) -> [UInt8] {
        colourCodeBody(canvas, code: { [0x40, hexDigit($0 >> 4), hexDigit($0), 0x40] }) { attribute, _ in attribute }
    }

    // MARK: Avatar

    /// Codes that are commands in Avatar text: written through a one character ^Y repeat.
    static let avatarCommands: Set<UInt8> = [0x0C, 0x16, 0x19]

    /// Avatar/0: ^V^A attribute (^V^B adds blink), ^Y repeats for 4 or more equal cells. With
    /// `plus`, the AVT/0+ ^V^Y pattern repeat is used where it is shorter (ruling 6).
    static func avatarBody(_ canvas: EditCanvas, plus: Bool) -> [UInt8] {
        var out: [UInt8] = []
        var current: UInt8?
        let blank = AnsiCell()
        func setAttribute(_ a: UInt8) {
            guard a != current else { return }
            out += [0x16, 0x01, a & 0x7F]
            if a & 0x80 != 0 { out += [0x16, 0x02] }
            current = a
        }
        for row in canvas.screen(trimmed: true).rows {
            var cells = row
            while let last = cells.last, last == blank { cells.removeLast() }
            let bytes = cells.map { TextConvert.lookalikes[$0.code] ?? $0.code }
            let attributes = cells.map { attribute($0, ice: canvas.iceColors) }
            var i = 0
            while i < cells.count {
                setAttribute(attributes[i])
                var n = 1
                while n < 255, i + n < cells.count, bytes[i + n] == bytes[i], attributes[i + n] == attributes[i] { n += 1 }
                if plus, let (length, times) = bestPattern(bytes, attributes, at: i, run: n) {
                    out += [0x16, 0x19, UInt8(length)] + bytes[i..<(i + length)] + [UInt8(times)]
                    i += length * times
                    continue
                }
                if n >= 4 || avatarCommands.contains(bytes[i]) {
                    out += [0x19, bytes[i], UInt8(n)]
                } else {
                    out += Array(repeating: bytes[i], count: n)
                }
                i += n
            }
            out += [0x0D, 0x0A]
        }
        return out
    }

    /// The AVT/0+ pattern (2 to 8 characters of one colour, repeated) starting at `i` that saves the
    /// most bytes over plain characters and ^Y runs; nil when none saves any.
    static func bestPattern(_ bytes: [UInt8], _ attributes: [UInt8], at i: Int, run: Int) -> (Int, Int)? {
        var best: (length: Int, times: Int, saving: Int)?
        for length in 2...8 where i + 2 * length <= bytes.count {
            let pattern = bytes[i..<(i + length)]
            guard Set(pattern).count > 1, !pattern.contains(where: avatarCommands.contains),
                  attributes[i..<(i + length)].allSatisfy({ $0 == attributes[i] }) else { continue }
            var times = 1
            while times < 255, i + (times + 1) * length <= bytes.count,
                  bytes[(i + times * length)..<(i + (times + 1) * length)].elementsEqual(pattern),
                  attributes[(i + times * length)..<(i + (times + 1) * length)].allSatisfy({ $0 == attributes[i] }) {
                times += 1
            }
            guard times >= 2 else { continue }
            let covered = length * times
            let plainCost = runCost(bytes[i..<(i + covered)])
            let saving = plainCost - (4 + length)
            if saving > 0, saving > (best?.saving ?? 0) { best = (length, times, saving) }
        }
        return best.map { ($0.length, $0.times) }
    }

    /// Bytes plain Avatar/0 text needs for `slice`: runs of 4 or more as ^Y, others as characters.
    static func runCost(_ slice: ArraySlice<UInt8>) -> Int {
        var cost = 0, i = slice.startIndex
        while i < slice.endIndex {
            var n = 1
            while i + n < slice.endIndex, slice[i + n] == slice[i] { n += 1 }
            cost += n >= 4 ? 3 : n
            i += n
        }
        return cost
    }
}
