import Foundation
import Testing
@testable import AnsiCore

// Critical 1: hostile XBin dimensions.
@Test func xbinHugeDimensionsAreRejected() {
    let header = bytes("XBIN") + [0x1A, 0xFF, 0xFF, 0xFF, 0xFF, 16, 0]
    #expect(throws: (any Error).self) { try BinaryFormats.xbin(header) }
}

@Test func xbinZeroWidthIsRejected() {
    #expect(throws: (any Error).self) { try BinaryFormats.xbin(bytes("XBIN") + [0x1A, 0, 0, 25, 0, 16, 0]) }
}

@Test func xbinAbsurdFontHeightIsRejected() {
    let header = bytes("XBIN") + [0x1A, 80, 0, 25, 0, 255, 0b0010]
    #expect(throws: (any Error).self) { try BinaryFormats.xbin(header + [UInt8](repeating: 0, count: 256 * 255)) }
}

@Test func xbinHeightIsCappedToMaxRows() throws {
    let header = bytes("XBIN") + [0x1A, 1, 0, 0xFF, 0xFF, 16, 0]
    let (screen, _) = try BinaryFormats.xbin(header + [0x41, 0x07])
    #expect(screen.rows.count <= AnsiTerminal.maxRows)
}

// Critical 2: the render budget holds for wide art.
@Test func wideArtRenderStaysWithinBudget() throws {
    let row = [AnsiCell](repeating: AnsiCell(code: 0x41), count: 1000)
    let screen = AnsiScreen(columns: 1000, rows: Array(repeating: row, count: AnsiTerminal.maxRows))
    let rendered = try #require(AnsiRenderer.render(screen, options: RenderOptions(font: .vga, ninePixel: true, scale: 2)))
    #expect(rendered.image.width * rendered.image.height * 4 <= AnsiRenderer.maxImageBytes)
    #expect(AnsiRenderer.maxImageBytes <= 200_000_000)
}

// Important 3: 0x1A is an Avatar parameter, not end of file.
@Test func avatarAttributeOf1AIsKept() {
    let screen = AnsiAnalysis(ArtFile(data: Data([0x16, 0x01, 0x1A] + bytes("HELLO")), fileExtension: "avt")).finalScreen
    #expect(screen.rows[0][0].code == 0x48)
    #expect(screen.rows[0][0].bg == Palette.vga[1])
}

@Test func avatarRepeatCountOf26IsKept() {
    let screen = AnsiAnalysis(ArtFile(data: Data([0x19, 0xC4, 0x1A] + bytes("AFTER")), fileExtension: "avt")).finalScreen
    #expect(screen.rows[0][26].code == 0x41)
}

@Test func avatarStopsAtEndOfFileInText() {
    let out = BBSCodes.avatarToANSI(bytes("AB") + [0x1A] + bytes("junk"))
    #expect(out == bytes("AB"))
}

// Important 4: repeat bombs are bounded.
@Test func avatarRepeatOutputIsCapped() {
    let bomb = Array(repeating: [UInt8]([0x19, 0x41, 0xFF]), count: 100_000).flatMap { $0 }
    #expect(BBSCodes.avatarToANSI(bomb).count <= BBSCodes.maxOutputBytes)
}

// Important 5: art text is not mistaken for BBS color codes.
@Test func asciiArtWithAtSignsStaysAnsi() {
    #expect(ArtFormat.detect(bytes: bytes("  .d@88@b.  ascii art"), fileExtension: "asc", sauce: nil) == .ansi)
    #expect(ArtFormat.detect(bytes: bytes("Email: @XE0 tag"), fileExtension: "ans", sauce: nil) == .ansi)
}

@Test func lateSingleCodeInUnknownFileIsNotSniffed() {
    let text = [UInt8](repeating: 0x2E, count: 1000) + bytes("@1F@")
    #expect(ArtFormat.detect(bytes: text, fileExtension: "txt", sauce: nil) == .ansi)
}
