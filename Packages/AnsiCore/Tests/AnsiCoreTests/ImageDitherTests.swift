import CoreGraphics
import Testing
@testable import AnsiCore

private func options(_ mode: ImageToAnsi.Mode, _ dither: ImageToAnsi.Dither, strength: Float = 1, columns: Int = 40) -> ImageToAnsi.Options {
    var o = ImageToAnsi.Options()
    o.columns = columns
    o.mode = mode
    o.dither = dither
    o.ditherStrength = strength
    return o
}

/// Mean linear luminance of a canvas as rendered at 8x16 per cell.
func renderedLuminance(_ canvas: EditCanvas) -> Double {
    let (w, h, data) = renderedPixels(canvas.screen(trimmed: false))
    var sum = 0.0
    let bytes = [UInt8](data)
    for i in 0..<(w * h) {
        let r = Double(OKLab.linear(bytes[i * 4])), g = Double(OKLab.linear(bytes[i * 4 + 1]))
        let b = Double(OKLab.linear(bytes[i * 4 + 2]))
        sum += 0.2126 * r + 0.7152 * g + 0.0722 * b
    }
    return sum / Double(w * h)
}

@Suite struct ImageDitherTests {
    @Test func kernelWeights() {
        func total(_ d: ImageToAnsi.Dither) -> Float { DitherKernel.kernel(for: d)!.taps.reduce(0) { $0 + $1.weight } }
        #expect(abs(total(.floydSteinberg) - 1) < 1e-6)
        #expect(abs(total(.serpentine) - 1) < 1e-6)
        #expect(abs(total(.atkinson) - 0.75) < 1e-6)
        #expect(abs(total(.sierraLite) - 1) < 1e-6)
        #expect(DitherKernel.kernel(for: .none) == nil && DitherKernel.kernel(for: .ordered) == nil)
        #expect(DitherKernel.kernel(for: .serpentine)!.serpentine && !DitherKernel.kernel(for: .floydSteinberg)!.serpentine)
    }

    @Test func serpentineDiffersFromFloydSteinberg() {
        let gradient = makeImage(64, 32) { x, _ in let v = UInt8(x * 4); return RGB(r: v, g: v / 2, b: 40) }
        for mode in [ImageToAnsi.Mode.halfBlocks, .glyphs] {
            let fs = ImageToAnsi.convert(gradient, options: options(mode, .floydSteinberg, columns: 64))
            let serpentine = ImageToAnsi.convert(gradient, options: options(mode, .serpentine, columns: 64))
            #expect(fs != serpentine)
            // The first row is processed left to right by both.
            if mode == .halfBlocks { #expect(fs[0, 0] == serpentine[0, 0]) }
        }
    }

    @Test func strengthZeroEqualsNone() {
        let gradient = makeImage(64, 32) { x, y in RGB(r: UInt8(x * 4), g: UInt8(y * 8), b: 90) }
        for mode in ImageToAnsi.Mode.allCases {
            let none = ImageToAnsi.convert(gradient, options: options(mode, .none))
            for dither in ImageToAnsi.Dither.allCases {
                #expect(ImageToAnsi.convert(gradient, options: options(mode, dither, strength: 0)) == none, "\(mode) \(dither)")
            }
        }
    }

    @Test func diffusionKeepsMeanBrightness() {
        // A grey that no VGA colour (and no shade mix) matches exactly.
        let grey = makeImage(80, 80) { _, _ in RGB(r: 128, g: 128, b: 128) }
        let target = Double(OKLab.linear(128))
        for mode in [ImageToAnsi.Mode.halfBlocks, .fullBlocks, .glyphs] {
            for dither in [ImageToAnsi.Dither.floydSteinberg, .serpentine, .sierraLite] {
                let canvas = ImageToAnsi.convert(grey, options: options(mode, dither))
                #expect(abs(renderedLuminance(canvas) - target) < 0.03, "\(mode) \(dither) \(renderedLuminance(canvas))")
            }
        }
        // Atkinson drops a quarter of the error, so it may drift further.
        let atkinson = ImageToAnsi.convert(grey, options: options(.halfBlocks, .atkinson))
        #expect(abs(renderedLuminance(atkinson) - target) < 0.08)
    }

    @Test func cancelReturnsNil() {
        let image = makeImage(16, 16) { _, _ in Palette.vga[3] }
        for mode in ImageToAnsi.Mode.allCases {
            #expect(ImageToAnsi.convert(image, options: options(mode, .floydSteinberg), cancel: { true }) == nil)
            #expect(ImageToAnsi.convert(image, options: options(mode, .floydSteinberg), cancel: { false }) != nil)
        }
    }
}
