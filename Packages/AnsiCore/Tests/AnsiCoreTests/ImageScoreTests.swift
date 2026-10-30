import CoreGraphics
import Testing
@testable import AnsiCore

/// Flat VGA colour blocks aligned to 8x16 character cells, `columns` x `rows` cells.
private func cellBlocks(_ columns: Int, _ rows: Int) -> CGImage {
    makeImage(columns * 8, rows * 16) { x, y in Palette.vga[(x / 8 + y / 16 * 3) % 16] }
}

private func glyphOptions(_ columns: Int) -> ImageToAnsi.Options {
    var o = ImageToAnsi.Options()
    o.columns = columns
    o.dither = .none
    return o
}

@Suite struct ImageScoreTests {
    @Test func identicalScoresZero() {
        let image = cellBlocks(10, 5)
        let canvas = ImageToAnsi.convert(image, options: glyphOptions(10))
        #expect(canvas.height == 5)
        let score = ImageScore.score(canvas, source: image, options: glyphOptions(10))
        #expect(score.deltaE < 1, "\(score)")  // about one just noticeable difference (smoothing at cell edges)
        #expect(score.ssim > 0.99, "\(score)")
    }

    @Test func worseIsHigher() {
        let image = makeImage(80, 80) { x, y in RGB(r: UInt8(x * 3), g: UInt8(y * 3), b: 128) }
        let good = ImageToAnsi.convert(image, options: glyphOptions(20))
        var black = EditCanvas(columns: good.columns, height: good.height)
        black.setIceColors(true)
        let a = ImageScore.score(good, source: image, options: glyphOptions(20))
        let b = ImageScore.score(black, source: image, options: glyphOptions(20))
        #expect(a.deltaE < b.deltaE && a.ssim > b.ssim, "\(a) \(b)")
    }

    @Test func presetsSetPinnedValues() {
        var base = ImageToAnsi.Options()
        base.columns = 100
        base.palette = .imagePalette
        let photo = ImagePreset.photo.options(base: base, imageWidth: 640, imageHeight: 480)
        #expect(photo.mode == .glyphs && photo.dither == .serpentine && photo.ditherStrength == 0.5)
        #expect(!photo.adjustments.autoLevels && photo.columns == 100 && photo.palette == .imagePalette)
        let logo = ImagePreset.logo.options(base: base, imageWidth: 640, imageHeight: 480)
        #expect(logo.mode == .glyphs && logo.dither == .none && !logo.extendedGlyphs && !logo.nearestNeighbour)
        let pixel = ImagePreset.pixelArt.options(base: base, imageWidth: 48, imageHeight: 32)
        #expect(pixel.mode == .halfBlocks && pixel.dither == .none && pixel.nearestNeighbour && pixel.columns == 48)
        #expect(pixel.aspectCorrection)
        #expect(ImagePreset.pixelArt.options(base: base, imageWidth: 4000, imageHeight: 10).columns == 1000)
        var cropped = base
        cropped.crop = CGRect(x: 0, y: 0, width: 20, height: 10)
        #expect(ImagePreset.pixelArt.options(base: cropped, imageWidth: 48, imageHeight: 32).columns == 20)
        let line = ImagePreset.lineArt.options(base: base, imageWidth: 640, imageHeight: 480)
        #expect(line.mode == .glyphs && line.extendedGlyphs && line.dither == .none)
        #expect(line.adjustments.autoLevels && line.adjustments.contrast == 0.3)
        #expect(ImagePreset.custom.options(base: base, imageWidth: 1, imageHeight: 1) == base)
    }

    @Test func pixelArtIsExact() {
        let sprite = makeImage(12, 10) { x, y in Palette.vga[(x * 3 + y * 5) % 16] }
        let o = ImagePreset.pixelArt.options(base: ImageToAnsi.Options(), imageWidth: 12, imageHeight: 10)
        let canvas = ImageToAnsi.convert(sprite, options: o)
        #expect(canvas.columns == 12 && canvas.height == 5)
        for y in 0..<5 {
            for x in 0..<12 {
                let (top, bottom) = EditCanvas.halves(canvas[x, y])
                #expect(top == Palette.vga[(x * 3 + y * 2 * 5) % 16] && bottom == Palette.vga[(x * 3 + (y * 2 + 1) * 5) % 16])
            }
        }
    }

    @Test func autoSortedAndDeterministic() throws {
        let image = makeImage(64, 48) { x, y in RGB(r: UInt8(x * 4), g: UInt8(y * 5), b: UInt8(255 - x * 2)) }
        var base = ImageToAnsi.Options()
        base.columns = 16
        let first = try #require(ImageToAnsi.autoCandidates(image, base: base, cancel: { false }))
        #expect(first.count >= 3)
        #expect(first.map(\.score.deltaE) == first.map(\.score.deltaE).sorted())
        #expect(first.allSatisfy { $0.options.columns == 16 })
        let second = try #require(ImageToAnsi.autoCandidates(image, base: base, cancel: { false }))
        #expect(first.map(\.name) == second.map(\.name))
        #expect(ImageToAnsi.autoCandidates(image, base: base, cancel: { true }) == nil)
    }
}
