import Foundation
import Testing
@testable import AnsiCore

private func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }

/// XBin header: width, height, font height, flags.
private func xbinHeader(width: Int, height: Int, fontHeight: Int = 16, flags: UInt8) -> [UInt8] {
    bytes("XBIN") + [0x1A] + le16(width) + le16(height) + [UInt8(fontHeight), flags]
}

@Test func binPairsAreCharThenAttribute() {
    let cell = BinaryFormats.bin([0x41, 0x1F], columns: 1, ice: false).rows[0][0]
    #expect(cell.code == 0x41)
    #expect(cell.fg == Palette.vga[15])
    #expect(cell.bg == Palette.vga[1])
}

@Test func binDefaultWidthIs160() {
    let file = ArtFile(data: Data([UInt8](repeating: 0x41, count: 640)), fileExtension: "bin")
    #expect(AnsiAnalysis(file).finalScreen.columns == 160)
    #expect(AnsiAnalysis(file).finalScreen.rows.count == 2)
}

@Test func binBlinkBitWithoutIce() {
    #expect(BinaryFormats.bin([0x41, 0x8F], columns: 1, ice: false).rows[0][0].blink)
}

@Test func binBlinkBitWithIceBrightensBackground() {
    let cell = BinaryFormats.bin([0x41, 0x9F], columns: 1, ice: true).rows[0][0]
    #expect(!cell.blink)
    #expect(cell.bg == Palette.vga[9])
}

@Test func xbinPaletteIsSixBit() throws {
    var palette = [UInt8](repeating: 0, count: 48)
    palette[0] = 63
    let file = xbinHeader(width: 1, height: 1, flags: 0b0001) + palette + [0x41, 0x07]
    let (screen, _) = try BinaryFormats.xbin(file)
    #expect(screen.rows[0][0].bg == RGB(r: 255, g: 0, b: 0))
}

@Test func xbinCompressedRuns() throws {
    // Type 3 (char and attribute both repeat), count 3.
    let file = xbinHeader(width: 3, height: 1, flags: 0b0100) + [0b1100_0010, 0x41, 0x07]
    let (screen, _) = try BinaryFormats.xbin(file)
    #expect(screen.rows[0].prefix(3).allSatisfy { $0.code == 0x41 })
}

@Test func xbinCharacterRun() throws {
    // Type 1: one character, then 2 attributes.
    let file = xbinHeader(width: 2, height: 1, flags: 0b0100) + [0b0100_0001, 0x42, 0x07, 0x1F]
    let (screen, _) = try BinaryFormats.xbin(file)
    #expect(screen.rows[0][0].code == 0x42)
    #expect(screen.rows[0][1].code == 0x42)
    #expect(screen.rows[0][1].fg == Palette.vga[15])
}

@Test func xbinEmbeddedFont() throws {
    var font = [UInt8](repeating: 0, count: 256 * 8)
    font[0x41 * 8] = 0xFF
    let file = xbinHeader(width: 1, height: 1, fontHeight: 8, flags: 0b0010) + font + [0x41, 0x07]
    let (_, embedded) = try BinaryFormats.xbin(file)
    #expect(embedded?.height == 8)
    #expect(embedded?.pixels(for: 0x41)[0] == true)
}

@Test func adfLayout() throws {
    let file: [UInt8] = [1] + [UInt8](repeating: 0, count: 192) + [UInt8](repeating: 0, count: 4096)
        + Array(repeating: [0x41, 0x07], count: 160).flatMap { $0 }
    let (screen, font) = try BinaryFormats.adf(file)
    #expect(screen.columns == 80)
    #expect(screen.rows.count == 2)
    #expect(font.height == 16)
}

@Test func idfRunLength() throws {
    let header: [UInt8] = [0x04] + bytes("1.4") + le16(0) + le16(0) + le16(3) + le16(0)
    let data: [UInt8] = [0x01, 0x00, 4, 0, 0x5A, 0x07]
    let file = header + data + [UInt8](repeating: 0, count: 4096) + [UInt8](repeating: 0, count: 48)
    let (screen, _) = try BinaryFormats.idf(file)
    #expect(screen.columns == 4)
    #expect(screen.rows[0].allSatisfy { $0.code == 0x5A })
}

@Test func truncatedBinaryDoesNotCrash() {
    #expect(throws: (any Error).self) { try BinaryFormats.xbin(bytes("XBIN") + [0x1A]) }
    #expect(throws: (any Error).self) { try BinaryFormats.adf([1, 2, 3]) }
    #expect(throws: (any Error).self) { try BinaryFormats.idf([0x04]) }
    // A header promising more data than the file has renders what is there.
    #expect(throws: Never.self) { _ = try BinaryFormats.xbin(xbinHeader(width: 80, height: 25, flags: 0) + [0x41, 0x07]) }
}

@Test func wideBinIsCapped() {
    let screen = BinaryFormats.bin([UInt8](repeating: 0x41, count: 2_000_000) + [0x07], columns: 1000, ice: false)
    #expect(screen.rows.count <= AnsiTerminal.maxRows)
}

@Test func artFileLoadsBinaryAsScreen() {
    let file = ArtFile(data: Data(xbinHeader(width: 1, height: 1, flags: 0) + [0x41, 0x07]), fileExtension: "xb")
    guard case .screen(let screen) = file.content else { Issue.record("expected a screen"); return }
    #expect(screen.rows[0][0].code == 0x41)
}
