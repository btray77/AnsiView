import Foundation
import Testing
@testable import AnsiCore

/// Final gaps rulings 1 to 7: .ICE, .ADF, .IDF, PCBoard, Wildcat, Avatar/0 and AVT/0+ writers,
/// each read back through AnsiView's own readers.
@Suite struct FormatWriterTests {
    /// A 6 bit palette (every channel a multiple of 255 / 63) so it survives the files' 6 bit storage.
    static let palette: [RGB] = (0..<16).map { i in
        func six(_ v: Int) -> UInt8 { UInt8(v * 255 / 63) }
        return RGB(r: six((i * 7) % 64), g: six((i * 13 + 5) % 64), b: six((i * 29 + 11) % 64))
    }

    /// An original 8x16 font: every glyph a different pattern.
    static let font: BitmapFont = {
        var raw: [UInt8] = []
        for code in 0..<256 { for row in 0..<16 { raw.append(UInt8((code * 31 + row * 17) & 0xFF) ^ UInt8(row)) } }
        return BitmapFont(rawGlyphs: raw, height: 16)
    }()

    /// Random cells: `codes` characters, VGA (or `palette`) colours, blink only without iCE.
    static func randomCanvas(columns: Int, height: Int, ice: Bool, seed: UInt64, codes: [UInt8], colours: [RGB] = Palette.vga,
                             runs: Bool = true) -> EditCanvas {
        var rng = SeededGenerator(seed: seed)
        var canvas = EditCanvas(columns: columns, height: height)
        canvas.setIceColors(ice)
        if colours != Palette.vga { canvas.palette = colours }
        var y = 0, x = 0
        while y < height {
            let cell = AnsiCell(code: codes[Int(rng.next() % UInt64(codes.count))], fg: colours[Int(rng.next() % 16)],
                                bg: colours[Int(rng.next() % (ice ? 16 : 8))], blink: !ice && rng.next() % 5 == 0)
            let length = runs && rng.next() % 4 == 0 ? Int(rng.next() % 12) + 1 : 1
            for _ in 0..<length where y < height {
                canvas.set(cell, x: x, y: y)
                x += 1
                if x == columns { x = 0; y += 1 }
            }
        }
        return canvas
    }

    /// Codes a stream format writes as themselves (control codes become lookalikes).
    static let textCodes = (0...255).map(UInt8.init).filter { !TextConvert.lookalikes.keys.contains($0) && !(0x01...0x1F).contains($0) && $0 != 0x7F }

    static func reread(_ data: Data, ext: String) -> EditCanvas {
        EditCanvas(file: ArtFile(data: data, fileExtension: ext))
    }

    /// Cells of `a` and `b` over `a`'s area (missing cells count as blank), and how many differ.
    static func differences(_ a: EditCanvas, _ b: EditCanvas, normalize: (AnsiCell) -> AnsiCell = { $0 }) -> Int {
        var count = 0
        for y in 0..<max(a.screen(trimmed: true).rows.count, b.screen(trimmed: true).rows.count) {
            for x in 0..<a.columns where normalize(a[x, y]) != normalize(b[x, y]) { count += 1 }
        }
        return count
    }

    // MARK: Embedded fonts and palettes

    @Test func adfAndIdfReadersKeepTheirPaletteAndTheCanvasKeepsTheFont() throws {
        var raw: [UInt8] = [1]
        let slots = [0, 1, 2, 3, 4, 5, 20, 7, 56, 57, 58, 59, 60, 61, 62, 63]
        var sixty4 = [UInt8](repeating: 0, count: 192)
        for (i, slot) in slots.enumerated() {
            let c = Self.palette[i]
            sixty4[slot * 3] = c.r / 4; sixty4[slot * 3 + 1] = c.g / 4; sixty4[slot * 3 + 2] = c.b / 4
        }
        raw += sixty4
        for code in 0..<256 { raw += Self.font.pixels(for: UInt8(code)).chunked(8).map { $0.byte } }
        raw += [0x41, 0x1F] + [UInt8](repeating: 0, count: 158)
        let canvas = Self.reread(Data(raw), ext: "adf")
        #expect(canvas.palette == Self.palette)
        #expect(canvas.embeddedFont == Self.font)
        #expect(canvas.font == Self.font)
        #expect(canvas[0, 0] == AnsiCell(code: 0x41, fg: Self.palette[15], bg: Self.palette[1]))
    }

    @Test func xbinSavesKeepAnEmbeddedFont() throws {
        var canvas = Self.randomCanvas(columns: 60, height: 10, ice: true, seed: 1, codes: (0...255).map(UInt8.init))
        canvas.embeddedFont = Self.font
        let back = Self.reread(try ArtWriter.data(canvas, format: .xbin), ext: "xb")
        #expect(back.embeddedFont == Self.font)
        #expect(Self.differences(canvas, back) == 0)
    }

    @Test func projectFilesKeepAnEmbeddedFont() throws {
        var canvas = EditCanvas(columns: 20, height: 3)
        canvas.embeddedFont = Self.font
        let project = CanvasEditor(canvas: canvas).project
        let back = try ArtProject(data: try project.data())
        #expect(back.frames[0].layers[0].canvas.embeddedFont == Self.font)
    }

    // MARK: ADF

    @Test func adfRoundTripKeepsCellsPaletteAndFont() throws {
        var canvas = Self.randomCanvas(columns: 80, height: 30, ice: true, seed: 2, codes: (0...255).map(UInt8.init), colours: Self.palette)
        canvas.embeddedFont = Self.font
        let data = try ArtWriter.data(canvas, format: .adf)
        #expect(data.count == 1 + 192 + 4096 + 80 * 30 * 2)
        let back = Self.reread(data, ext: "adf")
        #expect(Self.differences(canvas, back) == 0)
        #expect(back.palette == Self.palette)
        #expect(back.embeddedFont == Self.font)
    }

    @Test func adfWritesTheNamedFontAndVGAWhenThereIsNoEmbeddedOne() throws {
        let canvas = Self.randomCanvas(columns: 40, height: 5, ice: false, seed: 3, codes: (0...255).map(UInt8.init))
        let back = Self.reread(try ArtWriter.data(canvas, format: .adf), ext: "adf")
        #expect(back.columns == 80)
        #expect(back.embeddedFont.map { f in (0..<256).allSatisfy { f.pixels(for: UInt8($0)) == BitmapFont.vga.pixels(for: UInt8($0)) } } == true)
        #expect(back.palette == nil || back.palette == Palette.vga)
        // Blinking cells become bright backgrounds (ADF is always iCE).
        #expect(Self.differences(canvas, back, normalize: { EditCanvas.cell($0, iceColors: true) }) == 0)
    }

    @Test func adfRefusesArtWiderThan80Columns() {
        #expect(throws: ArtWriter.WriteError.self) { try ArtWriter.data(EditCanvas(columns: 81, height: 2), format: .adf) }
    }

    // MARK: IDF

    @Test func idfRoundTripKeepsCellsPaletteAndFontAndCompresses() throws {
        var canvas = Self.randomCanvas(columns: 100, height: 20, ice: true, seed: 4, codes: (0...255).map(UInt8.init), colours: Self.palette)
        canvas.embeddedFont = Self.font
        // A literal 01 00 pair (character 1, black on black) must not read as a run.
        canvas.set(AnsiCell(code: 0x01, fg: Self.palette[0], bg: Self.palette[0]), x: 5, y: 5)
        let data = try ArtWriter.data(canvas, format: .idf)
        #expect(Array(data.prefix(4)) == [0x04] + Array("1.4".utf8))
        #expect(data.count < 12 + 100 * 20 * 2 + 4096 + 48)
        let back = Self.reread(data, ext: "idf")
        #expect(back.columns == 100)
        #expect(Self.differences(canvas, back) == 0)
        #expect(back.palette == Self.palette)
        #expect(back.embeddedFont == Self.font)
    }

    // MARK: ICE

    @Test func iceFilesAreAnsiWithIceColours() throws {
        let ice = Self.randomCanvas(columns: 80, height: 12, ice: true, seed: 5, codes: Self.textCodes)
        let data = try ArtWriter.data(ice, format: .ice)
        let back = Self.reread(data, ext: "ice")
        #expect(back.iceColors)
        #expect(Sauce.read([UInt8](data)).0?.iceColors == true)
        #expect(Self.differences(ice, back) == 0)
        let blinking = Self.randomCanvas(columns: 80, height: 12, ice: false, seed: 6, codes: Self.textCodes)
        let fromBlink = Self.reread(try ArtWriter.data(blinking, format: .ice), ext: "ice")
        #expect(Self.differences(blinking, fromBlink, normalize: { EditCanvas.cell($0, iceColors: true) }) == 0)
    }

    // MARK: PCBoard and Wildcat

    /// PCBoard's @X00 means "save the colour", so black on black is written as grey (blank) or dark grey (text).
    static func pcboardNormal(_ c: AnsiCell) -> AnsiCell {
        var c = c
        if c.fg == Palette.vga[0], c.bg == Palette.vga[0], !c.blink { c.fg = (c.code == 0x20 || c.code == 0) ? Palette.vga[7] : Palette.vga[8] }
        if c.code == 0 { c.code = 0x20 }
        // @XFF restores the colour, so bright white on bright grey is saved without the bright background.
        if c.fg == Palette.vga[15], c.bg == Palette.vga[15] || (c.bg == Palette.vga[7] && c.blink) { c.bg = Palette.vga[7]; c.blink = false }
        return c
    }

    @Test func pcboardRoundTrip() throws {
        for ice in [false, true] {
            let canvas = Self.randomCanvas(columns: 80, height: 25, ice: ice, seed: 7, codes: Self.textCodes)
            let data = try ArtWriter.data(canvas, format: .pcboard)
            #expect(Sauce.read([UInt8](data)).0.map { [$0.dataType, $0.fileType] } == [1, 4])
            #expect(String(decoding: data.prefix(4), as: UTF8.self).hasPrefix("@X"))
            let back = Self.reread(data, ext: "pcb")
            #expect(Self.differences(canvas, back, normalize: Self.pcboardNormal) == 0, "ice \(ice)")
        }
    }

    @Test func pcboardAndWildcatKeepLiteralAtSigns() throws {
        var canvas = EditCanvas(columns: 40, height: 2)
        for (i, ch) in "@X1F @CLS@ @1F@ @@X07".utf8.enumerated() { canvas.set(AnsiCell(code: ch), x: i, y: 0) }
        for (format, ext) in [(SaveFormat.pcboard, "pcb"), (.wildcat, "bbs")] {
            let back = Self.reread(try ArtWriter.data(canvas, format: format), ext: ext)
            #expect(Self.differences(canvas, back) == 0, "\(format)")
        }
    }

    @Test func wildcatRoundTripIsDetectedWithoutASauceRecord() throws {
        let canvas = Self.randomCanvas(columns: 80, height: 25, ice: false, seed: 8, codes: Self.textCodes)
        let data = try ArtWriter.data(canvas, format: .wildcat)
        #expect(Sauce.read([UInt8](data)).0 == nil)
        #expect(ArtFile(data: data, fileExtension: "bbs").format == .wildcat)
        #expect(ArtFile(data: data, fileExtension: nil).format == .wildcat)
        #expect(Self.differences(canvas, Self.reread(data, ext: "bbs")) == 0)
    }

    // MARK: Avatar

    @Test func avatarRoundTripUsesRepeats() throws {
        for ice in [false, true] {
            let canvas = Self.randomCanvas(columns: 80, height: 25, ice: ice, seed: 9, codes: Self.textCodes)
            let data = try ArtWriter.data(canvas, format: .avatar)
            let bytes = [UInt8](data)
            #expect(Sauce.read(bytes).0.map { [$0.dataType, $0.fileType] } == [1, 5])
            #expect(bytes.contains(0x19))
            #expect(!zip(bytes, bytes.dropFirst()).contains { $0 == (0x16, 0x19) })
            #expect(Self.differences(canvas, Self.reread(data, ext: "avt")) == 0, "ice \(ice)")
        }
    }

    @Test func avt0PlusPatternRepeatIsShorterAndReadsBack() throws {
        var canvas = EditCanvas(columns: 80, height: 4)
        let pattern: [UInt8] = [0xC4, 0xC2, 0xC4, 0xC1]
        for x in 0..<80 { canvas.set(AnsiCell(code: pattern[x % 4], fg: Palette.vga[11]), x: x, y: 1) }
        for x in 0..<78 { canvas.set(AnsiCell(code: x % 2 == 0 ? 0xB0 : 0xB2, fg: Palette.vga[4], bg: Palette.vga[1]), x: x, y: 2) }
        let plain = try ArtWriter.data(canvas, format: .avatar)
        let plus = try ArtWriter.data(canvas, format: .avatarPlus)
        #expect(plus.count < plain.count)
        let bytes = [UInt8](plus)
        #expect(zip(bytes, bytes.dropFirst()).contains { $0 == (0x16, 0x19) })
        #expect(Self.differences(canvas, Self.reread(plus, ext: "avt")) == 0)
        // The terminal's AVT/0+ emulation draws the same screen.
        var terminal = AvatarTerminal(columns: 80, rows: 25)
        terminal.feed(Array(bytes.prefix(Sauce.read(bytes).1)))
        let screen = terminal.screen(scrollOffset: 0)
        for y in 0..<4 { for x in 0..<80 { #expect(screen.rows[y][x] == canvas[x, y], "\(x),\(y)") } }
    }

    @Test func avt0PlusRandomArtStillRoundTrips() throws {
        for seed in 10..<14 {
            let canvas = Self.randomCanvas(columns: 80, height: 25, ice: seed % 2 == 0, seed: UInt64(seed), codes: Self.textCodes)
            #expect(Self.differences(canvas, Self.reread(try ArtWriter.data(canvas, format: .avatarPlus), ext: "avt")) == 0)
        }
    }

    // MARK: Formats list and reports

    @Test func everyFormatHasAnExtensionLabelAndSuggestion() {
        #expect(SaveFormat.allCases.map(\.fileExtension) == ["ans", "ice", "bin", "xb", "adf", "idf", "pcb", "bbs", "avt", "avt"])
        #expect(SaveFormat.suggested(for: .adf) == .adf)
        #expect(SaveFormat.suggested(for: .idf) == .idf)
        #expect(SaveFormat.suggested(for: .pcboard) == .pcboard)
        #expect(SaveFormat.suggested(for: .wildcat) == .wildcat)
        #expect(SaveFormat.suggested(for: .avatar) == .avatar)
        #expect(Set(SaveFormat.allCases.map(\.label)).count == SaveFormat.allCases.count)
    }

    /// Review minors: SAUCE font names only where the SAUCE spec has them; the font note names
    /// the font that is really written; wide Wildcat art is not counted as a round trip failure.
    @Test func reviewMinors() throws {
        var canvas = EditCanvas(columns: 40, height: 2)
        canvas.fontName = "IBM EGA"
        for format in [SaveFormat.pcboard, .avatar, .avatarPlus] {
            #expect(Sauce.read([UInt8](try ArtWriter.data(canvas, format: format))).0?.fontName == "", "\(format)")
        }
        // An 8x14 embedded font: IBM VGA (the named 8x16 font) is written, and the note names it.
        var ega = EditCanvas(columns: 40, height: 2)
        ega.embeddedFont = BitmapFont(rawGlyphs: [], height: 14)
        #expect(SaucePreservation.saveReport(ega, format: .adf).joined().contains("IBM VGA"))
        let wide = SaveRoundTrip.check(EditCanvas(columns: 120, height: 2), format: .wildcat)
        #expect(wide.refused != nil)
    }

    @Test func saveReportsSayWhatEachFormatCannotKeep() {
        var canvas = Self.randomCanvas(columns: 40, height: 3, ice: false, seed: 20, codes: Self.textCodes)
        canvas.title = "T"
        func report(_ f: SaveFormat) -> String { SaucePreservation.saveReport(canvas, format: f).joined(separator: " ") }
        #expect(report(.adf).contains("80 columns"))
        #expect(report(.adf).contains("SAUCE"))
        #expect(report(.adf).contains("bright background"))
        #expect(report(.idf).contains("bright background"))
        #expect(report(.ice).contains("bright background"))
        #expect(report(.wildcat).contains("SAUCE"))
        var black = EditCanvas(columns: 10, height: 1)
        black.set(AnsiCell(code: 0x41, fg: Palette.vga[0], bg: Palette.vga[0]), x: 0, y: 0)
        #expect(SaucePreservation.saveReport(black, format: .pcboard).joined().contains("@X00"))
        #expect(SaucePreservation.saveReport(EditCanvas(columns: 90, height: 1), format: .wildcat).joined().contains("90"))
    }
}

@Suite struct SaveRoundTripTests {
    @Test func everyFormatReadsBackWhatItCanHold() {
        for trueColor in [false, true] {
            let wide = sampleCanvas(trueColor: trueColor)
            var blinking = FormatWriterTests.randomCanvas(columns: 80, height: 25, ice: false, seed: 30,
                                                          codes: (0...255).map(UInt8.init))
            blinking.set(AnsiCell(code: 0x41, fg: RGB(r: 1, g: 2, b: 3), bg: RGB(r: 90, g: 9, b: 9)), x: 0, y: 0)
            for format in SaveFormat.allCases {
                for canvas in [wide, blinking] {
                    let result = SaveRoundTrip.check(canvas, format: format)
                    if format == .adf, canvas.columns > 80 { #expect(result.refused != nil); continue }
                    if format == .wildcat, canvas.columns > 80 { continue }
                    #expect(result.refused == nil)
                    #expect(result.differing == 0, "\(format) trueColor \(trueColor) columns \(canvas.columns)")
                }
            }
        }
    }
}

extension Array where Element == Bool {
    func chunked(_ size: Int) -> [[Bool]] { stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) } }
    /// Eight pixels as a byte, leftmost the high bit.
    var byte: UInt8 { enumerated().reduce(0) { $1.element ? $0 | (0x80 >> UInt8($1.offset)) : $0 } }
}
