import Foundation
import Testing
@testable import AnsiCore

/// Bytes for a string, with "\u{1B}" written as ESC.
func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

func parse(_ raw: [UInt8]) -> AnsiScreen { AnsiParser.parse(Data(raw)) }

/// A 128 byte SAUCE record for a character file of the given width.
func sauceRecord(width: UInt16, flags: UInt8 = 0, fileSize: Int = 0) -> [UInt8] {
    var record = bytes("SAUCE00")
    record += [UInt8](repeating: 0x20, count: 35 + 20 + 20)
    record += bytes("20261030")
    record += withUnsafeBytes(of: UInt32(fileSize).littleEndian, Array.init)
    record += [1, 1]
    record += withUnsafeBytes(of: width.littleEndian, Array.init)
    record += [0, 0, 0, 0, 0, 0]
    record += [0, flags]
    record += [UInt8](repeating: 0, count: 22)
    return record
}

@Test func plainTextWrapsAt80() {
    let s = parse([UInt8](repeating: 0x41, count: 81))
    #expect(s.rows.count == 2)
    #expect(s.rows[1][0].code == 0x41)
}

@Test func exactly80ThenCRLFDoesNotAddBlankLine() {
    let s = parse([UInt8](repeating: 0x41, count: 80) + bytes("\r\nB"))
    #expect(s.rows.count == 2)
    #expect(s.rows[1][0].code == 0x42)
}

@Test func saveRestoreRestoresRowAndColumn() {
    let s = parse(bytes("AB\u{1B}[s\r\n\u{1B}[uC"))
    #expect(s.rows[0][2].code == 0x43)
}

@Test func boldGivesBrightForeground() {
    let s = parse(bytes("\u{1B}[1;31mX"))
    #expect(s.rows[0][0].fg == 12)
}

@Test func cursorPositionIsOneBased() {
    let s = parse(bytes("\u{1B}[3;5HX"))
    #expect(s.rows[2][4].code == 0x58)
}

@Test func clearScreenCountsAsAnimationOnlyAfterDrawing() {
    var first = AnsiTerminal(AnsiSource(data: Data(bytes("\u{1B}[2JHello"))))
    first.runToEnd()
    #expect(first.clearsAfterDrawing == 0)
    var second = AnsiTerminal(AnsiSource(data: Data(bytes("Hello\u{1B}[2JWorld"))))
    second.runToEnd()
    #expect(second.clearsAfterDrawing == 1)
}

@Test func truncatedEscapeAtEndIsIgnored() {
    let s = parse(bytes("AB\u{1B}["))
    #expect(s.rows[0][1].code == 0x42)
}

@Test func hugeParametersDoNotCrash() {
    let s = parse(bytes("\u{1B}[99999CX\u{1B}[999999999mY\u{1B}[999999;999999HZ\u{1B}[9999999999999999999999999CW"))
    #expect(s.rows.count <= AnsiTerminal.maxRows)
}

@Test func sauceWidthIsHonoured() {
    let s = parse([UInt8](repeating: 0x41, count: 10) + [0x1A] + sauceRecord(width: 5))
    #expect(s.columns == 5)
    #expect(s.rows.count == 2)
}
