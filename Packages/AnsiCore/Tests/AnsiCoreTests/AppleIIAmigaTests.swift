import Foundation
import Testing
@testable import AnsiCore

private func apple(_ bytes: [UInt8], upperCaseOnly: Bool = false) -> AppleIITerminal {
    var t = AppleIITerminal()
    t.upperCaseOnly = upperCaseOnly
    t.feed(bytes)
    return t
}

private func row(_ cells: [AnsiCell], _ n: Int) -> String {
    String(decoding: cells.prefix(n).map(\.code), as: UTF8.self)
}

@Test func appleIIPrintsHighBitASCIIAndReturns() {
    let t = apple([0xC8, 0xC9, 0x8D, 0x8A, 0x41])
    let rows = t.screen(scrollOffset: 0).rows
    #expect(row(rows[0], 2) == "HI")
    // CR then LF is one new line.
    #expect(row(rows[1], 1) == "A")
    #expect(t.columns == 40 && t.rows == 24)
    #expect(rows[0][0].glyph == 0x48)
}

@Test func appleIIInverseAndClear() {
    let t = apple(Array("X".utf8) + [0x0C, 0x0F] + Array("I".utf8) + [0x0E] + Array("N".utf8))
    let cells = t.screen(scrollOffset: 0).rows[0]
    #expect(cells[0].code == 0x49 && cells[0].bg == AppleIITerminal.foreground)
    #expect(cells[1].bg == AppleIITerminal.background)
}

@Test func appleIIUpperCaseOnly() {
    let t = apple(Array("abc".utf8), upperCaseOnly: true)
    #expect(row(t.screen(scrollOffset: 0).rows[0], 3) == "ABC")
}

@Test func appleIICursorCodes() {
    var t = apple([0x1E, 0x20 + 5, 0x20 + 2] + Array("Q".utf8))
    #expect(t.screen(scrollOffset: 0).rows[2][5].code == 0x51)
    t.feed([0x19] + Array("ABC".utf8) + [0x08, 0x08, 0x1D])
    #expect(row(t.screen(scrollOffset: 0).rows[0], 3) == "A  ")
}

@Test func appleIIKeys() {
    let t = AppleIITerminal()
    #expect(t.bytes(for: .left, backspaceSendsDelete: false) == [0x08])
    #expect(t.bytes(for: .right, backspaceSendsDelete: false) == [0x15])
    #expect(t.bytes(for: .up, backspaceSendsDelete: false) == [0x0B])
    #expect(t.bytes(for: .down, backspaceSendsDelete: false) == [0x0A])
    #expect(t.bytes(for: .returnKey, backspaceSendsDelete: false) == [0x0D])
}

@Test func amigaLatin1WithTopaz() {
    let e = TerminalEngines.make(.amiga, columns: 80, rows: 25, encoding: .cp437, iceColors: false)
    var t = e as! TerminalEmulator
    #expect(t.profile == .amiga)
    #expect(t.font?.name == PlatformFonts.topaz.name)
    t.feed([0xE9, 0x41])
    let cells = t.screen(scrollOffset: 0).rows[0]
    #expect(cells[0].glyph == 0xE9)
    #expect(cells[0].code == 0x82)  // e acute in CP437, for copying
    #expect(cells[1].glyph == 0x41)
}

@Test func amigaSingleByteCSIAndLineFeed() {
    var t = TerminalEmulator(columns: 80, rows: 25)
    t.profile = .amiga
    t.feed([0x41, 0x9B] + Array("31mB".utf8) + [0x0A, 0x43])
    let rows = t.screen(scrollOffset: 0).rows
    #expect(rows[0][1].fg == Palette.vga[4])
    #expect(rows[1][0].code == 0x43)
}

@Test func amigaWindowStatusReport() {
    var t = TerminalEmulator(columns: 80, rows: 25)
    t.profile = .amiga
    t.feed(Array("\u{1B}[0 q".utf8))
    #expect(String(decoding: t.takeReplies(), as: UTF8.self) == "\u{1B}[1;1;25;80 r")
    t.feed(Array("\u{1B}[0 p".utf8))
    #expect(!t.cursorVisible)
    t.feed(Array("\u{1B}[ p".utf8))
    #expect(t.cursorVisible)
}
