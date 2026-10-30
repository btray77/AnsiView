import Foundation
import Testing
@testable import AnsiCore

private let esc = "\u{1B}"

@Test func ansiBBSIgnoresApplicationCursorKeys() {
    // DECCKM is a DEC mode; SyncTERM does not have it, so ANSI-BBS keys stay ESC [ A as in plan 7.
    var t = TerminalEmulator(columns: 80, rows: 25)
    t.feed(Array("\(esc)[?1h".utf8))
    #expect(t.bytes(for: .up, backspaceSendsDelete: false) == [0x1B, 0x5B, 0x41])
}

@Test func resetClearsHostICEButKeepsTheEntrySetting() {
    var host = TerminalEngines.make(.ansiBBS, columns: 80, rows: 25, encoding: .cp437, iceColors: false) as! TerminalEmulator
    host.feed(Array("\(esc)[?33h\(esc)c".utf8))
    #expect(!host.iceColors)
    var entry = TerminalEngines.make(.ansiBBS, columns: 80, rows: 25, encoding: .cp437, iceColors: true) as! TerminalEmulator
    entry.feed(Array("\(esc)c".utf8))
    #expect(entry.iceColors)
}

@Test func ripCopyRegionIsClampedToTheScreen() {
    var t = RIPTerminal()
    t.feed(Array("!|1C0000ZZZZ|1P000000\r\n".utf8))
    #expect(t.clipboardSize?.width == 640 && t.clipboardSize?.height == 350)
}

@Test func ripFloodFillStillFillsOnlyTheArea() {
    var t = RIPTerminal()
    t.feed(Array("!|c0F|R0A0A1414|S0103|F0F0F0F|F0F0F0F\r\n".utf8))
    #expect(t.canvas.pixel(15, 15) == 3)
    #expect(t.canvas.pixel(5, 5) == 0)
    #expect(t.canvas.pixel(50, 50) == 0)
}

@Test func teletextPastedCRLFIsOneReturn() {
    let t = TeletextTerminal(flavour: .viewdata)
    #expect(t.text("1\r\n2", encoding: .cp437) == [0x31, 0x5F, 0x32])
}

@Test func teletextScrollbackRowsFitAfterResize() {
    var t = TeletextTerminal(flavour: .mode7)
    t.feed([UInt8](repeating: 0x0A, count: 30))
    t.resize(columns: 60, rows: 25)
    let screen = t.screen(scrollOffset: 3)
    #expect(screen.rows.allSatisfy { $0.count == 60 })
}

@Test func detectorIgnoresHighBytesOnUTF8Boards() {
    var d = TerminalDetector(encoding: .utf8)
    // An en dash (E2 80 93) and curly quotes contain PETSCII looking bytes.
    let text = Array("Welcome \u{2013} \u{201C}quoted\u{201D} \u{2013} \u{2013} \u{201C}x\u{201D}\r\n".utf8)
    #expect(d.feed(text) == nil)
}
