import Foundation
import Testing
@testable import AnsiCore

@Suite struct EditorToolCommandTests {
    private func code(_ c: Character) -> UInt8 { CP437.code(for: c.unicodeScalars.first!)! }
    private func rowText(_ canvas: EditCanvas, _ y: Int, _ x0: Int, _ x1: Int) -> String {
        String((x0...x1).map { Character(CP437.unicode[Int(canvas[$0, y].code)]) })
    }

    @Test func lineModeByArrowsJoinsCorners() {
        let editor = CanvasEditor(canvas: EditCanvas(columns: 10, height: 6))
        editor.setCursor(x: 1, y: 1)
        for _ in 0..<3 { editor.lineStep(dx: 1, dy: 0, style: .single) }
        for _ in 0..<2 { editor.lineStep(dx: 0, dy: 1, style: .single) }
        #expect(rowText(editor.canvas, 1, 1, 4) == "───┐")
        #expect(editor.canvas[4, 3].code == code("│"))
        #expect(editor.cursor == (4, 3) as (Int, Int) || (editor.cursor.x == 4 && editor.cursor.y == 3))
        #expect(editor.undoManager.undoActionName == "Line")
        // Erasing back up removes the vertical part and fixes the corner.
        editor.lineStep(dx: 0, dy: -1, style: .single, erase: true)
        editor.lineStep(dx: 0, dy: -1, style: .single, erase: true)
        #expect(editor.canvas[4, 2].code == 0x20 && editor.canvas[4, 1].code == code("─"))
        // At the edge the cursor stays and nothing is drawn beyond it.
        editor.setCursor(x: 9, y: 0)
        editor.lineStep(dx: 1, dy: 0, style: .double)
        #expect(editor.canvas[9, 0].code == 0x20)
    }

    @Test func mouseLineStrokeIsOneUndo() {
        let editor = CanvasEditor(canvas: EditCanvas(columns: 10, height: 6))
        editor.beginStroke()
        editor.strokeLine(from: (0, 0), to: (3, 0), style: .double)
        editor.strokeLine(from: (3, 0), to: (3, 2), style: .double)
        editor.endStroke()
        #expect(editor.canvas[3, 0].code == code("╗"))
        editor.undoManager.undo()
        #expect(editor.canvas == EditCanvas(columns: 10, height: 6))
    }

    @Test func shapesThroughTheEditorAndPreview() {
        let editor = CanvasEditor(canvas: EditCanvas(columns: 20, height: 10))
        editor.setForeground(14)
        let rect = CellRect(x: 1, y: 1, width: 6, height: 4)
        editor.setPreview { $0.drawRectangle(rect, style: .line(.double), fg: Palette.vga[14], bg: Palette.vga[0]) }
        #expect(editor.displayCanvas[1, 1].code == code("╔") && editor.canvas[1, 1].code == 0x20)
        editor.setPreview(nil)
        editor.drawRectangle(rect, style: .line(.double), filled: true, shadow: true, title: "Hi")
        #expect(editor.canvas[1, 1].code == code("╔") && editor.canvas[1, 1].fg == Palette.vga[14])
        #expect(editor.canvas[7, 2].fg == Palette.vga[8])
        #expect(editor.undoManager.undoActionName == "Rectangle")
        editor.drawStraightLine(from: (0, 8), to: (9, 8), style: .character(0x2A))
        #expect(editor.canvas[5, 8].code == 0x2A && editor.undoManager.undoActionName == "Line")
        editor.drawEllipse(in: CellRect(x: 10, y: 0, width: 8, height: 5))
        #expect(editor.undoManager.undoActionName == "Ellipse")
    }

    @Test func brushesAndEyedropper() {
        let editor = CanvasEditor(canvas: EditCanvas(columns: 10, height: 3))
        editor.setForeground(12)
        editor.setBackground(1)
        editor.brushCharacter = 0xB2
        editor.beginStroke()
        editor.brush(x: 1, y: 1, colourOnly: false, useBackground: false)
        editor.brush(x: 2, y: 1, colourOnly: false, useBackground: true)
        editor.endStroke()
        #expect(editor.canvas[1, 1] == AnsiCell(code: 0xB2, fg: Palette.vga[12], bg: Palette.vga[1]))
        // The right button swaps the colours (a bright colour becomes a dark background without iCE).
        #expect(editor.canvas[2, 1].fg == Palette.vga[1] && editor.canvas[2, 1].bg == Palette.vga[4])
        editor.setCursor(x: 5, y: 0)
        editor.type("A")
        editor.setForeground(10)
        editor.setBackground(2)
        editor.brush(x: 5, y: 0, colourOnly: true, useBackground: false)
        #expect(editor.canvas[5, 0].code == 0x41 && editor.canvas[5, 0].fg == Palette.vga[10])
        editor.setForeground(7)
        editor.setBackground(0)
        editor.pickColours(x: 1, y: 1, includeCharacter: true)
        #expect(editor.foreground == 12 && editor.background == 1 && editor.brushCharacter == 0xB2)
    }

    @Test func fillReplaceAndSwapCommands() {
        let editor = CanvasEditor(canvas: EditCanvas(columns: 6, height: 3))
        editor.setForeground(14)
        editor.brushCharacter = 0xB0
        editor.floodFill(x: 0, y: 0, matchBy: .both, apply: .both)
        #expect(editor.canvas[5, 2].code == 0xB0 && editor.undoManager.undoActionName == "Fill")
        editor.select(CellRect(x: 0, y: 0, width: 2, height: 1))
        let changed = editor.replace(matching: CellPattern(code: 0xB0), with: CellPattern(code: 0x2E))
        #expect(changed == 2 && editor.canvas[1, 0].code == 0x2E && editor.canvas[2, 0].code == 0xB0)
        editor.swapSelectionColours()
        #expect(editor.canvas[0, 0].fg == Palette.vga[0] && editor.canvas[0, 0].bg == Palette.vga[6])
        editor.setForeground(9)
        editor.setBackground(4)
        editor.swapDrawingColours()
        #expect(editor.foreground == 4 && editor.background == 1)
    }

    @Test func insertModeTypingAndDeleting() {
        let editor = CanvasEditor(canvas: EditCanvas(columns: 6, height: 2))
        editor.type("ABCD")
        editor.setCursor(x: 1, y: 0)
        editor.insertMode = true
        editor.type("x")
        #expect(rowText(editor.canvas, 0, 0, 5) == "AxBCD ")
        editor.backspace()
        #expect(rowText(editor.canvas, 0, 0, 5) == "ABCD  " && editor.cursor.x == 1)
        editor.deleteForward()
        #expect(rowText(editor.canvas, 0, 0, 5) == "ACD   ")
        editor.insertMode = false
        editor.deleteForward()
        #expect(rowText(editor.canvas, 0, 0, 5) == "A D   ")
        editor.backspace()
        #expect(rowText(editor.canvas, 0, 0, 5) == "  D   " && editor.cursor.x == 0)
    }

    @Test func insertAndDeleteLinesAndColumns() {
        let editor = CanvasEditor(canvas: EditCanvas(columns: 4, height: 2))
        editor.type("ABCD")
        editor.setCursor(x: 1, y: 0)
        editor.insertLine()
        #expect(editor.canvas.height == 3 && editor.canvas[0, 1].code == 0x41)
        editor.deleteLine()
        #expect(editor.canvas.height == 2 && editor.canvas[0, 0].code == 0x41)
        editor.insertColumn()
        #expect(rowText(editor.canvas, 0, 0, 3) == "A BC")
        editor.deleteColumn()
        #expect(rowText(editor.canvas, 0, 0, 3) == "ABC ")
        #expect(editor.undoManager.undoActionName == "Delete Column")
    }

    @Test func commandsRefusedWhileFloating() {
        let editor = CanvasEditor(canvas: EditCanvas(columns: 6, height: 3))
        editor.beginFloating(text: "Z")
        let before = editor.canvas
        editor.floodFill(x: 0, y: 0, matchBy: .both, apply: .both)
        editor.drawRectangle(CellRect(x: 0, y: 0, width: 3, height: 3), style: .solid)
        editor.lineStep(dx: 1, dy: 0, style: .single)
        editor.insertLine()
        #expect(editor.canvas == before)
    }

    /// Ruling 15: measured on 160 x 1500 and printed for the report.
    @Test func performanceOnTallCanvas() {
        let editor = CanvasEditor(canvas: EditCanvas(columns: 160, height: 1500))
        let clock = ContinuousClock()
        // A 51 x 51 outline has 200 cells.
        let rect = CellRect(x: 40, y: 700, width: 51, height: 51)
        #expect(EditCanvas.perimeter(rect).count == 201) // closed path: the start cell twice
        let box = clock.measure { editor.drawRectangle(rect, style: .line(.double)) }
        let fill = clock.measure { editor.floodFill(x: 0, y: 0, matchBy: .both, apply: .both) }
        let filled = (0..<1500).reduce(0) { total, y in total + (0..<160).filter { editor.canvas[$0, y].code == editor.brushCharacter }.count }
        print("PERF box200 \(box) flood \(fill) filledCells \(filled)")
        #expect(filled == 160 * 1500 - 200 - 49 * 49)
        #expect(box < .seconds(1) && fill < .seconds(5))
    }
}
