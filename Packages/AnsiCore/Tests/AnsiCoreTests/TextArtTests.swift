import Foundation
import Testing
@testable import AnsiCore

struct TextArtTests {
    static func glyph(_ lines: [String], attribute: UInt8 = 0) -> TDFGlyph {
        TDFGlyph(rows: lines.map { line in
            TDFRow(cells: line.unicodeScalars.map { TDFCell(code: CP437.code(for: $0) ?? 0x3F, attribute: attribute) })
        })
    }

    static func codes(_ region: CanvasRegion) -> [String] {
        region.cells.map { row in String(String.UnicodeScalarView(row.map { CP437.unicode[Int($0.code)] })) }
    }

    let vga = Palette.vga

    @Test func outlineStyleTableHasAllNineteenStyles() {
        #expect(TextArt.outlineStyles.count == 19)
        #expect(TextArt.outlineStyles.allSatisfy { $0.count == 17 })
        // Style 0 is the single line style: A top edge, B bottom, C left, D right, E to L corners.
        let single = TextArt.outlineStyles[0].map { CP437.unicode[Int($0)] }
        #expect(String(String.UnicodeScalarView(single)) == "──││┌┐┌┐└┘└┘┤├   ")
        // Style 15 is all double; 16 to 18 are block styles.
        let double = TextArt.outlineStyles[15].map { CP437.unicode[Int($0)] }
        #expect(String(String.UnicodeScalarView(double)) == "══║║╔╗╔╗╚╝╚╝╣╠   ")
        #expect(TextArt.outlineStyles[16][2] == 219)
        #expect(TextArt.outlineStyles[18][0] == 223 && TextArt.outlineStyles[18][1] == 220)
    }

    @Test func outlineGlyphUsesStyleAndCurrentColours() {
        let font = TDFFont(name: "O", type: .outline, spacing: 0,
                           glyphs: [65: Self.glyph(["@EAF", "@COD", "@KBL"])])
        var options = TextArtOptions()
        options.foreground = 14
        options.background = 1
        let single = TextArt.render("A", font: .tdf(font), options: options).region
        #expect(Self.codes(single) == [" ┌─┐", " │ │", " └─┘"])
        #expect(single.cells[1][1].fg == vga[14] && single.cells[1][1].bg == vga[1])
        // The `@` gap and the `O` hole are spaces in the current colours.
        #expect(single.cells[0][0] == AnsiCell(code: 0x20, fg: vga[14], bg: vga[1]))
        options.outlineStyle = 15
        #expect(Self.codes(TextArt.render("A", font: .tdf(font), options: options).region) == [" ╔═╗", " ║ ║", " ╚═╝"])
        // Out of range styles are clamped.
        options.outlineStyle = 99
        #expect(Self.codes(TextArt.render("A", font: .tdf(font), options: options).region)[0] == " ▐▀▌")
    }

    @Test func outlineLettersPastQAreBlank() {
        let font = TDFFont(name: "O", type: .outline, spacing: 0, glyphs: [65: Self.glyph(["ARx"])])
        #expect(Self.codes(TextArt.render("A", font: .tdf(font), options: TextArtOptions()).region) == ["─ x"])
    }

    @Test func blockFontUsesCurrentColours() {
        let font = TDFFont(name: "B", type: .block, spacing: 1, glyphs: [
            65: Self.glyph(["█▀█", "█▀█"]), 66: Self.glyph(["██", "█▄"]),
        ])
        var options = TextArtOptions()
        options.foreground = 12
        let region = TextArt.render("AB", font: .tdf(font), options: options).region
        #expect(Self.codes(region) == ["█▀█ ██", "█▀█ █▄"])
        #expect(region.cells[0][0].fg == vga[12] && region.cells[0][0].bg == vga[0])
    }

    @Test func colourFontKeepsAttributes() {
        var g = Self.glyph(["█▓"], attribute: 0x4E)
        g.rows[0].cells[1].attribute = 0x9F
        let font = TDFFont(name: "C", type: .color, spacing: 0, glyphs: [65: g])
        var options = TextArtOptions()
        options.foreground = 2
        let plain = TextArt.render("A", font: .tdf(font), options: options).region
        #expect(plain.cells[0][0] == AnsiCell(code: 219, fg: vga[14], bg: vga[4]))
        // Bit 7 is blink; with iCE it is a bright background.
        #expect(plain.cells[0][1] == AnsiCell(code: 178, fg: vga[15], bg: vga[1], blink: true))
        options.iceColors = true
        let ice = TextArt.render("A", font: .tdf(font), options: options).region
        #expect(ice.cells[0][1] == AnsiCell(code: 178, fg: vga[15], bg: vga[9]))
    }

    @Test func shortRowsAndShortGlyphsLeaveGaps() {
        let font = TDFFont(name: "B", type: .block, spacing: 0, glyphs: [
            65: Self.glyph(["███", "█"]), 66: Self.glyph(["▄"]),
        ])
        let region = TextArt.render("AB", font: .tdf(font), options: TextArtOptions()).region
        #expect(region.width == 4 && region.height == 2)
        #expect(Self.codes(region) == ["███▄", "█   "])
    }

    @Test func spacingOverrideAndDefault() {
        let font = TDFFont(name: "B", type: .block, spacing: 2, glyphs: [65: Self.glyph(["█"])])
        #expect(Self.codes(TextArt.render("AA", font: .tdf(font), options: TextArtOptions()).region) == ["█  █"])
        var options = TextArtOptions()
        options.spacing = 0
        #expect(Self.codes(TextArt.render("AA", font: .tdf(font), options: options).region) == ["██"])
    }

    @Test func caseFallbackAndMissingCharacters() {
        let font = TDFFont(name: "B", type: .block, spacing: 0, glyphs: [
            65: Self.glyph(["A"]), 98: Self.glyph(["b"]), 67: Self.glyph(["CCCC"]),
        ])
        let result = TextArt.render("aB%c", font: .tdf(font), options: TextArtOptions())
        // a uses A, B uses b, % is missing (a space wide gap), c uses C.
        // Average width (1 + 1 + 4) / 3 = 2, half rounded up = 1.
        #expect(Self.codes(result.region) == ["Ab CCCC"])
        #expect(result.missing == ["%"])
    }

    @Test func spaceWidthIsHalfTheAverageGlyphWidth() {
        let font = TDFFont(name: "B", type: .block, spacing: 1, glyphs: [
            65: Self.glyph(["AAAAA"]), 66: Self.glyph(["BBBBBBB"]),
        ])
        // Average 6, half 3, plus spacing after each.
        #expect(Self.codes(TextArt.render("A B", font: .tdf(font), options: TextArtOptions()).region)
                == ["AAAAA     BBBBBBB"])
    }

    @Test func multipleLinesWithOneBlankRowBetween() {
        let font = TDFFont(name: "B", type: .block, spacing: 0, glyphs: [65: Self.glyph(["AA", "AA"]), 66: Self.glyph(["B"])])
        let region = TextArt.render("A\nBB", font: .tdf(font), options: TextArtOptions()).region
        #expect(Self.codes(region) == ["AA", "AA", "  ", "BB"])
    }

    @Test func alignment() {
        let font = TDFFont(name: "B", type: .block, spacing: 0, glyphs: [65: Self.glyph(["A"])])
        var options = TextArtOptions()
        options.alignment = .right
        #expect(Self.codes(TextArt.render("AAAA\nA", font: .tdf(font), options: options).region) == ["AAAA", "    ", "   A"])
        options.alignment = .center
        #expect(Self.codes(TextArt.render("AAAAA\nA", font: .tdf(font), options: options).region)[2] == "  A  ")
    }

    @Test func wrapsWordsToWidthAndCutsLongWords() {
        let font = TDFFont(name: "B", type: .block, spacing: 1, glyphs: [65: Self.glyph(["AA"])])
        var options = TextArtOptions()
        options.wrapWidth = 9
        // "AA AA" is 2+1 + 1+1 (space width 1 plus spacing) + 2 = 7 columns wide: fits.
        let fits = TextArt.render("A A", font: .tdf(font), options: options).region
        #expect(fits.height == 1)
        // Three words do not: the third moves to a new line.
        let wrapped = TextArt.render("A A A", font: .tdf(font), options: options).region
        #expect(Self.codes(wrapped).map { $0.trimmingCharacters(in: .whitespaces) } == ["AA   AA", "", "AA"])
        // A word wider than the width is cut between letters.
        let long = TextArt.render("AAAAA", font: .tdf(font), options: options).region
        #expect(long.width <= 9)
        #expect(long.height == 3)
    }

    @Test func gradientColoursMonochromeFonts() {
        let font = TDFFont(name: "B", type: .block, spacing: 0, glyphs: [65: Self.glyph(["AAAA", "AAAA"])])
        var options = TextArtOptions()
        options.gradient = TextArtGradient(colors: [9, 12], direction: .columns)
        let region = TextArt.render("A", font: .tdf(font), options: options).region
        #expect(region.cells[0].map(\.fg) == [vga[9], vga[9], vga[12], vga[12]])
        options.gradient = TextArtGradient(colors: [9, 12], direction: .rows)
        let rows = TextArt.render("A", font: .tdf(font), options: options).region
        #expect(rows.cells.map { $0[0].fg } == [vga[9], vga[12]])
    }

    @Test func clippedToCanvasLimits() {
        let font = TDFFont(name: "B", type: .block, spacing: 0, glyphs: [65: Self.glyph([String(repeating: "A", count: 200)])])
        let region = TextArt.render(String(repeating: "A", count: 20), font: .tdf(font), options: TextArtOptions()).region
        #expect(region.width == EditCanvas.maxColumns)
    }

    @Test func emptyTextAndEmptyFont() {
        let font = TDFFont(name: "E", type: .block, spacing: 0, glyphs: [:])
        #expect(TextArt.render("", font: .tdf(font), options: TextArtOptions()).region.height == 0)
        let result = TextArt.render("Hi", font: .tdf(font), options: TextArtOptions())
        #expect(result.missing == ["H", "i"])
    }
}
