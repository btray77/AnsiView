import Foundation

/// Pictures for modern terminals (plan 10 ruling 12): DEC sixel and the kitty graphics protocol.
public enum TerminalGraphics {
    /// The finished art drawn with its own colours (at most 256; more fall to the nearest) for sixel.
    public static func sixelImage(_ screen: AnsiScreen, scale: Int) -> (image: IndexedImage, palette: [RGB])? {
        let palette = GIFColors.palette(for: [screen], mode: .automatic) ?? Palette.xterm256
        let options = RenderOptions(for: screen, scale: max(1, scale))
        guard let image = AnsiRenderer.renderIndexed(screen, options: options, palette: palette) else { return nil }
        return (image, palette)
    }

    /// A sixel picture: `ESC P 0;1;0 q`, square pixels at the image's size, a colour register for
    /// each colour used (`#n;2;r;g;b` in percent), six pixel bands with `!n` runs, then `ESC \`.
    public static func sixel(_ image: IndexedImage, palette: [RGB]) -> String {
        var out = "\u{1B}P0;1;0q\"1;1;\(image.width);\(image.height)"
        let used = Set(image.pixels).sorted()
        for index in used {
            let color = Int(index) < palette.count ? palette[Int(index)] : RGB(r: 0, g: 0, b: 0)
            func percent(_ v: UInt8) -> Int { Int((Double(v) * 100 / 255).rounded()) }
            out += "#\(index);2;\(percent(color.r));\(percent(color.g));\(percent(color.b))"
        }
        let width = image.width
        var band = 0
        while band * 6 < image.height {
            let top = band * 6
            let rows = min(6, image.height - top)
            // Which colours appear in this band, and each one's six bit column values.
            var columns: [UInt8: [UInt8]] = [:]
            for row in 0..<rows {
                let start = (top + row) * width
                for x in 0..<width {
                    let index = image.pixels[start + x]
                    if columns[index] == nil { columns[index] = [UInt8](repeating: 0, count: width) }
                    columns[index]![x] |= 1 << row
                }
            }
            var first = true
            for index in columns.keys.sorted() {
                if !first { out += "$" }
                first = false
                out += "#\(index)"
                var bits = columns[index]!
                while bits.last == 0 { bits.removeLast() }
                out += runs(bits)
            }
            band += 1
            if band * 6 < image.height { out += "-" }
        }
        return out + "\u{1B}\\"
    }

    /// A PNG for the kitty graphics protocol: transmit and display (`a=T,f=100`), base64 in chunks
    /// of at most `chunkSize` characters, `m=1` on every chunk but the last.
    public static func kitty(png: Data, chunkSize: Int = 4096) -> String {
        let payload = Array(png.base64EncodedString().utf8)
        var out = ""
        var start = 0
        repeat {
            let end = min(payload.count, start + chunkSize)
            let more = end < payload.count ? 1 : 0
            let keys = start == 0 ? "a=T,f=100,m=\(more)" : "m=\(more)"
            out += "\u{1B}_G\(keys);" + String(decoding: payload[start..<end], as: UTF8.self) + "\u{1B}\\"
            start = end
        } while start < payload.count
        return out
    }

    // MARK: Helpers

    /// Sixel characters for column values, with `!n` for runs of four or more.
    private static func runs(_ bits: [UInt8]) -> String {
        var out = ""
        var i = 0
        while i < bits.count {
            var j = i
            while j < bits.count, bits[j] == bits[i] { j += 1 }
            let character = String(UnicodeScalar(63 + bits[i]))
            let count = j - i
            out += count >= 4 ? "!\(count)\(character)" : String(repeating: character, count: count)
            i = j
        }
        return out
    }
}
