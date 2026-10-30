import Foundation
import Testing
@testable import AnsiCore

@Suite struct CellTransformTests {
    private func code(_ c: Character) -> UInt8 { CP437.code(for: c.unicodeScalars.first!)! }
    private func glyph(_ code: UInt8) -> Character { Character(CP437.unicode[Int(code)]) }

    @Test func mirrorPairs() {
        let horizontal: [(Character, Character)] = [("┌", "┐"), ("└", "┘"), ("├", "┤"), ("╟", "╢"), ("╒", "╕"),
                                                    ("▌", "▐"), ("/", "\\"), ("<", ">"), ("(", ")"), ("[", "]"),
                                                    ("{", "}"), ("→", "←"), ("►", "◄"), ("«", "»")]
        for (a, b) in horizontal {
            #expect(CellTransform.mirrorHorizontal.map(code(a)) == code(b), "\(a)")
            #expect(CellTransform.mirrorHorizontal.map(code(b)) == code(a), "\(b)")
        }
        let vertical: [(Character, Character)] = [("┌", "└"), ("╦", "╩"), ("▀", "▄"), ("/", "\\"), ("↑", "↓"),
                                                  ("▲", "▼"), ("⌠", "⌡"), ("╓", "╙")]
        for (a, b) in vertical {
            #expect(CellTransform.mirrorVertical.map(code(a)) == code(b), "\(a)")
            #expect(CellTransform.mirrorVertical.map(code(b)) == code(a), "\(b)")
        }
        // Symmetric characters stay.
        for c: Character in ["─", "│", "┼", "A", "█", "░"] { #expect(CellTransform.mirrorHorizontal.map(code(c)) == code(c)) }
        #expect(CellTransform.rotate180.map(code("┌")) == code("┘"))
    }

    @Test func mirrorTwiceIsIdentityForEveryCode() {
        for value in 0...255 {
            let c = UInt8(value)
            for t in [CellTransform.mirrorHorizontal, .mirrorVertical, .rotate180] {
                #expect(t.map(t.map(c)) == c, "\(t) code \(value)")
            }
        }
    }

    @Test func rotateQuarterTurns() {
        let cases: [(Character, Character)] = [("┌", "┐"), ("─", "│"), ("═", "║"), ("╒", "╖"), ("▀", "▐"), ("▐", "▄"),
                                               ("▄", "▌"), ("▌", "▀"), ("/", "\\"), ("-", "|"), ("↑", "→"), ("▲", "►")]
        for (a, b) in cases { #expect(CellTransform.rotateClockwise.map(code(a)) == code(b), "\(a)") }
        for value in 0xB3...0xDA {
            let c = UInt8(value)
            var r = c
            for _ in 0..<4 { r = CellTransform.rotateClockwise.map(r) }
            #expect(r == c, "four turns of \(value)")
            // Every rotated box character exists exactly in CP437.
            let rotated = BoxJoin(code: c)!.rotatedClockwise
            #expect(BoxJoin(code: BoxDrawing.code(for: rotated)!) == rotated, "rotation of \(value) is not exact")
        }
    }

    @Test func regionTransforms() {
        let a = AnsiCell(code: code("┌"), fg: Palette.vga[14]), b = AnsiCell(code: 0x41), c = AnsiCell(code: code("▀"), fg: Palette.vga[1], bg: Palette.vga[4])
        let region = CanvasRegion(cells: [[a, b], [c, AnsiCell()]])
        let h = region.transformed(.mirrorHorizontal)
        #expect(h.cells[0].map(\.code) == [0x41, code("┐")] && h.cells[0][1].fg == Palette.vga[14])
        let v = region.transformed(.mirrorVertical)
        #expect(v.cells[0][0].code == code("▄") && v.cells[0][0].fg == Palette.vga[1] && v.cells[1][0].code == code("└"))
        let r = region.transformed(.rotateClockwise)
        #expect(r.width == 2 && r.height == 2)
        // Top row of the result is the left column read bottom to top.
        #expect(r.cells[0][0].code == code("▐") && r.cells[0][1].code == code("┐"))
        let tall = CanvasRegion(cells: [[a], [b], [c]]).transformed(.rotateClockwise)
        #expect(tall.width == 3 && tall.height == 1)
    }

    @Test func cropKeepsMetadata() {
        var canvas = EditCanvas(columns: 10, height: 5)
        canvas.title = "Kept"
        canvas.set(AnsiCell(code: 0x41), x: 3, y: 2)
        canvas.crop(to: CellRect(x: 3, y: 2, width: 4, height: 2))
        #expect(canvas.columns == 4 && canvas.height == 2 && canvas[0, 0].code == 0x41 && canvas.title == "Kept")
        canvas.crop(to: CellRect(x: 50, y: 50, width: 4, height: 2))
        #expect(canvas.columns == 4)
    }
}

@Suite struct SelectionMoveTests {
    private func editorWithBlock() -> CanvasEditor {
        let editor = CanvasEditor(canvas: EditCanvas(columns: 20, height: 10))
        editor.setForeground(14)
        editor.setCursor(x: 2, y: 2)
        editor.type("AB")
        editor.setCursor(x: 2, y: 3)
        editor.type("CD")
        editor.select(CellRect(x: 2, y: 2, width: 2, height: 2))
        return editor
    }

    @Test func liftMoveStampIsOneUndo() {
        let editor = editorWithBlock()
        let before = editor.canvas
        editor.setBackground(1)
        #expect(editor.liftSelection())
        #expect(editor.canvas == before) // nothing changes until stamped
        editor.moveFloating(dx: 5, dy: 1)
        // The display shows the vacated area cleared to the background and the block moved.
        #expect(editor.displayCanvas[2, 2].code == 0x20 && editor.displayCanvas[2, 2].bg == Palette.vga[1])
        #expect(editor.displayCanvas[7, 3].code == 0x41)
        editor.stampFloating()
        #expect(editor.canvas[7, 3].code == 0x41 && editor.canvas[8, 4].code == 0x44)
        #expect(editor.canvas[2, 2].code == 0x20 && editor.canvas[2, 2].bg == Palette.vga[1])
        #expect(editor.selection == CellRect(x: 7, y: 3, width: 2, height: 2))
        #expect(editor.undoManager.undoActionName == "Move")
        editor.undoManager.undo()
        #expect(editor.canvas == before)
    }

    @Test func cancelPutsItBack() {
        let editor = editorWithBlock()
        let before = editor.canvas
        editor.moveSelection(dx: 3, dy: 0)
        #expect(editor.floating != nil)
        editor.cancelFloating()
        #expect(editor.canvas == before && editor.displayCanvas == before)
        #expect(editor.selection == CellRect(x: 2, y: 2, width: 2, height: 2))
        #expect(!editor.undoManager.canUndo || editor.undoManager.undoActionName == "Typing")
    }

    @Test func duplicateLeavesOriginal() {
        let editor = editorWithBlock()
        editor.liftSelection(duplicate: true)
        editor.moveFloating(dx: 0, dy: 4)
        editor.stampFloating()
        #expect(editor.canvas[2, 2].code == 0x41 && editor.canvas[2, 6].code == 0x41)
        #expect(editor.undoManager.undoActionName == "Duplicate")
        // The setting keeps a copy on every move.
        let other = editorWithBlock()
        other.leaveCopyWhenMoving = true
        other.moveSelection(dx: 4, dy: 0)
        other.stampFloating()
        #expect(other.canvas[2, 2].code == 0x41 && other.canvas[6, 2].code == 0x41)
    }

    @Test func movedBlockCanMoveAgainAndPastesToo() {
        let editor = editorWithBlock()
        editor.moveSelection(dx: 2, dy: 0)
        editor.stampFloating()
        editor.moveSelection(dx: 0, dy: 2)
        editor.stampFloating()
        #expect(editor.canvas[4, 4].code == 0x41 && editor.canvas[4, 2].code == 0x20)
        // A stamped paste is plain cells: it moves the same way.
        editor.beginFloating(text: "XY", x: 10, y: 0)
        editor.stampFloating()
        #expect(editor.selection == CellRect(x: 10, y: 0, width: 2, height: 1))
        editor.moveSelection(dx: 1, dy: 0)
        editor.stampFloating()
        #expect(editor.canvas[10, 0].code == 0x20 && editor.canvas[11, 0].code == 0x58 && editor.canvas[12, 0].code == 0x59)
    }

    @Test func transparentMoveKeepsWhatIsUnderBlanks() {
        let editor = CanvasEditor(canvas: EditCanvas(columns: 10, height: 3))
        editor.setCursor(x: 0, y: 0)
        editor.type("A B")
        editor.setCursor(x: 0, y: 1)
        editor.type("zzz")
        editor.select(CellRect(x: 0, y: 0, width: 3, height: 1))
        editor.transparentPaste = true
        editor.moveSelection(dx: 0, dy: 1)
        editor.stampFloating()
        #expect(editor.canvas[0, 1].code == 0x41 && editor.canvas[1, 1].code == 0x7A && editor.canvas[2, 1].code == 0x42)
    }

    @Test func noSelectionNothingLifts() {
        let editor = CanvasEditor()
        #expect(!editor.liftSelection())
        editor.moveSelection(dx: 1, dy: 0)
        #expect(editor.floating == nil)
    }

    @Test func transformSelectionAndCrop() {
        let editor = editorWithBlock()
        editor.transformSelection(.mirrorHorizontal)
        #expect(editor.canvas[2, 2].code == 0x42 && editor.canvas[3, 2].code == 0x41)
        #expect(editor.undoManager.undoActionName == "Mirror Horizontally")
        // Rotating a 3 x 1 block at the right edge into 1 x 3 fits; 1 x 3 at the edge into 3 x 1 does not.
        let edge = CanvasEditor(canvas: EditCanvas(columns: 4, height: 4))
        edge.setCursor(x: 3, y: 0)
        edge.type("Q")
        edge.select(CellRect(x: 3, y: 0, width: 1, height: 3))
        #expect(!edge.canTransformSelection(.rotateClockwise))
        #expect(!edge.transformSelection(.rotateClockwise))
        edge.select(CellRect(x: 0, y: 0, width: 3, height: 1))
        #expect(edge.transformSelection(.rotateClockwise))
        #expect(edge.selection == CellRect(x: 0, y: 0, width: 1, height: 3))
        editor.select(CellRect(x: 2, y: 2, width: 2, height: 2))
        editor.cropToSelection()
        #expect(editor.canvas.columns == 2 && editor.canvas.height == 2 && editor.canvas[0, 0].code == 0x42)
        #expect(editor.undoManager.undoActionName == "Crop to Selection")
    }
}
