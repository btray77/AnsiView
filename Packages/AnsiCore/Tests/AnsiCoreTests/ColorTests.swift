import Foundation
import Testing
@testable import AnsiCore

private func firstCell(_ text: String) -> AnsiCell { parse(bytes(text)).rows[0][0] }

@Test func classicColorsMapToVGA() {
    #expect(firstCell("\u{1B}[1;34mX").fg == Palette.vga[9])
}

@Test func xterm256Foreground() {
    #expect(firstCell("\u{1B}[38;5;196mX").fg == RGB(r: 255, g: 0, b: 0))
}

@Test func xterm256Grey() {
    #expect(firstCell("\u{1B}[48;5;232mX").bg == RGB(r: 8, g: 8, b: 8))
}

@Test func xterm256LowIndexesAreVGA() {
    #expect(firstCell("\u{1B}[38;5;9mX").fg == Palette.vga[12])
}

@Test func truecolorForegroundAndBackground() {
    let cell = firstCell("\u{1B}[38;2;1;2;3;48;2;4;5;6mX")
    #expect(cell.fg == RGB(r: 1, g: 2, b: 3))
    #expect(cell.bg == RGB(r: 4, g: 5, b: 6))
}

@Test func pabloDrawTrueColor() {
    let row = parse(bytes("\u{1B}[1;10;20;30tX\u{1B}[0;40;50;60tY")).rows[0]
    #expect(row[0].fg == RGB(r: 10, g: 20, b: 30))
    #expect(row[1].bg == RGB(r: 40, g: 50, b: 60))
}

@Test func boldDoesNotBrightenTrueColor() {
    #expect(firstCell("\u{1B}[1m\u{1B}[38;2;10;10;10mX").fg == RGB(r: 10, g: 10, b: 10))
}

@Test func resetRestoresVGADefaults() {
    let cell = firstCell("\u{1B}[38;5;196;48;5;21m\u{1B}[0mX")
    #expect(cell.fg == Palette.vga[7])
    #expect(cell.bg == Palette.vga[0])
}

@Test func malformedExtendedColorIsIgnored() {
    #expect(firstCell("\u{1B}[38;2;1mX").fg == Palette.vga[7])
}
