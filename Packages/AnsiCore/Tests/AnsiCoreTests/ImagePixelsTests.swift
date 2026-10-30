import CoreGraphics
import Testing
@testable import AnsiCore

/// A solid sRGB image made with one fill (fast for big sizes).
func solidImage(_ width: Int, _ height: Int, _ color: RGB) -> CGImage {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(srgbRed: CGFloat(color.r) / 255, green: CGFloat(color.g) / 255,
                                 blue: CGFloat(color.b) / 255, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
}

private func bytes(_ grid: PixelGrid, _ x: Int, _ y: Int) -> RGB {
    let v = grid.srgb[y * grid.width + x]
    return RGB(r: OKLab.byte(srgb: v.x), g: OKLab.byte(srgb: v.y), b: OKLab.byte(srgb: v.z))
}

private func grey(_ v: Float) -> SIMD3<Float> { SIMD3(repeating: v) }

@Suite struct ImagePixelsTests {
    @Test func transparentLogoBecomesBlack() {
        let image = makeImage(4, 4) { x, _ in x < 2 ? nil : RGB(r: 255, g: 0, b: 0) }
        let grid = PixelGrid.sample(image, width: 4, height: 4, crop: nil, nearest: true)
        #expect(bytes(grid, 0, 0) == RGB(r: 0, g: 0, b: 0))
        #expect(bytes(grid, 3, 3) == RGB(r: 255, g: 0, b: 0))
    }

    @Test func cropClampsAndIgnoresEmpty() {
        #expect(ImageToAnsi.normalizedCrop(CGRect(x: -10, y: -10, width: 20, height: 20), width: 40, height: 40)
                == CGRect(x: 0, y: 0, width: 10, height: 10))
        #expect(ImageToAnsi.normalizedCrop(CGRect(x: 5, y: 5, width: 0, height: 10), width: 40, height: 40) == nil)
        #expect(ImageToAnsi.normalizedCrop(CGRect(x: 50, y: 50, width: 10, height: 10), width: 40, height: 40) == nil)
        #expect(ImageToAnsi.normalizedCrop(CGRect(x: 0, y: 0, width: 40, height: 40), width: 40, height: 40) == nil)
        // The crop's origin is the top left: the top left quarter of this image is red.
        let image = makeImage(4, 4) { x, y in x < 2 && y < 2 ? RGB(r: 255, g: 0, b: 0) : RGB(r: 0, g: 0, b: 255) }
        let grid = PixelGrid.sample(image, width: 2, height: 2, crop: CGRect(x: 0, y: 0, width: 2, height: 2), nearest: true)
        #expect((0..<4).allSatisfy { bytes(grid, $0 % 2, $0 / 2) == RGB(r: 255, g: 0, b: 0) })
    }

    @Test func nearestSamplingIsExact() {
        let image = makeImage(4, 4) { x, y in (x + y) % 2 == 0 ? Palette.vga[14] : Palette.vga[1] }
        let grid = PixelGrid.sample(image, width: 8, height: 8, crop: nil, nearest: true)
        for y in 0..<8 {
            for x in 0..<8 {
                #expect(bytes(grid, x, y) == ((x / 2 + y / 2) % 2 == 0 ? Palette.vga[14] : Palette.vga[1]))
            }
        }
    }

    @Test func largeImageSamplesAtGridSize() {
        let grid = PixelGrid.sample(solidImage(3000, 3000, Palette.vga[3]), width: 320, height: 360, crop: nil, nearest: false)
        #expect(grid.srgb.count == 320 * 360)
        #expect(bytes(grid, 100, 100) == Palette.vga[3])
    }

    @Test func autoLevelsStretches() {
        var grid = PixelGrid(width: 101, height: 1, srgb: (0...100).map { grey(0.25 + 0.5 * Float($0) / 100) })
        var adjust = ImageAdjustments()
        adjust.autoLevels = true
        grid.apply(adjust)
        #expect(grid.srgb.first!.x < 0.01 && grid.srgb.last!.x > 0.99)
        #expect(abs(grid.srgb[50].x - 0.5) < 0.02)
    }

    @Test func brightnessContrastSaturationGamma() {
        func one(_ value: SIMD3<Float>, _ change: (inout ImageAdjustments) -> Void) -> SIMD3<Float> {
            var grid = PixelGrid(width: 1, height: 1, srgb: [value])
            var adjust = ImageAdjustments()
            change(&adjust)
            grid.apply(adjust)
            return grid.srgb[0]
        }
        #expect(abs(one(grey(0.4)) { $0.brightness = 0.2 }.x - 0.5) < 1e-5)
        #expect(abs(one(grey(0.6)) { $0.contrast = 1 }.x - 0.7) < 1e-5)
        let desaturated = one(SIMD3(1, 0, 0)) { $0.saturation = -1 }
        #expect(abs(desaturated.x - desaturated.y) < 1e-5 && abs(desaturated.x - 0.2126) < 1e-3)
        #expect(abs(one(grey(0.25)) { $0.gamma = 2 }.x - 0.5) < 1e-5)
        #expect(one(grey(0.3)) { _ in } == grey(0.3))
    }

    @Test func sharpenRaisesEdgeContrast() {
        var grid = PixelGrid(width: 6, height: 3, srgb: (0..<18).map { grey($0 % 6 < 3 ? 0.3 : 0.7) })
        var adjust = ImageAdjustments()
        adjust.sharpen = 1
        grid.apply(adjust)
        #expect(grid.srgb[2].x < 0.3 && grid.srgb[3].x > 0.7)
        #expect(abs(grid.srgb[0].x - 0.3) < 1e-5)
    }

    @Test func backgroundRemovalFloodsFromEdges() {
        // White border, a red ring, a white hole inside the ring.
        let image = makeImage(20, 20) { x, y in
            let d = (Float(x) - 9.5) * (Float(x) - 9.5) + (Float(y) - 9.5) * (Float(y) - 9.5)
            return d < 49 && d > 9 ? RGB(r: 220, g: 0, b: 0) : RGB(r: 255, g: 255, b: 255)
        }
        var grid = PixelGrid.sample(image, width: 20, height: 20, crop: nil, nearest: true)
        var adjust = ImageAdjustments()
        adjust.removeBackground = true
        grid.apply(adjust)
        #expect(bytes(grid, 0, 0) == RGB(r: 0, g: 0, b: 0))
        #expect(bytes(grid, 19, 10) == RGB(r: 0, g: 0, b: 0))
        #expect(bytes(grid, 10, 4).r == 220)
        #expect(bytes(grid, 10, 10) == RGB(r: 255, g: 255, b: 255))
    }
}
