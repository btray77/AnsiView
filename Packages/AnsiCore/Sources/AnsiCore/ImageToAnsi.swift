import CoreGraphics
import Foundation
import ImageIO

/// Converts a picture to block character ANSI art (plan 6 ruling 13).
public enum ImageToAnsi {
    public enum Mode: String, CaseIterable {
        /// Two pixels per cell with the upper and lower half blocks.
        case halfBlocks = "half"
        /// One full block per cell.
        case fullBlocks = "full"
        /// One cell per pixel, using the shade characters to mix two colours.
        case shades = "shade"

        public var label: String {
            switch self {
            case .halfBlocks: return "Half blocks (2 pixels per cell)"
            case .fullBlocks: return "Full blocks"
            case .shades: return "Shades (extra tones)"
            }
        }
    }

    public enum PaletteChoice: String, CaseIterable {
        case vga16 = "vga"
        case trueColor = "truecolor"

        public var label: String { self == .vga16 ? "16 VGA colours" : "24 bit truecolor" }
    }

    public enum Dither: String, CaseIterable {
        case none
        case floydSteinberg = "fs"
        case ordered

        public var label: String {
            switch self {
            case .none: return "None"
            case .floydSteinberg: return "Floyd-Steinberg"
            case .ordered: return "Ordered"
            }
        }
    }

    public struct Options: Equatable {
        public var columns = 80
        public var mode = Mode.halfBlocks
        public var palette = PaletteChoice.vga16
        public var dither = Dither.floydSteinberg
        public var iceColors = true
        /// Compensates for the 8x16 character cell so the picture keeps its proportions.
        public var aspectCorrection = true

        public init() {}
    }

    public enum ImportError: Error, LocalizedError {
        case unreadable

        public var errorDescription: String? { "The file is not an image AnsiView can read." }
    }

    /// The first image in `data` (the first frame of a GIF), in any format ImageIO reads.
    public static func load(_ data: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw ImportError.unreadable }
        return image
    }

    public static func convert(data: Data, options: Options, title: String?) throws -> EditCanvas {
        var canvas = convert(try load(data), options: options)
        if let title { canvas.title = String(title.prefix(35)) }
        return canvas
    }

    public static func convert(_ image: CGImage, options: Options) -> EditCanvas {
        let columns = min(EditCanvas.maxColumns, max(1, options.columns))
        let half = options.mode == .halfBlocks
        let factor = (half ? 1.0 : 0.5) * (options.aspectCorrection ? 1 : 2)
        let maxSamples = AnsiTerminal.maxRows * (half ? 2 : 1)
        let ratio = Double(max(1, image.height)) / Double(max(1, image.width))
        let sampleRows = min(maxSamples, max(1, Int((ratio * Double(columns) * factor).rounded())))
        var pixels = samples(image, width: columns, height: sampleRows)
        let cellRows = half ? (sampleRows + 1) / 2 : sampleRows

        var canvas = EditCanvas(columns: columns, height: cellRows)
        canvas.setIceColors(options.iceColors)
        let black = Palette.vga[0]
        if options.palette == .trueColor {
            for y in 0..<cellRows {
                for x in 0..<columns {
                    if half {
                        let top = pixels.color(x, y * 2)
                        let bottom = y * 2 + 1 < sampleRows ? pixels.color(x, y * 2 + 1) : black
                        canvas.set(AnsiCell(code: EditCanvas.blockUpper, fg: top, bg: bottom), x: x, y: y)
                    } else {
                        canvas.set(AnsiCell(code: EditCanvas.blockFull, fg: pixels.color(x, y), bg: black), x: x, y: y)
                    }
                }
            }
            return canvas
        }

        let ice = options.iceColors
        let backgrounds = ice ? 0...15 : 0...7
        let shadeChoices = options.mode == .shades ? shadeCandidates(backgrounds: backgrounds) : []
        let shadeMixes = shadeChoices.map(\.mix)
        var chosen = [Int](repeating: 0, count: columns * sampleRows)
        for y in 0..<sampleRows {
            for x in 0..<columns {
                var target = pixels.value(x, y)
                if options.dither == .ordered {
                    let bias = (Float(bayer[y % 4][x % 4]) / 16 - 0.5) * 64
                    target = (target.0 + bias, target.1 + bias, target.2 + bias)
                }
                let result: (index: Int, color: (Float, Float, Float))
                if options.mode == .shades {
                    let best = nearest(target, in: shadeMixes)
                    result = (best, shadeChoices[best].mix)
                } else {
                    // Without iCE a cell can hold only one bright colour (the foreground), so a lower
                    // half under a bright upper half is limited to dark colours or the same colour.
                    var allowed = allIndexes
                    if half, !ice, y % 2 == 1, chosen[(y - 1) * columns + x] >= 8 {
                        allowed = darkPlus[chosen[(y - 1) * columns + x] - 8]
                    }
                    let best = nearest(target, in: allowed.candidates)
                    result = (allowed.indexes[best], allowed.candidates[best])
                }
                chosen[y * columns + x] = result.index
                if options.dither == .floydSteinberg {
                    let original = pixels.value(x, y)
                    let error = (original.0 - result.color.0, original.1 - result.color.1, original.2 - result.color.2)
                    pixels.spread(error, x: x + 1, y: y, weight: 7 / 16)
                    pixels.spread(error, x: x - 1, y: y + 1, weight: 3 / 16)
                    pixels.spread(error, x: x, y: y + 1, weight: 5 / 16)
                    pixels.spread(error, x: x + 1, y: y + 1, weight: 1 / 16)
                }
            }
        }

        for y in 0..<cellRows {
            for x in 0..<columns {
                switch options.mode {
                case .halfBlocks:
                    let top = Palette.vga[chosen[y * 2 * columns + x]]
                    let bottom = y * 2 + 1 < sampleRows ? Palette.vga[chosen[(y * 2 + 1) * columns + x]] : black
                    canvas.set(canvas.encodeHalves(top: top, bottom: bottom, keepingBackground: black), x: x, y: y)
                case .fullBlocks:
                    canvas.set(AnsiCell(code: EditCanvas.blockFull, fg: Palette.vga[chosen[y * columns + x]], bg: black), x: x, y: y)
                case .shades:
                    let shade = shadeChoices[chosen[y * columns + x]]
                    canvas.set(AnsiCell(code: shade.code, fg: Palette.vga[shade.fg], bg: Palette.vga[shade.bg]), x: x, y: y)
                }
            }
        }
        return canvas
    }

    // MARK: Helpers

    private typealias Choices = (indexes: [Int], candidates: [(Float, Float, Float)])
    private static let allIndexes: Choices = (Array(0...15), vgaFloat)
    /// For each bright colour 8 to 15: the dark colours plus that colour.
    private static let darkPlus: [Choices] = (8...15).map { bright in
        let indexes = Array(0...7) + [bright]
        return (indexes, indexes.map { vgaFloat[$0] })
    }

    private static let bayer: [[Int]] = [[0, 8, 2, 10], [12, 4, 14, 6], [3, 11, 1, 9], [15, 7, 13, 5]]

    private static let vgaFloat: [(Float, Float, Float)] = Palette.vga.map { (Float($0.r), Float($0.g), Float($0.b)) }

    /// A character and colour pair for shade mode, with the colour it shows from a distance.
    struct Shade {
        let code: UInt8
        let fg: Int
        let bg: Int
        let mix: (Float, Float, Float)
    }

    /// Space (background only), the three shades and the full block, over every allowed pair.
    static func shadeCandidates(backgrounds: ClosedRange<Int>) -> [Shade] {
        var out: [Shade] = []
        for bg in backgrounds { out.append(Shade(code: 0x20, fg: 7, bg: bg, mix: vgaFloat[bg])) }
        for fg in 0...15 { out.append(Shade(code: EditCanvas.blockFull, fg: fg, bg: 0, mix: vgaFloat[fg])) }
        let shades: [(UInt8, Float)] = [(176, 0.25), (177, 0.5), (178, 0.75)]
        for (code, coverage) in shades {
            for fg in 0...15 {
                for bg in backgrounds where bg != fg {
                    let f = vgaFloat[fg], b = vgaFloat[bg]
                    out.append(Shade(code: code, fg: fg, bg: bg,
                                     mix: (f.0 * coverage + b.0 * (1 - coverage), f.1 * coverage + b.1 * (1 - coverage),
                                           f.2 * coverage + b.2 * (1 - coverage))))
                }
            }
        }
        return out
    }

    private static func nearest(_ c: (Float, Float, Float), in candidates: [(Float, Float, Float)]) -> Int {
        var best = 0
        var bestDistance = Float.greatestFiniteMagnitude
        for (index, k) in candidates.enumerated() {
            let dr = c.0 - k.0, dg = c.1 - k.1, db = c.2 - k.2
            let distance = dr * dr + dg * dg + db * db
            if distance < bestDistance { best = index; bestDistance = distance }
        }
        return best
    }

    /// RGB samples as floats, the image drawn on black at the sample size.
    struct Samples {
        let width: Int
        let height: Int
        var values: [Float]

        func value(_ x: Int, _ y: Int) -> (Float, Float, Float) {
            let o = (y * width + x) * 3
            return (values[o], values[o + 1], values[o + 2])
        }

        func color(_ x: Int, _ y: Int) -> RGB {
            let v = value(x, y)
            func byte(_ f: Float) -> UInt8 { UInt8(min(255, max(0, f.rounded()))) }
            return RGB(r: byte(v.0), g: byte(v.1), b: byte(v.2))
        }

        mutating func spread(_ error: (Float, Float, Float), x: Int, y: Int, weight: Float) {
            guard x >= 0, x < width, y < height else { return }
            let o = (y * width + x) * 3
            values[o] += error.0 * weight
            values[o + 1] += error.1 * weight
            values[o + 2] += error.2 * weight
        }
    }

    static func samples(_ image: CGImage, width: Int, height: Int) -> Samples {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var values = [Float](repeating: 0, count: width * height * 3)
        for i in 0..<(width * height) {
            values[i * 3] = Float(bytes[i * 4])
            values[i * 3 + 1] = Float(bytes[i * 4 + 1])
            values[i * 3 + 2] = Float(bytes[i * 4 + 2])
        }
        return Samples(width: width, height: height, values: values)
    }
}
