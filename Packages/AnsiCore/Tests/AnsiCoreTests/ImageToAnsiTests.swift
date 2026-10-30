import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import AnsiCore

/// An sRGB image whose pixel at (x, y) (y down) is `color(x, y)`; alpha 0 where it returns nil.
func makeImage(_ width: Int, _ height: Int, _ color: (Int, Int) -> RGB?) -> CGImage {
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            guard let c = color(x, y) else { continue }
            let o = (y * width + x) * 4
            bytes[o] = c.r; bytes[o + 1] = c.g; bytes[o + 2] = c.b; bytes[o + 3] = 255
        }
    }
    let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    return context.makeImage()!
}

func encode(_ images: [CGImage], type: UTType) -> Data {
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, images.count, nil)!
    for image in images { CGImageDestinationAddImage(destination, image, nil) }
    CGImageDestinationFinalize(destination)
    return data as Data
}

private func options(_ columns: Int, _ mode: ImageToAnsi.Mode = .halfBlocks, palette: ImageToAnsi.PaletteChoice = .vga16,
                     dither: ImageToAnsi.Dither = .none, ice: Bool = true, aspect: Bool = true) -> ImageToAnsi.Options {
    var o = ImageToAnsi.Options()
    o.columns = columns
    o.mode = mode
    o.palette = palette
    o.dither = dither
    o.iceColors = ice
    o.aspectCorrection = aspect
    return o
}

@Suite struct ImageToAnsiTests {
    @Test func defaults() {
        let o = ImageToAnsi.Options()
        #expect(o.columns == 80 && o.mode == .glyphs && o.palette == .vga16 && o.dither == .serpentine)
        #expect(o.iceColors && o.aspectCorrection && !o.extendedGlyphs && !o.nearestNeighbour && o.crop == nil)
        #expect(o.ditherStrength == 0.5 && o.adjustments == ImageAdjustments())
    }

    @Test func halfBlocksExactColours() {
        let image = makeImage(2, 4) { _, y in y < 2 ? Palette.vga[12] : Palette.vga[1] }
        let canvas = ImageToAnsi.convert(image, options: options(2))
        #expect(canvas.columns == 2 && canvas.height == 2)
        for x in 0..<2 {
            #expect(canvas[x, 0].code == 219 && canvas[x, 0].fg == Palette.vga[12])
            #expect(canvas[x, 1].code == 219 && canvas[x, 1].fg == Palette.vga[1])
        }
    }

    @Test func halfBlockSplitCell() {
        let image = makeImage(1, 2) { _, y in y == 0 ? Palette.vga[12] : Palette.vga[1] }
        let canvas = ImageToAnsi.convert(image, options: options(1))
        #expect(canvas[0, 0] == AnsiCell(code: 223, fg: Palette.vga[12], bg: Palette.vga[1]))
    }

    @Test func oddSampleRowsRoundUp() {
        let image = makeImage(1, 3) { _, _ in Palette.vga[14] }
        let canvas = ImageToAnsi.convert(image, options: options(1))
        #expect(canvas.height == 2)
        #expect(canvas[0, 1] == AnsiCell(code: 223, fg: Palette.vga[14], bg: Palette.vga[0]))
    }

    @Test func fullBlocksAspect() {
        let image = makeImage(40, 40) { _, _ in Palette.vga[2] }
        #expect(ImageToAnsi.convert(image, options: options(40, .fullBlocks)).height == 20)
        #expect(ImageToAnsi.convert(image, options: options(40, .fullBlocks, aspect: false)).height == 40)
        #expect(ImageToAnsi.convert(image, options: options(40)).height == 20)
        #expect(ImageToAnsi.convert(image, options: options(40, aspect: false)).height == 40)
        let cell = ImageToAnsi.convert(image, options: options(40, .fullBlocks))[3, 3]
        #expect(cell == AnsiCell(code: 219, fg: Palette.vga[2], bg: Palette.vga[0]))
    }

    /// Light mixes in linear RGB: half blue (0, 0, 170) and half black shows as (0, 0, 124).
    @Test func shadesFindMix() {
        let image = makeImage(4, 8) { _, _ in RGB(r: 0, g: 0, b: 124) }
        let canvas = ImageToAnsi.convert(image, options: options(4, .shades))
        let cell = canvas[1, 1]
        #expect(cell.code == 177)
        #expect(Set([cell.fg, cell.bg]) == Set([Palette.vga[1], Palette.vga[0]]))
    }

    @Test func trueColorIsExact() {
        let color = RGB(r: 10, g: 200, b: 30)
        let image = makeImage(2, 2) { _, y in y == 0 ? color : RGB(r: 1, g: 2, b: 3) }
        let canvas = ImageToAnsi.convert(image, options: options(2, palette: .trueColor))
        #expect(canvas[0, 0] == AnsiCell(code: 223, fg: color, bg: RGB(r: 1, g: 2, b: 3)))
        let full = ImageToAnsi.convert(makeImage(2, 4) { _, _ in color }, options: options(2, .fullBlocks, palette: .trueColor))
        #expect(full[0, 0] == AnsiCell(code: 219, fg: color, bg: Palette.vga[0]))
    }

    @Test func iceOffNoBrightBackground() {
        var seed: UInt64 = 42
        func next() -> UInt8 { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return UInt8(seed >> 56) }
        let noise = makeImage(40, 40) { _, _ in RGB(r: next(), g: next(), b: next()) }
        for mode in ImageToAnsi.Mode.allCases {
            for dither in ImageToAnsi.Dither.allCases {
                let canvas = ImageToAnsi.convert(noise, options: options(40, mode, dither: dither, ice: false))
                #expect(!canvas.iceColors)
                let bright = canvas.rows.flatMap { $0 }.filter { (Palette.vgaIndex(of: $0.bg) ?? 99) >= 8 }
                #expect(bright.isEmpty, "\(mode) \(dither)")
                #expect(canvas.rows.flatMap { $0 }.allSatisfy { Palette.vgaIndex(of: $0.fg) != nil })
            }
        }
        let withIce = ImageToAnsi.convert(noise, options: options(40, ice: true))
        #expect(withIce.iceColors)
        #expect(withIce.rows.flatMap { $0 }.contains { (Palette.vgaIndex(of: $0.bg) ?? 0) >= 8 })
    }

    @Test func ditherChangesOutput() {
        let gradient = makeImage(64, 32) { x, _ in let v = UInt8(x * 4); return RGB(r: v, g: v, b: v) }
        let none = ImageToAnsi.convert(gradient, options: options(64, dither: .none))
        let fs = ImageToAnsi.convert(gradient, options: options(64, dither: .floydSteinberg))
        let ordered = ImageToAnsi.convert(gradient, options: options(64, dither: .ordered))
        #expect(none != fs && none != ordered && fs != ordered)
        // Without dithering a column is one colour all the way down; dithering mixes them.
        #expect((0..<none.height).allSatisfy { none[10, $0] == none[10, 0] })
        #expect(!(0..<fs.height).allSatisfy { fs[10, $0] == fs[10, 0] })
    }

    @Test func gifFirstFrameAndPNGLoad() throws {
        let red = makeImage(4, 4) { _, _ in RGB(r: 255, g: 0, b: 0) }
        let blue = makeImage(4, 4) { _, _ in RGB(r: 0, g: 0, b: 255) }
        let gif = encode([red, blue], type: .gif)
        let canvas = try ImageToAnsi.convert(data: gif, options: options(4, palette: .trueColor), title: "anim")
        #expect(canvas[0, 0].fg == RGB(r: 255, g: 0, b: 0))
        #expect(canvas.title == "anim")
        let png = encode([blue], type: .png)
        #expect(try ImageToAnsi.convert(data: png, options: options(4, palette: .trueColor), title: nil)[1, 1].fg
                == RGB(r: 0, g: 0, b: 255))
        let image = try ImageToAnsi.load(png)
        #expect(image.width == 4 && image.height == 4)
    }

    @Test func degenerateImages() {
        let tall = makeImage(1, 1000) { _, _ in Palette.vga[3] }
        let wide = makeImage(1000, 1) { _, _ in Palette.vga[3] }
        let clear = makeImage(10, 10) { _, _ in nil }
        for image in [tall, wide, clear] {
            for columns in [1, 16, 80] {
                // Glyph search and shades are slow in a debug build; 16 columns already reaches the row limit.
                for mode in ImageToAnsi.Mode.allCases where columns < 80 || mode == .halfBlocks || mode == .fullBlocks {
                    let canvas = ImageToAnsi.convert(image, options: options(columns, mode))
                    #expect(canvas.height >= 1 && canvas.columns == columns)
                    #expect(canvas.height <= AnsiTerminal.maxRows)
                }
            }
        }
        let black = ImageToAnsi.convert(clear, options: options(10, .fullBlocks))
        #expect(black.rows.flatMap { $0 }.allSatisfy { $0.fg == Palette.vga[0] })
        #expect(ImageToAnsi.convert(wide, options: options(5000)).columns == 1000)
        #expect(ImageToAnsi.convert(wide, options: options(0)).columns == 1)
    }

    @Test func unreadableDataThrows() {
        #expect(throws: ImageToAnsi.ImportError.self) { try ImageToAnsi.load(Data("not an image".utf8)) }
    }

    @Test func gradientRoundTripThroughANSI() throws {
        let pattern = makeImage(64, 32) { x, y in
            y < 16 ? RGB(r: UInt8(x * 4), g: UInt8(y * 16), b: UInt8(255 - x * 4)) : Palette.vga[(x / 4) % 16]
        }
        for palette in [ImageToAnsi.PaletteChoice.vga16, .trueColor] {
            for ice in [true, false] {
                let canvas = ImageToAnsi.convert(pattern, options: options(64, dither: .floydSteinberg, ice: ice, aspect: true)
                    .with(palette: palette))
                let data = try ArtWriter.data(canvas, format: .ansi)
                let back = reopened(data, ext: "ans")
                let a = renderedPixels(back), b = renderedPixels(canvas.screen(trimmed: true))
                #expect(a.0 == b.0 && a.1 == b.1 && a.2 == b.2, "\(palette) ice \(ice)")
            }
        }
    }
}

private extension ImageToAnsi.Options {
    func with(palette: ImageToAnsi.PaletteChoice) -> Self {
        var copy = self
        copy.palette = palette
        return copy
    }
}
