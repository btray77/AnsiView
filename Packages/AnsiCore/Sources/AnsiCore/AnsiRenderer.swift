import CoreGraphics
import CoreText
import Foundation

/// How to draw a screen.
public struct RenderOptions {
    public var font: BitmapFont = .vga
    /// VGA 9 pixel wide character cells.
    public var ninePixel = false
    /// Output pixels per font pixel.
    public var scale = 2
    /// When false, blinking cells show only their background (the "off" half of a blink).
    public var blinkVisible = true

    public init(font: BitmapFont = .vga, ninePixel: Bool = false, scale: Int = 2, blinkVisible: Bool = true) {
        self.font = font
        self.ninePixel = ninePixel
        self.scale = scale
        self.blinkVisible = blinkVisible
    }

    /// The screen's own font and letter spacing, at the scale suited to its height.
    public init(for screen: AnsiScreen, scale: Int? = nil, blinkVisible: Bool = true) {
        self.init(font: screen.font,
                  ninePixel: screen.sauce?.letterSpacing == .nine,
                  scale: scale ?? AnsiRenderer.preferredScale(rows: screen.rows.count),
                  blinkVisible: blinkVisible)
    }
}

/// A rendered screen: a bitmap at `scale` pixels per font pixel.
public struct RenderedAnsi {
    public let image: CGImage
    public let columns: Int
    public let rows: Int
    public let scale: Int
    public let cellWidth: Int
    public let cellHeight: Int
    /// Height stretch that reproduces a 4:3 CRT for art whose SAUCE asks for legacy aspect.
    public let pixelAspect: CGFloat

    /// Size in points, one point per font pixel.
    public var pointSize: CGSize {
        CGSize(width: columns * cellWidth, height: rows * cellHeight)
    }
}

/// Draws an AnsiScreen as a text mode bitmap.
public enum AnsiRenderer {
    /// Scale used for a screen of this height: 2x normally, 1x for very tall files to bound memory.
    public static func preferredScale(rows: Int) -> Int {
        rows <= 250 ? 2 : 1
    }

    /// Pixel aspect for a screen: 4:3 CRT stretch when SAUCE asks for legacy aspect.
    public static func pixelAspect(for screen: AnsiScreen, ninePixel: Bool) -> CGFloat {
        guard screen.sauce?.aspectRatio == .legacy else { return 1 }
        return ninePixel ? 1.35 : 1.2
    }

    public static func render(_ screen: AnsiScreen, options: RenderOptions) -> RenderedAnsi? {
        let rowCount = max(1, screen.rows.count)
        let scale = max(1, options.scale)
        let masks = GlyphMasks.shared(font: options.font, ninePixel: options.ninePixel, scale: scale)
        let cw = masks.cellWidth * scale
        let ch = options.font.height * scale
        let width = screen.columns * cw
        let height = rowCount * ch

        var pixels = [UInt32](repeating: packed(Palette.vga[0]), count: width * height)
        pixels.withUnsafeMutableBufferPointer { out in
            for (rowIndex, row) in screen.rows.enumerated() {
                for (colIndex, cell) in row.enumerated() where colIndex < screen.columns {
                    let hidden = cell.blink && !options.blinkVisible
                    let mask = hidden ? masks.mask(for: 0x20)
                        : cell.scalar.map { masks.mask(for: $0) } ?? masks.mask(for: cell.code)
                    let fgPacked = packed(cell.fg)
                    let bgPacked = packed(cell.bg)
                    let originX = colIndex * cw
                    let originY = rowIndex * ch
                    for py in 0..<ch {
                        let rowStart = (originY + py) * width + originX
                        let maskStart = py * cw
                        for px in 0..<cw {
                            out[rowStart + px] = mask[maskStart + px] ? fgPacked : bgPacked
                        }
                    }
                }
            }
        }

        let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let provider = CGDataProvider(data: data as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(
                width: width, height: height,
                bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: space,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        return RenderedAnsi(
            image: image, columns: screen.columns, rows: rowCount, scale: scale,
            cellWidth: masks.cellWidth, cellHeight: options.font.height,
            pixelAspect: pixelAspect(for: screen, ninePixel: options.ninePixel))
    }

    // RGBX in memory order, which is little endian UInt32 0xXXBBGGRR.
    private static func packed(_ c: RGB) -> UInt32 {
        UInt32(c.r) | UInt32(c.g) << 8 | UInt32(c.b) << 16 | 0xFF00_0000
    }
}

/// Scaled glyph masks for one font, letter spacing and scale, built once and shared.
final class GlyphMasks {
    let cellWidth: Int
    private let cellHeight: Int
    private let scale: Int
    private let masks: [[Bool]]
    private let scalarLock = NSLock()
    private var scalarMasks: [Unicode.Scalar: [Bool]] = [:]

    private init(font: BitmapFont, ninePixel: Bool, scale: Int) {
        let w = font.width + (ninePixel ? 1 : 0)
        let h = font.height
        cellWidth = w
        cellHeight = h
        self.scale = scale
        masks = (0..<256).map { code in
            let glyph = font.pixels(for: UInt8(code))
            let ninth = ninePixel ? font.ninthColumn(for: UInt8(code)) : []
            var out = [Bool](repeating: false, count: w * scale * h * scale)
            for y in 0..<(h * scale) {
                for x in 0..<(w * scale) {
                    let fx = x / scale, fy = y / scale
                    out[y * w * scale + x] = fx < font.width ? glyph[fy * font.width + fx] : ninth[fy]
                }
            }
            return out
        }
    }

    func mask(for code: UInt8) -> [Bool] { masks[Int(code)] }

    /// A character the bitmap font does not have (from UTF-8 art), drawn from the system
    /// monospaced font with antialiasing off so it matches the pixel look.
    func mask(for scalar: Unicode.Scalar) -> [Bool] {
        scalarLock.lock()
        defer { scalarLock.unlock() }
        if let cached = scalarMasks[scalar] { return cached }
        let width = cellWidth * scale, height = cellHeight * scale
        var buffer = [UInt8](repeating: 0, count: width * height)
        let font = CTFontCreateWithName("Menlo-Regular" as CFString, CGFloat(height) / 1.2, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: String(Character(scalar)), attributes: attributes))
        let lineWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font)
        buffer.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            ctx.setShouldAntialias(false)
            ctx.textPosition = CGPoint(x: (CGFloat(width) - lineWidth) / 2,
                                       y: (CGFloat(height) - (ascent + descent)) / 2 + descent)
            CTLineDraw(line, ctx)
        }
        let mask = buffer.map { $0 > 127 }
        scalarMasks[scalar] = mask
        return mask
    }

    private static let lock = NSLock()
    private static var cache: [String: GlyphMasks] = [:]

    static func shared(font: BitmapFont, ninePixel: Bool, scale: Int) -> GlyphMasks {
        let key = "\(font.name)|\(font.width)x\(font.height)|\(ninePixel)|\(scale)"
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[key], font.name != "Embedded" { return cached }
        let built = GlyphMasks(font: font, ninePixel: ninePixel, scale: scale)
        if font.name != "Embedded" { cache[key] = built }
        return built
    }
}
