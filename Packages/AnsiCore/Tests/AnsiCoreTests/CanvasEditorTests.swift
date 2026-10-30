import Foundation
import Testing
@testable import AnsiCore

@Suite struct CanvasEditorTests {
    @Test func typingWritesAndAdvances() {
        let editor = CanvasEditor()
        editor.setForeground(14)
        editor.setBackground(1)
        editor.type("Hi")
        #expect(editor.canvas[0, 0] == AnsiCell(code: 0x48, fg: Palette.vga[14], bg: Palette.vga[1]))
        #expect(editor.canvas[1, 0] == AnsiCell(code: 0x69, fg: Palette.vga[14], bg: Palette.vga[1]))
        #expect(editor.cursor.x == 2 && editor.cursor.y == 0)
    }

    @Test func typingWrapsAtEdge() {
        let editor = CanvasEditor(canvas: EditCanvas(columns: 3, height: 2))
        editor.type("abcd")
        #expect(editor.canvas[2, 0].code == 0x63)
        #expect(editor.canvas[0, 1].code == 0x64)
        #expect(editor.cursor.x == 1 && editor.cursor.y == 1)
    }

    @Test func unicodeTypingMapsToCP437() {
        let editor = CanvasEditor()
        editor.type("░é€")
        #expect(editor.canvas[0, 0].code == 176)
        #expect(editor.canvas[1, 0].code == 130)
        #expect(editor.canvas[2, 0] == AnsiCell())
        #expect(editor.cursor.x == 2)
    }

    @Test func returnAndLineKeys() {
        let editor = CanvasEditor()
        editor.type("ab\ncd")
        #expect(editor.canvas[0, 1].code == 0x63)
        editor.moveToLineStart()
        #expect(editor.cursor.x == 0)
        editor.moveToLineEnd()
        #expect(editor.cursor.x == 79)
        editor.moveCursor(dx: -100, dy: -100, extendSelection: false)
        #expect(editor.cursor.x == 0 && editor.cursor.y == 0)
    }

    @Test func cursorDownGrowsHeight() {
        let editor = CanvasEditor(canvas: EditCanvas(columns: 80, height: 2))
        editor.moveCursor(dx: 0, dy: 1, extendSelection: false)
        editor.moveCursor(dx: 0, dy: 1, extendSelection: false)
        #expect(editor.cursor.y == 2)
        #expect(editor.canvas.height == 3)
    }

    @Test func backspaceAndDelete() {
        let editor = CanvasEditor()
        editor.type("abc")
        editor.backspace()
        #expect(editor.cursor.x == 2 && editor.canvas[2, 0] == AnsiCell())
        editor.moveCursor(dx: -2, dy: 0, extendSelection: false)
        editor.deleteForward()
        #expect(editor.canvas[0, 0] == AnsiCell() && editor.canvas[1, 0].code == 0x62)
    }

    @Test func fKeysInsertCurrentSet() {
        let editor = CanvasEditor()
        #expect(editor.blockSet == 5)
        editor.insertBlock(3)
        #expect(editor.canvas[0, 0].code == 219)
        editor.blockSet = 0
        editor.insertBlock(0)
        #expect(editor.canvas[1, 0].code == 218)
        #expect(editor.lastBlockCharacter == 218)
        #expect(CanvasEditor.blockSets.count == 10 && CanvasEditor.blockSets.allSatisfy { $0.count == 10 })
        #expect(CanvasEditor.blockSets[5] == [176, 177, 178, 219, 223, 220, 221, 222, 254, 250])
    }

    @Test func backgroundDarkensWithoutIce() {
        let editor = CanvasEditor()
        editor.setBackground(12)
        #expect(editor.background == 4)
        editor.setIceColors(true)
        editor.setBackground(12)
        #expect(editor.background == 12)
        editor.setIceColors(false)
        #expect(editor.background == 4)
        #expect(!editor.canvas.iceColors)
    }

    @Test func undoRedoRestoresCanvas() {
        let editor = CanvasEditor()
        editor.type("A")
        let typed = editor.canvas
        #expect(editor.undoManager.canUndo)
        #expect(editor.undoManager.undoActionName == "Typing")
        editor.undoManager.undo()
        #expect(editor.canvas == EditCanvas())
        editor.undoManager.redo()
        #expect(editor.canvas == typed)
    }

    @Test func strokeIsOneUndo() {
        let editor = CanvasEditor()
        editor.type("Z")
        editor.setForeground(12)
        editor.beginStroke()
        editor.paint(x: 0, y: 1, half: .top, useBackground: false)
        editor.paint(x: 1, y: 1, half: .top, useBackground: false)
        editor.paint(x: 2, y: 1, half: .bottom, useBackground: false)
        editor.endStroke()
        #expect(editor.canvas[0, 1].code == 223 && editor.canvas[2, 1].code == 220)
        #expect(editor.undoManager.undoActionName == "Draw")
        editor.undoManager.undo()
        #expect(editor.canvas[0, 1] == AnsiCell() && editor.canvas[2, 1] == AnsiCell())
        #expect(editor.canvas[0, 0].code == 0x5A)
    }

    @Test func strokeWithoutChangeRegistersNothing() {
        let editor = CanvasEditor()
        editor.beginStroke()
        editor.paint(x: 0, y: 0, half: .top, useBackground: true)
        editor.endStroke()
        #expect(!editor.undoManager.canUndo)
        #expect(!editor.isModified)
    }

    @Test func copyPasteCells() throws {
        var start = EditCanvas()
        start.set(AnsiCell(code: 0x58, fg: RGB(r: 1, g: 2, b: 3), bg: RGB(r: 9, g: 8, b: 7)), x: 0, y: 1)
        let editor = CanvasEditor(canvas: start)
        editor.setForeground(10)
        editor.setBackground(5)
        editor.type("ab")
        editor.moveCursor(dx: -2, dy: 1, extendSelection: false)
        editor.select(CellRect(x: 0, y: 0, width: 2, height: 2))
        let copied = try #require(editor.copySelection())
        #expect(copied.text == "ab\nX\n")
        editor.select(nil)
        editor.moveCursor(dx: 10, dy: 4, extendSelection: false)
        editor.paste(cells: copied.cells)
        #expect(editor.canvas[10, 5] == editor.canvas[0, 0])
        #expect(editor.canvas[11, 5] == editor.canvas[1, 0])
        #expect(editor.canvas[10, 6] == editor.canvas[0, 1])
        #expect(editor.selection == CellRect(x: 10, y: 5, width: 2, height: 2))
        #expect(editor.undoManager.undoActionName == "Paste")
        editor.paste(cells: Data([1, 2, 3]))
        #expect(editor.undoManager.undoActionName == "Paste")
    }

    @Test func cutClearsSelection() throws {
        let editor = CanvasEditor()
        editor.type("abc")
        editor.select(CellRect(x: 0, y: 0, width: 2, height: 1))
        let cut = try #require(editor.cut())
        #expect(cut.text == "ab\n")
        #expect(editor.canvas[0, 0] == AnsiCell() && editor.canvas[2, 0].code == 0x63)
        #expect(editor.copySelection() != nil)
        editor.select(nil)
        #expect(editor.copySelection() == nil)
    }

    @Test func pastePlainTextClipsAtEdges() {
        let editor = CanvasEditor(canvas: EditCanvas(columns: 80, height: 1))
        editor.setForeground(11)
        editor.moveCursor(dx: 78, dy: 0, extendSelection: false)
        editor.paste(text: "hello\r\nworld\tX")
        #expect(editor.canvas[78, 0] == AnsiCell(code: 0x68, fg: Palette.vga[11]))
        #expect(editor.canvas[79, 0].code == 0x65)
        #expect(editor.canvas[78, 1].code == 0x77 && editor.canvas[79, 1].code == 0x6F)
        #expect(editor.canvas.height == 2)
        let tall = CanvasEditor()
        tall.moveCursor(dx: 0, dy: AnsiTerminal.maxRows - 1, extendSelection: false)
        tall.paste(text: "a\nb\nc")
        #expect(tall.canvas.height == AnsiTerminal.maxRows)
    }

    @Test func fillWithCharacterAndColour() {
        let editor = CanvasEditor()
        editor.type("xy")
        editor.blockSet = 5
        editor.insertBlock(0)
        editor.setForeground(4)
        editor.setBackground(2)
        editor.select(CellRect(x: 0, y: 1, width: 3, height: 2))
        editor.fillWithCharacter()
        #expect(editor.canvas[2, 2] == AnsiCell(code: 176, fg: Palette.vga[4], bg: Palette.vga[2]))
        #expect(editor.canvas[3, 2] == AnsiCell())
        editor.select(CellRect(x: 0, y: 0, width: 2, height: 1))
        editor.setForeground(15)
        editor.fillWithColour()
        #expect(editor.canvas[0, 0] == AnsiCell(code: 0x78, fg: Palette.vga[15], bg: Palette.vga[2]))
        #expect(editor.undoManager.undoActionName == "Fill with Colour")
        editor.select(nil)
        editor.fillWithCharacter()
        #expect(editor.canvas[79, 24].code == 176)
    }

    @Test func extendSelectionWithShiftArrows() {
        let editor = CanvasEditor()
        editor.moveCursor(dx: 2, dy: 2, extendSelection: false)
        editor.moveCursor(dx: 3, dy: 1, extendSelection: true)
        #expect(editor.selection == CellRect(x: 2, y: 2, width: 4, height: 2))
        editor.moveCursor(dx: -1, dy: 0, extendSelection: true)
        #expect(editor.selection == CellRect(x: 2, y: 2, width: 3, height: 2))
        editor.moveCursor(dx: 1, dy: 0, extendSelection: false)
        #expect(editor.selection == nil)
        editor.selectAll()
        #expect(editor.selection == CellRect(x: 0, y: 0, width: 80, height: 25))
    }

    @Test func resizeClampsCursorAndSelection() {
        let editor = CanvasEditor()
        editor.moveCursor(dx: 70, dy: 20, extendSelection: false)
        editor.select(CellRect(x: 30, y: 5, width: 40, height: 18))
        editor.resize(columns: 40, height: 10)
        #expect(editor.cursor.x == 39 && editor.cursor.y == 9)
        #expect(editor.selection == CellRect(x: 30, y: 5, width: 10, height: 5))
        editor.select(CellRect(x: 50, y: 0, width: 2, height: 2))
        #expect(editor.selection == nil)
        #expect(editor.undoManager.undoActionName == "Canvas Size")
        editor.undoManager.undo()
        #expect(editor.canvas.columns == 80)
    }

    @Test func metadataIsUndoable() {
        let editor = CanvasEditor()
        editor.setMetadata(title: "T", author: "A", group: "G")
        #expect(editor.canvas.title == "T" && editor.canvas.author == "A" && editor.canvas.group == "G")
        editor.undoManager.undo()
        #expect(editor.canvas.title == "")
    }

    @Test func modifiedFlag() {
        let editor = CanvasEditor()
        #expect(!editor.isModified)
        editor.type("a")
        #expect(editor.isModified)
        editor.markSaved()
        #expect(!editor.isModified)
        editor.undoManager.undo()
        #expect(editor.isModified)
        editor.undoManager.redo()
        #expect(!editor.isModified)
    }

    @Test func onChangeFires() {
        let editor = CanvasEditor()
        var count = 0
        editor.onChange = { count += 1 }
        editor.type("a")
        editor.moveCursor(dx: 1, dy: 0, extendSelection: false)
        #expect(count >= 2)
    }
}
