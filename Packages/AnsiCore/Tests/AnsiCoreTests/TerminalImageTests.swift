import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import AnsiCore

private func px(_ image: TerminalImage, _ x: Int, _ y: Int) -> [UInt8] {
    let i = (y * image.width + x) * 4
    return Array(image.rgba[i..<(i + 4)])
}

private func png(width: Int, height: Int, rgb: (UInt8, UInt8, UInt8)) -> [UInt8] {
    var pixels = [UInt8](repeating: 255, count: width * height * 4)
    for p in 0..<(width * height) { pixels[p * 4] = rgb.0; pixels[p * 4 + 1] = rgb.1; pixels[p * 4 + 2] = rgb.2 }
    let image = TerminalImage(width: width, height: height, rgba: pixels).cgImage!
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    return [UInt8](data as Data)
}

// MARK: Sixel

@Test func sixelDrawsColouredBands() throws {
    let image = try #require(SixelDecoder.decode(Array("q#1;2;100;0;0~~-#2;2;0;100;0!3~".utf8)))
    #expect(image.width == 3 && image.height == 12)
    #expect(px(image, 0, 0) == [255, 0, 0, 255])
    #expect(px(image, 1, 5) == [255, 0, 0, 255])
    #expect(px(image, 2, 0) == [0, 0, 0, 255])       // not drawn: colour 0 (P2 is 0)
    #expect(px(image, 2, 6) == [0, 255, 0, 255])
}

@Test func sixelTransparentBackground() throws {
    let image = try #require(SixelDecoder.decode(Array("0;1;0q#1;2;100;100;100@".utf8)))
    #expect(px(image, 0, 0) == [255, 255, 255, 255])
    #expect(px(image, 0, 1)[3] == 0)
}

@Test func sixelRasterAttributesAndLimits() throws {
    let sized = try #require(SixelDecoder.decode(Array("q\"1;1;5;3#1~".utf8)))
    #expect(sized.width == 5 && sized.height == 6)
    let huge = try #require(SixelDecoder.decode(Array("q\"1;1;99999;99999#1~".utf8)))
    #expect(huge.width == 1 && huge.height == 6)
    let repeated = try #require(SixelDecoder.decode(Array("q#1!99999~".utf8)))
    #expect(repeated.width == TerminalImageLimits.maxSide)
    #expect(SixelDecoder.decode(Array("1;2;3".utf8)) == nil)
    #expect(SixelDecoder.decode(Array("qABC".utf8)).map { $0.width } == 3)
}

@Test func sixelHLSColours() {
    #expect(SixelDecoder.hls(0, 50, 100) == (0, 0, 255))
    #expect(SixelDecoder.hls(120, 50, 100) == (255, 0, 0))
    #expect(SixelDecoder.hls(240, 50, 100) == (0, 255, 0))
}

@Test func sixelFuzzStaysBounded() {
    var seed: UInt64 = 0x51CE1
    func next() -> UInt8 { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return UInt8(truncatingIfNeeded: seed >> 33) }
    let alphabet = Array("0123456789;#!\"$-~?@ABCabc".utf8)
    for round in 0..<10 {
        var body = Array("q".utf8)
        body += (0..<5_000).map { _ in round % 2 == 0 ? alphabet[Int(next()) % alphabet.count] : next() }
        if let image = SixelDecoder.decode(body) {
            #expect(image.width <= TerminalImageLimits.maxSide && image.height <= TerminalImageLimits.maxSide)
            #expect(image.width * image.height <= TerminalImageLimits.maxPixels)
            #expect(image.rgba.count == image.width * image.height * 4)
        }
    }
}

// MARK: iTerm2

@Test func iterm2RequestParses() throws {
    let data = png(width: 2, height: 2, rgb: (0, 0, 255))
    let body = Array("1337;File=name=eA==;size=\(data.count);inline=1;width=10;height=auto:".utf8) + Array(Data(data).base64EncodedData())
    let request = try #require(ITerm2Image.parse(body))
    #expect(request.inline && request.width == .cells(10) && request.height == .auto)
    let image = try #require(ITerm2Image.decode(request.data))
    #expect(image.width == 2 && image.height == 2)
    #expect(px(image, 1, 1) == [0, 0, 255, 255])
    #expect(ITerm2Image.parse(Array("0;title".utf8)) == nil)
    #expect(ITerm2Image.size("50%") == .percent(50) && ITerm2Image.size("40px") == .pixels(40))
}

@Test func iterm2RefusesHugeAndBrokenImages() {
    #expect(ITerm2Image.decode(png(width: 5000, height: 1, rgb: (1, 2, 3))) == nil)
    #expect(ITerm2Image.decode(Array("not an image".utf8)) == nil)
    #expect(ITerm2Image.decode([]) == nil)
}

@Test func iterm2FuzzNeverCrashes() {
    var seed: UInt64 = 0x17E2
    func next() -> UInt8 { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return UInt8(truncatingIfNeeded: seed >> 33) }
    var data = png(width: 8, height: 8, rgb: (9, 9, 9))
    for _ in 0..<200 {
        let i = Int(next()) % data.count
        data[i] = next()
        if let image = ITerm2Image.decode(data) { #expect(image.width <= TerminalImageLimits.maxSide) }
    }
}

// MARK: Terminal placement

@Test func sixelInTheTerminalIsPlacedAndMovesTheCursor() {
    var t = TerminalEmulator(columns: 80, rows: 25)
    t.feed(Array("AB\u{1B}Pq#1;2;100;0;0!16~-!16~-!16~\u{1B}\\".utf8))
    let images = t.images(scrollOffset: 0)
    #expect(images.count == 1)
    #expect(images.first?.line == 0 && images.first?.column == 2)
    #expect(images.first?.columns == 2 && images.first?.rows == 2)   // 16x18 pixels in 8x16 cells
    #expect(t.cursor.row == 2 && t.cursor.column == 0)
    // The sixel data is not shown as text.
    #expect(String(decoding: t.screen(scrollOffset: 0).rows[0].prefix(4).map(\.code), as: UTF8.self) == "AB  ")
}

@Test func iterm2InTheTerminalSizedInCells() {
    var t = TerminalEmulator(columns: 80, rows: 25)
    let data = png(width: 20, height: 10, rgb: (255, 0, 0))
    t.feed(Array("\u{1B}]1337;File=inline=1;width=10:".utf8) + Array(Data(data).base64EncodedData()) + [0x07])
    let image = t.images(scrollOffset: 0).first
    #expect(image?.columns == 10 && image?.rows == 3)   // 80x40 pixels at 8x16: 2.5 rows, rounded up
    #expect(t.cursor.row == 3)
}

@Test func imagesScrollWithTheTextAndClearWithTheScreen() {
    var t = TerminalEmulator(columns: 80, rows: 25)
    t.feed(Array("\u{1B}Pq#1~\u{1B}\\".utf8))
    t.feed(Array(String(repeating: "\r\n", count: 30).utf8))
    #expect(t.images(scrollOffset: 0).isEmpty)   // scrolled out of view: 7 lines up
    #expect(t.images(scrollOffset: 7).first?.line == 0)
    t.feed(Array("\u{1B}Pq#1~\u{1B}\\\u{1B}[2J".utf8))
    #expect(t.images(scrollOffset: 0).filter { $0.line >= 0 }.isEmpty)
    #expect(t.images(scrollOffset: 8).count == 1)
}

@Test func imageMemoryIsBounded() {
    var t = TerminalEmulator(columns: 80, rows: 25)
    let row = "#1!2000~"
    let body = "q\"1;1;2000;1800" + String(repeating: row + "-", count: 300)
    for _ in 0..<6 { t.feed(Array(("\u{1B}P" + body + "\u{1B}\\").utf8)) }
    let total = t.images(scrollOffset: 0).reduce(0) { $0 + $1.image.width * $1.image.height }
    #expect(total <= TerminalImageLimits.maxTotalPixels)
    #expect(!t.images(scrollOffset: 0).isEmpty)
}

@Test func oversizedPayloadIsDropped() {
    var t = TerminalEmulator(columns: 80, rows: 25)
    t.feed(Array("\u{1B}Pq".utf8))
    let chunk = [UInt8](repeating: UInt8(ascii: "~"), count: 1 << 20)
    for _ in 0..<9 { t.feed(chunk) }
    t.feed(Array("\u{1B}\\X".utf8))
    #expect(t.images(scrollOffset: 0).isEmpty)
    #expect(t.screen(scrollOffset: 0).rows[0][0].code == UInt8(ascii: "X"))
}

@Test func avatarAndRIPEnginesShowPictures() {
    var a = AvatarTerminal(columns: 80, rows: 25)
    a.feed(Array("\u{1B}Pq#1~\u{1B}\\".utf8))
    #expect(a.images(scrollOffset: 0).count == 1)
    var r = RIPTerminal()
    r.feed(Array("\u{1B}Pq#1~\u{1B}\\".utf8))
    #expect(r.images(scrollOffset: 0).count == 1)
}
