import Foundation
import Testing
@testable import AnsiCore

private func atari(_ bytes: [UInt8]) -> ATASCIITerminal {
    var t = ATASCIITerminal()
    t.feed(bytes)
    return t
}

private func row(_ t: ATASCIITerminal, _ r: Int, _ n: Int) -> String {
    String(decoding: t.screen(scrollOffset: 0).rows[r].prefix(n).map(\.code), as: UTF8.self)
}

@Test func atasciiClearAndEOL() {
    let t = atari(Array("OLD".utf8) + [0x7D] + Array("HI".utf8) + [0x9B] + Array("YO".utf8))
    #expect(row(t, 0, 3) == "HI ")
    #expect(row(t, 1, 2) == "YO")
    #expect(t.columns == 40 && t.rows == 24)
}

@Test func atasciiInverseIsHighBit() {
    let t = atari([0xC1, 0x41])
    let cells = t.screen(scrollOffset: 0).rows[0]
    #expect(cells[0].glyph == 0x41 && cells[1].glyph == 0x41)
    #expect(cells[0].fg == ATASCIITerminal.background && cells[0].bg == ATASCIITerminal.foreground)
    #expect(cells[1].fg == ATASCIITerminal.foreground)
}

@Test func atasciiCursorKeysWrapWithoutScrolling() {
    let t = atari([0x1C, 0x41, 0x1E, 0x1E, 0x1E, 0x42])
    let rows = t.screen(scrollOffset: 0).rows
    #expect(rows[23][0].code == 0x41)
    #expect(rows[23][38].code == 0x42)
    #expect(t.scrollbackCount == 0)
}

@Test func atasciiEscapePrintsAControlGlyph() {
    let t = atari([0x1B, 0x1C, 0x1B, 0x7D, 0x41])
    let cells = t.screen(scrollOffset: 0).rows[0]
    #expect(cells[0].glyph == 0x1C && cells[1].glyph == 0x7D && cells[2].code == 0x41)
}

@Test func atasciiGraphicsGlyphs() {
    let t = atari([0x00, 0x12, 0x60, 0x7B])
    #expect(t.screen(scrollOffset: 0).rows[0].prefix(4).map(\.glyph) == [0x00, 0x12, 0x60, 0x7B])
}

@Test func atasciiEditing() {
    var bytes = Array("ABCD".utf8) + [0x1E, 0x1E, 0x1E, 0xFE]  // delete char: ACD
    bytes += [0xFF, 0x58]  // insert char then X: AXCD
    bytes += [0x7E]  // backspace erases X
    let t = atari(bytes)
    #expect(row(t, 0, 4) == "A CD")
    let lines = atari(Array("1".utf8) + [0x9B] + Array("2".utf8) + [0x9B] + Array("3".utf8) + [0x1C, 0x9C])
    #expect(row(lines, 0, 1) == "1" && row(lines, 1, 1) == "3")
    let inserted = atari(Array("1".utf8) + [0x9B] + Array("2".utf8) + [0x9D])
    #expect(row(inserted, 1, 1) == " " && row(inserted, 2, 1) == "2")
}

@Test func atasciiScrollsAtTheBottom() {
    let t = atari([UInt8](repeating: 0x9B, count: 24) + Array("Z".utf8))
    #expect(row(t, 23, 1) == "Z")
    #expect(t.scrollbackCount == 1)
}

@Test func atasciiBellAndTab() {
    let t = atari([0xFD, 0x7F, 0x41])
    #expect(t.bells == 1)
    #expect(t.screen(scrollOffset: 0).rows[0][8].code == 0x41)
}

@Test func atasciiKeys() {
    let t = ATASCIITerminal()
    #expect(t.bytes(for: .returnKey, backspaceSendsDelete: false) == [0x9B])
    #expect(t.bytes(for: .backspace, backspaceSendsDelete: true) == [0x7E])
    #expect(t.bytes(for: .up, backspaceSendsDelete: false) == [0x1C])
    #expect(t.bytes(for: .down, backspaceSendsDelete: false) == [0x1D])
    #expect(t.bytes(for: .left, backspaceSendsDelete: false) == [0x1E])
    #expect(t.bytes(for: .right, backspaceSendsDelete: false) == [0x1F])
    #expect(t.bytes(for: .insert, backspaceSendsDelete: false) == [0xFF])
    #expect(t.bytes(for: .forwardDelete, backspaceSendsDelete: false) == [0xFE])
    #expect(t.bytes(for: .tab, backspaceSendsDelete: false) == [0x7F])
    #expect(t.bytes(for: .end, backspaceSendsDelete: false) == [0x7D])
    #expect(t.text("ab\n", encoding: .cp437) == [0x61, 0x62, 0x9B])
}
