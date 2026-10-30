import CoreGraphics
import Foundation

/// How close a conversion looks to its picture (image import ruling 8).
///
/// Both images are compared at the rendered size (8x16 pixels per cell), each reduced by 4x4
/// box averages in linear light: a cell becomes 2x4 samples, which keeps the half block and
/// quarter structure while dither and shade patterns count as the colour they blend to, as they
/// do at a normal viewing distance. `deltaE` is the mean OKLab distance x 100 (about 1 is a just
/// noticeable difference; lower is better). `ssim` is structural similarity of OKLab lightness
/// over 8x8 blocks of the reduced images (1 is identical); it is shown as a cross check because
/// it ignores hue, which is what the old converter got wrong.
public enum ImageScore {
    public struct Result: Equatable, CustomStringConvertible {
        public let deltaE: Double
        public let ssim: Double

        public var description: String { String(format: "dE %.2f, SSIM %.3f", deltaE, ssim) }
    }

    /// Scores `canvas` against `source` as `options` prepared it (crop and adjustments applied).
    public static func score(_ canvas: EditCanvas, source: CGImage, options: ImageToAnsi.Options) -> Result {
        let screen = canvas.screen(trimmed: false)
        guard let rendered = AnsiRenderer.render(screen, options: RenderOptions(font: canvas.font, scale: 1)) else {
            return Result(deltaE: .infinity, ssim: 0)
        }
        var reference = PixelGrid.sample(source, width: rendered.image.width, height: rendered.image.height,
                                         crop: options.crop, nearest: options.nearestNeighbour)
        reference.apply(options.adjustments)
        let drawn = PixelGrid.sample(rendered.image, width: rendered.image.width, height: rendered.image.height,
                                     crop: nil, nearest: true)
        return compare(drawn, reference)
    }

    /// Compares two images of any size at the first one's size.
    public static func compare(rendered: CGImage, source: CGImage) -> Result {
        let a = PixelGrid.sample(rendered, width: rendered.width, height: rendered.height, crop: nil, nearest: true)
        let b = PixelGrid.sample(source, width: rendered.width, height: rendered.height, crop: nil, nearest: false)
        return compare(a, b)
    }

    static func compare(_ a: PixelGrid, _ b: PixelGrid) -> Result {
        let ra = reduced(a), rb = reduced(b)
        let labA = ra.values.map { OKLab.lab(linear: $0) }, labB = rb.values.map { OKLab.lab(linear: $0) }
        var sum = 0.0
        for i in labA.indices {
            let d = labA[i] - labB[i]
            sum += Double((d * d).sum().squareRoot())
        }
        let deltaE = labA.isEmpty ? 0 : sum / Double(labA.count) * 100
        return Result(deltaE: deltaE, ssim: ssim(labA.map(\.x), labB.map(\.x), width: ra.width, height: ra.height))
    }

    /// 4x4 box averages in linear light (partial blocks at the edges average what they have).
    static func reduced(_ grid: PixelGrid) -> (width: Int, height: Int, values: [SIMD3<Float>]) {
        let linear = grid.linear
        let w = max(1, (grid.width + 3) / 4), h = max(1, (grid.height + 3) / 4)
        var out = [SIMD3<Float>](repeating: .zero, count: w * h)
        var counts = [Float](repeating: 0, count: w * h)
        for y in 0..<grid.height {
            for x in 0..<grid.width {
                out[(y / 4) * w + x / 4] += linear[y * grid.width + x]
                counts[(y / 4) * w + x / 4] += 1
            }
        }
        for i in out.indices where counts[i] > 0 { out[i] /= counts[i] }
        return (w, h, out)
    }

    /// Mean SSIM over 8x8 blocks (one block when the image is smaller), lightness 0 to 1.
    static func ssim(_ a: [Float], _ b: [Float], width: Int, height: Int) -> Double {
        let c1 = 0.0001, c2 = 0.0009
        let block = 8
        var total = 0.0, blocks = 0
        for by in Swift.stride(from: 0, to: height, by: block) {
            for bx in Swift.stride(from: 0, to: width, by: block) {
                var sa = 0.0, sb = 0.0, saa = 0.0, sbb = 0.0, sab = 0.0, n = 0.0
                for y in by..<min(height, by + block) {
                    for x in bx..<min(width, bx + block) {
                        let va = Double(a[y * width + x]), vb = Double(b[y * width + x])
                        sa += va; sb += vb; saa += va * va; sbb += vb * vb; sab += va * vb; n += 1
                    }
                }
                let ma = sa / n, mb = sb / n
                let va = max(0, saa / n - ma * ma), vb = max(0, sbb / n - mb * mb), cov = sab / n - ma * mb
                total += ((2 * ma * mb + c1) * (2 * cov + c2)) / ((ma * ma + mb * mb + c1) * (va + vb + c2))
                blocks += 1
            }
        }
        return blocks == 0 ? 1 : total / Double(blocks)
    }
}
