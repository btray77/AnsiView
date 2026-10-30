import Testing
@testable import AnsiCore

@Test func vgaIsEightBySixteen() {
    #expect(BitmapFont.vga.width == 8)
    #expect(BitmapFont.vga.height == 16)
}

@Test func fullBlockIsSolid() {
    #expect(BitmapFont.vga.pixels(for: 0xDB).allSatisfy { $0 })
}

@Test func spaceIsEmpty() {
    #expect(!BitmapFont.vga.pixels(for: 0x20).contains(true))
}

@Test func lowerHalfBlock() {
    let p = BitmapFont.vga.pixels(for: 0xDC)
    #expect(!p[0])
    #expect(p[15 * 8])
}

@Test func letterAHasPixelsInMiddleRows() {
    #expect(BitmapFont.vga.pixels(for: 0x41)[(7 * 8)..<(8 * 8)].contains(true))
}

@Test func lightShadeIsAQuarterLit() {
    let lit = BitmapFont.vga.pixels(for: 0xB0).filter { $0 }.count
    #expect(lit == 32)
}

@Test func unknownNameFallsBackToVGA() {
    #expect(BitmapFont.named("No Such Font").name == BitmapFont.vga.name)
    #expect(BitmapFont.named(nil).name == BitmapFont.vga.name)
    #expect(BitmapFont.named("").name == BitmapFont.vga.name)
}

@Test func sauceNamesResolve() {
    #expect(!BitmapFont.supportedNames.isEmpty)
    for name in BitmapFont.supportedNames {
        #expect(BitmapFont.named(name).height > 0)
    }
}

@Test func vga50UsesEightByEight() {
    #expect(BitmapFont.named("IBM VGA50").height == 8)
}

@Test func rawGlyphsDecodeMSBFirst() {
    var raw = [UInt8](repeating: 0, count: 256 * 16)
    raw[0x41 * 16] = 0x80
    let font = BitmapFont(rawGlyphs: raw, height: 16)
    #expect(font.pixels(for: 0x41)[0])
    #expect(!font.pixels(for: 0x41)[1])
}

@Test func ninthColumnDuplicatesBoxDrawing() {
    #expect(BitmapFont.vga.ninthColumn(for: 0xC4).contains(true))
    #expect(!BitmapFont.vga.ninthColumn(for: 0x41).contains(true))
}
