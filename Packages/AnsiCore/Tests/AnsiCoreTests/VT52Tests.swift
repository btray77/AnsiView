import Testing
@testable import AnsiCore

private func vt52(_ text: String, bytewise: Bool = false) -> TerminalEmulator {
    var t = TerminalEmulator(columns: 80, rows: 24)
    t.profile = .vt52
    if bytewise { for b in Array(text.utf8) { t.feed([b]) } } else { t.feed(Array(text.utf8)) }
    return t
}

private func line(_ t: TerminalEmulator, _ row: Int) -> String {
    String(decoding: t.screen(scrollOffset: 0).rows[row].map(\.code), as: UTF8.self)
}

@Test func vt52IsATerminalType() {
    #expect(TerminalEmulation.vt52.label == "VT52 (Atari ST)")
    #expect(TerminalEmulation.vt52.defaultColumns == 80 && TerminalEmulation.vt52.defaultRows == 24)
    #expect(TerminalEmulation.vt52.terminalNames.first == "VT52")
    let e = TerminalEngines.make(.vt52, columns: 80, rows: 24, encoding: .cp437, iceColors: false)
    #expect((e as? TerminalEmulator)?.profile == .vt52)
    #expect(IEMSI.crtName(.vt52) == "VT52")
}

@Test func vt52DirectCursorAddress() {
    let t = vt52("\u{1B}Y\u{22}\u{25}X")       // row 2, column 5
    #expect(t.cursor.row == 2 && t.cursor.column == 6)
    #expect(line(t, 2).dropFirst(5).first == "X")
    let split = vt52("\u{1B}Y\u{22}\u{25}X", bytewise: true)
    #expect(split.grid == t.grid && split.cursor == t.cursor)
}

@Test func vt52CursorMovesAndHome() {
    var t = vt52("\u{1B}Y\u{25}\u{2A}")         // row 5, column 10
    t.feed(Array("\u{1B}A\u{1B}A\u{1B}D\u{1B}C\u{1B}C\u{1B}B".utf8))
    #expect(t.cursor.row == 4 && t.cursor.column == 11)
    t.feed(Array("\u{1B}H".utf8))
    #expect(t.cursor.row == 0 && t.cursor.column == 0)
}

@Test func vt52Erases() {
    var t = vt52("ABCDEF\r\nGHIJKL\u{1B}Y\u{20}\u{22}\u{1B}K")
    #expect(line(t, 0).hasPrefix("AB ") && line(t, 1).hasPrefix("GHIJKL"))
    t.feed(Array("\u{1B}J".utf8))
    #expect(line(t, 1).hasPrefix("      "))
    t.feed(Array("XY\u{1B}E".utf8))     // Atari ST: clear screen and home
    #expect(line(t, 0).trimmingCharacters(in: .whitespaces).isEmpty && t.cursor.row == 0 && t.cursor.column == 0)
}

@Test func vt52ReverseLineFeedScrollsAtTheTop() {
    let t = vt52("TOP\u{1B}H\u{1B}I")
    #expect(line(t, 1).hasPrefix("TOP"))
}

@Test func vt52IdentifiesAndIgnoresCSI() {
    var t = vt52("\u{1B}Z\u{1B}[2JA")
    #expect(t.takeReplies() == [0x1B, 0x2F, 0x4B])
    #expect(line(t, 0).hasPrefix("2JA"))
}

@Test func vt52KeysAndANSIMode() {
    var t = vt52("")
    #expect(t.bytes(for: .up, backspaceSendsDelete: false) == [0x1B, 0x41])
    #expect(t.bytes(for: .left, backspaceSendsDelete: false) == [0x1B, 0x44])
    t.feed(Array("\u{1B}<".utf8))
    #expect(t.profile == .vt100)
    #expect(t.bytes(for: .up, backspaceSendsDelete: false) == [0x1B, 0x5B, 0x41])
}

@Test func vt52AtariColoursAndReverse() {
    let t = vt52("\u{1B}b\u{31}R\u{1B}c\u{34}B\u{1B}pV\u{1B}qN")
    let row = t.screen(scrollOffset: 0).rows[0]
    #expect(row[0].fg == Palette.vga[4])              // ST colour 1 is red
    #expect(row[1].bg == Palette.vga[1])              // ST colour 4 is blue
    #expect(row[2].fg == row[1].bg && row[2].bg == row[1].fg)
    #expect(row[3].fg == Palette.vga[4])
}

@Test func vt52GraphicsMode() {
    let t = vt52("\u{1B}Fq\u{1B}Gq")
    let row = t.screen(scrollOffset: 0).rows[0]
    #expect(row[0].code == 0xC4 && row[1].code == UInt8(ascii: "q"))
}

@Test func vt52SaveRestoreAndCursorVisibility() {
    var t = vt52("\u{1B}Y\u{23}\u{23}\u{1B}j\u{1B}H\u{1B}k\u{1B}f")
    #expect(t.cursor.row == 3 && t.cursor.column == 3)
    #expect(!t.cursorVisible)
    t.feed(Array("\u{1B}e".utf8))
    #expect(t.cursorVisible)
}
