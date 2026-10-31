import CoreGraphics
import Foundation
import Testing
@testable import AnsiCore

private let ripBar = Array("!|*|S010C|B00000A0A\r\n!|c0E|L00140A14\r\nHI".utf8)

@Test func ripFilesAreDetected() {
    #expect(ArtFormat.detect(bytes: ripBar, fileExtension: "rip", sauce: nil) == .rip)
    #expect(ArtFormat.detect(bytes: ripBar, fileExtension: "RIP", sauce: nil) == .rip)
    #expect(ArtFormat.detect(bytes: ripBar, fileExtension: nil, sauce: nil) == .rip)
    #expect(ArtFormat.detect(bytes: Array("Hello !|".utf8), fileExtension: "ans", sauce: nil) == .ansi)
    #expect(!ArtFormat.rip.isStream)
}

@Test func ripFileBecomesAScreenWithItsPicture() throws {
    let file = ArtFile(data: Data(ripBar), fileExtension: "rip")
    guard case .screen(let screen) = file.content else { Issue.record("not a screen"); return }
    #expect(screen.columns == 80 && screen.rows.count == 25)
    #expect(screen.font.name == "IBM EGA")
    let underlay = try #require(screen.underlay)
    #expect(underlay.width == 640 && underlay.height == 350)
    #expect(String(decoding: screen.rows[0].prefix(2).map(\.code), as: UTF8.self) == "HI")
}

private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) {
    let data = image.dataProvider!.data! as Data
    let i = y * image.bytesPerRow + x * 4
    return (data[i], data[i + 1], data[i + 2])
}

@Test func rendererDrawsTheUnderlayUnderBlackBackgrounds() throws {
    let file = ArtFile(data: Data(ripBar), fileExtension: "rip")
    guard case .screen(let screen) = file.content else { Issue.record("not a screen"); return }
    let image = try #require(AnsiRenderer.render(screen, options: RenderOptions(for: screen, scale: 1))?.image)
    #expect(image.width == 640 && image.height == 350)
    // Colour 12 is EGA 60: light red. The bar covers 0-10; "HI" text sits in the first row.
    let p = pixel(image, 7, 5)
    #expect(p == (0xFF, 0x55, 0x55))
    // Colour 14 line at y 40.
    #expect(pixel(image, 5, 40) == (0xFF, 0xFF, 0x55))
    #expect(pixel(image, 300, 200) == (0, 0, 0))
}

@Test func screensWithoutUnderlayRenderAsBefore() throws {
    var screen = AnsiScreen(columns: 2, rows: [[AnsiCell(), AnsiCell()]])
    let before = try #require(AnsiRenderer.render(screen, options: RenderOptions(scale: 1))?.image)
    screen.underlay = nil
    let after = try #require(AnsiRenderer.render(screen, options: RenderOptions(scale: 1))?.image)
    #expect((before.dataProvider!.data! as Data) == (after.dataProvider!.data! as Data))
}
