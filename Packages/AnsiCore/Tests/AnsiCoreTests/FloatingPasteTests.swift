import Foundation
import Testing
@testable import AnsiCore

@Suite struct FloatingPasteTests {
    static let red = AnsiCell(code: 0x41, fg: Palette.vga[12], bg: Palette.vga[1])
    /// 2 x 2: "A" on blue, a space on blue, a space, a "B".
    static let block = CanvasRegion(cells: [
        [red, AnsiCell(code: 0x20, fg: Palette.vga[7], bg: Palette.vga[1])],
        [AnsiCell(), AnsiCell(code: 0x42)],
    ])

    static func filled() -> EditCanvas {
        var canvas = EditCanvas(columns: 10, height: 4)
        canvas.fill(CellRect(x: 0, y: 0, width: 10, height: 4)) { _ in AnsiCell(code: 0x2E, fg: Palette.vga[2]) }
        return canvas
    }

    @Test func beginsAtTheCursorWithoutChangingTheCanvas() throws {
        let editor = CanvasEditor(canvas: Self.filled())
        editor.moveCursor(dx: 3, dy: 1, extendSelection: false)
        editor.beginFloating(Self.block)
        let floating = try #require(editor.floating)
        #expect(floating.x == 3 && floating.y == 1)
        #expect(editor.canvas == Self.filled())
        #expect(!editor.undoManager.canUndo)
        // What is shown has the block in place.
        #expect(editor.displayCanvas[3, 1] == Self.red)
        #expect(editor.displayCanvas[4, 2].code == 0x42)
    }

    @Test func beginsAtAGivenCell() {
        let editor = CanvasEditor(canvas: Self.filled())
        editor.beginFloating(Self.block, x: 7, y: 2)
        #expect(editor.floating?.x == 7 && editor.floating?.y == 2)
    }

    @Test func movesAndClamps() {
        let editor = CanvasEditor(canvas: Self.filled())
        editor.beginFloating(Self.block)
        editor.moveFloating(dx: 2, dy: 1)
        #expect(editor.floating?.x == 2 && editor.floating?.y == 1)
        editor.moveFloating(dx: -10, dy: -10)
        #expect(editor.floating?.x == 0 && editor.floating?.y == 0)
        editor.moveFloating(dx: 100, dy: 0)
        #expect(editor.floating?.x == 9)
        editor.moveFloating(toX: 4, y: 3)
        #expect(editor.floating?.x == 4 && editor.floating?.y == 3)
        #expect(editor.canvas == Self.filled())
    }

    @Test func stampIsOneUndoAndSelects() throws {
        let editor = CanvasEditor(canvas: Self.filled())
        editor.beginFloating(Self.block)
        editor.moveFloating(dx: 1, dy: 0)
        editor.moveFloating(dx: 1, dy: 1)
        editor.stampFloating()
        #expect(editor.floating == nil)
        #expect(editor.canvas[2, 1] == Self.red)
        #expect(editor.canvas[3, 1].code == 0x20)
        #expect(editor.canvas[3, 2].code == 0x42)
        #expect(editor.selection == CellRect(x: 2, y: 1, width: 2, height: 2))
        #expect(editor.cursor.x == 2 && editor.cursor.y == 1)
        #expect(editor.undoManager.undoActionName == "Paste")
        editor.undoManager.undo()
        #expect(editor.canvas == Self.filled())
        #expect(!editor.undoManager.canUndo)
        editor.undoManager.redo()
        #expect(editor.canvas[2, 1] == Self.red)
        #expect(editor.isModified)
    }

    @Test func cancelLeavesTheCanvas() {
        let editor = CanvasEditor(canvas: Self.filled())
        editor.beginFloating(Self.block)
        editor.moveFloating(dx: 3, dy: 0)
        editor.cancelFloating()
        #expect(editor.floating == nil)
        #expect(editor.canvas == Self.filled())
        #expect(editor.displayCanvas == Self.filled())
        #expect(!editor.undoManager.canUndo)
        // Stamping with nothing floating does nothing.
        editor.stampFloating()
        #expect(!editor.undoManager.canUndo)
    }

    @Test func transparentKeepsWhatIsUnderSpaces() {
        let editor = CanvasEditor(canvas: Self.filled())
        editor.transparentPaste = true
        editor.beginFloating(Self.block)
        #expect(editor.displayCanvas[1, 0].code == 0x2E)
        editor.stampFloating()
        #expect(editor.canvas[0, 0] == Self.red)
        #expect(editor.canvas[1, 0] == AnsiCell(code: 0x2E, fg: Palette.vga[2]))
        #expect(editor.canvas[0, 1] == AnsiCell(code: 0x2E, fg: Palette.vga[2]))
        #expect(editor.canvas[1, 1].code == 0x42)
        // NUL and 255 are blanks too.
        #expect(EditCanvas.transparentCodes == [0x00, 0x20, 0xFF])
    }

    @Test func clipsAtTheEdgesAndGrowsRows() {
        let editor = CanvasEditor(canvas: Self.filled())
        editor.beginFloating(Self.block, x: 9, y: 3)
        editor.stampFloating()
        #expect(editor.canvas.columns == 10)
        #expect(editor.canvas.height == 5)
        #expect(editor.canvas[9, 3] == Self.red)
        #expect(editor.selection == CellRect(x: 9, y: 3, width: 1, height: 2))
        // At the row limit nothing crashes.
        let tall = CanvasEditor(canvas: EditCanvas(columns: 10, height: AnsiTerminal.maxRows))
        tall.beginFloating(Self.block, x: 0, y: AnsiTerminal.maxRows + 5)
        #expect(tall.floating?.y == AnsiTerminal.maxRows - 1)
        tall.stampFloating()
        #expect(tall.canvas.height == AnsiTerminal.maxRows)
    }

    @Test func regionFromText() {
        let region = CanvasEditor.region(fromText: "ab\r\n░\tc€\n", fg: Palette.vga[14], bg: Palette.vga[1])
        #expect(region.width == 4 && region.height == 2)
        #expect(region.cells[0].map(\.code) == [0x61, 0x62, 0x20, 0x20])
        #expect(region.cells[1].map(\.code) == [176, 0x20, 0x63, 0x3F])
        #expect(region.cells[0][0].fg == Palette.vga[14] && region.cells[1][3].bg == Palette.vga[1])
        #expect(CanvasEditor.region(fromText: "", fg: Palette.vga[7], bg: Palette.vga[0]).height == 0)
        let wide = CanvasEditor.region(fromText: String(repeating: "x", count: 1200), fg: Palette.vga[7], bg: Palette.vga[0])
        #expect(wide.width == EditCanvas.maxColumns)
    }

    @Test func floatingFromCellsAndTextData() {
        let editor = CanvasEditor(canvas: Self.filled())
        #expect(editor.beginFloating(cells: CanvasEditor.encode(Self.block)))
        #expect(editor.floating?.region == Self.block)
        #expect(!editor.beginFloating(cells: Data("junk".utf8)))
        editor.setForeground(11)
        editor.beginFloating(text: "hi")
        #expect(editor.floating?.region.cells[0][0] == AnsiCell(code: 0x68, fg: Palette.vga[11], bg: Palette.vga[0]))
        // An empty text paste floats nothing.
        editor.cancelFloating()
        editor.beginFloating(text: "")
        #expect(editor.floating == nil)
    }
}
