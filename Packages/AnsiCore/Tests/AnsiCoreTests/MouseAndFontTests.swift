import Foundation
import Testing
@testable import AnsiCore

private func term(_ text: String) -> TerminalEmulator {
    var t = TerminalEmulator(columns: 80, rows: 25)
    t.feed(Array(text.utf8))
    return t
}

@Test func mouseIsSilentUntilAsked() {
    var t = term("")
    #expect(t.mouse(column: 0, row: 0, button: 0, pressed: true) == [])
}

@Test func normalTrackingReportsPressAndRelease() {
    var t = term("\u{1B}[?1000h")
    #expect(t.mouse(column: 4, row: 2, button: 0, pressed: true) == [0x1B, 0x5B, 0x4D, 32, 37, 35] as [UInt8])
    #expect(t.mouse(column: 4, row: 2, button: 0, pressed: false) == [0x1B, 0x5B, 0x4D, 35, 37, 35] as [UInt8])
    t.feed(Array("\u{1B}[?1000l".utf8))
    #expect(t.mouse(column: 4, row: 2, button: 0, pressed: true) == [])
}

@Test func x10ReportsPressesOnly() {
    var t = term("\u{1B}[?9h")
    #expect(t.mouse(column: 0, row: 0, button: 2, pressed: true) == [0x1B, 0x5B, 0x4D, 34, 33, 33] as [UInt8])
    #expect(t.mouse(column: 0, row: 0, button: 2, pressed: false) == [])
}

@Test func sgrMouseReports() {
    var t = term("\u{1B}[?1000h\u{1B}[?1006h")
    #expect(t.mouse(column: 9, row: 4, button: 0, pressed: true) == Array("\u{1B}[<0;10;5M".utf8))
    #expect(t.mouse(column: 9, row: 4, button: 0, pressed: false) == Array("\u{1B}[<0;10;5m".utf8))
    // Far columns stay exact in SGR; the old encoding stops at 223.
    var wide = TerminalEmulator(columns: 255, rows: 25)
    wide.feed(Array("\u{1B}[?1000h".utf8))
    #expect(wide.mouse(column: 250, row: 0, button: 0, pressed: true) == [])
}

@Test func ctermLoadableFontIsSelected() {
    var glyphs = [UInt8](repeating: 0, count: 4096)
    for row in 0..<16 { glyphs[0x41 * 16 + row] = 0xFF }   // a solid "A"
    let b64 = Data(glyphs).base64EncodedString()
    var t = term("\u{1B}PCTerm:Font:43:\(b64)\u{1B}\\")
    #expect(t.font == nil)
    t.feed(Array("\u{1B}[0;43 D\u{1B}[=1n".utf8))
    #expect(t.font?.height == 16)
    #expect(t.font?.pixels(for: 0x41).allSatisfy { $0 } == true)
    #expect(String(decoding: t.takeReplies(), as: UTF8.self) == "\u{1B}[=1;255;0;0;0;0;0n")
    // Back to the default font.
    t.feed(Array("\u{1B}[0;0 D".utf8))
    #expect(t.font == nil)
    // A slot that holds no font fails; sizes other than 8x8, 8x14 and 8x16 are refused.
    t.feed(Array("\u{1B}PCTerm:Font:44:\(Data([1, 2, 3]).base64EncodedString())\u{1B}\\\u{1B}[0;44 D".utf8))
    #expect(t.font == nil)
}

@Test func loadedFontsSurviveTheImageCapture() {
    // A CTerm font string is a DCS too: it must not be taken for a sixel picture.
    let b64 = Data([UInt8](repeating: 0, count: 2048)).base64EncodedString()
    let t = term("\u{1B}PCTerm:Font:50:\(b64)\u{1B}\\")
    #expect(t.images(scrollOffset: 0).isEmpty)
}
