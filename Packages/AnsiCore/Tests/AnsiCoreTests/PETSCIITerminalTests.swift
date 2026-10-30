import Foundation
import Testing
@testable import AnsiCore

private func pet(_ bytes: [UInt8], model: PETSCIITerminal.Model = .c64) -> PETSCIITerminal {
    var t = PETSCIITerminal(model: model)
    t.feed(bytes)
    return t
}

private func row(_ t: PETSCIITerminal, _ r: Int, _ n: Int) -> String {
    String(decoding: t.screen(scrollOffset: 0).rows[r].prefix(n).map(\.code), as: UTF8.self)
}

@Test func petsciiStartsInTheLowerCaseSetLikeC64TerminalPrograms() {
    // Synchronet's PETSCII port sends "sYNCHRONET" without a 0x0E first: CCGMS starts in lower case.
    let t = pet(Array("sYNC".utf8))
    let cells = t.screen(scrollOffset: 0).rows[0]
    #expect(String(decoding: cells.prefix(4).map(\.code), as: UTF8.self) == "Sync")
    #expect(Int(cells[0].glyph ?? 0) == 128 + 0x53)
    #expect(Int(cells[1].glyph ?? 0) == 128 + 0x19)
}

@Test func petsciiPrintsUpperCaseAndClears() {
    let t = pet([0x8E] + Array("HELLO".utf8) + [0x93] + Array("HI".utf8))
    #expect(row(t, 0, 5) == "HI   ")
    let cell = t.screen(scrollOffset: 0).rows[0][0]
    #expect(cell.glyph == 8)  // screen code of H in the upper case set
    #expect(t.columns == 40 && t.rows == 25)
}

@Test func petsciiColoursUseTheC64Palette() {
    let t = pet([0x1C, 0x41, 0x05, 0x42, 0x9E, 0x43])
    let cells = t.screen(scrollOffset: 0).rows[0]
    #expect(cells[0].fg == PETSCIITerminal.c64Palette[2])
    #expect(cells[1].fg == PETSCIITerminal.c64Palette[1])
    #expect(cells[2].fg == PETSCIITerminal.c64Palette[7])
    #expect(cells[0].bg == PETSCIITerminal.c64Palette[0])
}

@Test func petsciiReverseSwapsColoursUntilReturn() {
    let t = pet([0x05, 0x12, 0x41, 0x0D, 0x42])
    let rows = t.screen(scrollOffset: 0).rows
    #expect(rows[0][0].bg == PETSCIITerminal.c64Palette[1])
    #expect(rows[1][0].bg == PETSCIITerminal.c64Palette[0])
}

@Test func petsciiLowerCaseSetSwitchesTheWholeScreen() {
    let t = pet([0x8E] + Array("A".utf8) + [0x0E] + Array("A".utf8) + [0xC1])
    let cells = t.screen(scrollOffset: 0).rows[0]
    // 0x41 in the lower case set is a lower case a (screen code 1 in the second set).
    #expect(cells[0].glyph == 128 + 1 && cells[0].code == UInt8(ascii: "a"))
    #expect(cells[2].glyph == 128 + 0x41 && cells[2].code == UInt8(ascii: "A"))
}

@Test func petsciiGraphicsCharacters() {
    let t = pet([0x8E, 0x60, 0xA0, 0xFF, 0x7E])
    let cells = t.screen(scrollOffset: 0).rows[0]
    #expect(cells.prefix(4).map(\.glyph) == [0x40, 0x60, 0x5E, 0x5E])
}

@Test func petsciiCursorMovement() {
    var bytes: [UInt8] = [0x8E, 0x11, 0x11, 0x1D, 0x1D, 0x41, 0x91, 0x9D, 0x42, 0x13, 0x43]
    bytes += [0x9D]  // left at home stays
    let t = pet(bytes)
    let rows = t.screen(scrollOffset: 0).rows
    #expect(rows[2][2].code == 0x41)
    #expect(rows[1][2].code == 0x42)
    #expect(rows[0][0].code == 0x43)
}

@Test func petsciiWrapsAndScrollsAtTheBottom() {
    var bytes = [0x8E] + [UInt8](repeating: 0x41, count: 40) + [0x42]
    let t = pet(bytes)
    #expect(row(t, 1, 1) == "B")
    bytes = [UInt8](repeating: 0x0D, count: 24) + Array("X".utf8) + [0x0D] + Array("Y".utf8)
    let u = pet([0x8E] + Array("TOP".utf8) + bytes)
    #expect(row(u, 23, 1) == "X")
    #expect(row(u, 24, 1) == "Y")
    #expect(u.scrollbackCount == 1)
}

@Test func petsciiInsertAndDelete() {
    let t = pet([0x8E] + Array("ABCD".utf8) + [0x9D, 0x9D, 0x14] + [0x94] + Array("X".utf8))
    #expect(row(t, 0, 5) == "AXCD ")
}

@Test func petsciiKeys() {
    let t = PETSCIITerminal(model: .c64)
    #expect(t.bytes(for: .up, backspaceSendsDelete: false) == [0x91])
    #expect(t.bytes(for: .down, backspaceSendsDelete: false) == [0x11])
    #expect(t.bytes(for: .left, backspaceSendsDelete: false) == [0x9D])
    #expect(t.bytes(for: .right, backspaceSendsDelete: false) == [0x1D])
    #expect(t.bytes(for: .home, backspaceSendsDelete: false) == [0x13])
    #expect(t.bytes(for: .end, backspaceSendsDelete: false) == [0x93])
    #expect(t.bytes(for: .backspace, backspaceSendsDelete: true) == [0x14])
    #expect(t.bytes(for: .insert, backspaceSendsDelete: false) == [0x94])
    #expect(t.bytes(for: .escape, backspaceSendsDelete: false) == [0x03])
    #expect(t.bytes(for: .function(1), backspaceSendsDelete: false) == [0x85])
    #expect(t.bytes(for: .function(2), backspaceSendsDelete: false) == [0x89])
    #expect(t.bytes(for: .function(8), backspaceSendsDelete: false) == [0x8C])
    #expect(t.control("9") == [0x12])
    #expect(t.control("0") == [0x92])
    #expect(t.control("2") == [0x05])
}

@Test func petsciiTypedTextFollowsTheCharacterSet() {
    var t = PETSCIITerminal(model: .c64)
    t.feed([0x8E])
    #expect(t.text("Ab1\n", encoding: .cp437) == [0x41, 0x42, 0x31, 0x0D])
    #expect(t.text("a\r\nb", encoding: .cp437) == [0x41, 0x0D, 0x42])
    t.feed([0x0E])
    #expect(t.text("Ab", encoding: .cp437) == [0xC1, 0x42])
}

@Test func c128EightyColumnUsesItsPaletteAndFlash() {
    let t = pet([0x1F, 0x0F, 0x41, 0x8F, 0x42], model: .c128)
    #expect(t.columns == 80)
    let cells = t.screen(scrollOffset: 0).rows[0]
    #expect(cells[0].fg == PETSCIITerminal.c128Palette[2])
    #expect(cells[0].blink && !cells[1].blink)
}

@Test func petsciiRandomBytesStayInBounds() {
    var state: UInt64 = 7
    var t = PETSCIITerminal(model: .c64)
    for _ in 0..<50_000 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        t.feed([UInt8(truncatingIfNeeded: state >> 33)])
    }
    #expect(t.cursor.row < 25 && t.cursor.column < 40)
    #expect(t.scrollbackCount <= TerminalEmulator.maxScrollback)
}
