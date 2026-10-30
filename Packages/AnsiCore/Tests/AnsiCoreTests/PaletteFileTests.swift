import Foundation
import Testing
@testable import AnsiCore

struct PaletteFileTests {
    /// 16 distinct colours: entry i is (i*16, 255 - i*16, i).
    var sixteen: [RGB] {
        (0..<16).map { (i: Int) -> RGB in
            let step = UInt8(i * 16)
            return RGB(r: step, g: 255 - step, b: UInt8(i))
        }
    }

    @Test func jascParses() throws {
        let text = "JASC-PAL\r\n0100\r\n16\r\n" + sixteen.map { "\($0.r) \($0.g) \($0.b)" }.joined(separator: "\r\n") + "\r\n"
        let palette = try PaletteFile.load(Data(text.utf8), fileExtension: "pal", name: "Test")
        #expect(palette.name == "Test")
        #expect(palette.colors == sixteen)
    }

    @Test func gimpParsesWithCommentsAndNames() throws {
        var text = "GIMP Palette\nName: Sunset Sixteen\nColumns: 8\n#\n# a comment\n"
        for (i, c) in sixteen.enumerated() { text += String(format: "%3d %3d %3d\tColour %d\n", c.r, c.g, c.b, i) }
        let palette = try PaletteFile.load(Data(text.utf8), fileExtension: "gpl", name: "file name")
        #expect(palette.name == "Sunset Sixteen")
        #expect(palette.colors == sixteen)
    }

    @Test func actParses768AndCount() throws {
        var bytes = [UInt8](repeating: 0, count: 768)
        for (i, c) in sixteen.enumerated() { bytes[i * 3] = c.r; bytes[i * 3 + 1] = c.g; bytes[i * 3 + 2] = c.b }
        #expect(try PaletteFile.load(Data(bytes), fileExtension: "act", name: "A").colors == sixteen)
        // With a count of 4 and a transparency index: the other 12 come from VGA.
        let counted = try PaletteFile.load(Data(bytes + [0x00, 0x04, 0xFF, 0xFF]), fileExtension: "ACT", name: "B")
        #expect(Array(counted.colors.prefix(4)) == Array(sixteen.prefix(4)))
        #expect(Array(counted.colors.suffix(12)) == Array(Palette.vga.suffix(12)))
    }

    @Test func xbinEmbeddedPalette() throws {
        var six = [UInt8](repeating: 0, count: 48)
        six[3] = 63 // entry 1 red at full
        let header = Array("XBIN".utf8) + [0x1A, 1, 0, 1, 0, 16, 0x01]
        let bytes = header + six + [0x41, 0x01]
        let palette = try PaletteFile.load(Data(bytes), fileExtension: "xb", name: "Art")
        #expect(palette.colors[1] == RGB(r: 255, g: 0, b: 0))
        #expect(palette.colors[0] == RGB(r: 0, g: 0, b: 0))
        // An XBin without its own palette has nothing to load.
        #expect(throws: PaletteFile.LoadError.self) {
            try PaletteFile.load(Data(header.dropLast() + [0x00, 0x41, 0x07]), fileExtension: "xb", name: "Art")
        }
    }

    @Test func adfEmbeddedPalette() throws {
        var table = [UInt8](repeating: 0, count: 192)
        // ADF colour 6 (brown) is table entry 20; colour 8 is entry 56.
        table[20 * 3] = 42
        table[56 * 3 + 2] = 63
        let bytes = [UInt8(1)] + table + [UInt8](repeating: 0, count: 4096) + [0x41, 0x07]
        let palette = try PaletteFile.load(Data(bytes), fileExtension: "adf", name: "Art")
        #expect(palette.colors[6] == RGB(r: 170, g: 0, b: 0))
        #expect(palette.colors[8] == RGB(r: 0, g: 0, b: 255))
        let file = ArtFile(data: Data(bytes), fileExtension: "adf")
        #expect(file.embeddedPalette == palette.colors)
    }

    @Test func shortPalettesPadWithVGA() throws {
        let text = "JASC-PAL\n0100\n2\n1 2 3\n4 5 6\n"
        let colors = try PaletteFile.load(Data(text.utf8), fileExtension: "pal", name: "Two").colors
        #expect(colors.count == 16)
        #expect(colors[0] == RGB(r: 1, g: 2, b: 3))
        #expect(colors[2] == Palette.vga[2])
        #expect(PaletteFile.normalized(sixteen + sixteen) == sixteen)
    }

    @Test func junkThrows() {
        #expect(throws: PaletteFile.LoadError.self) { try PaletteFile.load(Data("hello".utf8), fileExtension: "pal", name: "x") }
        #expect(throws: PaletteFile.LoadError.self) { try PaletteFile.load(Data([1, 2, 3]), fileExtension: "act", name: "x") }
        #expect(throws: PaletteFile.LoadError.self) { try PaletteFile.load(Data("GIMP Palette\n".utf8), fileExtension: "gpl", name: "x") }
        #expect(throws: PaletteFile.LoadError.self) { try PaletteFile.load(Data(), fileExtension: "png", name: "x") }
        // Out of range numbers are a broken file, not a crash.
        #expect(throws: PaletteFile.LoadError.self) {
            try PaletteFile.load(Data("JASC-PAL\n0100\n1\n999 0 0\n".utf8), fileExtension: "pal", name: "x")
        }
    }

    @Test func builtInsAreSixteenColours() {
        #expect(PaletteFile.builtIn.map(\.name) == ["VGA", "CGA (dark yellow)", "Greyscale"])
        #expect(PaletteFile.builtIn.allSatisfy { $0.colors.count == 16 })
        #expect(PaletteFile.builtIn[1].colors[6] == RGB(r: 0xAA, g: 0xAA, b: 0x00))
    }

    @Test func remapByIndex() {
        let red = AnsiCell(code: 0x41, fg: Palette.vga[4], bg: Palette.vga[0])
        let custom = AnsiCell(code: 0x42, fg: RGB(r: 1, g: 2, b: 3), bg: Palette.vga[1])
        let screen = AnsiScreen(columns: 2, rows: [[red, custom]])
        let map = PaletteRemap.map(from: Palette.vga, to: sixteen)
        let out = PaletteRemap.apply(map, to: screen)
        #expect(out.rows[0][0].fg == sixteen[4])
        #expect(out.rows[0][0].bg == sixteen[0])
        #expect(out.rows[0][1].fg == RGB(r: 1, g: 2, b: 3))
        #expect(out.rows[0][1].bg == sixteen[1])
        #expect(PaletteRemap.map(from: Palette.vga, to: Palette.vga).isEmpty)
    }

    @Test func remapUsesTheFilesOwnPalette() {
        var six = [UInt8](repeating: 0, count: 48)
        six[3 * 7] = 63 // entry 7 is pure red in this file
        let bytes = Array("XBIN".utf8) + [0x1A, 1, 0, 1, 0, 16, 0x01] + six + [0x41, 0x07]
        let file = ArtFile(data: Data(bytes), fileExtension: "xb")
        let source = PaletteRemap.sourcePalette(for: file)
        #expect(source[7] == RGB(r: 255, g: 0, b: 0))
        let out = PaletteRemap.apply(PaletteRemap.map(from: source, to: sixteen), to: AnsiAnalysis(file).finalScreen)
        #expect(out.rows[0][0].fg == sixteen[7])
        #expect(PaletteRemap.sourcePalette(for: ArtFile(data: Data("A".utf8), fileExtension: "ans")) == Palette.vga)
    }

    @Test func palettesRoundTripThroughJSON() throws {
        let palette = NamedPalette(name: "Test", colors: sixteen)
        let decoded = try JSONDecoder().decode(NamedPalette.self, from: JSONEncoder().encode(palette))
        #expect(decoded == palette)
    }
}
