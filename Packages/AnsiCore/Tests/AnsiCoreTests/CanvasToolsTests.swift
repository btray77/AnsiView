import Foundation
import Testing
@testable import AnsiCore

@Suite struct CanvasToolsTests {
    private let red = Palette.vga[4], blue = Palette.vga[1], yellow = Palette.vga[14]

    /// A 6 x 4 canvas with a wall of '#' in column 3.
    private func walled() -> EditCanvas {
        var canvas = EditCanvas(columns: 6, height: 4)
        for y in 0..<4 { canvas.set(AnsiCell(code: 0x23, fg: yellow, bg: red), x: 3, y: y) }
        return canvas
    }

    @Test func floodFillStopsAtWallsAndIsFourConnected() {
        var canvas = walled()
        let fill = AnsiCell(code: 0xB1, fg: blue, bg: Palette.vga[0])
        let changed = canvas.floodFill(x: 0, y: 0, matchBy: .both, apply: .both, with: fill)
        #expect(changed == 12)
        #expect(canvas[2, 3].code == 0xB1 && canvas[4, 0].code == 0x20 && canvas[3, 0].code == 0x23)
        // Diagonal neighbours are not connected.
        var diagonal = EditCanvas(columns: 3, height: 3)
        diagonal.set(AnsiCell(code: 0x23), x: 1, y: 0)
        diagonal.set(AnsiCell(code: 0x23), x: 0, y: 1)
        #expect(diagonal.floodFill(x: 0, y: 0, matchBy: .both, apply: .character, with: fill) == 1)
    }

    @Test func floodFillMatchModes() {
        var canvas = EditCanvas(columns: 4, height: 1)
        canvas.set(AnsiCell(code: 0x41, fg: yellow, bg: red), x: 0, y: 0)
        canvas.set(AnsiCell(code: 0x42, fg: yellow, bg: red), x: 1, y: 0)
        canvas.set(AnsiCell(code: 0x42, fg: blue, bg: red), x: 2, y: 0)
        var byColour = canvas
        #expect(byColour.floodFill(x: 0, y: 0, matchBy: .colour, apply: .colour, with: AnsiCell(code: 0, fg: blue, bg: blue)) == 2)
        #expect(byColour[1, 0].code == 0x42 && byColour[1, 0].bg == blue && byColour[2, 0].bg == red)
        var byCharacter = canvas
        #expect(byCharacter.floodFill(x: 1, y: 0, matchBy: .character, apply: .character, with: AnsiCell(code: 0x43)) == 2)
        #expect(byCharacter[2, 0].code == 0x43 && byCharacter[2, 0].fg == blue)
        // Filling a region with what it already is changes nothing and terminates.
        var same = canvas
        #expect(same.floodFill(x: 3, y: 0, matchBy: .both, apply: .both, with: AnsiCell()) == 0)
    }

    @Test func floodFillOutsideAndTiny() {
        var canvas = EditCanvas(columns: 1, height: 1)
        #expect(canvas.floodFill(x: 5, y: 5, matchBy: .both, apply: .both, with: AnsiCell(code: 1)) == 0)
        #expect(canvas.floodFill(x: 0, y: 0, matchBy: .both, apply: .both, with: AnsiCell(code: 1)) == 1)
    }

    @Test func globalReplace() {
        var canvas = walled()
        let rect = CellRect(x: 0, y: 0, width: 6, height: 4)
        // Character only: '#' becomes '=' keeping colours.
        #expect(canvas.replace(in: rect, matching: CellPattern(code: 0x23), with: CellPattern(code: 0x3D)) == 4)
        #expect(canvas[3, 1].code == 0x3D && canvas[3, 1].bg == red)
        // Colour only: red backgrounds become blue.
        #expect(canvas.replace(in: rect, matching: CellPattern(bg: red), with: CellPattern(bg: blue)) == 4)
        #expect(canvas[3, 2].bg == blue && canvas[3, 2].fg == yellow)
        // Inside a selection only.
        #expect(canvas.replace(in: CellRect(x: 3, y: 0, width: 1, height: 2), matching: CellPattern(code: 0x3D),
                               with: CellPattern(code: 0x2A, fg: red)) == 2)
        #expect(canvas[3, 2].code == 0x3D && canvas[3, 0].code == 0x2A && canvas[3, 0].fg == red)
    }

    @Test func swapCellColours() {
        var canvas = walled()
        canvas.setIceColors(true)
        canvas.swapColours(in: CellRect(x: 3, y: 0, width: 1, height: 1))
        #expect(canvas[3, 0].fg == red && canvas[3, 0].bg == yellow)
        // iCE off: a bright foreground becomes the dark background, blink cleared.
        var plain = EditCanvas(columns: 2, height: 1)
        plain.set(AnsiCell(code: 0x41, fg: yellow, bg: blue), x: 0, y: 0)
        plain.swapColours(in: CellRect(x: 0, y: 0, width: 1, height: 1))
        #expect(plain[0, 0].bg == Palette.vga[6] && plain[0, 0].fg == blue)
    }

    @Test func insertAndDeleteCells() {
        var canvas = EditCanvas(columns: 5, height: 1)
        for (x, c) in "ABCDE".unicodeScalars.enumerated() { canvas.set(AnsiCell(code: UInt8(c.value)), x: x, y: 0) }
        canvas.insertCell(x: 1, y: 0, blank: AnsiCell(code: 0x2E))
        #expect(rowText(canvas, 0) == "A.BCD")
        canvas.deleteCell(x: 0, y: 0)
        #expect(rowText(canvas, 0) == ".BCD ")
    }

    @Test func insertAndDeleteRowsAndColumns() {
        var canvas = EditCanvas(columns: 3, height: 3)
        for y in 0..<3 { for x in 0..<3 { canvas.set(AnsiCell(code: UInt8(0x41 + y * 3 + x)), x: x, y: y) } }
        canvas.insertRow(at: 1)
        #expect(canvas.height == 4 && rowText(canvas, 1) == "   " && rowText(canvas, 2) == "DEF")
        canvas.deleteRow(at: 1)
        #expect(canvas.height == 3 && rowText(canvas, 1) == "DEF")
        canvas.insertColumn(at: 0)
        #expect(rowText(canvas, 0) == " AB" && canvas.columns == 3)
        canvas.deleteColumn(at: 0)
        #expect(rowText(canvas, 0) == "AB ")
        var single = EditCanvas(columns: 2, height: 1)
        single.deleteRow(at: 0)
        #expect(single.height == 1)
    }

    private func rowText(_ canvas: EditCanvas, _ y: Int) -> String {
        String((0..<canvas.columns).map { Character(CP437.unicode[Int(canvas[$0, y].code)]) })
    }
}

@Suite struct CharacterPickerTests {
    @Test func namesForEveryCode() {
        for code in 0...255 {
            let info = CharacterInfo(code: UInt8(code))
            #expect(!info.name.isEmpty)
            #expect(info.summary.contains("\(code)"))
        }
        #expect(CharacterInfo(code: 0xB0).name == "LIGHT SHADE")
        #expect(CharacterInfo(code: 0xC9).summary == "201 (0xC9)  U+2554  BOX DRAWINGS DOUBLE DOWN AND RIGHT")
        #expect(CharacterInfo(code: 0x01).name == "WHITE SMILING FACE")
    }

    @Test func recentlyUsedIsNewestFirstWithoutDuplicates() {
        var history = CharacterHistory()
        for code: UInt8 in [1, 2, 3, 2] { history.use(code) }
        #expect(history.recent == [2, 3, 1])
        for code in 10...40 { history.use(UInt8(code)) }
        #expect(history.recent.count == CharacterHistory.recentLimit && history.recent.first == 40)
    }

    @Test func favouritesToggleAndPersist() throws {
        var history = CharacterHistory()
        history.toggleFavourite(219)
        history.toggleFavourite(176)
        history.toggleFavourite(219)
        #expect(history.favourites == [176])
        #expect(history.isFavourite(176) && !history.isFavourite(219))
        history.use(5)
        let restored = CharacterHistory(plist: history.plist)
        #expect(restored == history)
        #expect(CharacterHistory(plist: ["recent": "nonsense"]) == CharacterHistory())
    }
}
