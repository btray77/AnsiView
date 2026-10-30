import CoreGraphics
import Foundation

/// The BBC Micro's bitmap graphics in modes 0-6 (VDU 25 PLOT, VDU 18 GCOL, VDU 16 CLG,
/// VDU 19 palette): logical coordinates 0-1279 by 0-1023 from the bottom left, drawn on the mode's
/// own pixel grid in its 2, 4 or 8 colours. Modes 3 and 6 are text only.
struct BBCGraphics {
    /// Physical colours 0-7: black, red, green, yellow, blue, magenta, cyan, white.
    static let colours: [RGB] = [0x000000, 0xFF0000, 0x00FF00, 0xFFFF00, 0x0000FF, 0xFF00FF, 0x00FFFF, 0xFFFFFF]
        .map(RGB.init(hex:))

    let mode: Int
    let width: Int
    let height: Int
    private(set) var pixels: [UInt8]
    /// Logical colour to physical colour.
    private var palette: [Int]
    var textForeground = 7
    var textBackground = 0
    var graphicsColour = (mode: 0, colour: 1)
    private var points: [(Int, Int)] = [(0, 0), (0, 0)]

    init(mode: Int) {
        self.mode = mode
        switch mode {
        case 0: (width, height) = (640, 256)
        case 1, 4: (width, height) = (320, 256)
        case 2, 5: (width, height) = (160, 256)
        default: (width, height) = (0, 0)
        }
        pixels = [UInt8](repeating: 0, count: width * height)
        switch mode {
        case 0, 3, 4, 6: palette = [0, 7]
        case 1, 5: palette = [0, 1, 3, 7]
        default: palette = Array(0..<8) + Array(0..<8)
        }
        textForeground = palette.count > 7 ? 7 : palette[palette.count - 1]
        graphicsColour = (0, palette.count - 1)
    }

    var hasGraphics: Bool { width > 0 }
    /// The cell colour byte: text foreground (low nibble), background (high nibble).
    var cellColour: UInt8 { UInt8(textForeground & 7) | UInt8(textBackground & 7) << 4 }

    func physical(_ logical: Int) -> Int { palette[logical % palette.count] }

    mutating func setPalette(logical: Int, physical: Int) {
        guard !palette.isEmpty else { return }
        palette[logical % palette.count] = physical & 7
    }

    func pixel(_ x: Int, _ y: Int) -> UInt8 {
        guard x >= 0, y >= 0, x < width, y < height else { return 0 }
        return pixels[y * width + x]
    }

    mutating func clear() {
        let background = UInt8(textBackground & 7)
        for i in pixels.indices { pixels[i] = background }
    }

    private func screenPoint(_ p: (Int, Int)) -> (Int, Int) {
        (p.0 * width / 1280, height - 1 - p.1 * height / 1024)
    }

    private mutating func set(_ x: Int, _ y: Int, how: Int) {
        guard x >= 0, y >= 0, x < width, y < height else { return }
        let i = y * width + x
        let colour = UInt8(physical(graphicsColour.colour))
        switch how {
        case 1:
            switch graphicsColour.mode {
            case 1: pixels[i] |= colour
            case 2: pixels[i] &= colour
            case 3: pixels[i] ^= colour
            case 4: pixels[i] ^= 7
            default: pixels[i] = colour
            }
        case 2: pixels[i] ^= 7
        case 3: pixels[i] = UInt8(textBackground & 7)
        default: break
        }
    }

    /// VDU 25: k's low two bits say how (0 move, 1 foreground, 2 invert, 3 background), bit 2
    /// absolute or relative, and k / 8 what: 0 line, 8 point, 10 filled triangle.
    mutating func plot(_ k: Int, x: Int, y: Int) {
        guard hasGraphics else { return }
        let absolute = k & 4 != 0
        let target = absolute ? (x, y) : (points[1].0 + x, points[1].1 + y)
        let how = k & 3
        let older = points[0], previous = points[1]
        points = [points[1], target]
        guard how != 0 else { return }
        let a = screenPoint(previous), b = screenPoint(target)
        switch k >> 3 {
        case 0: line(a, b, how: how)
        case 8: set(b.0, b.1, how: how)
        case 10:
            // The triangle made by the last three points (the two before and this one).
            fillTriangle(screenPoint(older), a, b, how: how)
        default: break
        }
    }

    private mutating func line(_ a: (Int, Int), _ b: (Int, Int), how: Int) {
        var x = a.0, y = a.1
        let dx = abs(b.0 - a.0), dy = -abs(b.1 - a.1)
        let sx = a.0 < b.0 ? 1 : -1, sy = a.1 < b.1 ? 1 : -1
        var err = dx + dy, steps = 0
        while steps <= 4000 {
            set(x, y, how: how)
            if x == b.0, y == b.1 { break }
            let e2 = 2 * err
            if e2 >= dy { err += dy; x += sx }
            if e2 <= dx { err += dx; y += sy }
            steps += 1
        }
    }

    private mutating func fillTriangle(_ p: (Int, Int), _ q: (Int, Int), _ r: (Int, Int), how: Int) {
        let minY = max(0, min(p.1, q.1, r.1)), maxY = min(height - 1, max(p.1, q.1, r.1))
        guard minY <= maxY else { return }
        let edges = [(p, q), (q, r), (r, p)]
        for y in minY...maxY {
            var xs: [Int] = []
            for (a, b) in edges where (a.1 <= y && b.1 >= y) || (b.1 <= y && a.1 >= y) {
                if a.1 == b.1 { xs += [a.0, b.0] } else { xs.append(a.0 + (y - a.1) * (b.0 - a.0) / (b.1 - a.1)) }
            }
            guard let lo = xs.min(), let hi = xs.max() else { continue }
            for x in max(0, lo)...min(width - 1, max(max(0, lo), hi)) { set(x, y, how: how) }
        }
    }

    func image() -> CGImage? {
        guard hasGraphics else { return nil }
        var data = [UInt8](repeating: 255, count: width * height * 4)
        for i in 0..<(width * height) {
            let c = Self.colours[Int(pixels[i] & 7)]
            data[i * 4] = c.r; data[i * 4 + 1] = c.g; data[i * 4 + 2] = c.b
        }
        guard let provider = CGDataProvider(data: Data(data) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
