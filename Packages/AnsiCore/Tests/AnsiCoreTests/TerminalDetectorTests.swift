import Foundation
import Testing
@testable import AnsiCore

@Test func detectsPETSCIIClearScreenAndColours() {
    var d = TerminalDetector()
    #expect(d.feed([0x93, 0x05] + Array("WELCOME".utf8) + [0x0D, 0x1C]) == .petscii64)
}

@Test func detectsPETSCIIFromSwappedCaseText() {
    // A Color 64 board's greeting in lower case set PETSCII, seen as ASCII: capitals and small letters swapped.
    var d = TerminalDetector()
    #expect(d.feed(Array("\r\nyOU HAVE CONNECTED TO A\r\n   cOMMODORE 64 uLTIMATE!\r\nwELCOME tO cOMMODORE64bbs.COM!".utf8)) == .petscii64)
}

@Test func ordinaryMixedCaseIsNotPETSCII() {
    var d = TerminalDetector()
    #expect(d.feed(Array("Welcome to the BBS, iPhone and eBay users: Press RETURN to continue.\r\n".utf8)) == nil)
}

@Test func detectsATASCIIWithAFewCarriageReturns() {
    var d = TerminalDetector()
    #expect(d.feed([0x0D] + Array("ATA".utf8) + [0x0D, 0x0D, 0x0A, 0x9B] + Array("Press Return".utf8) + [0x9B]) == .atascii)
}

@Test func detectsATASCIIClearAndEOL() {
    var d = TerminalDetector()
    #expect(d.feed([0x7D] + Array("ATARI BBS".utf8) + [0x9B, 0x9B]) == .atascii)
}

@Test func detectsRIPscrip() {
    var d = TerminalDetector()
    #expect(d.feed(Array("\r\n!|*|c0F|L00001010|#\r\n".utf8)) == .ripscrip)
}

@Test func detectsViewdata() {
    var d = TerminalDetector()
    #expect(d.feed([0x0C, 0x1B, 0x41] + Array("TELSTAR".utf8) + [0x1B, 0x52, 0x7F, 0x1B, 0x43]) == .viewdata)
}

@Test func detectsAvatar() {
    var d = TerminalDetector()
    #expect(d.feed([0x0C, 0x16, 0x01, 0x1F] + Array("Hello".utf8) + [0x16, 0x08, 0x05, 0x05]) == .avatar)
}

@Test func ansiArtIsNotFlagged() {
    var d = TerminalDetector()
    // CP437 art with ESC[ sequences may contain 0x93 or 0x7D; once ANSI is seen nothing is suggested.
    let ansi = Array("\u{1B}[2J\u{1B}[1;33m".utf8) + [0x93, 0x7D, 0x9B, 0xDB, 0xB0] + Array("\u{1B}[0m".utf8)
    #expect(d.feed(ansi) == nil)
    #expect(d.feed([0x93, 0x93, 0x05]) == nil)
}

@Test func plainTextSuggestsNothingAndDetectionStopsAfterTwoKilobytes() {
    var d = TerminalDetector()
    #expect(d.feed(Array("Welcome to my BBS\r\nLogin: ".utf8)) == nil)
    #expect(d.feed([UInt8](repeating: 0x41, count: 3000)) == nil)
    #expect(d.feed([0x93, 0x05, 0x1C, 0x0D]) == nil)
    #expect(d.isFinished)
}

@Test func detectionWorksAcrossFeeds() {
    var d = TerminalDetector()
    #expect(d.feed(Array("!".utf8)) == nil)
    #expect(d.feed(Array("|L00001111".utf8)) == .ripscrip)
}

@Test func suggestionIsGivenOnce() {
    var d = TerminalDetector()
    #expect(d.feed([0x93, 0x05, 0x0D, 0x1C]) == .petscii64)
    #expect(d.feed([0x93, 0x05, 0x0D, 0x1C]) == nil)
}

@Test func vt52IsNotTakenForViewdata() {
    // VT52 commands are ESC and a letter, like Viewdata attributes: a VT52 entry is not offered Viewdata.
    #expect(!TerminalDetector.shouldSuggest(.viewdata, current: .vt52))
    #expect(TerminalDetector.shouldSuggest(.viewdata, current: .ansiBBS))
    #expect(!TerminalDetector.shouldSuggest(.petscii64, current: .petscii128))
    #expect(!TerminalDetector.shouldSuggest(.ansiBBS, current: .ansiBBS))
}
