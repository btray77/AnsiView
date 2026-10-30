import Foundation
import Testing
@testable import AnsiCore

/// Builds TDF bytes by hand (independent of `TDFFile.write`), so the parser is tested
/// against the layout in the plan, not against our own writer.
enum TDFBytes {
    static let signature: [UInt8] = [0x13] + Array("TheDraw FONTS file".utf8) + [0x1A]

    /// One font: `glyphs` maps a character to its raw glyph bytes (width, height, cells, ..., NUL).
    static func font(name: String, type: UInt8, spacing: UInt8 = 1, glyphs: [Character: [UInt8]],
                     nameLength: UInt8 = 12, blockSizeOverride: Int? = nil) -> [UInt8] {
        var block: [UInt8] = []
        var offsets = [UInt16](repeating: 0xFFFF, count: 94)
        for (ch, bytes) in glyphs.sorted(by: { $0.key < $1.key }) {
            let index = Int(ch.asciiValue!) - 33
            offsets[index] = UInt16(block.count)
            block += bytes
        }
        var out: [UInt8] = [0x55, 0xAA, 0x00, 0xFF, nameLength]
        var nameBytes = Array(name.utf8.prefix(12))
        nameBytes += Array(repeating: 0, count: 12 - nameBytes.count)
        out += nameBytes
        out += [0, 0, 0, 0, type, spacing]
        let size = blockSizeOverride ?? block.count
        out += [UInt8(size & 0xFF), UInt8(size >> 8)]
        for offset in offsets { out += [UInt8(offset & 0xFF), UInt8(offset >> 8)] }
        return out + block
    }

    static func file(_ fonts: [[UInt8]], between: [UInt8] = []) -> Data {
        var out = signature
        for (index, font) in fonts.enumerated() {
            if index > 0 { out += between }
            out += font
        }
        return Data(out)
    }
}

struct TheDrawFontTests {
    let cr: UInt8 = 0x0D

    @Test func fixedOffsetsMatchThePlan() throws {
        // The first font's glyph data starts at byte 233 (tdfiglet's map[233]).
        let font = TDFBytes.font(name: "Plain", type: 1, glyphs: ["A": [2, 1, 0xDB, 0xDB, 0]])
        let data = TDFBytes.file([font])
        #expect(data.count == 233 + 5)
        #expect(data[20] == 0x55 && data[41] == 1)
        let fonts = try TDFFile.parse(data).fonts
        #expect(fonts.count == 1)
        #expect(fonts[0].name == "Plain")
        #expect(fonts[0].type == .block)
        #expect(fonts[0].spacing == 1)
        #expect(fonts[0].glyphs[UInt8(ascii: "A")]?.rows == [TDFRow(cells: [TDFCell(code: 0xDB), TDFCell(code: 0xDB)])])
        #expect(fonts[0].glyphs.count == 1)
    }

    @Test func refusesOtherFiles() {
        #expect(throws: TDFError.notTDF) { try TDFFile.parse(Data("hello".utf8)) }
        var bad = TDFBytes.signature
        bad[1] = UInt8(ascii: "t")
        #expect(throws: TDFError.notTDF) { try TDFFile.parse(Data(bad + [0, 0, 0])) }
        // A signature with no font in it.
        #expect(throws: TDFError.noFonts) { try TDFFile.parse(Data(TDFBytes.signature)) }
    }

    @Test func allThreeTypes() throws {
        let outline = TDFBytes.font(name: "O", type: 0, glyphs: ["A": [3, 2] + Array("EAF".utf8) + [cr] + Array("K@L".utf8) + [0]])
        let block = TDFBytes.font(name: "B", type: 1, glyphs: ["B": [1, 1, 0xDC, 0]])
        let color = TDFBytes.font(name: "C", type: 2, glyphs: ["C": [2, 1, 0xDB, 0x4E, 0x20, 0x9F, 0]])
        let fonts = try TDFFile.parse(TDFBytes.file([outline, block, color])).fonts
        #expect(fonts.map(\.type) == [.outline, .block, .color])
        #expect(fonts[0].glyphs[UInt8(ascii: "A")]?.rows.map { $0.cells.map(\.code) }
                == [Array("EAF".utf8), Array("K@L".utf8)])
        let c = fonts[2].glyphs[UInt8(ascii: "C")]!
        #expect(c.rows[0].cells == [TDFCell(code: 0xDB, attribute: 0x4E), TDFCell(code: 0x20, attribute: 0x9F)])
    }

    @Test func colourAttributeZeroDoesNotEndTheGlyph() throws {
        // Roy/SAC: an attribute of 00 is valid; only the character byte is checked for NUL.
        let color = TDFBytes.font(name: "C", type: 2, glyphs: ["A": [2, 1, 0xDB, 0x00, 0xDB, 0x07, 0]])
        let glyph = try TDFFile.parse(TDFBytes.file([color])).fonts[0].glyphs[UInt8(ascii: "A")]!
        #expect(glyph.rows[0].cells.count == 2)
    }

    @Test func fontsSeparatedByNulPaddingAndEndedBySauce() throws {
        let a = TDFBytes.font(name: "One", type: 1, glyphs: ["A": [1, 1, 0xDB, 0]])
        let b = TDFBytes.font(name: "Two", type: 1, glyphs: ["A": [1, 1, 0xB0, 0]])
        var data = TDFBytes.file([a, b], between: [0, 0])
        data += Data([0x1A] + Array("SAUCE00".utf8) + Array(repeating: 0x20, count: 120))
        let result = try TDFFile.parse(data)
        #expect(result.fonts.map(\.name) == ["One", "Two"])
    }

    @Test func nameStopsAtNulAndHonoursShortLength() throws {
        let a = TDFBytes.font(name: "Abcdefghijkl", type: 1, glyphs: ["A": [1, 1, 0xDB, 0]], nameLength: 5)
        #expect(try TDFFile.parse(TDFBytes.file([a])).fonts[0].name == "Abcde")
        let b = TDFBytes.font(name: "Hi", type: 1, glyphs: ["A": [1, 1, 0xDB, 0]], nameLength: 200)
        #expect(try TDFFile.parse(TDFBytes.file([b])).fonts[0].name == "Hi")
    }

    @Test func ampersandRules() throws {
        // Block: `&` at a row end is the descender mark; mid row it is drawn.
        let block = TDFBytes.font(name: "B", type: 1, glyphs: [
            "g": [2, 1, 0xDB, 0xDB, cr, 0xDB, UInt8(ascii: "&"), 0],
            "h": [3, 1, 0xDB, UInt8(ascii: "&"), 0xDB, 0],
        ])
        let fonts = try TDFFile.parse(TDFBytes.file([block])).fonts
        let g = fonts[0].glyphs[UInt8(ascii: "g")]!
        #expect(g.rows.count == 2)
        #expect(g.rows[1].descender && g.rows[1].cells.map(\.code) == [0xDB])
        #expect(!g.rows[0].descender)
        #expect(fonts[0].glyphs[UInt8(ascii: "h")]!.rows[0].cells.map(\.code) == [0xDB, 0x26, 0xDB])

        // Colour: `&` then CR or NUL is the mark; `&` then an attribute is a drawn `&` (DOLCEX.TDF).
        let color = TDFBytes.font(name: "C", type: 2, glyphs: [
            "j": [1, 1, 0xDB, 0x07, cr, UInt8(ascii: "&"), 0x08, 0xDB, 0x07, UInt8(ascii: "&"), 0],
        ])
        let j = try TDFFile.parse(TDFBytes.file([color])).fonts[0].glyphs[UInt8(ascii: "j")]!
        #expect(j.rows[1].cells == [TDFCell(code: 0x26, attribute: 0x08), TDFCell(code: 0xDB, attribute: 0x07)])
        #expect(j.rows[1].descender)
    }

    @Test func undefinedAndOutOfBlockOffsetsAreSkipped() throws {
        var font = TDFBytes.font(name: "X", type: 1, glyphs: ["A": [1, 1, 0xDB, 0], "B": [1, 1, 0xDB, 0]])
        // Point "C" past the block (offset table entry 2 is at font offset 25 + 4).
        font[25 + 4] = 0x00
        font[25 + 5] = 0x40
        let fonts = try TDFFile.parse(TDFBytes.file([font])).fonts
        #expect(fonts[0].glyphs.keys.sorted() == [UInt8(ascii: "A"), UInt8(ascii: "B")])
    }

    @Test func glyphWithoutTerminatorStopsAtBlockEnd() throws {
        let font = TDFBytes.font(name: "X", type: 2, glyphs: ["A": [2, 1, 0xDB, 0x07, 0xDB]])
        let glyph = try TDFFile.parse(TDFBytes.file([font])).fonts[0].glyphs[UInt8(ascii: "A")]!
        // The second cell has no attribute byte left: dropped.
        #expect(glyph.rows[0].cells == [TDFCell(code: 0xDB, attribute: 0x07)])
    }

    @Test func truncatedSecondFontIsDroppedWithWarning() throws {
        let a = TDFBytes.font(name: "Good", type: 1, glyphs: ["A": [1, 1, 0xDB, 0]])
        let b = TDFBytes.font(name: "Cut", type: 1, glyphs: ["A": [1, 1, 0xDB, 0]], blockSizeOverride: 5000)
        let result = try TDFFile.parse(TDFBytes.file([a, b]))
        #expect(result.fonts.map(\.name) == ["Good"])
        #expect(!result.warnings.isEmpty)
        // A single truncated font: nothing to show.
        #expect(throws: TDFError.noFonts) { try TDFFile.parse(TDFBytes.file([b])) }
        // A header cut short.
        #expect(throws: TDFError.noFonts) { try TDFFile.parse(Data(TDFBytes.signature + Array(a.prefix(40)))) }
    }

    @Test func capsRowsAndRefusesHugeFiles() throws {
        var bytes: [UInt8] = [1, 1]
        for _ in 0..<200 { bytes += [0xDB, cr] }
        bytes += [0]
        let font = TDFBytes.font(name: "Tall", type: 1, glyphs: ["A": bytes])
        let glyph = try TDFFile.parse(TDFBytes.file([font])).fonts[0].glyphs[UInt8(ascii: "A")]!
        #expect(glyph.rows.count == TDFFile.maxRows)
        #expect(throws: TDFError.tooLarge) { try TDFFile.parse(Data(count: TDFFile.maxFileSize + 1)) }
    }

    @Test func unknownTypeIsDroppedNotTrapped() throws {
        let odd = TDFBytes.font(name: "Odd", type: 7, glyphs: ["A": [1, 1, 0xDB, 0]])
        let good = TDFBytes.font(name: "Good", type: 1, glyphs: ["A": [1, 1, 0xDB, 0]])
        let result = try TDFFile.parse(TDFBytes.file([odd, good]))
        #expect(result.fonts.map(\.name) == ["Good"])
    }

    @Test func fuzzNeverTraps() {
        // Fixed seed: random bytes, random corruptions of a valid file and random truncations.
        var rng = SplitMix(seed: 0x7D_F0_57)
        let base = [UInt8](TDFBytes.file([
            TDFBytes.font(name: "Base", type: 2, glyphs: ["A": [2, 2, 0xDB, 0x07, 0xDC, 0x4F, cr, 0xDF, 0x01, 0]]),
            TDFBytes.font(name: "Base2", type: 0, glyphs: ["B": [2, 1] + Array("EF".utf8) + [0]]),
        ]))
        var parsed = 0
        for round in 0..<3000 {
            var bytes = base
            switch round % 3 {
            case 0:
                bytes = TDFBytes.signature + (0..<Int(rng.next() % 600)).map { _ in UInt8(truncatingIfNeeded: rng.next()) }
            case 1:
                for _ in 0..<(1 + Int(rng.next() % 8)) {
                    bytes[20 + Int(rng.next() % UInt64(bytes.count - 20))] = UInt8(truncatingIfNeeded: rng.next())
                }
            default:
                bytes = Array(bytes.prefix(Int(rng.next() % UInt64(bytes.count))))
            }
            if let result = try? TDFFile.parse(Data(bytes)) {
                parsed += 1
                // Whatever parses must render and write without trapping.
                for font in result.fonts {
                    _ = TextArt.render("AB ab!", font: .tdf(font), options: TextArtOptions())
                    _ = try? TDFFile.write([font])
                }
            }
        }
        #expect(parsed > 0)
    }

    // MARK: Writer

    @Test func writerRoundTrip() throws {
        let original = try TDFFile.parse(TDFBytes.file([
            TDFBytes.font(name: "Round", type: 2, spacing: 3, glyphs: [
                "A": [2, 2, 0xDB, 0x07, 0xDC, 0x4F, cr, 0xDF, 0x01, 0],
                "g": [1, 1, 0xDB, 0x07, cr, 0xDB, 0x08, UInt8(ascii: "&"), 0],
                "&": [1, 1, UInt8(ascii: "&"), 0x0C, 0],
            ]),
            TDFBytes.font(name: "Line", type: 0, glyphs: ["B": [3, 1] + Array("E@F".utf8) + [0]]),
        ])).fonts
        let written = try TDFFile.write(original)
        #expect(written.prefix(20) == Data(TDFBytes.signature))
        #expect(written[24] == 12)
        let again = try TDFFile.parse(written).fonts
        #expect(again == original)
    }

    @Test func writerSharesIdenticalGlyphs() throws {
        let glyph = TDFGlyph(width: 1, height: 1, rows: [TDFRow(cells: [TDFCell(code: 0xDB)])])
        let font = TDFFont(name: "Same", type: .block, spacing: 1,
                           glyphs: [UInt8(ascii: "A"): glyph, UInt8(ascii: "B"): glyph])
        let data = [UInt8](try TDFFile.write([font]))
        let a = Int(data[20 + 25 + 64]) | Int(data[20 + 26 + 64]) << 8
        let b = Int(data[20 + 25 + 66]) | Int(data[20 + 26 + 66]) << 8
        #expect(a == b)
        #expect(Int(data[43]) | Int(data[44]) << 8 == 4)
    }

    @Test func writerRefusesBlocksOver64K() {
        let rows = (0..<60).map { _ in TDFRow(cells: Array(repeating: TDFCell(code: 0xDB, attribute: 7), count: 250)) }
        var glyphs: [UInt8: TDFGlyph] = [:]
        // Distinct glyphs (no sharing): 60 * 251 * 2 bytes each, 94 of them.
        for code in UInt8(33)...UInt8(126) {
            var r = rows
            r[0].cells[0].attribute = code
            glyphs[code] = TDFGlyph(width: 250, height: 60, rows: r)
        }
        let font = TDFFont(name: "Huge", type: .color, spacing: 1, glyphs: glyphs)
        #expect(throws: TDFError.blockTooLarge("Huge")) { try TDFFile.write([font]) }
    }

    @Test func writerRefusesLongNamesAndKeepsCP437() throws {
        let glyph = TDFGlyph(width: 1, height: 1, rows: [TDFRow(cells: [TDFCell(code: 0xDB)])])
        let font = TDFFont(name: "Ñoño", type: .block, spacing: 1, glyphs: [65: glyph])
        let back = try TDFFile.parse(TDFFile.write([font])).fonts[0]
        #expect(back.name == "Ñoño")
        var long = font
        long.name = "ThirteenChars"
        #expect(throws: TDFError.nameTooLong("ThirteenChars")) { try TDFFile.write([long]) }
    }
}

/// A small deterministic generator for fuzz tests.
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
