import Foundation
import Testing
@testable import AnsiCore

/// A small sixel decoder for the tests: palette registers and the indexed pixels.
private func decodeSixel(_ text: String) -> (width: Int, height: Int, palette: [Int: RGB], pixels: [Int: UInt8])? {
    let scalars = Array(text.unicodeScalars)
    guard let q = scalars.firstIndex(of: "q") else { return nil }
    var i = q + 1
    var width = 0, height = 0
    var palette: [Int: RGB] = [:]
    var pixels: [Int: UInt8] = [:]
    var x = 0, band = 0, color = 0
    func number() -> Int {
        var value = 0
        while i < scalars.count, let digit = Int(String(scalars[i])) { value = value * 10 + digit; i += 1 }
        return value
    }
    func numbers() -> [Int] {
        var list = [number()]
        while i < scalars.count, scalars[i] == ";" { i += 1; list.append(number()) }
        return list
    }
    while i < scalars.count {
        let c = scalars[i]
        if c == "\u{1B}" { break }
        i += 1
        switch c {
        case "\"":
            let raster = numbers()
            width = raster[2]; height = raster[3]
        case "#":
            let parts = numbers()
            color = parts[0]
            if parts.count == 5 {
                func level(_ percent: Int) -> UInt8 { UInt8((Double(percent) * 255 / 100).rounded()) }
                palette[color] = RGB(r: level(parts[2]), g: level(parts[3]), b: level(parts[4]))
            }
        case "$": x = 0
        case "-": x = 0; band += 1
        case "!":
            let count = number()
            let bits = Int(scalars[i].value) - 63
            i += 1
            for _ in 0..<count { paint(bits) }
        default:
            let value = Int(c.value)
            if (63...126).contains(value) { paint(value - 63) }
        }
    }
    func paint(_ bits: Int) {
        for row in 0..<6 where bits & (1 << row) != 0 {
            pixels[(band * 6 + row) * 100_000 + x] = UInt8(color)
        }
        x += 1
    }
    return (width, height, palette, pixels)
}

@Suite struct TerminalGraphicsTests {
    static func checker(width: Int, height: Int) -> IndexedImage {
        var pixels: [UInt8] = []
        for y in 0..<height { for x in 0..<width { pixels.append(UInt8((x / 2 + y) % 2)) } }
        return IndexedImage(width: width, height: height, pixels: pixels)
    }

    @Test func sixelHeaderAndTerminator() {
        let text = TerminalGraphics.sixel(Self.checker(width: 4, height: 3), palette: [Palette.vga[0], Palette.vga[15]])
        #expect(text.hasPrefix("\u{1B}P0;1;0q\"1;1;4;3"))
        #expect(text.hasSuffix("\u{1B}\\"))
        #expect(text.contains("#1;2;100;100;100"))
        #expect(text.contains("#0;2;0;0;0"))
    }

    @Test func sixelRoundTrips() throws {
        let image = Self.checker(width: 9, height: 7)
        let palette = [Palette.vga[1], Palette.vga[14]]
        let decoded = try #require(decodeSixel(TerminalGraphics.sixel(image, palette: palette)))
        #expect(decoded.width == 9 && decoded.height == 7)
        // Registers hold whole percents, so 0xAA comes back as 171.
        #expect(decoded.palette[0] == RGB(r: 0, g: 0, b: 171) && decoded.palette[1] == RGB(r: 255, g: 255, b: 84))
        for y in 0..<7 { for x in 0..<9 {
            #expect(decoded.pixels[y * 100_000 + x] == image.pixels[y * 9 + x], "pixel \(x),\(y)")
        } }
    }

    @Test func renderedScreenRoundTrips() throws {
        var row = Array(repeating: AnsiCell(), count: 4)
        row[0] = AnsiCell(code: 0xDB, fg: Palette.vga[12])
        row[1] = AnsiCell(code: 0x41, fg: Palette.vga[14], bg: Palette.vga[1])
        row[3] = AnsiCell(code: 0xB1, fg: RGB(r: 10, g: 200, b: 30), bg: Palette.vga[5])
        let screen = AnsiScreen(columns: 4, rows: [row, row])
        let output = try #require(TerminalGraphics.sixelImage(screen, scale: 1))
        let decoded = try #require(decodeSixel(TerminalGraphics.sixel(output.image, palette: output.palette)))
        #expect(decoded.width == 32 && decoded.height == 32)
        var same = 0
        for y in 0..<32 { for x in 0..<32 where decoded.pixels[y * 100_000 + x] == output.image.pixels[y * 32 + x] { same += 1 } }
        #expect(same == 32 * 32)
        // The art's own colours, to the 1 percent steps sixel colour registers have.
        for color in [Palette.vga[12], Palette.vga[1], RGB(r: 10, g: 200, b: 30)] {
            #expect(decoded.palette.values.contains { TextConvert.squaredDistance($0, color) <= 3 * 2 * 2 }, "\(color)")
        }
        // Only colours in the picture get a register.
        #expect(decoded.palette.count == Set(output.image.pixels).count)
    }

    @Test func sixelRunLength() {
        let wide = IndexedImage(width: 40, height: 6, pixels: [UInt8](repeating: 1, count: 240))
        let text = TerminalGraphics.sixel(wide, palette: [Palette.vga[0], Palette.vga[15]])
        #expect(text.contains("!40~"))
        #expect(text.count < 80)
    }

    @Test func kittyChunksAre4096() {
        let png = Data((0..<10_000).map { UInt8($0 % 251) })
        let text = TerminalGraphics.kitty(png: png)
        let chunks = text.components(separatedBy: "\u{1B}\\").filter { !$0.isEmpty }
        #expect(chunks.count == 4)  // 13,336 base64 characters
        #expect(chunks[0].hasPrefix("\u{1B}_Ga=T,f=100,m=1;"))
        #expect(chunks[1].hasPrefix("\u{1B}_Gm=1;"))
        #expect(chunks[3].hasPrefix("\u{1B}_Gm=0;"))
        for chunk in chunks { #expect(chunk.split(separator: ";", maxSplits: 1)[1].count <= 4096) }
    }

    @Test func kittyDecodesToTheSameBytes() {
        let png = Data((0..<5000).map { UInt8($0 % 256) })
        let text = TerminalGraphics.kitty(png: png)
        let payload = text.components(separatedBy: "\u{1B}\\").filter { !$0.isEmpty }
            .map { String($0.split(separator: ";", maxSplits: 1)[1]) }.joined()
        #expect(Data(base64Encoded: payload) == png)
    }

    @Test func kittyChunksAreWholeBase64Quads() {
        // The protocol needs every chunk but the last to be a multiple of 4 characters.
        let text = TerminalGraphics.kitty(png: Data((0..<3000).map { UInt8($0 % 256) }), chunkSize: 1001)
        let chunks = text.components(separatedBy: "\u{1B}\\").filter { !$0.isEmpty }
        for chunk in chunks.dropLast() { #expect(chunk.split(separator: ";", maxSplits: 1)[1].count % 4 == 0) }
    }

    @Test func kittySingleChunk() {
        let text = TerminalGraphics.kitty(png: Data([1, 2, 3]))
        #expect(text == "\u{1B}_Ga=T,f=100,m=0;AQID\u{1B}\\")
    }
}
