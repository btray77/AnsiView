import Foundation
import Testing
@testable import AnsiCore

private func reparse(_ text: String) -> AnsiScreen {
    AnsiAnalysis(ArtFile(data: Data(text.utf8), fileExtension: "ans")).finalScreen
}

/// NUL cells display as spaces; the conversions write them as spaces.
private func normalised(_ screen: AnsiScreen) -> [[AnsiCell]] {
    var rows = screen.rows.map { row in
        row.map { cell -> AnsiCell in
            var c = cell
            if c.code == 0 { c.code = 0x20 }
            return c
        }
    }
    while let last = rows.last, last.allSatisfy({ $0 == AnsiCell() }) { rows.removeLast() }
    return rows
}

/// An 80 column screen with VGA colours, an RGB colour, blink, block, box and control code glyphs.
private func sampleScreen(rgb: Bool) -> AnsiScreen {
    let blank = AnsiCell()
    var row0 = Array(repeating: blank, count: 80)
    row0[0] = AnsiCell(code: 0xDB, fg: Palette.vga[12], bg: Palette.vga[1])
    row0[1] = AnsiCell(code: 0x01, fg: Palette.vga[14], bg: Palette.vga[0], blink: true)
    row0[2] = AnsiCell(code: 0xC4, fg: Palette.vga[7], bg: Palette.vga[4])
    row0[3] = AnsiCell(code: 0x1B, fg: Palette.vga[10], bg: Palette.vga[0])
    row0[4] = AnsiCell(code: UInt8(ascii: "<"), fg: Palette.vga[7], bg: Palette.vga[0])
    row0[5] = AnsiCell(code: 0x20, fg: Palette.vga[7], bg: Palette.vga[2])
    if rgb { row0[6] = AnsiCell(code: UInt8(ascii: "X"), fg: RGB(r: 250, g: 1, b: 2), bg: RGB(r: 3, g: 40, b: 99)) }
    // A full row: the last column is written, then the line ends.
    let row1: [AnsiCell] = (0..<80).map { (i: Int) -> AnsiCell in
        let code = UInt8(0x41 + i % 26)
        return AnsiCell(code: code, fg: Palette.vga[i % 16], bg: Palette.vga[15 - i % 16])
    }
    let row2 = Array(repeating: blank, count: 80)
    var row3 = Array(repeating: blank, count: 80)
    row3[10] = AnsiCell(code: 0x00, fg: Palette.vga[7], bg: Palette.vga[0])
    row3[11] = AnsiCell(code: 0xB1, fg: Palette.vga[9], bg: Palette.vga[0])
    return AnsiScreen(columns: 80, rows: [row0, row1, row2, row3])
}

@Test func trueColorRoundTrips() {
    let screen = sampleScreen(rgb: true)
    let back = reparse(TextConvert.modernANSI(screen, colors: .trueColor))
    #expect(normalised(back) == normalised(screen))
}

@Test func xterm256RoundTripsVGA() {
    let screen = sampleScreen(rgb: false)
    let back = reparse(TextConvert.modernANSI(screen, colors: .xterm256))
    #expect(normalised(back) == normalised(screen))
}

@Test func xterm256NearestForOthers() {
    #expect(TextConvert.nearestXterm(RGB(r: 250, g: 0, b: 0)) == 196)
    #expect(TextConvert.nearestXterm(RGB(r: 128, g: 128, b: 128)) == 244)
    let text = TextConvert.modernANSI(AnsiScreen(columns: 1, rows: [[AnsiCell(code: 0x41, fg: RGB(r: 250, g: 0, b: 0))]]),
                                      colors: .xterm256)
    #expect(text.contains("38;5;196"))
}

@Test func utf8RoundTripKeepsScalars() {
    var row = [AnsiCell(code: 0x3F, scalar: "→"), AnsiCell(code: 0x3F, scalar: "😀")]
    row += Array(repeating: AnsiCell(), count: 78)
    // "→" has a CP437 code, so the terminal stores it as that code; a scalar it lacks stays a scalar.
    let screen = AnsiScreen(columns: 80, rows: [row])
    let back = reparse(TextConvert.modernANSI(screen, colors: .trueColor))
    #expect(back.rows[0][0].code == 0x1A)
    #expect(back.rows[0][1].scalar == "😀")
}

@Test func noCursorMovement() {
    let text = TextConvert.modernANSI(sampleScreen(rgb: true), colors: .trueColor)
    #expect(text.range(of: "\u{1B}\\[[0-9;]*[ABCDHJKfsu]", options: .regularExpression) == nil)
    for scalar in text.unicodeScalars where scalar.value < 0x20 {
        #expect(scalar == "\u{1B}" || scalar == "\n")
    }
    // One line per row, each ending with a reset when colours are in effect.
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    #expect(lines.count == 5) // 4 rows and the empty string after the last newline
    #expect(lines[0].hasSuffix("\u{1B}[0m"))
}

@Test func trailingDefaultsTrimmed() {
    var row = Array(repeating: AnsiCell(), count: 80)
    row[0] = AnsiCell(code: 0x41)
    let screen = AnsiScreen(columns: 80, rows: [row, Array(repeating: AnsiCell(), count: 80)])
    #expect(TextConvert.modernANSI(screen, colors: .trueColor) == "A\n")
}

@Test func cp437TextRoundTripsCharacters() {
    var row = Array(repeating: AnsiCell(), count: 80)
    for (i, code) in [0xDB, 0xB0, 0xC9, 0x41, 0x01, 0x7F, 0xFE].enumerated() { row[i].code = UInt8(code) }
    let screen = AnsiScreen(columns: 80, rows: [row, row])
    let bytes = TextConvert.cp437Text(screen)
    #expect(!bytes.contains(0x1B))
    let back = AnsiAnalysis(ArtFile(data: Data(bytes), fileExtension: "ans")).finalScreen
    #expect(back.rows.map { $0.map(\.code) } == screen.rows.map { $0.map(\.code) })
    #expect(Array(bytes.suffix(2)) == [0x0D, 0x0A])
}

@Test func cp437ControlLookalikes() {
    let codes: [UInt8] = [0x00, 0x07, 0x08, 0x09, 0x0A, 0x0D, 0x1A, 0x1B, 0x41]
    let screen = AnsiScreen(columns: codes.count, rows: [codes.map { AnsiCell(code: $0) }])
    #expect(TextConvert.cp437Text(screen) == [0x20, 0xF9, 0xDB, 0x6F, 0xDB, 0x0E, 0x3E, 0x3C, 0x41, 0x0D, 0x0A])
}

@Test func utf8TextMapsGlyphs() {
    let row = [AnsiCell(code: 0xDB), AnsiCell(code: 0x01), AnsiCell(code: 0x00), AnsiCell(code: 0x41),
               AnsiCell(code: 0x3F, scalar: "😀"), AnsiCell(), AnsiCell()]
    let screen = AnsiScreen(columns: row.count, rows: [row, row])
    #expect(TextConvert.utf8Text(screen) == "█☺ A😀\n█☺ A😀\n")
}
