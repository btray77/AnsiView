import CoreGraphics
import Foundation
import Testing
@testable import AnsiCore

private func solid(_ width: Int, _ height: Int, _ value: UInt8) -> CGImage {
    let bytes = [UInt8](repeating: value, count: width * height * 4)
    let provider = CGDataProvider(data: Data(bytes) as CFData)!
    return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                   space: CGColorSpace(name: CGColorSpace.sRGB)!,
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                   provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
}

/// Average of R, G and B at (x, y), top left origin, read back through a known RGBA layout.
private func luma(_ image: CGImage, x: Int, y: Int) -> Int {
    var buffer = [UInt8](repeating: 0, count: image.width * image.height * 4)
    buffer.withUnsafeMutableBytes { raw in
        let ctx = CGContext(data: raw.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    let o = (y * image.width + x) * 4
    return (Int(buffer[o]) + Int(buffer[o + 1]) + Int(buffer[o + 2])) / 3
}

@Test func keepsSize() {
    let input = solid(64, 48, 200)
    let out = CRTFilter().apply(input)!
    #expect(out.width == 64)
    #expect(out.height == 48)
}

@Test func scanlinesDarkenAlternateRows() {
    let out = CRTFilter(scanlines: 0.35, glow: 0, curvature: 0).apply(solid(64, 64, 255))!
    #expect(luma(out, x: 32, y: 33) < luma(out, x: 32, y: 32))
}

@Test func zeroSettingsAreIdentity() {
    let input = solid(16, 16, 123)
    let out = CRTFilter(scanlines: 0, glow: 0, curvature: 0).apply(input)!
    #expect(luma(out, x: 5, y: 5) == luma(input, x: 5, y: 5))
    #expect(luma(out, x: 5, y: 6) == luma(input, x: 5, y: 6))
}

@Test func defaultSettingsChangeTheImage() {
    let input = solid(64, 64, 255)
    let out = CRTFilter().apply(input)!
    #expect(luma(out, x: 32, y: 33) != luma(input, x: 32, y: 33))
}
