import CoreGraphics
import CoreImage
import Foundation

/// An optional old monitor look: darkened scanlines, phosphor glow and a slight screen bulge.
public struct CRTFilter {
    /// How much every other pixel row is darkened, 0 to 1.
    public var scanlines: Double
    /// Bloom intensity, 0 for none.
    public var glow: Double
    /// Bulge strength, 0 for a flat screen.
    public var curvature: Double

    public init(scanlines: Double = 0.35, glow: Double = 0.6, curvature: Double = 0.08) {
        self.scanlines = scanlines
        self.glow = glow
        self.curvature = curvature
    }

    private static let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])

    public func apply(_ image: CGImage) -> CGImage? {
        guard var working = scanlined(image) else { return nil }
        guard glow > 0 || curvature > 0 else { return working }

        let extent = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        var ci = CIImage(cgImage: working)
        if glow > 0, let bloom = CIFilter(name: "CIBloom") {
            bloom.setValue(ci, forKey: kCIInputImageKey)
            bloom.setValue(max(1, Double(image.height) / 200), forKey: kCIInputRadiusKey)
            bloom.setValue(glow, forKey: kCIInputIntensityKey)
            ci = bloom.outputImage?.cropped(to: extent) ?? ci
        }
        if curvature > 0, let bump = CIFilter(name: "CIBumpDistortion") {
            bump.setValue(ci.clampedToExtent(), forKey: kCIInputImageKey)
            bump.setValue(CIVector(x: extent.midX, y: extent.midY), forKey: kCIInputCenterKey)
            bump.setValue(hypot(extent.width, extent.height) / 2, forKey: kCIInputRadiusKey)
            bump.setValue(curvature, forKey: kCIInputScaleKey)
            ci = bump.outputImage?.cropped(to: extent) ?? ci
        }
        working = Self.context.createCGImage(ci, from: extent) ?? working
        return working
    }

    /// Multiplies odd pixel rows by (1 - scanlines). Returns an RGBX copy of the image.
    private func scanlined(_ image: CGImage) -> CGImage? {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGImageAlphaInfo.noneSkipLast.rawValue
        let drew = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: space, bitmapInfo: info) else { return false }
            ctx.interpolationQuality = .none
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drew else { return nil }
        if scanlines > 0 {
            let factor = max(0, 1 - scanlines)
            for y in stride(from: 1, to: height, by: 2) {
                let start = y * width * 4
                for i in start..<(start + width * 4) where i % 4 != 3 {
                    pixels[i] = UInt8(Double(pixels[i]) * factor)
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
