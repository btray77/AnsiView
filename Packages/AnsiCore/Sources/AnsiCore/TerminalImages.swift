import CoreGraphics
import Foundation
import ImageIO

/// A picture a BBS sent inline (sixel or iTerm2), as RGBA pixels, with the cells it covers.
public struct TerminalImage: Equatable {
    public let width: Int
    public let height: Int
    /// Row major, 4 bytes per pixel, straight alpha.
    public let rgba: [UInt8]

    public init(width: Int, height: Int, rgba: [UInt8]) {
        self.width = width
        self.height = height
        self.rgba = rgba
    }

    public var cgImage: CGImage? {
        guard width > 0, height > 0, rgba.count == width * height * 4,
              let provider = CGDataProvider(data: Data(rgba) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

/// An image placed on the terminal: its top left cell (as an absolute line, counting the
/// scrollback) and the cells it covers.
public struct PlacedTerminalImage: Equatable {
    /// Unique on its terminal: a new picture in the same place is a new id.
    public let id: Int
    public let image: TerminalImage
    /// Line number counted from the first line ever kept in the scrollback.
    public var line: Int
    public let column: Int
    public let columns: Int
    public let rows: Int
}

/// Limits for pictures from a BBS, so a hostile stream cannot use unbounded memory.
public enum TerminalImageLimits {
    /// Largest control string kept while it arrives (an iTerm2 base64 payload or sixel data).
    public static let maxPayloadBytes = 8 * 1024 * 1024
    /// Largest side of a decoded picture, in pixels.
    public static let maxSide = 4096
    /// Most pixels in one picture (16 MB of RGBA).
    public static let maxPixels = 4 * 1024 * 1024
    /// Most pictures kept on one terminal.
    public static let maxImages = 256
    /// Most pixels of all pictures kept on one terminal (screen and scrollback).
    public static let maxTotalPixels = 12 * 1024 * 1024
}

/// DEC sixel graphics (VT340 style): `ESC P p1;p2;p3 q` data `ESC \`. Supports raster
/// attributes, colour registers in HLS and RGB, repeats, carriage return and next line.
public enum SixelDecoder {
    /// The VT340 default colour registers 0-15.
    static let defaultPalette: [(UInt8, UInt8, UInt8)] = [
        (0, 0, 0), (51, 51, 204), (204, 33, 33), (51, 204, 51), (204, 51, 204), (51, 204, 204), (204, 204, 51),
        (120, 120, 120), (69, 69, 69), (87, 87, 153), (153, 69, 69), (87, 153, 87), (153, 87, 153),
        (87, 153, 153), (153, 153, 87), (204, 204, 204),
    ]

    /// Decodes the bytes after `ESC P` up to (not including) the string terminator: the
    /// parameters, `q`, then the sixel data. Nil when nothing was drawn.
    public static func decode(_ body: [UInt8]) -> TerminalImage? {
        guard let q = body.firstIndex(of: UInt8(ascii: "q")),
              body[..<q].allSatisfy({ (0x30...0x39).contains($0) || $0 == 0x3B }) else { return nil }
        let params = String(decoding: body[..<q], as: UTF8.self).split(separator: ";", omittingEmptySubsequences: false)
        // P2 = 1: pixels not drawn stay transparent; otherwise they take colour 0.
        let transparent = params.count > 1 && params[1] == "1"
        var palette = defaultPalette + Array(repeating: (UInt8(0), UInt8(0), UInt8(0)), count: 240)
        var width = 0, height = 0
        var indexes: [Int16] = []   // -1 not drawn
        var stride = 0, capacityRows = 0
        var x = 0, band = 0, color = 0
        var declared: (Int, Int)?

        func grow(toWidth w: Int, height h: Int) -> Bool {
            let nw = max(width, w), nh = max(height, h)
            guard nw <= TerminalImageLimits.maxSide, nh <= TerminalImageLimits.maxSide,
                  nw * nh <= TerminalImageLimits.maxPixels else { return false }
            // Storage grows geometrically so a wide picture is not copied once per column.
            if nw > stride || nh > capacityRows {
                let cw = nw > stride ? min(TerminalImageLimits.maxSide, max(nw, stride * 2, 64)) : stride
                var ch = nh > capacityRows ? min(TerminalImageLimits.maxSide, max(nh, capacityRows * 2, 64)) : capacityRows
                while cw * ch > TerminalImageLimits.maxPixels * 2, ch > nh { ch = max(nh, ch / 2) }
                var fresh = [Int16](repeating: -1, count: cw * ch)
                for row in 0..<height { for col in 0..<width { fresh[row * cw + col] = indexes[row * stride + col] } }
                indexes = fresh
                stride = cw; capacityRows = ch
            }
            width = nw; height = nh
            return true
        }

        var i = q + 1
        func number() -> Int? {
            var value: Int?
            while i < body.count, (0x30...0x39).contains(body[i]) {
                value = min(100_000, (value ?? 0) * 10 + Int(body[i] - 0x30))
                i += 1
            }
            return value
        }
        func numbers() -> [Int] {
            var out: [Int] = [number() ?? 0]
            while i < body.count, body[i] == 0x3B, out.count < 8 { i += 1; out.append(number() ?? 0) }
            return out
        }
        // Repeats can ask for far more writes than pixels; the total is bounded too.
        var written = 0
        func draw(_ bits: UInt8, count: Int) {
            let n = min(count, TerminalImageLimits.maxSide - x)
            guard n > 0, written < TerminalImageLimits.maxPixels * 4 else { return }
            written += n * 6
            let top = band * 6
            guard grow(toWidth: x + n, height: top + 6) else { x += n; return }
            if bits != 0 {
                for bit in 0..<6 where bits & (1 << bit) != 0 {
                    let rowStart = (top + bit) * stride
                    for col in x..<(x + n) { indexes[rowStart + col] = Int16(color) }
                }
            }
            x += n
        }
        while i < body.count {
            let b = body[i]
            switch b {
            case UInt8(ascii: "\""):
                i += 1
                let v = numbers()
                if v.count >= 4, v[2] > 0, v[3] > 0 { declared = (v[2], v[3]) }
            case UInt8(ascii: "#"):
                i += 1
                let v = numbers()
                let register = max(0, min(255, v[0]))
                if v.count >= 5 {
                    if v[1] == 1 {
                        palette[register] = hls(v[2], v[3], v[4])
                    } else if v[1] == 2 {
                        func pct(_ p: Int) -> UInt8 { UInt8(min(100, max(0, p)) * 255 / 100) }
                        palette[register] = (pct(v[2]), pct(v[3]), pct(v[4]))
                    }
                }
                color = register
            case UInt8(ascii: "!"):
                i += 1
                let n = max(1, number() ?? 1)
                if i < body.count, (0x3F...0x7E).contains(body[i]) {
                    draw(body[i] - 0x3F, count: n)
                    i += 1
                }
            case UInt8(ascii: "$"): x = 0; i += 1
            case UInt8(ascii: "-"):
                x = 0; i += 1
                band += 1
                if band * 6 >= TerminalImageLimits.maxSide { i = body.count }
            case 0x3F...0x7E:
                draw(b - 0x3F, count: 1)
                i += 1
            default: i += 1
            }
        }
        if let declared, !transparent, declared.0 <= TerminalImageLimits.maxSide, declared.1 <= TerminalImageLimits.maxSide,
           declared.0 * declared.1 <= TerminalImageLimits.maxPixels {
            _ = grow(toWidth: declared.0, height: declared.1)
        }
        guard width > 0, height > 0 else { return nil }
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for p in 0..<(width * height) {
            let index = Int(indexes[(p / width) * stride + p % width])
            if index < 0 {
                if transparent { continue }
                let c = palette[0]
                rgba[p * 4] = c.0; rgba[p * 4 + 1] = c.1; rgba[p * 4 + 2] = c.2; rgba[p * 4 + 3] = 255
            } else {
                let c = palette[index]
                rgba[p * 4] = c.0; rgba[p * 4 + 1] = c.1; rgba[p * 4 + 2] = c.2; rgba[p * 4 + 3] = 255
            }
        }
        return TerminalImage(width: width, height: height, rgba: rgba)
    }

    /// DEC HLS: hue 0 is blue, 120 red, 240 green; lightness and saturation 0-100.
    static func hls(_ h: Int, _ l: Int, _ s: Int) -> (UInt8, UInt8, UInt8) {
        let hue = Double(((h % 360) + 360 + 240) % 360) / 360
        let light = Double(min(100, max(0, l))) / 100, sat = Double(min(100, max(0, s))) / 100
        func channel(_ t0: Double) -> UInt8 {
            var t = t0
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            let q = light < 0.5 ? light * (1 + sat) : light + sat - light * sat
            let p = 2 * light - q
            let v: Double
            if t < 1.0 / 6 { v = p + (q - p) * 6 * t } else if t < 0.5 { v = q } else if t < 2.0 / 3 { v = p + (q - p) * (2.0 / 3 - t) * 6 } else { v = p }
            return UInt8((v * 255).rounded())
        }
        return (channel(hue + 1.0 / 3), channel(hue), channel(hue - 1.0 / 3))
    }
}

/// iTerm2 inline images: `ESC ] 1337 ; File = key=value;... : base64 BEL` (or ST).
public enum ITerm2Image {
    /// How big the picture should be shown, in cells.
    public enum Size: Equatable { case auto, cells(Int), pixels(Int), percent(Int) }

    public struct Request: Equatable {
        public var inline = false
        public var width = Size.auto
        public var height = Size.auto
        public var preserveAspect = true
        public var data: [UInt8] = []
    }

    /// Parses the bytes after `ESC ]` (up to the terminator). Nil when it is not a File command.
    public static func parse(_ body: [UInt8]) -> Request? {
        let prefix = Array("1337;File=".utf8)
        guard body.starts(with: prefix), let colon = body.firstIndex(of: UInt8(ascii: ":")) else { return nil }
        var request = Request()
        let args = String(decoding: body[prefix.count..<colon], as: UTF8.self)
        for pair in args.split(separator: ";") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { continue }
            switch kv[0] {
            case "inline": request.inline = kv[1] == "1"
            case "width": request.width = size(kv[1])
            case "height": request.height = size(kv[1])
            case "preserveAspectRatio": request.preserveAspect = kv[1] != "0"
            default: break
            }
        }
        let base64 = body[(colon + 1)...].filter { $0 > 0x20 }
        guard let data = Data(base64Encoded: Data(base64), options: .ignoreUnknownCharacters) else { return request }
        request.data = [UInt8](data)
        return request
    }

    static func size(_ text: String) -> Size {
        if text == "auto" { return .auto }
        if text.hasSuffix("px"), let v = Int(text.dropLast(2)) { return .pixels(max(1, min(TerminalImageLimits.maxSide, v))) }
        if text.hasSuffix("%"), let v = Int(text.dropLast()) { return .percent(max(1, min(100, v))) }
        if let v = Int(text) { return .cells(max(1, min(1000, v))) }
        return .auto
    }

    /// Decodes PNG, JPEG, GIF (first frame) and the other ImageIO formats, refusing pictures over
    /// the limits before decoding them.
    public static func decode(_ data: [UInt8]) -> TerminalImage? {
        guard !data.isEmpty, let source = CGImageSourceCreateWithData(Data(data) as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0, w <= TerminalImageLimits.maxSide, h <= TerminalImageLimits.maxSide,
              w * h <= TerminalImageLimits.maxPixels,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let drawn: Bool = rgba.withUnsafeMutableBytes { raw in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        // Back to straight alpha.
        for p in 0..<(w * h) {
            let a = Int(rgba[p * 4 + 3])
            guard a > 0, a < 255 else { continue }
            for c in 0..<3 { rgba[p * 4 + c] = UInt8(min(255, Int(rgba[p * 4 + c]) * 255 / a)) }
        }
        return TerminalImage(width: w, height: h, rgba: rgba)
    }
}
