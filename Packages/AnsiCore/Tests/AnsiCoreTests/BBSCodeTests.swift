import Foundation
import Testing
@testable import AnsiCore

private func screen(_ raw: [UInt8], _ ext: String) -> AnsiScreen {
    AnsiAnalysis(ArtFile(data: Data(raw), fileExtension: ext)).finalScreen
}

@Test func pcboardColorCode() {
    let cell = screen(bytes("@X1FA"), "pcb").rows[0][0]
    #expect(cell.code == 0x41)
    #expect(cell.fg == Palette.vga[15])
    #expect(cell.bg == Palette.vga[1])
}

@Test func pcboardClearScreen() {
    #expect(screen(bytes("A@CLS@B"), "pcb").rows[0][0].code == 0x42)
}

@Test func wildcatColorCode() {
    let cell = screen(bytes("@4E@A"), "txt").rows[0][0]
    #expect(cell.fg == Palette.vga[14])
    #expect(cell.bg == Palette.vga[4])
}

@Test func avatarSetAttribute() {
    let cell = screen([0x16, 0x01, 0x1F] + bytes("A"), "avt").rows[0][0]
    #expect(cell.fg == Palette.vga[15])
    #expect(cell.bg == Palette.vga[1])
}

@Test func avatarRepeatChar() {
    let row = screen([0x19, 0x58, 5], "avt").rows[0]
    #expect(row.prefix(5).allSatisfy { $0.code == 0x58 })
    #expect(row[5].code == 0x20)
}

@Test func avatarGotoXY() {
    #expect(screen([0x16, 0x08, 3, 5] + bytes("Z"), "avt").rows[2][4].code == 0x5A)
}

@Test func avatarBlink() {
    #expect(screen([0x16, 0x01, 0x07, 0x16, 0x02] + bytes("A"), "avt").rows[0][0].blink)
}

@Test func unknownAtCodesPassThrough() {
    let row = screen(bytes("a@b"), "pcb").rows[0]
    #expect(row.prefix(3).map(\.code) == bytes("a@b"))
}
