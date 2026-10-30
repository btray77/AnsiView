import CoreGraphics
import Foundation

/// The RIPscrip graphics screen: 640x350 pixels in 16 colours chosen from the EGA's 64, with the
/// Borland BGI style drawing state RIPscrip 1.54 relies on (drawing and fill colours, write mode,
/// line style and thickness, fill pattern, viewport, text style). All drawing is clipped.
public struct RIPCanvas {
    public let width = 640
    public let height = 350
    /// Palette indexes, row major.
    public private(set) var pixels: [UInt8]
    /// The 16 colours in use.
    public private(set) var palette: [RGB]

    /// RIPscrip's default palette: EGA colours 0-5, 20, 7, 56-63.
    public static let defaultPaletteIndexes = [0, 1, 2, 3, 4, 5, 20, 7, 56, 57, 58, 59, 60, 61, 62, 63]

    /// An EGA colour 0-63 (rgbRGB bits: low intensity 0xAA, high 0x55).
    public static func ega(_ c: Int) -> RGB {
        func channel(_ low: Int, _ high: Int) -> UInt8 {
            let dim: Int = (c >> low) & 1, bright: Int = (c >> high) & 1
            return UInt8(dim * 0xAA + bright * 0x55)
        }
        return RGB(r: channel(2, 5), g: channel(1, 4), b: channel(0, 3))
    }

    var color: UInt8 = 15
    var fillColor: UInt8 = 15
    var fillPattern: [UInt8] = RIPCanvas.patterns[1]
    var xorMode = false
    var lineStyle: UInt16 = 0xFFFF
    var thick = false
    var viewport = (x0: 0, y0: 0, x1: 639, y1: 349)
    var position = (x: 0, y: 0)
    var font = 0, direction = 0, size = 1
    public private(set) var changeCount = 0

    public init() {
        pixels = [UInt8](repeating: 0, count: 640 * 350)
        palette = Self.defaultPaletteIndexes.map(Self.ega)
    }

    public func pixel(_ x: Int, _ y: Int) -> UInt8 {
        guard x >= 0, y >= 0, x < width, y < height else { return 0 }
        return pixels[y * width + x]
    }

    mutating func reset() {
        self = RIPCanvas()
    }

    mutating func setPalette(_ index: Int, ega value: Int) {
        guard (0..<16).contains(index) else { return }
        palette[index] = Self.ega(value & 63)
        changeCount &+= 1
    }

    // MARK: Pixels

    mutating func plot(_ x: Int, _ y: Int, _ c: UInt8) {
        guard x >= viewport.x0, x <= viewport.x1, y >= viewport.y0, y <= viewport.y1 else { return }
        let i = y * width + x
        pixels[i] = xorMode ? (pixels[i] ^ c) & 15 : c & 15
    }

    /// A pixel of the fill pattern at a position.
    private func patternPixel(_ x: Int, _ y: Int) -> UInt8 {
        fillPattern[y & 7] & (0x80 >> UInt8(x & 7)) != 0 ? fillColor : 0
    }

    mutating func fillSpan(_ x0: Int, _ x1: Int, _ y: Int) {
        guard y >= viewport.y0, y <= viewport.y1 else { return }
        let a = max(x0, viewport.x0), b = min(x1, viewport.x1)
        guard a <= b else { return }
        for x in a...b { pixels[y * width + x] = patternPixel(x, y) & 15 }
    }

    mutating func erase(x0: Int, y0: Int, x1: Int, y1: Int) {
        let left = max(0, x0), right = min(width - 1, x1), top = max(0, y0), bottom = min(height - 1, y1)
        guard left <= right, top <= bottom else { return }
        for y in top...bottom {
            for x in left...right { pixels[y * width + x] = 0 }
        }
        changeCount &+= 1
    }

    // MARK: Lines and shapes

    mutating func line(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) {
        var x = x0, y = y0
        let dx = abs(x1 - x0), dy = -abs(y1 - y0)
        let sx = x0 < x1 ? 1 : -1, sy = y0 < y1 ? 1 : -1
        var err = dx + dy, step = 0
        while true {
            if lineStyle & (0x8000 >> UInt16(step & 15)) != 0 {
                plot(x, y, color)
                if thick {
                    if dx > -dy { plot(x, y - 1, color); plot(x, y + 1, color) } else { plot(x - 1, y, color); plot(x + 1, y, color) }
                }
            }
            step += 1
            if x == x1, y == y1 { break }
            let e2 = 2 * err
            if e2 >= dy { err += dy; x += sx }
            if e2 <= dx { err += dx; y += sy }
            if step > 4000 { break }
        }
        changeCount &+= 1
    }

    mutating func rectangle(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) {
        line(x0, y0, x1, y0); line(x1, y0, x1, y1); line(x1, y1, x0, y1); line(x0, y1, x0, y0)
    }

    mutating func bar(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) {
        for y in min(y0, y1)...max(y0, y1) { fillSpan(min(x0, x1), max(x0, x1), y) }
        changeCount &+= 1
    }

    /// Points of an elliptical arc; BGI angles: degrees counterclockwise from 3 o'clock.
    func arcPoints(_ cx: Int, _ cy: Int, start: Int, end: Int, rx: Int, ry: Int) -> [(Int, Int)] {
        var endAngle = end
        while endAngle <= start { endAngle += 360 }
        let steps = max(8, min(2000, Int(Double(max(rx, ry)) * Double(endAngle - start) / 20)))
        return (0...steps).map { i in
            let a = (Double(start) + Double(endAngle - start) * Double(i) / Double(steps)) * .pi / 180
            return (cx + Int((Double(rx) * cos(a)).rounded()), cy - Int((Double(ry) * sin(a)).rounded()))
        }
    }

    mutating func polyline(_ points: [(Int, Int)]) {
        guard let first = points.first else { return }
        var previous = first
        if points.count == 1 { plot(first.0, first.1, color) }
        for p in points.dropFirst() {
            line(previous.0, previous.1, p.0, p.1)
            previous = p
        }
    }

    /// Circles are drawn with the EGA aspect ratio, so they look round on a 4:3 screen.
    static let aspect = 0.775

    mutating func ellipseArc(_ cx: Int, _ cy: Int, start: Int, end: Int, rx: Int, ry: Int) {
        let saved = lineStyle
        lineStyle = 0xFFFF
        polyline(arcPoints(cx, cy, start: start, end: end, rx: rx, ry: ry))
        lineStyle = saved
    }

    /// Fills a polygon (even-odd rule) with the fill pattern.
    mutating func fillPolygon(_ points: [(Int, Int)]) {
        guard points.count >= 3 else { return }
        let minY = max(viewport.y0, points.map(\.1).min()!), maxY = min(viewport.y1, points.map(\.1).max()!)
        guard minY <= maxY else { return }
        for y in minY...maxY {
            var xs: [Int] = []
            for i in points.indices {
                let (ax, ay) = points[i], (bx, by) = points[(i + 1) % points.count]
                if (ay <= y && by > y) || (by <= y && ay > y) {
                    xs.append(ax + Int((Double(y - ay) * Double(bx - ax) / Double(by - ay)).rounded()))
                }
            }
            xs.sort()
            var i = 0
            while i + 1 < xs.count { fillSpan(xs[i], xs[i + 1], y); i += 2 }
        }
        changeCount &+= 1
    }

    /// BGI floodfill: fills the area around a point bounded by the border colour.
    mutating func floodFill(_ x: Int, _ y: Int, border: UInt8) {
        guard x >= viewport.x0, x <= viewport.x1, y >= viewport.y0, y <= viewport.y1, pixel(x, y) != border else { return }
        var inside = [Bool](repeating: false, count: width * height)
        var stack = [(x, y)]
        while let (px, py) = stack.popLast() {
            guard !inside[py * width + px] else { continue }
            var left = px
            while left > viewport.x0, pixel(left - 1, py) != border, !inside[py * width + left - 1] { left -= 1 }
            var right = px
            while right < viewport.x1, pixel(right + 1, py) != border, !inside[py * width + right + 1] { right += 1 }
            for cx in left...right { inside[py * width + cx] = true }
            for ny in [py - 1, py + 1] where ny >= viewport.y0 && ny <= viewport.y1 {
                var cx = left
                while cx <= right {
                    if pixel(cx, ny) != border, !inside[ny * width + cx] { stack.append((cx, ny)) }
                    cx += 1
                }
            }
        }
        for i in inside.indices where inside[i] { pixels[i] = patternPixel(i % width, i / width) & 15 }
        changeCount &+= 1
    }

    mutating func bezier(_ p: [(Int, Int)], segments: Int) {
        guard p.count == 4 else { return }
        let n = max(1, min(500, segments))
        let points: [(Int, Int)] = (0...n).map { i in
            let t = Double(i) / Double(n), u = 1 - t
            func f(_ a: Int, _ b: Int, _ c: Int, _ d: Int) -> Int {
                Int((u * u * u * Double(a) + 3 * u * u * t * Double(b) + 3 * u * t * t * Double(c) + t * t * t * Double(d)).rounded())
            }
            return (f(p[0].0, p[1].0, p[2].0, p[3].0), f(p[0].1, p[1].1, p[2].1, p[3].1))
        }
        polyline(points)
    }

    // MARK: Text

    /// Draws text with AnsiView's own 8x8 font (font 0), scaled by `size` for the stroke fonts.
    mutating func text(_ string: [UInt8], x: Int, y: Int) {
        let scale = font == 0 ? max(1, size) : max(1, size / 2 + 1)
        let glyphs = PlatformFonts.appleII
        var cx = x, cy = y
        for byte in string {
            let glyph = glyphs.pixels(glyph: Int(byte & 0x7F))
            for gy in 0..<8 {
                for gx in 0..<8 where glyph[gy * 8 + gx] {
                    for sy in 0..<scale {
                        for sx in 0..<scale {
                            if direction == 0 {
                                plot(cx + gx * scale + sx, cy + gy * scale + sy, color)
                            } else {
                                plot(cx + gy * scale + sy, cy - gx * scale - sx, color)
                            }
                        }
                    }
                }
            }
            if direction == 0 { cx += 8 * scale } else { cy -= 8 * scale }
        }
        position = (cx, cy)
        changeCount &+= 1
    }

    /// The width of text in pixels.
    func textWidth(_ count: Int) -> Int { count * 8 * (font == 0 ? max(1, size) : max(1, size / 2 + 1)) }

    // MARK: Image

    public func image() -> CGImage? {
        var data = [UInt8](repeating: 255, count: width * height * 4)
        for i in 0..<(width * height) {
            let c = palette[Int(pixels[i] & 15)]
            data[i * 4] = c.r; data[i * 4 + 1] = c.g; data[i * 4 + 2] = c.b
        }
        guard let provider = CGDataProvider(data: Data(data) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    // MARK: Fill patterns

    /// Fill patterns 0-11 in the BGI order (empty, solid, lines, slashes, hatches, dots), drawn for AnsiView.
    static let patterns: [[UInt8]] = [
        [0, 0, 0, 0, 0, 0, 0, 0],
        [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF],
        [0xFF, 0xFF, 0, 0, 0xFF, 0xFF, 0, 0],
        [0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80],
        [0x03, 0x06, 0x0C, 0x18, 0x30, 0x60, 0xC0, 0x81],
        [0xC0, 0x60, 0x30, 0x18, 0x0C, 0x06, 0x03, 0x81],
        [0x80, 0x40, 0x20, 0x10, 0x08, 0x04, 0x02, 0x01],
        [0xFF, 0x88, 0x88, 0x88, 0xFF, 0x88, 0x88, 0x88],
        [0x81, 0x42, 0x24, 0x18, 0x18, 0x24, 0x42, 0x81],
        [0xCC, 0x33, 0xCC, 0x33, 0xCC, 0x33, 0xCC, 0x33],
        [0x80, 0x00, 0x08, 0x00, 0x80, 0x00, 0x08, 0x00],
        [0x88, 0x00, 0x22, 0x00, 0x88, 0x00, 0x22, 0x00],
    ]

    /// Line styles 0-3: solid, dotted, centre, dashed.
    static let lineStyles: [UInt16] = [0xFFFF, 0xCCCC, 0xF8F8 ^ 0x0020, 0xF0F0]
}
