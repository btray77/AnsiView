import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import AnsiCore

private func screen(_ rows: [[AnsiCell]]) -> AnsiScreen { AnsiScreen(columns: rows[0].count, rows: rows) }

/// RGBA bytes of an image, top row first.
private func rgba(_ image: CGImage) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    bytes.withUnsafeMutableBytes { raw in
        let context = CGContext(data: raw.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    return bytes
}

private func expand(_ image: IndexedImage, _ palette: [RGB]) -> [UInt8] {
    image.pixels.flatMap { [palette[Int($0)].r, palette[Int($0)].g, palette[Int($0)].b, 255] }
}

private let sampleRows: [[AnsiCell]] = [
    [AnsiCell(code: 0x41, fg: Palette.vga[12], bg: Palette.vga[1]), AnsiCell(code: 0xDB, fg: Palette.vga[14]),
     AnsiCell(code: 0xB1, fg: Palette.vga[2], bg: Palette.vga[5])],
]

@Test func vgaArtGetsSixteenColours() {
    #expect(GIFColors.palette(for: [screen(sampleRows)], mode: .automatic) == Palette.vga)
    #expect(GIFColors.palette(for: [screen(sampleRows)], mode: .system) == nil)
}

@Test func exactPaletteForFewRGBColours() {
    let odd = RGB(r: 1, g: 2, b: 3)
    let palette = GIFColors.palette(for: [screen([[AnsiCell(code: 0x41, fg: odd)]])], mode: .automatic)
    #expect(palette?.contains(odd) == true)
    #expect(palette?.contains(Palette.vga[0]) == true)
    #expect((palette?.count ?? 0) <= 255)
}

@Test func vga16MapsToNearest() {
    let s = screen([[AnsiCell(code: 0xDB, fg: RGB(r: 250, g: 80, b: 90))]])
    let palette = GIFColors.palette(for: [s], mode: .vga16)!
    #expect(palette == Palette.vga)
    let image = AnsiRenderer.renderIndexed(s, options: RenderOptions(scale: 1), palette: palette)!
    #expect(image.pixels.contains(12)) // bright red
}

@Test func tooManyColoursHasNoPalette() {
    let cells = (0..<300).map { AnsiCell(code: 0xDB, fg: RGB(r: UInt8($0 % 256), g: UInt8($0 / 256), b: 7)) }
    #expect(GIFColors.palette(for: [screen([cells])], mode: .automatic) == nil)
    #expect(GIFColors.palette(for: [screen([cells])], mode: .vga16) == Palette.vga)
}

@Test func indexedRenderMatchesRGB() {
    let s = screen(sampleRows)
    let options = RenderOptions(scale: 2)
    let image = AnsiRenderer.renderIndexed(s, options: options, palette: Palette.vga)!
    let rendered = AnsiRenderer.render(s, options: options)!.image
    #expect(image.width == rendered.width && image.height == rendered.height)
    #expect(expand(image, Palette.vga) == rgba(rendered))
}

@Test func encodedGIFDecodes() throws {
    let base = screen(sampleRows)
    var second = base
    second.rows[0][0].code = 0x42
    var third = second
    third.rows[0][2].bg = Palette.vga[15]
    let frames = [base, second, third].map {
        AnsiRenderer.renderIndexed($0, options: RenderOptions(scale: 1), palette: Palette.vga)!
    }
    var encoder = GIFEncoder(width: frames[0].width, height: frames[0].height, palette: Palette.vga)
    for frame in frames { encoder.add(frame, delayHundredths: 10) }
    let data = encoder.finish()
    let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    #expect(CGImageSourceGetCount(source) == 3)
    for (index, frame) in frames.enumerated() {
        let image = try #require(CGImageSourceCreateImageAtIndex(source, index, nil))
        #expect(rgba(image) == expand(frame, Palette.vga), "frame \(index)")
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        #expect((gif?[kCGImagePropertyGIFDelayTime] as? Double) == 0.1)
    }
}

@Test func identicalFramesMerge() throws {
    let frame = AnsiRenderer.renderIndexed(screen(sampleRows), options: RenderOptions(scale: 1), palette: Palette.vga)!
    var encoder = GIFEncoder(width: frame.width, height: frame.height, palette: Palette.vga)
    encoder.add(frame, delayHundredths: 10)
    encoder.add(frame, delayHundredths: 25)
    let source = try #require(CGImageSourceCreateWithData(encoder.finish() as CFData, nil))
    #expect(CGImageSourceGetCount(source) == 1)
    let gif = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
    #expect((gif?[kCGImagePropertyGIFDelayTime] as? Double) == 0.35)
}

@Test func largeNoisyFrameDecodes() throws {
    // Enough distinct runs to fill the 4096 entry LZW table several times.
    var rows: [[AnsiCell]] = []
    var seed: UInt32 = 1
    for _ in 0..<25 {
        rows.append((0..<80).map { _ in
            seed = seed &* 1_103_515_245 &+ 12345
            return AnsiCell(code: UInt8(seed >> 16 & 0xFF), fg: Palette.vga[Int(seed >> 8 & 15)], bg: Palette.vga[Int(seed >> 24 & 15)])
        })
    }
    let frame = AnsiRenderer.renderIndexed(screen(rows), options: RenderOptions(scale: 2), palette: Palette.vga)!
    var encoder = GIFEncoder(width: frame.width, height: frame.height, palette: Palette.vga)
    encoder.add(frame, delayHundredths: 5)
    let source = try #require(CGImageSourceCreateWithData(encoder.finish() as CFData, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    #expect(rgba(image) == expand(frame, Palette.vga))
}

@Test func smallChangesMakeSmallFrames() {
    let rows = Array(repeating: (0..<80).map { AnsiCell(code: UInt8(0x41 + $0 % 26), fg: Palette.vga[$0 % 16]) }, count: 25)
    let first = AnsiRenderer.renderIndexed(screen(rows), options: RenderOptions(scale: 1), palette: Palette.vga)!
    var changed = rows
    changed[10][40].code = 0xDB
    let second = AnsiRenderer.renderIndexed(screen(changed), options: RenderOptions(scale: 1), palette: Palette.vga)!
    var one = GIFEncoder(width: first.width, height: first.height, palette: Palette.vga)
    one.add(first, delayHundredths: 10)
    var two = GIFEncoder(width: first.width, height: first.height, palette: Palette.vga)
    two.add(first, delayHundredths: 10)
    two.add(second, delayHundredths: 10)
    let single = one.finish().count, double = two.finish().count
    #expect(double - single < 200)
}

@Test func transparentFramesDecode() throws {
    // Two far apart changes give a frame rectangle that is mostly unchanged: the transparent
    // encoding is chosen and must still decode to the new frame.
    var rows: [[AnsiCell]] = []
    var seed: UInt32 = 7
    for _ in 0..<25 {
        var row: [AnsiCell] = []
        for _ in 0..<80 {
            seed = seed &* 1_103_515_245 &+ 12345
            row.append(AnsiCell(code: UInt8(seed >> 16 & 0xFF), fg: Palette.vga[Int(seed >> 8 & 15)]))
        }
        rows.append(row)
    }
    var changed = rows
    changed[0][0].code = 0xDB
    changed[24][79].code = 0xDB
    let a = AnsiRenderer.renderIndexed(screen(rows), options: RenderOptions(scale: 1), palette: Palette.vga)!
    let b = AnsiRenderer.renderIndexed(screen(changed), options: RenderOptions(scale: 1), palette: Palette.vga)!
    var encoder = GIFEncoder(width: a.width, height: a.height, palette: Palette.vga)
    encoder.add(a, delayHundredths: 10)
    encoder.add(b, delayHundredths: 10)
    let data = encoder.finish()
    let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 1, nil))
    #expect(rgba(image) == expand(b, Palette.vga))
    // The second frame's graphic control block sets the transparency flag.
    let bytes = [UInt8](data)
    var controls: [Int] = []
    for i in 0..<(bytes.count - 3) where bytes[i] == 0x21 && bytes[i + 1] == 0xF9 && bytes[i + 2] == 0x04 {
        controls.append(i)
    }
    #expect(controls.count == 2)
    #expect(bytes[controls[1] + 3] & 1 == 1)
}

@Test func fullByteAlphabetDecodes() throws {
    // 255 colours: 8 bit LZW codes, noise that fills the 4096 entry table many times.
    let palette = (0..<255).map { RGB(r: UInt8($0), g: UInt8(255 - $0), b: UInt8($0 / 2)) }
    var seed: UInt32 = 3
    var pixels: [UInt8] = []
    for _ in 0..<(300 * 200) {
        seed = seed &* 1_103_515_245 &+ 12345
        pixels.append(UInt8(seed >> 16 % 255))
    }
    let frame = IndexedImage(width: 300, height: 200, pixels: pixels.map { $0 % 255 })
    var next = frame
    next.pixels[12345] = (next.pixels[12345] + 1) % 255
    var encoder = GIFEncoder(width: 300, height: 200, palette: palette)
    encoder.add(frame, delayHundredths: 10)
    encoder.add(next, delayHundredths: 10)
    let source = try #require(CGImageSourceCreateWithData(encoder.finish() as CFData, nil))
    #expect(rgba(try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))) == expand(frame, palette))
    #expect(rgba(try #require(CGImageSourceCreateImageAtIndex(source, 1, nil))) == expand(next, palette))
}
