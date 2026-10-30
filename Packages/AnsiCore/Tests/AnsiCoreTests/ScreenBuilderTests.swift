import Foundation
import Testing
@testable import AnsiCore

@Test func builderWritesTextInCP437AndColours() {
    var b = ScreenBuilder(columns: 20, rows: 3)
    let next = b.text("A\u{2591}", x: 1, y: 1, fg: 14, bg: 1)
    #expect(next == 3)
    #expect(b.canvas[1, 1].code == 0x41)
    #expect(b.canvas[2, 1].code == 0xB0)
    #expect(b.canvas[1, 1].fg == Palette.vga[14] && b.canvas[1, 1].bg == Palette.vga[1])
}

@Test func builderCentresAndDrawsHotkeys() {
    var b = ScreenBuilder(columns: 11, rows: 2)
    b.centred("abc", y: 0, fg: 7)
    #expect(b.canvas[4, 0].code == 0x61)
    let end = b.hotkey("Q", "Quit", x: 0, y: 1)
    #expect(end == 8)
    #expect(b.canvas[0, 1].code == 0x5B && b.canvas[0, 1].fg == Palette.vga[8])
    #expect(b.canvas[1, 1].code == 0x51 && b.canvas[1, 1].fg == Palette.vga[15])
}

@Test func builderBoxUsesBoxToolCharactersAndTitle() {
    var b = ScreenBuilder(columns: 12, rows: 4)
    b.box(CellRect(x: 0, y: 0, width: 12, height: 4), style: .line(.double), fg: 9, title: "Hi")
    #expect(b.canvas[0, 0].code == 0xC9)
    #expect(b.canvas[11, 3].code == 0xBC)
    #expect(b.canvas[5, 0].code == 0x48)
}

@Test func builderGradientRampsUpAndDown() {
    var b = ScreenBuilder(columns: 8, rows: 1)
    b.gradientBar(x: 0, y: 0, length: 8, fg: 4)
    #expect((0..<8).map { b.canvas[$0, 0].code } == [0xB0, 0xB1, 0xB2, 0xDB, 0xDB, 0xB2, 0xB1, 0xB0])
}
