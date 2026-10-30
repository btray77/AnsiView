import Testing
@testable import AnsiCore

// The EGA 8x14 TTF has 1600 units per em and 200 units per pixel column: its pixel grid is
// 16 points, not 14. Drawn at 14 points it lost its first row and last column.
@Test func egaFullBlockFillsTheCell() {
    let ega = BitmapFont.named("IBM EGA")
    #expect(ega.width == 8 && ega.height == 14)
    let block = ega.pixels(for: 0xDB)
    #expect(block.filter { $0 }.count == 8 * 14)
}

@Test func egaHalfBlocksSplitTheCell() {
    let ega = BitmapFont.named("IBM EGA")
    let upper = ega.pixels(for: 0xDF), lower = ega.pixels(for: 0xDC), left = ega.pixels(for: 0xDD)
    #expect(upper.prefix(7 * 8).allSatisfy { $0 } && !upper.suffix(7 * 8).contains(true))
    #expect(lower.suffix(7 * 8).allSatisfy { $0 } && !lower.prefix(7 * 8).contains(true))
    #expect((0..<14).allSatisfy { row in (0..<4).allSatisfy { left[row * 8 + $0] } && !(4..<8).contains { left[row * 8 + $0] } })
}

@Test func otherBundledFontsKeepFullBlocks() {
    for name in ["IBM VGA", "IBM VGA50", "IBM EGA43"] {
        #expect(BitmapFont.named(name).pixels(for: 0xDB).allSatisfy { $0 }, "\(name)")
    }
}

@Test func rasterSizeFollowsThePixelGrid() {
    #expect(BitmapFont.rasterSize(advance: 800, unitsPerEm: 1600, width: 8) == 16)
    #expect(BitmapFont.rasterSize(advance: 800, unitsPerEm: 800, width: 8) == 8)
    #expect(BitmapFont.rasterSize(advance: 0, unitsPerEm: 1600, width: 8) == nil)
}
