import CoreGraphics
import CoreText
import Foundation

/// A rendered screen: a bitmap at `scale` pixels per VGA pixel.
public struct RenderedAnsi {
    public let image: CGImage
    public let columns: Int
    public let rows: Int
    public let scale: Int

    /// Size in points, one point per VGA pixel (8x16 per cell).
    public var pointSize: CGSize {
        CGSize(width: columns * AnsiRenderer.cellWidth, height: rows * AnsiRenderer.cellHeight)
    }
}

/// Draws an AnsiScreen as a VGA text mode bitmap.
public enum AnsiRenderer {
    public static let cellWidth = 8
    public static let cellHeight = 16

    /// Standard VGA text mode palette, RGB.
    public static let palette: [(UInt8, UInt8, UInt8)] = [
        (0x00, 0x00, 0x00), (0x00, 0x00, 0xAA), (0x00, 0xAA, 0x00), (0x00, 0xAA, 0xAA),
        (0xAA, 0x00, 0x00), (0xAA, 0x00, 0xAA), (0xAA, 0x55, 0x00), (0xAA, 0xAA, 0xAA),
        (0x55, 0x55, 0x55), (0x55, 0x55, 0xFF), (0x55, 0xFF, 0x55), (0x55, 0xFF, 0xFF),
        (0xFF, 0x55, 0x55), (0xFF, 0x55, 0xFF), (0xFF, 0xFF, 0x55), (0xFF, 0xFF, 0xFF),
    ]

    /// Scale used for a screen of this height: 2x normally, 1x for very tall files to bound memory.
    public static func preferredScale(rows: Int) -> Int {
        rows <= 250 ? 2 : 1
    }

    /// Renders the screen. Blinking cells show only their background when `blinkVisible` is false.
    /// Pass a shared `atlas` when rendering many frames at the same scale.
    public static func render(
        _ screen: AnsiScreen, scale requestedScale: Int? = nil,
        blinkVisible: Bool = true, atlas sharedAtlas: GlyphAtlas? = nil
    ) -> RenderedAnsi? {
        let rowCount = max(1, screen.rows.count)
        let scale = sharedAtlas?.scale ?? requestedScale ?? preferredScale(rows: rowCount)
        let atlas = sharedAtlas ?? GlyphAtlas(scale: scale)
        let cw = cellWidth * scale
        let ch = cellHeight * scale
        let width = screen.columns * cw
        let height = rowCount * ch

        var pixels = [UInt32](repeating: packed(palette[0]), count: width * height)
        let packedPalette = palette.map(packed)
        pixels.withUnsafeMutableBufferPointer { out in
            for (rowIndex, row) in screen.rows.enumerated() {
                for (colIndex, cell) in row.enumerated() where colIndex < screen.columns {
                    let mask = atlas.mask(for: cell.blink && !blinkVisible ? 0x20 : cell.code)
                    let fg = palette[Int(cell.fg & 0x0F)]
                    let bg = palette[Int(cell.bg & 0x0F)]
                    let bgPacked = packedPalette[Int(cell.bg & 0x0F)]
                    let fgPacked = packedPalette[Int(cell.fg & 0x0F)]
                    let originX = colIndex * cw
                    let originY = rowIndex * ch
                    for py in 0..<ch {
                        let rowStart = (originY + py) * width + originX
                        let maskStart = py * cw
                        for px in 0..<cw {
                            let a = mask[maskStart + px]
                            if a == 0 {
                                out[rowStart + px] = bgPacked
                            } else if a == 255 {
                                out[rowStart + px] = fgPacked
                            } else {
                                out[rowStart + px] = packed(blend(bg, fg, a))
                            }
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
        return RenderedAnsi(image: image, columns: screen.columns, rows: rowCount, scale: scale)
    }

    // RGBX in memory order, which is little endian UInt32 0xXXBBGGRR.
    private static func packed(_ c: (UInt8, UInt8, UInt8)) -> UInt32 {
        UInt32(c.0) | UInt32(c.1) << 8 | UInt32(c.2) << 16 | 0xFF00_0000
    }

    private static func blend(_ bg: (UInt8, UInt8, UInt8), _ fg: (UInt8, UInt8, UInt8), _ a: UInt8) -> (UInt8, UInt8, UInt8) {
        func mix(_ b: UInt8, _ f: UInt8) -> UInt8 {
            UInt8((Int(b) * (255 - Int(a)) + Int(f) * Int(a)) / 255)
        }
        return (mix(bg.0, fg.0), mix(bg.1, fg.1), mix(bg.2, fg.2))
    }
}

/// Coverage masks (0-255, top row first) for each CP437 code at a given scale.
/// Blocks, shades and box drawing are drawn pixel exact so art tiles without gaps;
/// everything else is rasterized from Menlo.
public final class GlyphAtlas {
    public let scale: Int
    private var cache: [[UInt8]?] = Array(repeating: nil, count: 256)
    private let font: CTFont

    public init(scale: Int) {
        self.scale = scale
        let targetHeight = CGFloat(AnsiRenderer.cellHeight * scale)
        self.font = CTFontCreateWithName("Menlo-Regular" as CFString, targetHeight / 1.2, nil)
    }

    public func mask(for code: UInt8) -> [UInt8] {
        if let cached = cache[Int(code)] { return cached }
        let built = Self.vgaPixels(for: code).map(upscale) ?? rasterize(code)
        cache[Int(code)] = built
        return built
    }

    // MARK: Pixel exact glyphs on the 8x16 VGA grid

    private static let w = AnsiRenderer.cellWidth
    private static let h = AnsiRenderer.cellHeight

    private static func vgaPixels(for code: UInt8) -> [Bool]? {
        switch code {
        case 0x00, 0x20, 0xFF:
            return Array(repeating: false, count: w * h)
        case 0xB0: return shade([0x22, 0x88])
        case 0xB1: return shade([0x55, 0xAA])
        case 0xB2: return shade([0xDD, 0x77])
        case 0xDB: return fill { _, _ in true }
        case 0xDC: return fill { _, y in y >= h / 2 }
        case 0xDF: return fill { _, y in y < h / 2 }
        case 0xDD: return fill { x, _ in x < w / 2 }
        case 0xDE: return fill { x, _ in x >= w / 2 }
        case 0xFE: return fill { x, y in (1...6).contains(x) && (4...11).contains(y) }
        default:
            guard let arms = boxArms[code] else { return nil }
            return boxDrawing(arms)
        }
    }

    private static func fill(_ on: (Int, Int) -> Bool) -> [Bool] {
        var p = [Bool](repeating: false, count: w * h)
        for y in 0..<h { for x in 0..<w where on(x, y) { p[y * w + x] = true } }
        return p
    }

    /// Alternating row bit patterns, most significant bit is the leftmost pixel.
    private static func shade(_ rowBits: [UInt8]) -> [Bool] {
        fill { x, y in rowBits[y % rowBits.count] & (0x80 >> UInt8(x)) != 0 }
    }

    /// Arm weights (up, down, left, right): 0 none, 1 single line, 2 double line.
    private typealias Arms = (u: Int, d: Int, l: Int, r: Int)

    private static let boxArms: [UInt8: Arms] = [
        0xB3: (1, 1, 0, 0), 0xB4: (1, 1, 1, 0), 0xB5: (1, 1, 2, 0), 0xB6: (2, 2, 1, 0),
        0xB7: (0, 2, 1, 0), 0xB8: (0, 1, 2, 0), 0xB9: (2, 2, 2, 0), 0xBA: (2, 2, 0, 0),
        0xBB: (0, 2, 2, 0), 0xBC: (2, 0, 2, 0), 0xBD: (2, 0, 1, 0), 0xBE: (1, 0, 2, 0),
        0xBF: (0, 1, 1, 0), 0xC0: (1, 0, 0, 1), 0xC1: (1, 0, 1, 1), 0xC2: (0, 1, 1, 1),
        0xC3: (1, 1, 0, 1), 0xC4: (0, 0, 1, 1), 0xC5: (1, 1, 1, 1), 0xC6: (1, 1, 0, 2),
        0xC7: (2, 2, 0, 1), 0xC8: (2, 0, 0, 2), 0xC9: (0, 2, 0, 2), 0xCA: (2, 0, 2, 2),
        0xCB: (0, 2, 2, 2), 0xCC: (2, 2, 0, 2), 0xCD: (0, 0, 2, 2), 0xCE: (2, 2, 2, 2),
        0xCF: (1, 0, 2, 2), 0xD0: (2, 0, 1, 1), 0xD1: (0, 1, 2, 2), 0xD2: (0, 2, 1, 1),
        0xD3: (2, 0, 0, 1), 0xD4: (1, 0, 0, 2), 0xD5: (0, 1, 0, 2), 0xD6: (0, 2, 0, 1),
        0xD7: (2, 2, 1, 1), 0xD8: (1, 1, 2, 2), 0xD9: (1, 0, 1, 0), 0xDA: (0, 1, 0, 1),
    ]

    /// How far a double line reaches past center: -1 near line, 0 center, +1 far line.
    private static func doubleReach(side: Int, other: Int) -> Int {
        if side == 2 { return -1 }
        if side == 1 { return 0 }
        return other == 2 ? 1 : 0
    }

    /// Same for a single line, given the opposite arm and the two perpendicular arms.
    private static func singleReach(opposite: Int, _ p1: Int, _ p2: Int) -> Int {
        if opposite > 0 { return 0 }
        if p1 == 2 && p2 == 2 { return -1 }
        return (p1 == 2 || p2 == 2) ? 1 : 0
    }

    private static func boxDrawing(_ a: Arms) -> [Bool] {
        var p = [Bool](repeating: false, count: w * h)
        let cx = 3, cy = 7
        func hline(_ y: Int, _ x0: Int, _ x1: Int) {
            for x in max(0, min(x0, x1))...min(w - 1, max(x0, x1)) { p[y * w + x] = true }
        }
        func vline(_ x: Int, _ y0: Int, _ y1: Int) {
            for y in max(0, min(y0, y1))...min(h - 1, max(y0, y1)) { p[y * w + x] = true }
        }
        // Left and right arms. Reach is measured toward the arm's own edge, so it flips sign on the right.
        for (weight, edge, sign, opposite) in [(a.l, 0, 1, a.r), (a.r, w - 1, -1, a.l)] where weight > 0 {
            if weight == 1 {
                hline(cy, edge, cx + sign * singleReach(opposite: opposite, a.u, a.d))
            } else {
                hline(cy - 1, edge, cx + sign * doubleReach(side: a.u, other: a.d))
                hline(cy + 1, edge, cx + sign * doubleReach(side: a.d, other: a.u))
            }
        }
        for (weight, edge, sign, opposite) in [(a.u, 0, 1, a.d), (a.d, h - 1, -1, a.u)] where weight > 0 {
            if weight == 1 {
                vline(cx, edge, cy + sign * singleReach(opposite: opposite, a.l, a.r))
            } else {
                vline(cx - 1, edge, cy + sign * doubleReach(side: a.l, other: a.r))
                vline(cx + 1, edge, cy + sign * doubleReach(side: a.r, other: a.l))
            }
        }
        return p
    }

    private func upscale(_ pixels: [Bool]) -> [UInt8] {
        let w = Self.w, h = Self.h, s = scale
        var out = [UInt8](repeating: 0, count: w * s * h * s)
        for y in 0..<(h * s) {
            for x in 0..<(w * s) where pixels[(y / s) * w + x / s] {
                out[y * w * s + x] = 255
            }
        }
        return out
    }

    // MARK: Font glyphs

    private func rasterize(_ code: UInt8) -> [UInt8] {
        let width = Self.w * scale
        let height = Self.h * scale
        var buffer = [UInt8](repeating: 0, count: width * height)
        let scalar = CP437.unicode[Int(code)]
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: String(Character(scalar)), attributes: attributes))
        let lineWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)
        buffer.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(
                data: raw.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            ctx.setShouldSmoothFonts(false)
            ctx.textPosition = CGPoint(
                x: (CGFloat(width) - lineWidth) / 2,
                y: (CGFloat(height) - (ascent + descent)) / 2 + descent)
            CTLineDraw(line, ctx)
        }
        return buffer
    }
}

/// Code page 437 to Unicode, including the graphic glyphs DOS shows for control codes.
public enum CP437 {
    public static let unicode: [Unicode.Scalar] = Array((
        "\u{0020}☺☻♥♦♣♠•◘○◙♂♀♪♫☼►◄↕‼¶§▬↨↑↓→←∟↔▲▼"
        + " !\"#$%&'()*+,-./0123456789:;<=>?"
        + "@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_"
        + "`abcdefghijklmnopqrstuvwxyz{|}~⌂"
        + "ÇüéâäàåçêëèïîìÄÅÉæÆôöòûùÿÖÜ¢£¥₧ƒ"
        + "áíóúñÑªº¿⌐¬½¼¡«»░▒▓│┤╡╢╖╕╣║╗╝╜╛┐"
        + "└┴┬├─┼╞╟╚╔╩╦╠═╬╧╨╤╥╙╘╒╓╫╪┘┌█▄▌▐▀"
        + "αßΓπΣσµτΦΘΩδ∞φε∩≡±≥≤⌠⌡÷≈°∙·√ⁿ²■\u{00A0}"
    ).unicodeScalars)
}
