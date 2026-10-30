import Foundation
import Testing
@testable import AnsiCore

private func term(_ text: String, columns: Int = 80, rows: Int = 25) -> TerminalEmulator {
    var t = TerminalEmulator(columns: columns, rows: rows)
    t.feed(Array(text.utf8))
    return t
}

/// A row as text (CP437 glyphs), trailing spaces removed.
private func line(_ cells: [AnsiCell]) -> String {
    var s = String(String.UnicodeScalarView(cells.map { CP437.unicode[Int($0.code)] }))
    while s.last == " " { s.removeLast() }
    return s
}

private let esc = "\u{1B}"

@Test func printsAndWraps() {
    let t = term(String(repeating: "A", count: 81))
    #expect(t.grid[1][0].code == 0x41)
    #expect(t.cursor.row == 1 && t.cursor.column == 1)
}

@Test func pendingWrapThenCRLF() {
    let t = term(String(repeating: "A", count: 80) + "\r\nB")
    #expect(t.grid[1][0].code == 0x42)
    #expect(line(t.grid[2]).isEmpty)
}

@Test func autowrapOff() {
    let t = term("\(esc)[?7l" + String(repeating: "A", count: 79) + "BC")
    #expect(t.grid[0][79].code == 0x43)
    #expect(line(t.grid[1]).isEmpty)
}

@Test func cursorPositionAndClamp() {
    var t = term("\(esc)[10;20H")
    #expect(t.cursor.row == 9 && t.cursor.column == 19)
    t.feed(Array("\(esc)[99;999H".utf8))
    #expect(t.cursor.row == 24 && t.cursor.column == 79)
    t.feed(Array("\(esc)[3;1H\(esc)[5A".utf8))
    #expect(t.cursor.row == 0)
    t.feed(Array("\(esc)[5;5H\(esc)[2B\(esc)[3C\(esc)[1D".utf8))
    #expect(t.cursor.row == 6 && t.cursor.column == 6)
    t.feed(Array("\(esc)[12G".utf8))
    #expect(t.cursor.column == 11)
    t.feed(Array("\(esc)[4d".utf8))
    #expect(t.cursor.row == 3 && t.cursor.column == 11)
    t.feed(Array("\(esc)[2E".utf8))
    #expect(t.cursor.row == 5 && t.cursor.column == 0)
    t.feed(Array("\(esc)[5;5H\(esc)[F".utf8))
    #expect(t.cursor.row == 3 && t.cursor.column == 0)
}

@Test func deviceStatusReplies() {
    var t = term("\(esc)[3;7H\(esc)[6n")
    #expect(t.takeReplies() == Array("\(esc)[3;7R".utf8))
    #expect(t.takeReplies().isEmpty)
    t.feed(Array("\(esc)[5n\(esc)[c".utf8))
    #expect(t.takeReplies() == Array("\(esc)[0n\(esc)[?1;0c".utf8))
}

@Test func scrollsAtBottomIntoScrollback() {
    let text = (0...25).map { "L\($0)" }.joined(separator: "\r\n")
    let t = term(text)
    #expect(line(t.grid[0]) == "L1")
    #expect(line(t.grid[24]) == "L25")
    #expect(t.scrollback.count == 1)
    #expect(line(t.scrollback[0]) == "L0")
    let back = t.screen(scrollOffset: 1)
    #expect(back.rows.count == 25)
    #expect(line(back.rows[0]) == "L0")
    #expect(line(back.rows[24]) == "L24")
    #expect(line(t.screen(scrollOffset: 99).rows[0]) == "L0")
    #expect(line(t.screen().rows[0]) == "L1")
}

@Test func scrollbackCapped() {
    let text = String(repeating: "x\r\n", count: TerminalEmulator.maxScrollback + 125)
    let t = term(text)
    #expect(t.scrollback.count == TerminalEmulator.maxScrollback)
}

@Test func scrollRegion() {
    var t = term((1...25).map { "R\($0)" }.joined(separator: "\r\n"))
    let before = t.scrollback.count
    t.feed(Array("\(esc)[5;10r".utf8))
    #expect(t.cursor.row == 0 && t.cursor.column == 0)
    t.feed(Array("\(esc)[10;1H\n".utf8))
    #expect(line(t.grid[3]) == "R4")
    #expect(line(t.grid[4]) == "R6")
    #expect(line(t.grid[8]) == "R10")
    #expect(line(t.grid[9]).isEmpty)
    #expect(line(t.grid[10]) == "R11")
    #expect(t.scrollback.count == before)
    // Cursor up stops at the region top when inside it.
    t.feed(Array("\(esc)[7;1H\(esc)[9A".utf8))
    #expect(t.cursor.row == 4)
}

@Test func insertDeleteLines() {
    var t = term((1...25).map { "R\($0)" }.joined(separator: "\r\n"))
    t.feed(Array("\(esc)[3;1H\(esc)[2L".utf8))
    #expect(line(t.grid[2]).isEmpty && line(t.grid[3]).isEmpty)
    #expect(line(t.grid[4]) == "R3")
    #expect(line(t.grid[24]) == "R23")
    t.feed(Array("\(esc)[2M".utf8))
    #expect(line(t.grid[2]) == "R3")
    #expect(line(t.grid[22]) == "R23")
    #expect(line(t.grid[23]).isEmpty)
}

@Test func insertDeleteEraseChars() {
    var t = term("ABCDE\(esc)[1;2H\(esc)[2P")
    #expect(line(t.grid[0]) == "ADE")
    t.feed(Array("\(esc)[2@".utf8))
    #expect(line(t.grid[0]) == "A  DE")
    t.feed(Array("\(esc)[1;4H\(esc)[2X".utf8))
    #expect(line(t.grid[0]) == "A")
    #expect(t.cursor.column == 3)
}

@Test func eraseDisplayAndLine() {
    var t = term("\(esc)[44mAAAAA\r\nBBBBB\r\nCCCCC\(esc)[2;3H\(esc)[K")
    #expect(line(t.grid[1]) == "BB")
    #expect(t.grid[1][3].bg == Palette.vga[1])
    t.feed(Array("\(esc)[1K".utf8))
    #expect(line(t.grid[1]).isEmpty)
    t.feed(Array("\(esc)[1;3H\(esc)[2K".utf8))
    #expect(line(t.grid[0]).isEmpty)
    t = term("AAAAA\r\nBBBBB\r\nCCCCC\(esc)[2;3H\(esc)[J")
    #expect(line(t.grid[0]) == "AAAAA" && line(t.grid[1]) == "BB" && line(t.grid[2]).isEmpty)
    t = term("AAAAA\r\nBBBBB\r\nCCCCC\(esc)[2;3H\(esc)[1J")
    #expect(line(t.grid[0]).isEmpty && line(t.grid[1]) == "   BB" && line(t.grid[2]) == "CCCCC")
    t = term("AAAAA\r\nBBBBB\(esc)[2J")
    #expect(t.grid.allSatisfy { line($0).isEmpty })
}

@Test func saveRestoreCursor() {
    var t = term("\(esc)[5;6H\(esc)[s\(esc)[1;1H\(esc)[u")
    #expect(t.cursor.row == 4 && t.cursor.column == 5)
    t = term("\(esc)[31m\(esc)[3;3H\(esc)7\(esc)[0m\(esc)[1;1H\(esc)8X")
    #expect(t.grid[2][2].code == 0x58)
    #expect(t.grid[2][2].fg == Palette.vga[4])
}

@Test func reverseIndexAtTopScrollsDown() {
    var t = term("TOP\r\nNEXT\(esc)[1;1H")
    t.feed(Array("\(esc)M".utf8))
    #expect(line(t.grid[0]).isEmpty)
    #expect(line(t.grid[1]) == "TOP")
    #expect(line(t.grid[2]) == "NEXT")
}

@Test func indexAndNextLine() {
    let t = term("AB\(esc)DC\(esc)EZ")
    #expect(line(t.grid[1]) == "  C")
    #expect(line(t.grid[2]) == "Z")
}

@Test func formFeedClears() {
    let t = term("HELLO\r\nWORLD\u{0C}X")
    #expect(line(t.grid[0]) == "X")
    #expect(line(t.grid[1]).isEmpty)
}

@Test func scrollUpDown() {
    var t = term("A\r\nB\r\nC")
    t.feed(Array("\(esc)[1S".utf8))
    #expect(line(t.grid[0]) == "B")
    t.feed(Array("\(esc)[2T".utf8))
    #expect(line(t.grid[2]) == "B")
    #expect(line(t.grid[0]).isEmpty)
}

@Test func cursorVisibility() {
    var t = term("\(esc)[?25l")
    #expect(!t.cursorVisible)
    t.feed(Array("\(esc)[?25h".utf8))
    #expect(t.cursorVisible)
}

@Test func sgrMatchesFileTerminal() {
    let text = "\(esc)[1;33;44mX\(esc)[0;38;5;196mY\(esc)[38;2;1;2;3;48;5;21mZ\(esc)[0;7;32mW\(esc)[0;94;101mV"
    let live = term(text)
    let file = AnsiParser.parse(Data(text.utf8))
    for col in 0..<5 {
        #expect(live.grid[0][col] == file.rows[0][col], "column \(col)")
    }
}

@Test func blinkIsBlink() {
    let t = term("\(esc)[5;41mB")
    #expect(t.grid[0][0].blink)
    #expect(t.grid[0][0].bg == Palette.vga[4])
}

@Test func byteByByteFeedMatchesWholeFeed() throws {
    let url = SampleArtTests.samples.appendingPathComponent("Welcome.ans")
    let data = Array(try Data(contentsOf: url))
    var whole = TerminalEmulator()
    whole.feed(data)
    var single = TerminalEmulator()
    for byte in data { single.feed([byte]) }
    #expect(whole.grid == single.grid)
    #expect(whole.cursor == single.cursor)
    #expect(whole.scrollback == single.scrollback)
    // The welcome art draws something.
    #expect(whole.grid.contains { !line($0).isEmpty })
}

@Test func utf8SplitAcrossFeeds() {
    var t = TerminalEmulator(encoding: .utf8)
    let shade = Array("░".utf8)
    t.feed([shade[0]])
    t.feed([shade[1]])
    t.feed([shade[2]])
    t.feed(Array("é".utf8))
    t.feed([0xFF, 0x41])
    t.feed(Array("€".utf8))
    #expect(t.grid[0][0].code == 176)
    #expect(t.grid[0][1].code == 130)
    #expect(t.grid[0][2].code == 255)
    #expect(t.grid[0][3].code == 0x41)
    #expect(t.grid[0][4].scalar == "€")
    #expect(t.cursor.column == 5)
}

@Test func cp437ModeHighBytesAreGlyphs() {
    let t = TerminalEmulator.withFeed([0xDB, 0xB0, 0x82])
    #expect(t.grid[0].prefix(3).map(\.code) == [0xDB, 0xB0, 0x82])
}

@Test func resizeKeepsTopLeft() {
    var t = term("HELLO\(esc)[20;70H")
    t.resize(columns: 40, rows: 10)
    #expect(t.columns == 40 && t.rows == 10)
    #expect(t.grid.count == 10 && t.grid.allSatisfy { $0.count == 40 })
    #expect(line(t.grid[0]) == "HELLO")
    #expect(t.cursor.row == 9 && t.cursor.column == 39)
    t.resize(columns: 132, rows: 50)
    #expect(t.grid.count == 50 && t.grid[0].count == 132)
}

@Test func hostileSequencesStayInBounds() {
    var t = term("\(esc)[99999999999C\(esc)[30;5r\(esc)[9999L\(esc)[9999@\(esc)[9999;9999H\(esc)[9999M\(esc)[9999P\(esc)[9999S")
    var generator = SystemRandomNumberGenerator()
    var noise = [UInt8](repeating: 0, count: 100_000)
    for i in noise.indices { noise[i] = UInt8.random(in: 0...255, using: &generator) }
    t.feed(noise)
    t.feed(Array("\(esc)[".utf8) + [UInt8](repeating: 0x31, count: 50_000) + [0x6D])
    #expect(t.grid.count == 25 && t.grid.allSatisfy { $0.count == 80 })
    #expect((0..<25).contains(t.cursor.row) && (0..<80).contains(t.cursor.column))
    #expect(t.scrollback.count <= TerminalEmulator.maxScrollback)
}

@Test func bellsCounted() {
    let t = term("a\u{07}b\u{07}")
    #expect(t.bells == 2)
    #expect(line(t.grid[0]) == "ab")
}

@Test func changeCountAdvances() {
    var t = TerminalEmulator()
    let start = t.changeCount
    t.feed(Array("x".utf8))
    #expect(t.changeCount > start)
}

@Test func resetClears() {
    let t = term("HELLO\(esc)[31m\(esc)c")
    #expect(line(t.grid[0]).isEmpty)
    #expect(t.cursor.row == 0 && t.cursor.column == 0)
}

@Test func backspaceAndTab() {
    let t = term("AB\u{08}C\tD")
    #expect(line(t.grid[0]) == "AC      D")
}

extension TerminalEmulator {
    static func withFeed(_ bytes: [UInt8]) -> TerminalEmulator {
        var t = TerminalEmulator()
        t.feed(bytes)
        return t
    }
}
