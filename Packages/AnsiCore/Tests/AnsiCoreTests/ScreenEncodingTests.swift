import Foundation
import Testing
@testable import AnsiCore

@Test func utf8OutputKeepsControlBytesAndMapsGlyphs() {
    // ESC [ 1 m, a block, Ctrl-A, CR LF, a box corner.
    let cp437: [UInt8] = [0x1B, 0x5B, 0x31, 0x6D, 0xDB, 0x01, 0x48, 0x0D, 0x0A, 0xC9]
    let utf8 = ScreenEncoding.utf8(fromCP437: cp437)
    #expect(String(decoding: utf8, as: UTF8.self) == "\u{1B}[1m\u{2588}\u{01}H\r\n\u{2554}")
}

@Test func lineEndingsConvertOnlyCRLF() {
    let crlf: [UInt8] = [0x41, 0x0D, 0x0A, 0x42, 0x0D, 0x0A]
    #expect(ScreenEncoding.lineEndings(crlf, .lf) == [0x41, 0x0A, 0x42, 0x0A])
    #expect(ScreenEncoding.lineEndings(crlf, .crlf) == crlf)
    // A CR on its own (an animation's padding) stays.
    #expect(ScreenEncoding.lineEndings([0x0D, 0x0D, 0x41, 0x0D, 0x0A], .lf) == [0x0D, 0x0D, 0x41, 0x0A])
}

@Test func lineEndingLabels() {
    #expect(LineEnding.crlf.label == "CR LF (DOS)")
    #expect(LineEnding.lf.label == "LF (Unix)")
}
