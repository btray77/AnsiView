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
    /// Pixels touched since the last `resetWork()`: the RIP terminal's drawing budget.
    public private(set) var work = 0
    private var fillMarks: [UInt32] = []
    private var fillGeneration: UInt32 = 0

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

    mutating func resetWork() { work = 0 }

    mutating func setPalette(_ index: Int, ega value: Int) {
        guard (0..<16).contains(index) else { return }
        palette[index] = Self.ega(value & 63)
        changeCount &+= 1
    }

    // MARK: Pixels

    mutating func plot(_ x: Int, _ y: Int, _ c: UInt8) {
        work &+= 1
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
        work &+= b - a + 1
        for x in a...b { pixels[y * width + x] = patternPixel(x, y) & 15 }
    }

    mutating func erase(x0: Int, y0: Int, x1: Int, y1: Int) {
        let left = max(0, x0), right = min(width - 1, x1), top = max(0, y0), bottom = min(height - 1, y1)
        guard left <= right, top <= bottom else { return }
        work &+= (right - left + 1) * (bottom - top + 1)
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
        // Marks are reused between fills (a generation number per fill), and only the touched box is painted.
        if fillMarks.count != width * height { fillMarks = [UInt32](repeating: 0, count: width * height) }
        fillGeneration &+= 1
        if fillGeneration == 0 { fillMarks = [UInt32](repeating: 0, count: width * height); fillGeneration = 1 }
        let mark = fillGeneration
        var box = (x0: x, y0: y, x1: x, y1: y)
        var stack = [(x, y)]
        while let (px, py) = stack.popLast() {
            guard fillMarks[py * width + px] != mark else { continue }
            var left = px
            while left > viewport.x0, pixel(left - 1, py) != border, fillMarks[py * width + left - 1] != mark { left -= 1 }
            var right = px
            while right < viewport.x1, pixel(right + 1, py) != border, fillMarks[py * width + right + 1] != mark { right += 1 }
            for cx in left...right { fillMarks[py * width + cx] = mark }
            work &+= right - left + 1
            box = (min(box.x0, left), min(box.y0, py), max(box.x1, right), max(box.y1, py))
            for ny in [py - 1, py + 1] where ny >= viewport.y0 && ny <= viewport.y1 {
                var cx = left
                var inRun = false
                while cx <= right {
                    // One seed per run of fillable pixels keeps the stack small.
                    let open = pixel(cx, ny) != border && fillMarks[ny * width + cx] != mark
                    if open, !inRun { stack.append((cx, ny)) }
                    inRun = open
                    cx += 1
                }
            }
        }
        for py in box.y0...box.y1 {
            for px in box.x0...box.x1 where fillMarks[py * width + px] == mark {
                pixels[py * width + px] = patternPixel(px, py) & 15
            }
        }
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

    /// Draws text: font 0 is AnsiView's 8x8 font scaled by `size`; fonts 1 to 10 are the stroke
    /// fonts (`RIPStrokeFont`), sized from the RIPscrip font metric tables. Direction 1 runs upwards.
    mutating func text(_ string: [UInt8], x: Int, y: Int) {
        if font == 0 {
            bitmapText(string, x: x, y: y)
        } else {
            strokeText(string, x: x, y: y)
        }
        changeCount &+= 1
    }

    private mutating func bitmapText(_ string: [UInt8], x: Int, y: Int) {
        let scale = max(1, size)
        let glyphs = PlatformFonts.appleII
        var cx = x, cy = y
        for byte in string {
            if direction == 0 ? cx > width : cy < 0 { break }
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
    }

    /// Glyph units to pixels for the current stroke font and size.
    private var strokeScale: Double {
        let m = RIPStrokeFont.metrics(font: font, size: size)
        return Double(max(1, m.base - m.top)) / 8
    }

    private func strokeAdvance(_ byte: UInt8) -> Int {
        let style = RIPStrokeFont.style(font: font)
        return max(1, Int((Double(RIPStrokeFont.advance(for: byte)) * style.narrow * strokeScale).rounded()))
    }

    private mutating func strokeText(_ string: [UInt8], x: Int, y: Int) {
        let style = RIPStrokeFont.style(font: font)
        let scale = strokeScale
        let top = Double(RIPStrokeFont.metrics(font: font, size: size).top)
        let brush = max(1, Int((style.weight * scale).rounded()))
        var along = 0
        for byte in string {
            // Text past the edge draws nothing: stop there rather than walk the rest of the line.
            if offCanvas(x: x, y: y, along: along) { along += string.count; break }
            for stroke in RIPStrokeFont.strokes(for: byte) {
                // Local offsets: `dx` along the text, `dy` down from the top of the cell.
                let points: [(Int, Int)] = stroke.map { p in
                    let dx = Double(along) + (Double(p.x) * style.narrow + style.slant * Double(8 - p.y)) * scale
                    let dy = top + Double(p.y) * scale
                    let ix = Int(dx.rounded()), iy = Int(dy.rounded())
                    return direction == 0 ? (x + ix, y + iy) : (x + iy, y - ix)
                }
                for pass in 0..<(style.double ? 2 : 1) {
                    let shift = pass * max(1, brush)
                    if points.count == 1 { strokeLine(points[0], points[0], brush: brush, shift: shift) }
                    for i in points.indices.dropFirst() { strokeLine(points[i - 1], points[i], brush: brush, shift: shift) }
                }
            }
            along += strokeAdvance(byte)
        }
        position = direction == 0 ? (x + along, y) : (x, y - along)
    }

    /// A solid line drawn with a square brush (text ignores the line style).
    private mutating func strokeLine(_ a: (Int, Int), _ b: (Int, Int), brush: Int, shift: Int) {
        var x = a.0, y = a.1
        let dx = abs(b.0 - a.0), dy = -abs(b.1 - a.1)
        let sx = a.0 < b.0 ? 1 : -1, sy = a.1 < b.1 ? 1 : -1
        var err = dx + dy, steps = 0
        let offset = (brush - 1) / 2
        while true {
            for by in 0..<brush {
                for bx in 0..<brush {
                    if direction == 0 { plot(x + bx - offset + shift, y + by - offset, color) } else { plot(x + bx - offset, y + by - offset - shift, color) }
                }
            }
            if x == b.0, y == b.1 { break }
            let e2 = 2 * err
            if e2 >= dy { err += dy; x += sx }
            if e2 <= dx { err += dx; y += sy }
            steps += 1
            if steps > 4000 { break }
        }
    }

    /// The longest start of `string` that fits in `width` pixels (one pass over the advances).
    func fittingPrefix(_ string: [UInt8], width: Int) -> [UInt8] {
        var used = 0
        for (i, byte) in string.enumerated() {
            used += font == 0 ? 8 * max(1, size) : strokeAdvance(byte)
            if used > width { return Array(string[..<i]) }
        }
        return string
    }

    /// True once text running from (x, y) is wholly past the canvas edge it runs towards.
    private func offCanvas(x: Int, y: Int, along: Int) -> Bool {
        direction == 0 ? x + along > width + 8 : y - along < -8
    }

    /// The width of text in pixels in the current font.
    func textWidth(_ string: [UInt8]) -> Int {
        if font == 0 { return string.count * 8 * max(1, size) }
        return string.reduce(0) { $0 + strokeAdvance($1) }
    }

    /// The height of a text line in pixels (cell top to the lowest descender).
    var textHeight: Int {
        font == 0 ? 8 * max(1, size) : RIPStrokeFont.metrics(font: font, size: size).drop + 1
    }

    // MARK: Images

    /// RIP_PUT_IMAGE modes: 0 copy, 1 xor, 2 or, 3 and, 4 not.
    mutating func put(_ source: [UInt8], width w: Int, height h: Int, x: Int, y: Int, mode: Int) {
        guard w > 0, h > 0, source.count == w * h else { return }
        for cy in 0..<h {
            let py = y + cy
            guard py >= viewport.y0, py <= viewport.y1 else { continue }
            for cx in 0..<w {
                let px = x + cx
                guard px >= viewport.x0, px <= viewport.x1 else { continue }
                let i = py * width + px, c = source[cy * w + cx] & 15, old = pixels[i]
                switch mode {
                case 1: pixels[i] = (old ^ c) & 15
                case 2: pixels[i] = (old | c) & 15
                case 3: pixels[i] = old & c
                case 4: pixels[i] = ~c & 15
                default: pixels[i] = c
                }
            }
        }
        work &+= w * h
        changeCount &+= 1
    }

    /// A copy of a screen rectangle (clamped), row major.
    func region(x0: Int, y0: Int, x1: Int, y1: Int) -> (width: Int, height: Int, pixels: [UInt8])? {
        let a = max(0, x0), b = max(0, y0), c = min(width - 1, x1), d = min(height - 1, y1)
        guard c >= a, d >= b else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity((c - a + 1) * (d - b + 1))
        for y in b...d { out += pixels[(y * width + a)...(y * width + c)] }
        return (c - a + 1, d - b + 1, out)
    }

    /// RIP_COPY_REGION: copies whole scan lines of a band (x widened to multiples of 8) to start at
    /// `destination`; ignored when the copy would leave the screen. Not clipped to the viewport.
    mutating func copyLines(x0: Int, y0: Int, x1: Int, y1: Int, destination: Int) {
        let a = max(0, x0 / 8 * 8), c = min(width - 1, (x1 + 7) / 8 * 8)
        guard c >= a, y1 >= y0, y0 >= 0, destination >= 0, destination != y0,
              destination + (y1 - y0) < height, y1 < height else { return }
        let band = (y0...y1).map { Array(pixels[($0 * width + a)...($0 * width + c)]) }
        for (k, line) in band.enumerated() {
            let start = (destination + k) * width + a
            pixels.replaceSubrange(start..<(start + line.count), with: line)
        }
        work &+= band.count * (c - a + 1)
        changeCount &+= 1
    }

    /// Inverts a rectangle's colours (selected buttons).
    mutating func invert(x0: Int, y0: Int, x1: Int, y1: Int) {
        let a = max(0, x0), b = max(0, y0), c = min(width - 1, x1), d = min(height - 1, y1)
        guard c >= a, d >= b else { return }
        for y in b...d { for x in a...c { pixels[y * width + x] ^= 15 } }
        work &+= (c - a + 1) * (d - b + 1)
        changeCount &+= 1
    }

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
