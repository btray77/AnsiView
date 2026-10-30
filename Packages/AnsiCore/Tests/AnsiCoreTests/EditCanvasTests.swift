import Foundation
import Testing
@testable import AnsiCore

@Suite struct EditCanvasTests {
    @Test func newCanvasIs80x25Blank() {
        let canvas = EditCanvas()
        #expect(canvas.columns == 80)
        #expect(canvas.height == 25)
        #expect(canvas.rows.allSatisfy { $0.count == 80 && $0.allSatisfy { $0 == AnsiCell() } })
        #expect(canvas.iceColors == false)
        #expect(canvas.fontName == "IBM VGA")
    }

    @Test func setGrowsHeightAndIgnoresOutside() {
        var canvas = EditCanvas()
        let cell = AnsiCell(code: 0x41, fg: Palette.vga[14], bg: Palette.vga[1])
        canvas.set(cell, x: 3, y: 30)
        #expect(canvas.height == 31)
        #expect(canvas[3, 30] == cell)
        let before = canvas
        canvas.set(cell, x: 80, y: 0)
        canvas.set(cell, x: 0, y: -1)
        canvas.set(cell, x: -1, y: 0)
        #expect(canvas == before)
        #expect(canvas[200, 200] == AnsiCell())
    }

    @Test func heightStopsAtTerminalLimit() {
        var canvas = EditCanvas()
        canvas.set(AnsiCell(code: 0x41), x: 0, y: AnsiTerminal.maxRows + 5)
        #expect(canvas.height == 25)
        canvas.ensureHeight(5000)
        #expect(canvas.height == AnsiTerminal.maxRows)
    }

    @Test func resizeKeepsCellsAndClamps() {
        var canvas = EditCanvas()
        let cell = AnsiCell(code: 0x42, fg: Palette.vga[2], bg: Palette.vga[0])
        canvas.set(cell, x: 79, y: 0)
        canvas.set(cell, x: 5, y: 0)
        canvas.resize(columns: 1200, height: 25)
        #expect(canvas.columns == 1000)
        #expect(canvas[79, 0] == cell)
        #expect(canvas.rows.allSatisfy { $0.count == 1000 })
        canvas.resize(columns: 40, height: 10)
        #expect(canvas.columns == 40)
        #expect(canvas.height == 10)
        #expect(canvas[5, 0] == cell)
        #expect(canvas.rows.allSatisfy { $0.count == 40 })
        canvas.resize(columns: 0, height: 0)
        #expect(canvas.columns == 1 && canvas.height == 1)
    }

    @Test func regionPasteRoundTrip() {
        var canvas = EditCanvas()
        for y in 0..<2 { for x in 0..<3 {
            canvas.set(AnsiCell(code: UInt8(0x41 + y * 3 + x), fg: Palette.vga[x + 1], bg: Palette.vga[y]), x: x, y: y)
        } }
        let region = canvas.region(CellRect(x: 0, y: 0, width: 3, height: 2))
        #expect(region.width == 3 && region.height == 2)
        #expect(region.cells[1][2].code == 0x46)
        canvas.paste(region, x: 78, y: 10)
        #expect(canvas[78, 10] == region.cells[0][0])
        #expect(canvas[79, 11] == region.cells[1][1])
        #expect(canvas.rows[10].count == 80)
        // A region taken partly outside the canvas is clipped to it.
        let edge = canvas.region(CellRect(x: 79, y: 0, width: 5, height: 1))
        #expect(edge.width == 1)
    }

    @Test func spanningRectIsOrderIndependent() {
        #expect(CellRect.spanning((5, 7), (2, 3)) == CellRect(x: 2, y: 3, width: 4, height: 5))
    }

    @Test func fillTransformsRect() {
        var canvas = EditCanvas()
        canvas.fill(CellRect(x: 1, y: 1, width: 2, height: 2)) { _ in AnsiCell(code: 0xDB, fg: Palette.vga[4]) }
        #expect(canvas[1, 1].code == 0xDB && canvas[2, 2].code == 0xDB)
        #expect(canvas[0, 0] == AnsiCell() && canvas[3, 3] == AnsiCell())
    }

    @Test func paintHalfBlocks() {
        var canvas = EditCanvas()
        canvas.paintHalf(x: 0, y: 0, half: .top, color: Palette.vga[12])
        #expect(canvas[0, 0] == AnsiCell(code: 223, fg: Palette.vga[12], bg: Palette.vga[0]))
        canvas.paintHalf(x: 0, y: 0, half: .bottom, color: Palette.vga[12])
        #expect(canvas[0, 0].code == 219 && canvas[0, 0].fg == Palette.vga[12])
        canvas.paintHalf(x: 1, y: 0, half: .bottom, color: Palette.vga[1])
        #expect(canvas[1, 0] == AnsiCell(code: 223, fg: Palette.vga[0], bg: Palette.vga[1])
                || canvas[1, 0] == AnsiCell(code: 220, fg: Palette.vga[1], bg: Palette.vga[0]))
        // Two bright colours without iCE: the bottom is darkened to its dark half.
        canvas.paintHalf(x: 2, y: 0, half: .top, color: Palette.vga[9])
        canvas.paintHalf(x: 2, y: 0, half: .bottom, color: Palette.vga[12])
        #expect(canvas[2, 0] == AnsiCell(code: 223, fg: Palette.vga[9], bg: Palette.vga[4]))
        // Bright bottom, dark top: the lower half block keeps both exact.
        canvas.paintHalf(x: 3, y: 0, half: .top, color: Palette.vga[1])
        canvas.paintHalf(x: 3, y: 0, half: .bottom, color: Palette.vga[14])
        #expect(canvas[3, 0] == AnsiCell(code: 220, fg: Palette.vga[14], bg: Palette.vga[1]))
        // With iCE both are exact as an upper half block.
        canvas.setIceColors(true)
        canvas.paintHalf(x: 4, y: 0, half: .top, color: Palette.vga[9])
        canvas.paintHalf(x: 4, y: 0, half: .bottom, color: Palette.vga[12])
        #expect(canvas[4, 0] == AnsiCell(code: 223, fg: Palette.vga[9], bg: Palette.vga[12]))
        // Painting over a letter replaces it; blink is cleared.
        canvas.set(AnsiCell(code: 0x41, fg: Palette.vga[7], bg: Palette.vga[2], blink: true), x: 5, y: 0)
        canvas.paintHalf(x: 5, y: 0, half: .top, color: Palette.vga[15])
        #expect(canvas[5, 0] == AnsiCell(code: 223, fg: Palette.vga[15], bg: Palette.vga[2]))
    }

    @Test func iceToggleConvertsExactly() {
        var canvas = EditCanvas()
        let blinking = AnsiCell(code: 0x41, fg: Palette.vga[15], bg: Palette.vga[4], blink: true)
        canvas.set(blinking, x: 0, y: 0)
        canvas.setIceColors(true)
        #expect(canvas.iceColors)
        #expect(canvas[0, 0] == AnsiCell(code: 0x41, fg: Palette.vga[15], bg: Palette.vga[12]))
        canvas.setIceColors(false)
        #expect(canvas[0, 0] == blinking)
    }

    @Test func canBeBackgroundDependsOnIce() {
        var canvas = EditCanvas()
        #expect(canvas.canBeBackground(Palette.vga[7]))
        #expect(!canvas.canBeBackground(Palette.vga[8]))
        #expect(canvas.canBeBackground(RGB(r: 1, g: 2, b: 3)))
        canvas.setIceColors(true)
        #expect(canvas.canBeBackground(Palette.vga[8]))
    }

    @Test func canvasFromFile() {
        var sauce = Sauce(title: "Test", author: "Me", group: "Us", date: nil, dataType: 1, fileType: 1,
                          tInfo: [100, 0, 0, 0], flags: 0x01, fontName: "IBM VGA", comments: [])
        sauce.title = "Test"
        var bytes = Array("\u{1B}[5;41mX".utf8)
        bytes += sauce.encoded(fileSize: bytes.count)
        let canvas = EditCanvas(file: ArtFile(data: Data(bytes), fileExtension: "ans"))
        #expect(canvas.columns == 100)
        #expect(canvas.iceColors)
        #expect(canvas.title == "Test" && canvas.author == "Me" && canvas.group == "Us")
        #expect(canvas[0, 0].bg == Palette.vga[12])
    }

    @Test func canvasFromFileDetectsBrightBackgrounds() {
        let screen = AnsiScreen(columns: 4, rows: [[AnsiCell(code: 0x41, bg: Palette.vga[9])]])
        let canvas = EditCanvas(screen: screen, iceColors: false)
        #expect(canvas.iceColors)
    }

    @Test func canvasFromHugeAndEmptyScreens() {
        let wide = AnsiScreen(columns: 1200, rows: [Array(repeating: AnsiCell(code: 0x41), count: 1200)])
        let a = EditCanvas(screen: wide, iceColors: false)
        #expect(a.columns == 1000 && a.rows[0].count == 1000)
        let empty = EditCanvas(screen: AnsiScreen(columns: 80, rows: []), iceColors: false)
        #expect(empty.height == 1 && empty.columns == 80)
        // Short rows are padded to the width.
        let ragged = EditCanvas(screen: AnsiScreen(columns: 10, rows: [[AnsiCell(code: 0x41)]]), iceColors: false)
        #expect(ragged.rows[0].count == 10)
    }

    @Test func screenTrimmedDropsBlankRows() {
        var canvas = EditCanvas()
        canvas.set(AnsiCell(code: 0x41), x: 0, y: 2)
        canvas.setIceColors(true)
        let trimmed = canvas.screen(trimmed: true)
        #expect(trimmed.rows.count == 3)
        #expect(trimmed.sauce?.iceColors == true)
        #expect(trimmed.columns == 80)
        #expect(canvas.screen(trimmed: false).rows.count == 25)
    }
}
