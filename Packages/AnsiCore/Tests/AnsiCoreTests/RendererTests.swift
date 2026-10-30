import CoreGraphics
import Foundation
import Testing
@testable import AnsiCore

private let red = Palette.vga[4]
private let blue = Palette.vga[1]
private let white = Palette.vga[15]

private func screen(_ cells: [AnsiCell], columns: Int? = nil, sauce: Sauce? = nil) -> AnsiScreen {
    var s = AnsiScreen(columns: columns ?? cells.count, rows: [cells])
    s.sauce = sauce
    return s
}

/// The RGB at (x, y), top left origin.
private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> RGB {
    let data = image.dataProvider!.data! as Data
    let offset = y * image.bytesPerRow + x * 4
    return RGB(r: data[offset], g: data[offset + 1], b: data[offset + 2])
}

private func render(_ s: AnsiScreen, nine: Bool = false, scale: Int = 1, blinkVisible: Bool = true) -> RenderedAnsi {
    AnsiRenderer.render(s, options: RenderOptions(font: .vga, ninePixel: nine, scale: scale, blinkVisible: blinkVisible))!
}

@Test func fullBlockFillsCellWithForeground() {
    let img = render(screen([AnsiCell(code: 0xDB, fg: red, bg: blue)])).image
    #expect(pixel(img, 0, 0) == red)
    #expect(pixel(img, 7, 15) == red)
}

@Test func spaceShowsBackground() {
    let img = render(screen([AnsiCell(code: 0x20, fg: red, bg: blue)])).image
    #expect(pixel(img, 4, 8) == blue)
}

@Test func ninePixelModeWidensCells() {
    let row = [AnsiCell](repeating: AnsiCell(), count: 80)
    #expect(render(screen(row), nine: true).image.width == 720)
    #expect(render(screen(row)).image.width == 640)
}

@Test func ninePixelDuplicatesBoxDrawingColumn() {
    let lineRow = (0..<16).first { BitmapFont.vga.pixels(for: 0xC4)[$0 * 8 + 7] }!
    let box = render(screen([AnsiCell(code: 0xC4, fg: white, bg: blue)]), nine: true).image
    #expect(pixel(box, 8, lineRow) == white)
    let letter = render(screen([AnsiCell(code: 0x41, fg: white, bg: blue)]), nine: true).image
    #expect((0..<16).allSatisfy { pixel(letter, 8, $0) == blue })
}

@Test func scaleThreeTriplesSize() {
    let img = render(screen([AnsiCell()]), scale: 3).image
    #expect(img.width == 8 * 3)
    #expect(img.height == 16 * 3)
}

@Test func legacyAspectReported() {
    var sauce = Sauce.read(makeSauce(flags: 0b0000_1000)).sauce!
    #expect(render(screen([AnsiCell()], sauce: sauce)).pixelAspect == 1.2)
    sauce.flags = 0b0000_1100
    #expect(render(screen([AnsiCell()], sauce: sauce), nine: true).pixelAspect == 1.35)
    #expect(render(screen([AnsiCell()])).pixelAspect == 1.0)
}

@Test func blinkHiddenShowsBackground() {
    let cell = AnsiCell(code: 0xDB, fg: red, bg: blue, blink: true)
    #expect(pixel(render(screen([cell]), blinkVisible: false).image, 3, 8) == blue)
    #expect(pixel(render(screen([cell]), blinkVisible: true).image, 3, 8) == red)
}

@Test func optionsFollowTheScreen() {
    var sauce = Sauce.read(makeSauce(flags: 0b0000_0100, font: "IBM EGA")).sauce!
    sauce.fontName = "IBM EGA"
    var s = screen([AnsiCell()], sauce: sauce)
    s.font = BitmapFont.named("IBM EGA")
    let options = RenderOptions(for: s)
    #expect(options.ninePixel)
    #expect(options.font.height == 14)
}

@Test func rendersUnderTwoHundredMegabytesForMaxRows() {
    let rows = [[AnsiCell]](repeating: [AnsiCell](repeating: AnsiCell(code: 0x41), count: 80), count: AnsiTerminal.maxRows)
    let img = render(AnsiScreen(columns: 80, rows: rows)).image
    #expect(img.bytesPerRow * img.height < 200_000_000)
}

@Test func scalarCellsAreDrawn() {
    let euro = AnsiCell(code: 0x3F, fg: white, bg: blue, scalar: "€")
    let question = AnsiCell(code: 0x3F, fg: white, bg: blue)
    let a = render(screen([euro])).image
    let b = render(screen([question])).image
    let lit = (0..<16).flatMap { y in (0..<8).map { x in pixel(a, x, y) == white } }
    let litQuestion = (0..<16).flatMap { y in (0..<8).map { x in pixel(b, x, y) == white } }
    #expect(lit.contains(true))
    #expect(lit != litQuestion)
}
