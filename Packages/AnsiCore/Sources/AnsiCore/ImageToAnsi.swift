import CoreGraphics
import Foundation
import ImageIO

/// Converts a picture to block character ANSI art (plan 6 ruling 13, rebuilt by the image
/// import plan: OKLab matching, linear light mixing, glyph search, more dithering).
public enum ImageToAnsi {
    public enum Mode: String, CaseIterable, Codable {
        /// For each cell, the best of several characters and colour pairs (ruling 6).
        case glyphs = "glyph"
        /// Two pixels per cell with the upper and lower half blocks.
        case halfBlocks = "half"
        /// One full block per cell.
        case fullBlocks = "full"
        /// One cell per pixel, using the shade characters to mix two colours.
        case shades = "shade"

        public var label: String {
            switch self {
            case .glyphs: return "Best character per cell"
            case .halfBlocks: return "Half blocks (2 pixels per cell)"
            case .fullBlocks: return "Full blocks"
            case .shades: return "Shades (extra tones)"
            }
        }
    }

    public enum PaletteChoice: String, CaseIterable, Codable {
        case vga16 = "vga"
        /// 16 colours fitted to the picture (ruling 7), saved as XBin, which carries a palette.
        case imagePalette = "xbin"
        case trueColor = "truecolor"

        public var label: String {
            switch self {
            case .vga16: return "16 VGA colours (.ans)"
            case .imagePalette: return "16 colours fitted to the image (.xb)"
            case .trueColor: return "24 bit truecolor (.ans)"
            }
        }

        /// The format a conversion with this palette saves in.
        public var saveFormat: SaveFormat { self == .imagePalette ? .xbin : .ansi }
    }

    public enum Dither: String, CaseIterable, Codable {
        case none
        case floydSteinberg = "fs"
        case serpentine
        case atkinson
        case sierraLite = "sierra"
        case ordered

        public var label: String {
            switch self {
            case .none: return "None"
            case .floydSteinberg: return "Floyd-Steinberg"
            case .serpentine: return "Floyd-Steinberg, serpentine"
            case .atkinson: return "Atkinson"
            case .sierraLite: return "Sierra Lite"
            case .ordered: return "Ordered (Bayer 4x4)"
            }
        }
    }

    public struct Options: Equatable, Codable {
        public var columns = 80
        public var mode = Mode.glyphs
        public var palette = PaletteChoice.vga16
        public var dither = Dither.serpentine
        /// 0 to 1: how much of the error dithering spreads (or how strong the ordered pattern is).
        public var ditherStrength: Float = 0.7
        public var iceColors = true
        /// Compensates for the 8x16 character cell so the picture keeps its proportions.
        public var aspectCorrection = true
        /// Glyph search also tries line, box and dot characters.
        public var extendedGlyphs = false
        /// Sample without smoothing (pixel art).
        public var nearestNeighbour = false
        public var adjustments = ImageAdjustments()
        /// Part of the image to convert, in image pixels with a top left origin; nil for all of it.
        public var crop: CGRect?

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
        convert(image, options: options, cancel: { false })!
    }

    /// The canvas size for an image: columns and cell rows.
    public static func size(imageWidth: Int, imageHeight: Int, options: Options) -> (columns: Int, rows: Int) {
        let g = geometry(imageWidth: imageWidth, imageHeight: imageHeight, options: options)
        return (g.columns, g.cellRows)
    }

    struct Geometry {
        let columns: Int
        let cellRows: Int
        /// Half blocks: sample rows (two per cell, the last cell may have one).
        let sampleRows: Int
    }

    static func geometry(imageWidth: Int, imageHeight: Int, options: Options) -> Geometry {
        let crop = normalizedCrop(options.crop, width: imageWidth, height: imageHeight)
        let width = crop.map { Int($0.width) } ?? imageWidth
        let height = crop.map { Int($0.height) } ?? imageHeight
        let columns = min(EditCanvas.maxColumns, max(1, options.columns))
        let half = options.mode == .halfBlocks
        let factor = (half ? 1.0 : 0.5) * (options.aspectCorrection ? 1 : 2)
        let maxSamples = AnsiTerminal.maxRows * (half ? 2 : 1)
        let ratio = Double(max(1, height)) / Double(max(1, width))
        let sampleRows = min(maxSamples, max(1, Int((ratio * Double(columns) * factor).rounded())))
        return Geometry(columns: columns, cellRows: half ? (sampleRows + 1) / 2 : sampleRows, sampleRows: sampleRows)
    }

    /// Converts `image`; nil when `cancel` returned true (checked once per row).
    public static func convert(_ image: CGImage, options: Options, cancel: () -> Bool) -> EditCanvas? {
        let g = geometry(imageWidth: image.width, imageHeight: image.height, options: options)
        var canvas = EditCanvas(columns: g.columns, height: g.cellRows)
        canvas.setIceColors(options.iceColors)
        let strength = min(1, max(0, options.ditherStrength))
        let kernel = strength > 0 ? DitherKernel.kernel(for: options.dither) : nil
        var palette = Palette.vga
        let backgrounds = options.iceColors ? 0...15 : 0...7

        // Glyph search samples each cell at block resolution; huge canvases use bigger blocks.
        let cells = g.columns * g.cellRows
        let block = cells > 500_000 ? 8 : cells > 125_000 ? 4 : 2
        var search: GlyphSearch? = options.mode == .glyphs
            ? GlyphSearch(font: canvas.font,
                          glyphs: options.palette == .trueColor ? GlyphSearch.trueColorGlyphs
                              : GlyphSearch.basicGlyphs + (options.extendedGlyphs ? GlyphSearch.extendedGlyphs : []),
                          palette: palette, allowedBackgrounds: backgrounds, block: block)
            : nil
        let (gridWidth, gridHeight): (Int, Int)
        switch options.mode {
        case .glyphs: (gridWidth, gridHeight) = (g.columns * search!.subWidth, g.cellRows * search!.subHeight)
        case .halfBlocks: (gridWidth, gridHeight) = (g.columns, g.sampleRows)
        case .fullBlocks, .shades: (gridWidth, gridHeight) = (g.columns, g.cellRows)
        }
        var grid = PixelGrid.sample(image, width: gridWidth, height: gridHeight, crop: options.crop,
                                    nearest: options.nearestNeighbour)
        grid.apply(options.adjustments)
        if cancel() { return nil }
        if options.palette == .imagePalette {
            palette = PaletteOptimizer.palette(linear: grid.linear, count: 16)
            canvas.palette = palette
            search = search.map { GlyphSearch(font: canvas.font, glyphs: $0.glyphCodes, palette: palette,
                                              allowedBackgrounds: backgrounds, block: block) }
            if cancel() { return nil }
        }

        if options.palette == .trueColor {
            return trueColor(grid: grid, canvas: canvas, geometry: g, mode: options.mode, search: search, cancel: cancel)
        }
        if options.dither == .ordered { applyOrdered(&grid, strength: strength) }
        var values = grid.linear
        let paletteLinear = palette.map { OKLab.linear($0) }
        let paletteLab = palette.map { OKLab.lab($0) }
        let one = SIMD3<Float>(repeating: 1)

        switch options.mode {
        case .glyphs:
            let search = search!
            let sw = search.subWidth, sh = search.subHeight
            // Error diffusion runs on cells: each cell's mean error moves to its neighbours.
            var carry = [SIMD3<Float>](repeating: .zero, count: cells)
            let diffusion = kernel ?? DitherKernel(taps: [], serpentine: false)
            var pixels = [SIMD3<Float>](repeating: .zero, count: sw * sh)
            let finished = diffusion.run(width: g.columns, height: g.cellRows, values: &carry, cancel: cancel) { index, offset in
                let cx = index % g.columns, cy = index / g.columns
                var mean = SIMD3<Float>.zero
                for sy in 0..<sh {
                    let row = (cy * sh + sy) * gridWidth + cx * sw
                    for sx in 0..<sw {
                        let v = (values[row + sx] + offset).clamped(lowerBound: .zero, upperBound: one)
                        pixels[sy * sw + sx] = v
                        mean += v
                    }
                }
                let match = search.best(cell: pixels)
                canvas.set(AnsiCell(code: match.code, fg: palette[match.fg], bg: palette[match.bg]), x: cx, y: cy)
                return kernel == nil ? .zero : (mean / Float(sw * sh) - match.rendered) * strength
            }
            return finished ? canvas : nil

        case .halfBlocks, .fullBlocks:
            let half = options.mode == .halfBlocks
            var chosen = [Int](repeating: 0, count: gridWidth * gridHeight)
            let diffusion = kernel ?? DitherKernel(taps: [], serpentine: false)
            let finished = diffusion.run(width: gridWidth, height: gridHeight, values: &values, cancel: cancel) { index, value in
                let target = value.clamped(lowerBound: .zero, upperBound: one)
                let x = index % gridWidth, y = index / gridWidth
                var allowed = 0...15
                // Without iCE a cell holds one bright colour (the foreground): a lower half under
                // a bright upper half must be dark or the same colour.
                var sameAs: Int?
                if half, !options.iceColors, y % 2 == 1, chosen[index - gridWidth] >= 8 {
                    allowed = 0...7
                    sameAs = chosen[index - gridWidth]
                }
                let lab = OKLab.lab(linear: target)
                var pick = OKLab.nearest(lab, in: paletteLab, allowed: allowed)
                if let sameAs {
                    let a = lab - paletteLab[pick], b = lab - paletteLab[sameAs]
                    if (b * b).sum() < (a * a).sum() { pick = sameAs }
                }
                chosen[index] = pick
                return kernel == nil ? .zero : (target - paletteLinear[pick]) * strength
            }
            guard finished else { return nil }
            for y in 0..<g.cellRows {
                for x in 0..<g.columns {
                    if half {
                        let top = chosen[y * 2 * gridWidth + x]
                        let bottom = y * 2 + 1 < gridHeight ? chosen[(y * 2 + 1) * gridWidth + x] : 0
                        canvas.set(halves(top: top, bottom: bottom, palette: palette, ice: options.iceColors), x: x, y: y)
                    } else {
                        canvas.set(AnsiCell(code: EditCanvas.blockFull, fg: palette[chosen[y * gridWidth + x]], bg: palette[0]),
                                   x: x, y: y)
                    }
                }
            }
            return canvas

        case .shades:
            let choices = shadeCandidates(palette: palette, backgrounds: backgrounds)
            let choiceLab = choices.map(\.lab)
            var chosen = [Int](repeating: 0, count: gridWidth * gridHeight)
            let diffusion = kernel ?? DitherKernel(taps: [], serpentine: false)
            let finished = diffusion.run(width: gridWidth, height: gridHeight, values: &values, cancel: cancel) { index, value in
                let target = value.clamped(lowerBound: .zero, upperBound: one)
                let pick = OKLab.nearest(OKLab.lab(linear: target), in: choiceLab, allowed: 0...(choices.count - 1))
                chosen[index] = pick
                return kernel == nil ? .zero : (target - choices[pick].linear) * strength
            }
            guard finished else { return nil }
            for y in 0..<g.cellRows {
                for x in 0..<g.columns {
                    let shade = choices[chosen[y * gridWidth + x]]
                    canvas.set(AnsiCell(code: shade.code, fg: palette[shade.fg], bg: palette[shade.bg]), x: x, y: y)
                }
            }
            return canvas
        }
    }

    // MARK: Helpers

    /// A half block cell for palette indexes `top` over `bottom` (plan 6 ruling 8).
    static func halves(top: Int, bottom: Int, palette: [RGB], ice: Bool) -> AnsiCell {
        if top == bottom { return AnsiCell(code: EditCanvas.blockFull, fg: palette[top], bg: palette[0]) }
        if ice || bottom < 8 { return AnsiCell(code: EditCanvas.blockUpper, fg: palette[top], bg: palette[bottom]) }
        if top < 8 { return AnsiCell(code: EditCanvas.blockLower, fg: palette[bottom], bg: palette[top]) }
        return AnsiCell(code: EditCanvas.blockUpper, fg: palette[top], bg: palette[bottom - 8])
    }

    private static func trueColor(grid: PixelGrid, canvas: EditCanvas, geometry g: Geometry, mode: Mode,
                                  search: GlyphSearch?, cancel: () -> Bool) -> EditCanvas? {
        var canvas = canvas
        let black = Palette.vga[0]
        func rgb(_ v: SIMD3<Float>) -> RGB { RGB(r: OKLab.byte(srgb: v.x), g: OKLab.byte(srgb: v.y), b: OKLab.byte(srgb: v.z)) }
        let linear = mode == .glyphs ? grid.linear : []
        for y in 0..<g.cellRows {
            if cancel() { return nil }
            for x in 0..<g.columns {
                switch mode {
                case .glyphs:
                    let search = search!
                    let sw = search.subWidth, sh = search.subHeight
                    var pixels: [SIMD3<Float>] = []
                    pixels.reserveCapacity(sw * sh)
                    for sy in 0..<sh { for sx in 0..<sw { pixels.append(linear[(y * sh + sy) * grid.width + x * sw + sx]) } }
                    let match = search.bestTrueColor(cell: pixels)
                    canvas.set(AnsiCell(code: match.code, fg: OKLab.rgb(linear: match.fg),
                                        bg: match.code == EditCanvas.blockFull ? black : OKLab.rgb(linear: match.bg)), x: x, y: y)
                case .halfBlocks:
                    let top = rgb(grid.srgb[y * 2 * grid.width + x])
                    let bottom = y * 2 + 1 < grid.height ? rgb(grid.srgb[(y * 2 + 1) * grid.width + x]) : black
                    canvas.set(AnsiCell(code: EditCanvas.blockUpper, fg: top, bg: bottom), x: x, y: y)
                case .fullBlocks, .shades:
                    canvas.set(AnsiCell(code: EditCanvas.blockFull, fg: rgb(grid.srgb[y * grid.width + x]), bg: black), x: x, y: y)
                }
            }
        }
        return canvas
    }

    /// A character and colour pair for shade mode, with the colour it shows from a distance.
    struct Shade {
        let code: UInt8
        let fg: Int
        let bg: Int
        let linear: SIMD3<Float>
        let lab: SIMD3<Float>
    }

    /// Space (background only), the three shades and the full block, over every allowed pair;
    /// a shade shows the linear light mix of its colours by coverage.
    static func shadeCandidates(palette: [RGB], backgrounds: ClosedRange<Int>) -> [Shade] {
        let linear = palette.map { OKLab.linear($0) }
        var out: [Shade] = []
        func add(_ code: UInt8, _ fg: Int, _ bg: Int, _ mix: SIMD3<Float>) {
            out.append(Shade(code: code, fg: fg, bg: bg, linear: mix, lab: OKLab.lab(linear: mix)))
        }
        for bg in backgrounds { add(0x20, 7, bg, linear[bg]) }
        for fg in palette.indices { add(EditCanvas.blockFull, fg, 0, linear[fg]) }
        for (code, coverage) in [(UInt8(176), Float(0.25)), (177, 0.5), (178, 0.75)] {
            for fg in palette.indices {
                for bg in backgrounds where bg != fg {
                    add(code, fg, bg, linear[fg] * coverage + linear[bg] * (1 - coverage))
                }
            }
        }
        return out
    }
}
