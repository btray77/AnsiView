import Testing
@testable import AnsiCore

@Suite struct ShapeTests {
    private func code(_ c: Character) -> UInt8 { CP437.code(for: c.unicodeScalars.first!)! }
    private func text(_ canvas: EditCanvas, _ y: Int, _ x0: Int, _ x1: Int) -> String {
        String((x0...x1).map { Character(CP437.unicode[Int(canvas[$0, y].code)]) })
    }
    private let fg = Palette.vga[15], bg = Palette.vga[1]

    @Test func rectangleOutlinesInEveryLineStyle() {
        let expected: [(LineStyle, String, String, String)] = [
            (.single, "┌──┐", "│  │", "└──┘"),
            (.double, "╔══╗", "║  ║", "╚══╝"),
            (.singleHDoubleV, "╓──╖", "║  ║", "╙──╜"),
            (.doubleHSingleV, "╒══╕", "│  │", "╘══╛"),
        ]
        for (style, top, middle, bottom) in expected {
            var canvas = EditCanvas(columns: 10, height: 6)
            canvas.drawRectangle(CellRect(x: 1, y: 1, width: 4, height: 3), style: .line(style), fg: fg, bg: bg)
            #expect(text(canvas, 1, 1, 4) == top)
            #expect(text(canvas, 2, 1, 4) == middle)
            #expect(text(canvas, 3, 1, 4) == bottom)
            #expect(canvas[1, 1].fg == fg && canvas[1, 1].bg == bg)
        }
    }

    @Test func overlappingBoxesJoin() {
        var canvas = EditCanvas(columns: 12, height: 8)
        canvas.drawRectangle(CellRect(x: 0, y: 0, width: 5, height: 4), style: .line(.single), fg: fg, bg: bg)
        canvas.drawRectangle(CellRect(x: 2, y: 2, width: 5, height: 4), style: .line(.single), fg: fg, bg: bg)
        // The second box's top edge crosses the first box's right edge, and its left edge the bottom.
        #expect(canvas[4, 2].code == code("┼"))
        #expect(canvas[2, 3].code == code("┼"))
        // A box sharing an edge makes tees.
        var shared = EditCanvas(columns: 12, height: 8)
        shared.drawRectangle(CellRect(x: 0, y: 0, width: 4, height: 3), style: .line(.single), fg: fg, bg: bg)
        shared.drawRectangle(CellRect(x: 3, y: 0, width: 4, height: 3), style: .line(.single), fg: fg, bg: bg)
        #expect(shared[3, 0].code == code("┬"))
        #expect(shared[3, 1].code == code("│"))
        #expect(shared[3, 2].code == code("┴"))
    }

    @Test func blockStyles() {
        var canvas = EditCanvas(columns: 10, height: 6)
        canvas.drawRectangle(CellRect(x: 0, y: 0, width: 4, height: 3), style: .solid, fg: fg, bg: bg)
        #expect(text(canvas, 0, 0, 3) == "████" && text(canvas, 1, 0, 3) == "█  █")
        canvas = EditCanvas(columns: 10, height: 6)
        canvas.drawRectangle(CellRect(x: 0, y: 0, width: 4, height: 3), style: .halfBlock, fg: fg, bg: bg)
        #expect(text(canvas, 0, 0, 3) == "█▀▀█" && text(canvas, 1, 0, 3) == "▌  ▐" && text(canvas, 2, 0, 3) == "█▄▄█")
        canvas = EditCanvas(columns: 10, height: 6)
        canvas.drawRectangle(CellRect(x: 0, y: 0, width: 3, height: 3), style: .shade(2), fg: fg, bg: bg)
        #expect(text(canvas, 0, 0, 2) == "▒▒▒" && text(canvas, 1, 0, 2) == "▒ ▒")
    }

    @Test func filledRectangles() {
        var canvas = EditCanvas(columns: 10, height: 6)
        canvas.drawRectangle(CellRect(x: 0, y: 0, width: 4, height: 3), style: .line(.single), fg: fg, bg: bg,
                             filled: true, fillCode: 0xB0)
        #expect(text(canvas, 1, 0, 3) == "│░░│")
        #expect(canvas[1, 1].bg == bg)
        canvas.drawRectangle(CellRect(x: 5, y: 0, width: 3, height: 2), style: .solid, fg: fg, bg: bg, filled: true)
        #expect(text(canvas, 1, 5, 7) == "███")
    }

    @Test func dropShadowDarkensAndKeepsCharacters() {
        var canvas = EditCanvas(columns: 12, height: 8)
        canvas.set(AnsiCell(code: 0x41, fg: Palette.vga[14], bg: Palette.vga[4]), x: 5, y: 2)
        canvas.drawRectangle(CellRect(x: 0, y: 0, width: 5, height: 3), style: .line(.single), fg: fg, bg: bg, shadow: true)
        // Right of the box from the second row: columns 5 and 6, rows 1 to 3.
        #expect(canvas[5, 2].code == 0x41 && canvas[5, 2].fg == Palette.vga[8] && canvas[5, 2].bg == Palette.vga[0])
        #expect(canvas[6, 1].fg == Palette.vga[8])
        #expect(canvas[5, 0].fg == Palette.vga[7]) // top row is not shadowed
        // Under the box from the third column: row 3, columns 2 to 6.
        #expect(canvas[2, 3].fg == Palette.vga[8] && canvas[1, 3].fg == Palette.vga[7])
        #expect(canvas[7, 3].fg == Palette.vga[7])
    }

    @Test func titleInTopEdge() {
        var canvas = EditCanvas(columns: 20, height: 5)
        canvas.drawRectangle(CellRect(x: 0, y: 0, width: 12, height: 3), style: .line(.double), fg: fg, bg: bg, title: "Menu")
        #expect(text(canvas, 0, 0, 11) == "╔═ Menu ═══╗")
        // A long title is clipped so the corner and one edge cell stay.
        canvas = EditCanvas(columns: 20, height: 5)
        canvas.drawRectangle(CellRect(x: 0, y: 0, width: 8, height: 3), style: .line(.single), fg: fg, bg: bg, title: "Very long title")
        #expect(canvas[7, 0].code == code("┐"))
        #expect(text(canvas, 0, 0, 7) == "┌─ Ver─┐")
    }

    @Test func straightLines() {
        var canvas = EditCanvas(columns: 20, height: 10)
        // Box styles snap to the longer axis.
        canvas.drawStraightLine(from: (1, 1), to: (8, 3), style: .line(.double), fg: fg, bg: bg)
        #expect(text(canvas, 1, 1, 8) == "════════")
        #expect(canvas[8, 3].code == 0x20)
        // Block styles go any direction (Bresenham over cells).
        canvas = EditCanvas(columns: 20, height: 10)
        canvas.drawStraightLine(from: (0, 0), to: (4, 4), style: .character(0x2A), fg: fg, bg: bg)
        #expect((0...4).allSatisfy { canvas[$0, $0].code == 0x2A })
        #expect(canvas[1, 0].code == 0x20)
    }

    @Test func halfBlockEllipseIsSymmetricAndClipped() {
        var canvas = EditCanvas(columns: 20, height: 10)
        canvas.drawEllipse(in: CellRect(x: 2, y: 1, width: 11, height: 6), color: Palette.vga[12])
        var painted = 0
        for y in 0..<10 { for x in 0..<20 where canvas[x, y].code != 0x20 {
            painted += 1
            // Mirror across the vertical centre line (x = 7).
            #expect(canvas[14 - x, y].code != 0x20, "not symmetric at \(x), \(y)")
        }}
        #expect(painted > 10)
        // Centre is empty (outline only).
        #expect(canvas[7, 3].code == 0x20 || canvas[7, 4].code == 0x20)
        var edge = EditCanvas(columns: 4, height: 2)
        edge.drawEllipse(in: CellRect(x: -3, y: -2, width: 10, height: 10), color: Palette.vga[12])
        #expect(edge.columns == 4)
    }

    @Test func degenerateRectangles() {
        var canvas = EditCanvas(columns: 5, height: 3)
        canvas.drawRectangle(CellRect(x: 2, y: 1, width: 1, height: 1), style: .line(.single), fg: fg, bg: bg)
        #expect(canvas[2, 1].code != 0x20)
        canvas.drawRectangle(CellRect(x: 0, y: 0, width: 5, height: 1), style: .line(.single), fg: fg, bg: bg)
        #expect(text(canvas, 0, 0, 4) == "─────")
        canvas.drawRectangle(CellRect(x: 3, y: -4, width: 40, height: 40), style: .solid, fg: fg, bg: bg, shadow: true, title: "x")
        #expect(canvas.columns == 5)
    }
}
