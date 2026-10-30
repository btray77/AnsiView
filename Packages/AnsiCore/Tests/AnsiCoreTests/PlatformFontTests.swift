import CoreGraphics
import Foundation
import Testing
@testable import AnsiCore

@Test func cellGlyphIndexDrawsFromTheExtendedFont() throws {
    // Glyph 300 is solid, everything else blank.
    let glyphs = (0..<400).map { $0 == 300 ? [Bool](repeating: true, count: 64) : [Bool](repeating: false, count: 64) }
    let font = BitmapFont(name: "Test400", width: 8, height: 8, glyphs: glyphs)
    var cell = AnsiCell(code: 0x41, fg: RGB(r: 255, g: 255, b: 255), bg: RGB(r: 0, g: 0, b: 0))
    cell.glyph = 300
    let screen = AnsiScreen(columns: 2, rows: [[cell, AnsiCell(code: 0x41)]])
    let image = try #require(AnsiRenderer.render(screen, options: RenderOptions(font: font, scale: 1))?.image)
    #expect(pixelAt(image, x: 3, y: 3) == RGB(r: 255, g: 255, b: 255))
    #expect(pixelAt(image, x: 11, y: 3) == RGB(r: 0, g: 0, b: 0))
    #expect(font.glyphCount == 400)
}

@Test func platformFontsHaveTheirGlyphSets() {
    #expect(PlatformFonts.petscii.glyphCount == 512)   // two sets, then the same underlined (C128)
    #expect(PlatformFonts.petscii.width == 8 && PlatformFonts.petscii.height == 8)
    #expect(PlatformFonts.atascii.glyphCount == 128)
    #expect(PlatformFonts.appleII.glyphCount == 160)   // 128 characters and 32 MouseText pictures
    #expect(PlatformFonts.topaz.glyphCount == 256)
    #expect(PlatformFonts.teletext.width == 12 && PlatformFonts.teletext.height == 20)
    #expect(PlatformFonts.teletext.glyphCount == TeletextGlyphs.count)
}

@Test func everyPrintableBaseGlyphIsDrawn() {
    for code in 0x21...0x7E {
        let lit = PlatformFonts.appleII.pixels(glyph: code).filter { $0 }.count
        #expect(lit > 0, "ASCII \(code)")
    }
    #expect(PlatformFonts.appleII.pixels(glyph: 0x20).allSatisfy { !$0 })
}

@Test func petsciiLettersAndGraphicsAreDistinct() {
    // Screen code 1 is A in the upper case set and a in the lower case set (offset 128).
    let upperA = PlatformFonts.petscii.pixels(glyph: 1)
    let lowerA = PlatformFonts.petscii.pixels(glyph: 128 + 1)
    #expect(upperA != lowerA)
    // 0x41 is a spade in the upper case set and A in the lower case set.
    #expect(PlatformFonts.petscii.pixels(glyph: 0x41) != PlatformFonts.petscii.pixels(glyph: 128 + 0x41))
    #expect(PlatformFonts.petscii.pixels(glyph: 128 + 0x41) == upperA)
    // Full block halves: 0x61 left half, 0x62 lower half.
    let left = PlatformFonts.petscii.pixels(glyph: 0x61)
    #expect(left[0] && left[3] && !left[4] && !left[7])
    let lower = PlatformFonts.petscii.pixels(glyph: 0x62)
    #expect(!lower[0] && lower[63])
}

@Test func teletextMosaicsFollowTheirBits() {
    // Mosaic 0x7F (all six cells) contiguous is a full cell; separated leaves gaps.
    let full = PlatformFonts.teletext.pixels(glyph: TeletextGlyphs.mosaic(0x7F, separated: false))
    #expect(full.allSatisfy { $0 })
    let separated = PlatformFonts.teletext.pixels(glyph: TeletextGlyphs.mosaic(0x7F, separated: true))
    #expect(separated.contains(false) && separated.contains(true))
    // 0x21 is the top left sixel only.
    let topLeft = PlatformFonts.teletext.pixels(glyph: TeletextGlyphs.mosaic(0x21, separated: false))
    #expect(topLeft[0] && !topLeft[11] && !topLeft[19 * 12])
}

@Test func teletextDoubleHeightHalvesStretchTheGlyph() {
    let normal = PlatformFonts.teletext.pixels(glyph: TeletextGlyphs.alpha(0x48))
    let top = PlatformFonts.teletext.pixels(glyph: TeletextGlyphs.doubleTop(TeletextGlyphs.alpha(0x48)))
    // Row 0 of the top half is row 0 of the glyph; row 2 of the top half is row 1.
    #expect(Array(top[0..<12]) == Array(normal[0..<12]))
    #expect(Array(top[24..<36]) == Array(normal[12..<24]))
}

@Test func existingCellsRenderUnchanged() throws {
    var screen = AnsiScreen(columns: 3, rows: [[AnsiCell(code: 0x41), AnsiCell(code: 0xDB, fg: Palette.vga[12]), AnsiCell(code: 0xB0)]])
    screen.font = .vga
    let image = try #require(AnsiRenderer.render(screen, options: RenderOptions(font: .vga, scale: 1))?.image)
    #expect(pixelAt(image, x: 12, y: 8) == Palette.vga[12])
}

func pixelAt(_ image: CGImage, x: Int, y: Int) -> RGB {
    var data = [UInt8](repeating: 0, count: 4)
    let context = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.interpolationQuality = .none
    context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
    return RGB(r: data[0], g: data[1], b: data[2])
}
