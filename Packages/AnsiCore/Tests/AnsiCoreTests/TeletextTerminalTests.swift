import Foundation
import Testing
@testable import AnsiCore

private let esc: UInt8 = 0x1B

private func viewdata(_ bytes: [UInt8]) -> TeletextTerminal {
    var t = TeletextTerminal(flavour: .viewdata)
    t.feed(bytes)
    return t
}

private func cells(_ t: TeletextTerminal, _ r: Int) -> [AnsiCell] { t.screen(scrollOffset: 0).rows[r] }

@Test func viewdataAlphaColourIsSetAfter() {
    let t = viewdata([esc, 0x41, 0x48, 0x49])
    let row = cells(t, 0)
    #expect(row[0].glyph == UInt16(TeletextGlyphs.alpha(0x20)))
    #expect(row[0].fg == TeletextTerminal.colours[7])
    #expect(row[1].fg == TeletextTerminal.colours[1] && row[1].code == 0x48)
    #expect(t.columns == 40 && t.rows == 24)
}

@Test func viewdataRawHighBitAttributes() {
    let t = viewdata([0x82, 0x41])
    #expect(cells(t, 0)[1].fg == TeletextTerminal.colours[2])
}

@Test func viewdataUKCharacterSet() {
    let t = viewdata([0x23, 0x5F])
    #expect(cells(t, 0)[0].code == 0x9C)
    #expect(cells(t, 0)[1].code == 0x23)
}

@Test func mosaicsContiguousAndSeparated() {
    let t = viewdata([esc, 0x52, 0x7F, esc, 0x5A, 0x7F, 0x41])
    let row = cells(t, 0)
    #expect(row[1].glyph == UInt16(TeletextGlyphs.mosaic(0x7F, separated: false)))
    #expect(row[1].fg == TeletextTerminal.colours[2])
    // Separated is set-at: the control cell shows a space, the next mosaic is separated.
    #expect(row[3].glyph == UInt16(TeletextGlyphs.mosaic(0x7F, separated: true)))
    // Capital letters stay letters in mosaic mode.
    #expect(row[4].glyph == UInt16(TeletextGlyphs.alpha(0x41)))
}

@Test func holdMosaicsFillControlCells() {
    let t = viewdata([esc, 0x51, 0x35, esc, 0x5E, esc, 0x52])
    let row = cells(t, 0)
    // Hold is set-at, so the hold cell and the colour change cell repeat the last mosaic.
    #expect(row[2].glyph == UInt16(TeletextGlyphs.mosaic(0x35, separated: false)))
    #expect(row[3].glyph == UInt16(TeletextGlyphs.mosaic(0x35, separated: false)))
}

@Test func attributesResetEachRow() {
    let t = viewdata([esc, 0x41, 0x41, 0x0D, 0x0A, 0x42])
    #expect(cells(t, 1)[0].fg == TeletextTerminal.colours[7])
}

@Test func doubleHeightShowsBottomHalvesBelow() {
    let t = viewdata([esc, 0x4D, 0x48, 0x0D, 0x0A, 0x58, 0x58])
    let top = cells(t, 0), bottom = cells(t, 1)
    #expect(top[1].glyph == UInt16(TeletextGlyphs.doubleTop(TeletextGlyphs.alpha(0x48))))
    #expect(bottom[1].glyph == UInt16(TeletextGlyphs.doubleBottom(TeletextGlyphs.alpha(0x48))))
    // The row under a double height row does not show its own text.
    #expect(bottom[2].code == 0x20)
}

@Test func concealHidesUntilReveal() {
    var t = viewdata([esc, 0x58, 0x41])
    #expect(cells(t, 0)[1].code == 0x20)
    t.reveal = true
    #expect(cells(t, 0)[1].code == 0x41)
}

@Test func flashBlinks() {
    let t = viewdata([esc, 0x48, 0x41, esc, 0x49, 0x42])
    #expect(cells(t, 0)[1].blink)
    #expect(!cells(t, 0)[3].blink)
}

@Test func backgroundCodes() {
    let t = viewdata([esc, 0x44, esc, 0x5D, 0x41, esc, 0x5C, 0x42])
    let row = cells(t, 0)
    #expect(row[2].bg == TeletextTerminal.colours[4])
    #expect(row[4].bg == TeletextTerminal.colours[0])
}

@Test func viewdataCursorWraps() {
    var t = viewdata([0x0B, 0x41])
    #expect(cells(t, 23)[0].code == 0x41)
    t.feed([0x1E, 0x08, 0x42])
    #expect(cells(t, 23)[39].code == 0x42)
    t.feed([0x0C])
    #expect(cells(t, 23)[39].code == 0x20 && t.cursor.row == 0 && t.cursor.column == 0)
}

@Test func viewdataEscapeSplitAcrossFeeds() {
    var t = TeletextTerminal(flavour: .viewdata)
    t.feed([esc])
    t.feed([0x41, 0x41])
    #expect(cells(t, 0)[1].fg == TeletextTerminal.colours[1])
}

@Test func viewdataKeys() {
    let t = TeletextTerminal(flavour: .viewdata)
    #expect(t.bytes(for: .returnKey, backspaceSendsDelete: false) == [0x5F])
    #expect(t.text("*12#", encoding: .cp437) == [0x2A, 0x31, 0x32, 0x5F])
    #expect(t.bytes(for: .left, backspaceSendsDelete: false) == [0x08])
    #expect(t.bytes(for: .home, backspaceSendsDelete: false) == [0x1E])
}

@Test func mode7UsesBBCControlCodes() {
    var t = TeletextTerminal(flavour: .mode7)
    t.feed([0x1F, 5, 3, 0x81, 0x41, 0x0D, 0x0A, 0x23, 0x60])
    let rows = t.screen(scrollOffset: 0).rows
    #expect(rows[3][6].fg == TeletextTerminal.colours[1])
    #expect(rows[4][0].glyph == UInt16(TeletextGlyphs.alpha(0x5F)))
    #expect(rows[4][1].code == 0x9C)
    #expect(t.rows == 25)
    #expect(t.bytes(for: .up, backspaceSendsDelete: false) == [0x8B])
    #expect(t.bytes(for: .backspace, backspaceSendsDelete: false) == [0x7F])
}

@Test func mode7ScrollsAtTheBottom() {
    var t = TeletextTerminal(flavour: .mode7)
    t.feed([UInt8](repeating: 0x0A, count: 24) + [0x41, 0x0A])
    #expect(t.screen(scrollOffset: 0).rows[23][0].code == 0x41)
}

@Test func teletextRandomBytesStayInBounds() {
    for flavour in [TeletextTerminal.Flavour.viewdata, .mode7] {
        var t = TeletextTerminal(flavour: flavour)
        var state: UInt64 = 11
        for _ in 0..<50_000 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            t.feed([UInt8(truncatingIfNeeded: state >> 33)])
        }
        #expect(t.screen(scrollOffset: 0).rows.count == t.rows)
    }
}
