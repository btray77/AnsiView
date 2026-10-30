import Testing
@testable import AnsiCore

// MARK: BBC modes 0-6

private func mode7(_ bytes: [UInt8]) -> TeletextTerminal {
    var t = TeletextTerminal(flavour: .mode7)
    t.feed(bytes)
    return t
}

@Test func vdu22ChangesTheTextGrid() {
    #expect(mode7([22, 1]).columns == 40 && mode7([22, 1]).rows == 32)
    #expect(mode7([22, 0]).columns == 80 && mode7([22, 0]).rows == 32)
    #expect(mode7([22, 2]).columns == 20)
    #expect(mode7([22, 3]).columns == 80 && mode7([22, 3]).rows == 25)
    let back = mode7([22, 1, 22, 7])
    #expect(back.columns == 40 && back.rows == 25 && back.bbcMode == 7)
    #expect(mode7([22, 1]).overlay() != nil && mode7([22, 3]).overlay() == nil)
}

@Test func bitmapModesPrintPlainColouredText() {
    // Mode 1, COLOUR 1 (red); "#" prints as # (the teletext swap is Mode 7 only).
    let t = mode7([22, 1, 17, 1] + Array("A#".utf8))
    let row = t.screen(scrollOffset: 0).rows[0]
    #expect(row[0].code == UInt8(ascii: "A") && row[0].fg == BBCGraphics.colours[1])
    #expect(row[1].code == UInt8(ascii: "#"))
}

@Test func plotDrawsLinesPointsAndTriangles() {
    func plot(_ k: UInt8, _ x: Int, _ y: Int) -> [UInt8] {
        [25, k, UInt8(x & 0xFF), UInt8(x >> 8), UInt8(y & 0xFF), UInt8(y >> 8)]
    }
    // Mode 1 is 320x256: logical x / 4, y / 4 from the bottom.
    var t = mode7([22, 1] + plot(4, 0, 0) + plot(5, 1276, 0))
    #expect(t.graphicsPixel(0, 255) == 7 && t.graphicsPixel(160, 255) == 7 && t.graphicsPixel(160, 254) == 0)
    t.feed([18, 0, 2] + plot(69, 400, 400))      // GCOL 0,2 (yellow); point
    #expect(t.graphicsPixel(100, 155) == 3)
    t.feed([18, 0, 1] + plot(4, 0, 512) + plot(4, 400, 512) + plot(85, 200, 800))
    #expect(t.graphicsPixel(50, 100) == 1)       // inside the triangle
    t.feed([16])                                // CLG
    #expect(t.graphicsPixel(50, 100) == 0)
}

// MARK: C128

@Test func c128UnderlineUsesUnderlinedGlyphs() {
    var t = PETSCIITerminal(model: .c128, columns: 80, rows: 25)
    t.feed([0x02, 0x41, 0x82, 0x41])
    let row = t.screen(scrollOffset: 0).rows[0]
    let underlined = Int(row[0].glyph ?? 0), plain = Int(row[1].glyph ?? 0)
    #expect(underlined == plain + 256)
    let pixels = PlatformFonts.petscii.pixels(glyph: underlined)
    #expect(pixels.suffix(8).allSatisfy { $0 })
    var c64 = PETSCIITerminal(model: .c64)
    c64.feed([0x02, 0x41])
    #expect(c64.screen(scrollOffset: 0).rows[0][0].glyph == row[1].glyph)
}

@Test func c128EscapeSequencesEdit() {
    var t = PETSCIITerminal(model: .c128, columns: 80, rows: 25)
    t.feed(Array("123456".utf8) + [0x9D, 0x9D, 0x9D, 0x1B, 0x51])   // ESC Q: erase to end of line
    #expect(String(decoding: t.screen(scrollOffset: 0).rows[0].prefix(6).map(\.code), as: UTF8.self) == "123   ")
    t.feed([0x1B, 0x4A])                                        // ESC J: start of line
    #expect(t.cursor.column == 0)
    t.feed([0x1B, 0x4B])                                        // ESC K: end of line text
    #expect(t.cursor.column == 3)
    t.feed([0x0D] + Array("789".utf8) + [0x91, 0x1B, 0x44])     // up, ESC D: delete line
    #expect(String(decoding: t.screen(scrollOffset: 0).rows[0].prefix(3).map(\.code), as: UTF8.self) == "789")
    t.feed([0x1B, 0x49])                                        // ESC I: insert line
    #expect(t.screen(scrollOffset: 0).rows[1].prefix(3).map(\.code) == Array("789".utf8))
    t.feed([0x1B, 0x40])                                        // ESC @: clear to end of screen
    #expect(t.screen(scrollOffset: 0).rows[1][0].code == 0x20)
}

// MARK: Apple II MouseText

@Test func mouseTextShowsPictures() {
    var t = AppleIITerminal(columns: 80, rows: 24)
    t.feed([0x0F, 0x1B, 0x40, 0x18, 0x40])   // inverse, MouseText on, @, MouseText off, @
    let row = t.screen(scrollOffset: 0).rows[0]
    #expect(row[0].glyph == 128)             // MouseText 0x40 (closed apple)
    #expect(row[1].glyph == 0x40)            // inverse @
    #expect(PlatformFonts.appleII.glyphCount == 160)
    #expect(PlatformFonts.appleII.pixels(glyph: 128 + 0x0E).allSatisfy { $0 })   // solid block
}

// MARK: ATASCII

@Test func atasciiInverseTyping() {
    var t = ATASCIITerminal()
    #expect(t.text("Ab", encoding: .cp437) == [0x41, 0x62])
    t.inverseTyping = true
    #expect(t.text("Ab\r", encoding: .cp437) == [0xC1, 0xE2, 0x9B])
}

// MARK: Avatar

@Test func avatarFillKeepsAutowrapOff() {
    var t = AvatarTerminal(columns: 80, rows: 25)
    t.feed(Array("\u{1B}[?7l".utf8) + [0x16, 0x0C, 0x1F, 1, 1] + [UInt8](repeating: 0x41, count: 85))
    #expect(t.cursor.row == 0)
}

@Test func avatarClearScreenStoresItsAttribute() {
    var t = AvatarTerminal(columns: 80, rows: 25)
    t.feed([0x16, 0x01, 0x1E, 0x0C, 0x16, 0x02, 0x58])
    let cell = t.screen(scrollOffset: 0).rows[0][0]
    #expect(cell.fg == Palette.vga[3])
}

// MARK: Amiga

@Test func amigaShowsDarkYellowNotBrown() {
    var t = TerminalEmulator(columns: 80, rows: 25)
    t.profile = .amiga
    t.feed(Array("\u{1B}[33mY".utf8))
    #expect(t.screen(scrollOffset: 0).rows[0][0].fg == RGB(r: 0xAA, g: 0xAA, b: 0x00))
    var pc = TerminalEmulator(columns: 80, rows: 25)
    pc.feed(Array("\u{1B}[33mY".utf8))
    #expect(pc.screen(scrollOffset: 0).rows[0][0].fg == Palette.vga[6])
}
