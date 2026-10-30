import CoreGraphics
import Foundation
import Testing
@testable import AnsiCore

/// A value the VGA DAC can show exactly (6 bit, read back as `v * 255 / 63`).
private func dac(_ v6: Int) -> UInt8 { UInt8(v6 * 255 / 63) }

@Suite struct PaletteOptimizerTests {
    @Test func fourColourImageRecoversColours() {
        let colours = [RGB(r: dac(60), g: dac(10), b: dac(5)), RGB(r: dac(5), g: dac(40), b: dac(20)),
                       RGB(r: dac(30), g: dac(30), b: dac(63)), RGB(r: dac(63), g: dac(60), b: dac(20))]
        let pixels = (0..<400).map { OKLab.linear(colours[$0 % 4]) }
        let palette = PaletteOptimizer.palette(linear: pixels, count: 16)
        #expect(palette.count == 16)
        for c in colours { #expect(palette.contains(c), "\(c)") }
    }

    @Test func paletteIsDACExactAndSorted() {
        let pixels = (0..<5000).map { i -> SIMD3<Float> in
            let t = Float(i) / 5000
            return SIMD3(t, t * t, 1 - t)
        }
        let palette = PaletteOptimizer.palette(linear: pixels, count: 16)
        for c in palette {
            for v in [c.r, c.g, c.b] { #expect(dac((Int(v) * 63 + 127) / 255) == v) }
        }
        let lightness = palette.map { OKLab.lab($0).x }
        #expect(lightness == lightness.sorted())
        #expect(PaletteOptimizer.palette(linear: pixels, count: 16) == palette)
    }

    @Test func imagePaletteConversionUsesIt() {
        let image = makeImage(64, 32) { x, y in RGB(r: UInt8(x * 4), g: UInt8(100 + y * 4), b: 30) }
        var o = ImageToAnsi.Options()
        o.columns = 32
        o.palette = .imagePalette
        o.mode = .halfBlocks
        let canvas = ImageToAnsi.convert(image, options: o)
        let palette = try! #require(canvas.palette)
        #expect(palette.count == 16)
        #expect(canvas.rows.flatMap { $0 }.allSatisfy { palette.contains($0.fg) && palette.contains($0.bg) })
    }

    @Test func xbinWritesPaletteAndReadsBack() throws {
        let image = makeImage(64, 32) { x, y in RGB(r: UInt8(x * 4), g: UInt8(255 - y * 8), b: UInt8(x * 2)) }
        var o = ImageToAnsi.Options()
        o.columns = 40
        o.palette = .imagePalette
        let canvas = ImageToAnsi.convert(image, options: o)
        let data = try ArtWriter.data(canvas, format: .xbin)
        let bytes = [UInt8](data)
        #expect(bytes[10] & 0x01 == 0x01)
        let back = reopened(data, ext: "xb")
        let a = renderedPixels(back), b = renderedPixels(canvas.screen(trimmed: false))
        #expect(a.0 == b.0 && a.1 == b.1 && a.2 == b.2)
        // A VGA canvas still writes no palette.
        #expect([UInt8](try ArtWriter.data(EditCanvas(), format: .xbin))[10] & 0x01 == 0)
    }

    @Test func ansiFromPaletteCanvasIsTruecolor() throws {
        var canvas = EditCanvas(columns: 2, height: 1)
        let odd = RGB(r: dac(33), g: dac(7), b: dac(50))
        canvas.palette = [odd] + Array(Palette.vga.dropFirst())
        canvas.set(AnsiCell(code: 219, fg: odd, bg: Palette.vga[0]), x: 0, y: 0)
        let text = String(decoding: try ArtWriter.data(canvas, format: .ansi), as: UTF8.self)
        #expect(text.contains("38;2;\(odd.r);\(odd.g);\(odd.b)"))
    }
}
