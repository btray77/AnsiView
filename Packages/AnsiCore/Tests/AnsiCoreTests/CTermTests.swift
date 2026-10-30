import Foundation
import Testing
@testable import AnsiCore

private let esc = "\u{1B}"

private func cterm(_ text: String) -> TerminalEmulator {
    var t = TerminalEmulator(columns: 80, rows: 25)
    t.feed(Array(text.utf8))
    return t
}

private func reply(_ t: inout TerminalEmulator) -> String { String(decoding: t.takeReplies(), as: UTF8.self) }

@Test func ctermICEColoursMode() {
    var t = cterm("\(esc)[?33h\(esc)[5;44mA")
    #expect(t.iceColors)
    #expect(t.grid[0][0].bg == Palette.vga[9])
    #expect(!t.grid[0][0].blink)
    t.feed(Array("\(esc)[?33l".utf8))
    #expect(!t.iceColors)
}

@Test func ctermCapabilityQuery() {
    var t = cterm("\(esc)[<0c")
    #expect(reply(&t) == "\(esc)[<0;2;5c")
    var u = cterm("\(esc)[<c")
    #expect(reply(&u) == "\(esc)[<0;2;5c")
}

@Test func ctermFontStateReport() {
    var t = cterm("\(esc)[=1n")
    #expect(reply(&t) == "\(esc)[=1;255;99;0;0;0;0n")
    t.feed(Array("\(esc)[0;0 D\(esc)[=1n".utf8))
    #expect(reply(&t) == "\(esc)[=1;255;0;0;0;0;0n")
    t.feed(Array("\(esc)[0;32 D\(esc)[=1n".utf8))
    #expect(reply(&t) == "\(esc)[=1;255;1;0;0;0;0n")
}

@Test func ctermModeReportAndCellSize() {
    var t = cterm("\(esc)[?33h\(esc)[=2n")
    #expect(reply(&t) == "\(esc)[=2;7;25;33n")
    t.feed(Array("\(esc)[=3n".utf8))
    #expect(reply(&t) == "\(esc)[=3;16;8n")
}

@Test func ctermScreenSizeQuery() {
    var t = cterm("\(esc)[255n")
    #expect(reply(&t) == "\(esc)[25;80R")
}

@Test func ctermDECRQM() {
    var t = cterm("\(esc)[?7$p\(esc)[?33$p\(esc)[?1$p")
    #expect(reply(&t) == "\(esc)[?7;1$y\(esc)[?33;2$y\(esc)[?1;0$y")
    var u = cterm("\(esc)[=255h\(esc)[=255$p")
    #expect(reply(&u) == "\(esc)[=255;1$y")
}

@Test func doorwayModeSendsScanCodes() {
    var t = cterm("\(esc)[=255h")
    #expect(t.bytes(for: .up, backspaceSendsDelete: false) == [0x00, 0x48])
    #expect(t.bytes(for: .function(1), backspaceSendsDelete: false) == [0x00, 0x3B])
    #expect(t.bytes(for: .pageDown, backspaceSendsDelete: false) == [0x00, 0x51])
    #expect(t.bytes(for: .returnKey, backspaceSendsDelete: false) == [0x0D])
    t.feed(Array("\(esc)[=255l".utf8))
    #expect(t.bytes(for: .up, backspaceSendsDelete: false) == [0x1B, 0x5B, 0x41])
}

@Test func ctermSpeedRequest() {
    var t = cterm("\(esc)[0;4*r")
    #expect(t.takeSpeedRequest() == 2400)
    #expect(t.takeSpeedRequest() == nil)
    t.feed(Array("\(esc)[*r".utf8))
    #expect(t.takeSpeedRequest() == 0)
    t.feed(Array("\(esc)[2;4*r".utf8))
    #expect(t.takeSpeedRequest() == nil)
}

@Test func ctermSequencesSplitAcrossFeeds() {
    var t = TerminalEmulator(columns: 80, rows: 25)
    for byte in Array("\(esc)[=1n".utf8) { t.feed([byte]) }
    #expect(reply(&t) == "\(esc)[=1;255;99;0;0;0;0n")
}

@Test func ripQueryIsAnsweredOnlyByTheRIPEngine() {
    var t = cterm("\(esc)[!")
    #expect(reply(&t) == "")
}
