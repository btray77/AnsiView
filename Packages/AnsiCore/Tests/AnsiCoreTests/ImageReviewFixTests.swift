import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import AnsiCore

/// Fixes from the image import branch's final review.
@Suite struct ImageReviewFixTests {
    /// Review Important 1: a canvas too big to render whole must still score against the whole picture.
    @Test func scoreCoversWideCanvases() {
        let image = makeImage(100, 100) { _, y in y < 50 ? Palette.vga[12] : Palette.vga[1] }
        var o = ImageToAnsi.Options()
        o.columns = 1000
        o.mode = .fullBlocks
        o.dither = .none
        let canvas = ImageToAnsi.convert(image, options: o)
        #expect(canvas.height == 500)
        let score = ImageScore.score(canvas, source: image, options: o)
        #expect(score.deltaE < 1, "\(score)")
    }

    /// Review Important 3: EXIF orientation is applied (a portrait phone photo stays upright).
    @Test func exifOrientationApplied() throws {
        let landscape = makeImage(8, 4) { x, _ in x < 4 ? RGB(r: 255, g: 0, b: 0) : RGB(r: 0, g: 0, b: 255) }
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, landscape, [kCGImagePropertyOrientation: 6] as CFDictionary)
        CGImageDestinationFinalize(destination)
        let loaded = try ImageToAnsi.load(data as Data)
        #expect(loaded.width == 4 && loaded.height == 8)
        let plain = try ImageToAnsi.load(encode([landscape], type: .png))
        #expect(plain.width == 8 && plain.height == 4)
    }

    /// Review Important 4: ordered dithering changes glyph search results on a flat colour.
    @Test func orderedDitherWorksWithGlyphSearch() {
        let grey = makeImage(80, 80) { _, _ in RGB(r: 128, g: 128, b: 128) }
        var o = ImageToAnsi.Options()
        o.columns = 20
        o.mode = .glyphs
        o.dither = .none
        let none = ImageToAnsi.convert(grey, options: o)
        o.dither = .ordered
        o.ditherStrength = 1
        let ordered = ImageToAnsi.convert(grey, options: o)
        #expect(none != ordered)
        let cells = Set(ordered.rows.flatMap { $0 }.map { "\($0.code) \($0.fg) \($0.bg)" })
        #expect(cells.count > 1)
    }

    /// Review Important 5: an XBin palette survives opening the saved file for editing.
    @Test func xbinPaletteSurvivesReopening() throws {
        let image = makeImage(64, 32) { x, y in RGB(r: UInt8(x * 4), g: UInt8(255 - y * 8), b: UInt8(x * 2)) }
        var o = ImageToAnsi.Options()
        o.columns = 40
        o.palette = .imagePalette
        let canvas = ImageToAnsi.convert(image, options: o)
        let data = try ArtWriter.data(canvas, format: .xbin)
        let reopened = EditCanvas(file: ArtFile(data: data, fileExtension: "xb"))
        #expect(reopened.palette == canvas.palette)
        let again = try ArtWriter.data(reopened, format: .xbin)
        #expect([UInt8](again)[10] & 0x01 == 0x01)
        let a = renderedPixels(AnsiAnalysis(ArtFile(data: again, fileExtension: "xb")).finalScreen)
        let b = renderedPixels(canvas.screen(trimmed: false))
        #expect(a.2 == b.2)
        // A VGA XBin keeps no palette.
        let vga = EditCanvas(file: ArtFile(data: try ArtWriter.data(EditCanvas(), format: .xbin), fileExtension: "xb"))
        #expect(vga.palette == nil)
    }

    /// Review Minor 3: the old `--dither fs` flag spreads the whole error again.
    @Test func defaultStrengthIsFull() throws {
        #expect(ImageToAnsi.Options().ditherStrength == 1)
        #expect(try ImageCommand.parse(["a.png", "--dither", "fs"]).options(imageWidth: 1, imageHeight: 1).ditherStrength == 1)
    }

    /// Review Minor 4: `--crop` with a part that is not a number is refused.
    @Test func cropRejectsJunk() {
        #expect(throws: ImageCommand.ParseError.self) { try ImageCommand.parse(["--crop", "1,x,3,4,5", "a"]) }
    }
}
