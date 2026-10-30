import CoreGraphics
import CoreText
import Foundation

/// A fixed size 256 glyph font for code page 437 text, one bit per pixel.
public struct BitmapFont {
    public let name: String
    public let width: Int
    public let height: Int
    /// 256 glyphs, each `width * height` pixels, row major, top row first.
    private let glyphs: [[Bool]]

    public func pixels(for code: UInt8) -> [Bool] {
        glyphs[Int(code)]
    }

    /// Platform fonts (PETSCII, teletext, ...) may hold more than 256 glyphs, addressed by `AnsiCell.glyph`.
    public var glyphCount: Int { declaredCount ?? glyphs.count }

    /// A glyph by index; out of range gives a blank glyph.
    public func pixels(glyph index: Int) -> [Bool] {
        glyphs.indices.contains(index) ? glyphs[index] : Array(repeating: false, count: width * height)
    }

    /// The extra 9th column VGA hardware drew in 9 pixel mode: line drawing characters
    /// (0xC0-0xDF) repeat their 8th column so lines join; everything else is blank.
    public func ninthColumn(for code: UInt8) -> [Bool] {
        guard (0xC0...0xDF).contains(code) else { return Array(repeating: false, count: height) }
        let glyph = glyphs[Int(code)]
        return (0..<height).map { glyph[$0 * width + width - 1] }
    }

    /// A font embedded in an XBin, ADF or IDF file: 8 pixels wide, `height` bytes per glyph,
    /// most significant bit leftmost. Missing bytes are blank.
    public init(rawGlyphs: [UInt8], height: Int, name: String = "Embedded") {
        self.name = name
        self.width = 8
        self.height = height
        self.glyphs = (0..<256).map { code in
            (0..<height * 8).map { pixel in
                let index = code * height + pixel / 8
                guard index < rawGlyphs.count else { return false }
                return rawGlyphs[index] & (0x80 >> UInt8(pixel % 8)) != 0
            }
        }
    }

    /// A font from glyph bitmaps (`width * height` pixels each). Fewer than 256 glyphs are padded
    /// with blanks so every byte code can be drawn.
    public init(name: String, width: Int, height: Int, glyphs: [[Bool]]) {
        self.name = name
        self.width = width
        self.height = height
        let blank = [Bool](repeating: false, count: width * height)
        var all = glyphs.map { $0.count == width * height ? $0 : blank }
        while all.count < 256 { all.append(blank) }
        self.glyphs = all
        self.declaredCount = glyphs.count
    }

    private var declaredCount: Int?

    // MARK: Bundled fonts

    /// SAUCE font names and the bundled pixel font that draws them.
    private static let catalog: [String: (file: String, width: Int, height: Int)] = [
        "IBM VGA": ("Px437_IBM_VGA_8x16", 8, 16),
        "IBM VGA50": ("Px437_IBM_EGA_8x8", 8, 8),
        "IBM EGA": ("Px437_IBM_EGA_8x14", 8, 14),
        "IBM EGA43": ("Px437_IBM_EGA_8x8", 8, 8),
    ]

    /// Every SAUCE font name that maps to a bundled font.
    public static var supportedNames: [String] { catalog.keys.sorted() }

    /// IBM VGA 8x16, the default for DOS art.
    public static let vga: BitmapFont = load("IBM VGA") ?? fallback

    /// The font for a SAUCE font name. Code page suffixes ("IBM VGA 437") are accepted;
    /// unknown or missing names give IBM VGA.
    public static func named(_ sauceFontName: String?) -> BitmapFont {
        guard var name = sauceFontName?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return vga }
        if let range = name.range(of: #" \d{3}$"#, options: .regularExpression) {
            name.removeSubrange(range)
        }
        return load(name) ?? vga
    }

    private static let lock = NSLock()
    private static var cache: [String: BitmapFont] = [:]

    private static func load(_ name: String) -> BitmapFont? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[name] { return cached }
        guard let entry = catalog[name],
              let url = Bundle.module.url(forResource: entry.file, withExtension: "ttf", subdirectory: "Fonts"),
              let provider = CGDataProvider(url: url as CFURL),
              let cgFont = CGFont(provider)
        else { return nil }
        let font = rasterize(cgFont, name: name, width: entry.width, height: entry.height)
        cache[name] = font
        return font
    }

    /// The point size at which a pixel outline font's grid is one pixel per font pixel: a glyph
    /// `advance` font units wide must come out `width` pixels. The EGA 8x14 font's grid is 16
    /// points (1600 units per em, 200 per column), not its 14 pixel height. Nil for no advance.
    static func rasterSize(advance: Int, unitsPerEm: Int, width: Int) -> CGFloat? {
        guard advance > 0, unitsPerEm > 0 else { return nil }
        return CGFloat(width * unitsPerEm) / CGFloat(advance)
    }

    /// Draws each glyph of a pixel outline font at its native pixel size with antialiasing off,
    /// which reproduces the original bitmap exactly.
    private static func rasterize(_ cgFont: CGFont, name: String, width: Int, height: Int) -> BitmapFont {
        // The full block's advance gives the size where one font pixel is one bitmap pixel.
        var blockGlyph = cgFont.getGlyphWithGlyphName(name: "uni2588" as CFString)
        var advance: Int32 = 0
        if blockGlyph == 0 {
            let probe = CTFontCreateWithGraphicsFont(cgFont, CGFloat(height), nil, nil)
            var unit: [UniChar] = [0x2588]
            CTFontGetGlyphsForCharacters(probe, &unit, &blockGlyph, 1)
        }
        let measured = cgFont.getGlyphAdvances(glyphs: &blockGlyph, count: 1, advances: &advance)
        let size = (measured ? rasterSize(advance: Int(advance), unitsPerEm: Int(cgFont.unitsPerEm), width: width) : nil)
            ?? CGFloat(height)
        let font = CTFontCreateWithGraphicsFont(cgFont, size, nil, nil)
        let baseline = CTFontGetDescent(font).rounded()
        var glyphs: [[Bool]] = []
        var buffer = [UInt8](repeating: 0, count: width * height)
        for code in 0..<256 {
            var glyph: CGGlyph = 0
            var units = Array(String(Character(CP437.unicode[code])).utf16)
            let found = CTFontGetGlyphsForCharacters(font, &units, &glyph, 1)
            for i in buffer.indices { buffer[i] = 0 }
            if found, code != 0x20, code != 0x00, code != 0xFF {
                buffer.withUnsafeMutableBytes { raw in
                    guard let ctx = CGContext(
                        data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                        bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                        bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
                    ctx.setShouldAntialias(false)
                    ctx.setAllowsAntialiasing(false)
                    ctx.setFillColor(gray: 1, alpha: 1)
                    var position = CGPoint(x: 0, y: baseline)
                    CTFontDrawGlyphs(font, &glyph, &position, 1, ctx)
                }
            }
            glyphs.append(buffer.map { $0 > 127 })
        }
        return BitmapFont(name: name, width: width, height: height, glyphs: glyphs)
    }

    /// Used only if the bundled VGA font cannot be loaded: solid blocks for block characters,
    /// blank elsewhere, so art still shows its colors.
    private static let fallback: BitmapFont = {
        let glyphs: [[Bool]] = (0..<256).map { code in
            (0..<128).map { pixel in
                switch code {
                case 0xDB: return true
                case 0xDC: return pixel >= 64
                case 0xDF: return pixel < 64
                case 0xDD: return pixel % 8 < 4
                case 0xDE: return pixel % 8 >= 4
                default: return false
                }
            }
        }
        return BitmapFont(name: "IBM VGA", width: 8, height: 16, glyphs: glyphs)
    }()
}
