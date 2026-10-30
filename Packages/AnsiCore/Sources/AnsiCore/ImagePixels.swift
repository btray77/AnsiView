import CoreGraphics
import Foundation

/// Picture adjustments applied before conversion (image import ruling 4). All default to
/// "no change".
public struct ImageAdjustments: Equatable, Codable {
    /// Stretch the darkest and lightest 0.5% of the picture to black and white.
    public var autoLevels = false
    /// -1 to 1: adds up to half the full range.
    public var brightness: Float = 0
    /// -1 to 1: -1 is flat grey, 1 doubles the contrast.
    public var contrast: Float = 0
    /// -1 to 1: -1 is greyscale, 1 doubles the colour.
    public var saturation: Float = 0
    /// 0.2 to 5: above 1 lightens the mid tones.
    public var gamma: Float = 1
    /// 0 to 2: unsharp mask amount.
    public var sharpen: Float = 0
    /// Flood fill the background colour from the edges and make it black (for logos).
    public var removeBackground = false
    /// 0 to 0.5: how far (OKLab distance) a colour may be from the background colour.
    public var backgroundTolerance: Float = 0.08

    public init() {}

    public static let brightnessRange: ClosedRange<Float> = -1...1
    public static let gammaRange: ClosedRange<Float> = 0.2...5
    public static let sharpenRange: ClosedRange<Float> = 0...2
    public static let toleranceRange: ClosedRange<Float> = 0...0.5
}

/// Gamma encoded (sRGB, 0 to 1) samples of a picture on the converter's grid.
public struct PixelGrid {
    public let width: Int
    public let height: Int
    public var srgb: [SIMD3<Float>]

    public init(width: Int, height: Int, srgb: [SIMD3<Float>]) {
        self.width = width
        self.height = height
        self.srgb = srgb
    }

    /// The samples in linear light.
    public var linear: [SIMD3<Float>] {
        srgb.map { SIMD3(OKLab.linear(srgb: $0.x), OKLab.linear(srgb: $0.y), OKLab.linear(srgb: $0.z)) }
    }

    /// Draws `image` (cropped, on black) at `width` x `height`. `nearest` turns interpolation off.
    public static func sample(_ image: CGImage, width: Int, height: Int, crop: CGRect?, nearest: Bool) -> PixelGrid {
        let source = ImageToAnsi.croppedImage(image, crop: crop)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.interpolationQuality = nearest ? .none : .high
            context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var values = [SIMD3<Float>](repeating: .zero, count: width * height)
        for i in 0..<(width * height) {
            values[i] = SIMD3(Float(bytes[i * 4]), Float(bytes[i * 4 + 1]), Float(bytes[i * 4 + 2])) / 255
        }
        return PixelGrid(width: width, height: height, srgb: values)
    }

    /// Applies the adjustments in ruling 4's order.
    public mutating func apply(_ adjust: ImageAdjustments) {
        let removed = adjust.removeBackground ? backgroundMask(tolerance: adjust.backgroundTolerance) : nil
        if adjust.autoLevels { autoLevels(skipping: removed) }
        let b = min(1, max(-1, adjust.brightness)) * 0.5
        let c = 1 + min(1, max(-1, adjust.contrast))
        let s = 1 + min(1, max(-1, adjust.saturation))
        let g = min(5, max(0.2, adjust.gamma))
        if b != 0 || c != 1 || s != 1 || g != 1 {
            let half = SIMD3<Float>(repeating: 0.5)
            for i in srgb.indices {
                var v = srgb[i] + SIMD3(repeating: b)
                v = (v - half) * c + half
                if s != 1 {
                    let luma = 0.2126 * v.x + 0.7152 * v.y + 0.0722 * v.z
                    v = SIMD3(repeating: luma) + (v - SIMD3(repeating: luma)) * s
                }
                v = v.clamped(lowerBound: .zero, upperBound: SIMD3(repeating: 1))
                if g != 1 { v = SIMD3(powf(v.x, 1 / g), powf(v.y, 1 / g), powf(v.z, 1 / g)) }
                srgb[i] = v
            }
        }
        if adjust.sharpen > 0 { sharpen(min(2, adjust.sharpen)) }
        if let removed {
            for i in srgb.indices where removed[i] { srgb[i] = .zero }
        }
    }

    private mutating func autoLevels(skipping removed: [Bool]?) {
        var lumas: [Float] = []
        lumas.reserveCapacity(srgb.count)
        for (i, v) in srgb.enumerated() where removed?[i] != true {
            lumas.append(0.2126 * v.x + 0.7152 * v.y + 0.0722 * v.z)
        }
        guard lumas.count > 1 else { return }
        lumas.sort()
        let low = lumas[Int(Float(lumas.count - 1) * 0.005)]
        let high = lumas[Int((Float(lumas.count - 1) * 0.995).rounded(.up))]
        guard high - low > 1e-4 else { return }
        let gain = 1 / (high - low)
        for i in srgb.indices {
            srgb[i] = ((srgb[i] - SIMD3(repeating: low)) * gain).clamped(lowerBound: .zero, upperBound: SIMD3(repeating: 1))
        }
    }

    private mutating func sharpen(_ amount: Float) {
        let original = srgb
        for y in 0..<height {
            for x in 0..<width {
                var sum = SIMD3<Float>.zero
                for dy in -1...1 {
                    let yy = min(height - 1, max(0, y + dy))
                    for dx in -1...1 {
                        sum += original[yy * width + min(width - 1, max(0, x + dx))]
                    }
                }
                let v = original[y * width + x]
                srgb[y * width + x] = (v + (v - sum / 9) * amount)
                    .clamped(lowerBound: .zero, upperBound: SIMD3(repeating: 1))
            }
        }
    }

    /// Pixels connected to the edges whose colour is within `tolerance` of the most common edge colour.
    func backgroundMask(tolerance: Float) -> [Bool] {
        let labs = srgb.map { OKLab.lab(linear: SIMD3(OKLab.linear(srgb: $0.x), OKLab.linear(srgb: $0.y),
                                                      OKLab.linear(srgb: $0.z))) }
        var edges: [Int] = []
        for x in 0..<width { edges.append(x); if height > 1 { edges.append((height - 1) * width + x) } }
        if height > 2 {
            for y in 1..<(height - 1) { edges.append(y * width); if width > 1 { edges.append(y * width + width - 1) } }
        }
        let t2 = tolerance * tolerance
        func close(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Bool { let d = a - b; return (d * d).sum() <= t2 }
        // The background colour: the edge sample with the most edge pixels near it.
        let stride = max(1, edges.count / 64)
        var background = labs[edges[0]]
        var bestCount = -1
        for candidate in Swift.stride(from: 0, to: edges.count, by: stride) {
            let c = labs[edges[candidate]]
            let count = edges.reduce(0) { $0 + (close(labs[$1], c) ? 1 : 0) }
            if count > bestCount { bestCount = count; background = c }
        }
        var mask = [Bool](repeating: false, count: srgb.count)
        var queue = edges.filter { close(labs[$0], background) }
        for i in queue { mask[i] = true }
        while let i = queue.popLast() {
            let x = i % width, y = i / width
            for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
            where nx >= 0 && nx < width && ny >= 0 && ny < height {
                let n = ny * width + nx
                if !mask[n], close(labs[n], background) { mask[n] = true; queue.append(n) }
            }
        }
        return mask
    }
}

extension ImageToAnsi {
    /// The crop inside the image's bounds (top left origin, whole pixels), or nil when it is
    /// empty or the whole image.
    public static func normalizedCrop(_ crop: CGRect?, width: Int, height: Int) -> CGRect? {
        guard let crop, !crop.isNull else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let clipped = crop.standardized.integral.intersection(bounds)
        guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1, clipped != bounds else { return nil }
        return clipped
    }

    /// `image` cut to the crop rectangle (top left origin); the image itself when there is no crop.
    public static func croppedImage(_ image: CGImage, crop: CGRect?) -> CGImage {
        guard let rect = normalizedCrop(crop, width: image.width, height: image.height),
              let cropped = image.cropping(to: rect) else { return image }
        return cropped
    }
}
