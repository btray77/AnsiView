import Foundation

/// A 16 colour palette fitted to a picture (image import ruling 7), for XBin files, which can
/// carry their own palette. Median cut in OKLab, refined by k-means, rounded to the VGA DAC.
public enum PaletteOptimizer {
    /// At most this many pixels are used (a fixed stride, so the result is deterministic).
    static let maxSamples = 32768

    public static func palette(linear pixels: [SIMD3<Float>], count: Int = 16) -> [RGB] {
        let stride = max(1, pixels.count / maxSamples)
        let samples = Swift.stride(from: 0, to: pixels.count, by: stride).map { OKLab.lab(linear: pixels[$0]) }
        guard !samples.isEmpty, count > 0 else { return [RGB](repeating: Palette.vga[0], count: max(0, count)) }

        // Median cut: split the box with the widest spread along that axis at its median.
        var boxes: [[SIMD3<Float>]] = [samples]
        while boxes.count < count {
            var bestBox = -1, bestAxis = 0
            var bestSpread: Float = 1e-6
            for (i, box) in boxes.enumerated() where box.count > 1 {
                let low = box.reduce(box[0]) { pointwiseMin($0, $1) }
                let high = box.reduce(box[0]) { pointwiseMax($0, $1) }
                let range = high - low
                for axis in 0..<3 where range[axis] * Float(box.count).squareRoot() > bestSpread {
                    bestSpread = range[axis] * Float(box.count).squareRoot()
                    bestBox = i
                    bestAxis = axis
                }
            }
            guard bestBox >= 0 else { break }
            let sorted = boxes[bestBox].sorted { $0[bestAxis] < $1[bestAxis] }
            var cut = sorted.count / 2
            // Keep equal values together so a flat colour is not split in two.
            while cut < sorted.count, cut > 0, sorted[cut][bestAxis] == sorted[cut - 1][bestAxis] { cut += 1 }
            if cut >= sorted.count {
                cut = sorted.count / 2
                while cut > 0, sorted[cut][bestAxis] == sorted[cut - 1][bestAxis] { cut -= 1 }
            }
            guard cut > 0, cut < sorted.count else { break }
            boxes[bestBox] = Array(sorted[..<cut])
            boxes.append(Array(sorted[cut...]))
        }
        var centres = boxes.map { box in box.reduce(SIMD3<Float>.zero, +) / Float(box.count) }

        // Lloyd iterations: each sample to its nearest centre, each centre to its samples' mean.
        for _ in 0..<8 {
            var sums = [SIMD3<Float>](repeating: .zero, count: centres.count)
            var counts = [Int](repeating: 0, count: centres.count)
            for s in samples {
                let i = OKLab.nearest(s, in: centres, allowed: 0...(centres.count - 1))
                sums[i] += s
                counts[i] += 1
            }
            for i in centres.indices where counts[i] > 0 { centres[i] = sums[i] / Float(counts[i]) }
        }

        var colours = centres.map { dacExact(OKLab.rgb(linear: OKLab.linearRGB(lab: $0))) }
        while colours.count < count { colours.append(Palette.vga[0]) }
        return colours.sorted { OKLab.lab($0).x < OKLab.lab($1).x }
    }

    /// The nearest colour the 6 bit VGA DAC shows, as XBin and ADF files read it back.
    static func dacExact(_ c: RGB) -> RGB {
        func q(_ v: UInt8) -> UInt8 {
            let six: Int = (Int(v) * 63 + 127) / 255
            return UInt8(six * 255 / 63)
        }
        return RGB(r: q(c.r), g: q(c.g), b: q(c.b))
    }
}
