import Foundation
import Testing
@testable import AnsiCore

/// Fixes from the editor v2 final review.
@Suite struct EditorToolsReviewTests {
    private func rowText(_ canvas: EditCanvas, _ y: Int, _ x0: Int, _ x1: Int) -> String {
        String((x0...x1).map { Character(CP437.unicode[Int(canvas[$0, y].code)]) })
    }

    /// C1: undo while a selection is lifted must not bring undone content back as a Move.
    @Test func undoWhileLiftedCancelsTheFloat() {
        let editor = CanvasEditor(canvas: EditCanvas(columns: 10, height: 2))
        editor.type("AB")
        editor.select(CellRect(x: 0, y: 0, width: 2, height: 1))
        editor.liftSelection()
        editor.undoManager.undo()
        #expect(editor.floating == nil)
        #expect(rowText(editor.canvas, 0, 0, 3) == "    ")
        editor.moveFloating(dx: 5, dy: 0)
        editor.stampFloating()
        #expect(rowText(editor.canvas, 0, 0, 7) == "        ")
        #expect(editor.undoManager.canRedo)
    }

    /// C2: layers keep one height, so crop and the project file stay consistent.
    @Test func layersShareOneHeightAndCropKeepsThemAligned() throws {
        let editor = CanvasEditor(canvas: EditCanvas(columns: 80, height: 25))
        editor.addLayer()
        editor.selectLayer(0)
        editor.setCursor(x: 0, y: 39)
        #expect(editor.layers.allSatisfy { $0.canvas.height == 40 })
        editor.select(CellRect(x: 10, y: 30, width: 5, height: 5))
        editor.cropToSelection()
        #expect(editor.layers.allSatisfy { $0.canvas.columns == 5 && $0.canvas.height == 5 })
        let reopened = try ArtProject(data: try editor.project.data())
        #expect(reopened.layers.count == 2)
    }

    /// C2: a project whose layer is narrower than the canvas pads instead of failing.
    @Test func projectToleratesANarrowLayer() throws {
        let wide = CanvasLayer(name: "A", canvas: EditCanvas(columns: 8, height: 2))
        var narrowCanvas = EditCanvas(columns: 4, height: 2)
        narrowCanvas.set(AnsiCell(code: 0x41), x: 3, y: 1)
        let mixed = ArtProject(layers: [wide, CanvasLayer(name: "B", canvas: narrowCanvas)])
        let read = try ArtProject(data: try mixed.data())
        #expect(read.layers[1].canvas.columns == 8 && read.layers[1].canvas[3, 1].code == 0x41)
    }

    /// I1: a shape preview does not hide a floating block.
    @Test func previewAndFloatShowTogether() {
        let editor = CanvasEditor(canvas: EditCanvas(columns: 10, height: 3))
        editor.beginFloating(text: "Q", x: 1, y: 1)
        editor.setPreview { $0.set(AnsiCell(code: 0x5A), x: 5, y: 0) }
        #expect(editor.displayCanvas[1, 1].code == 0x51 && editor.displayCanvas[5, 0].code == 0x5A)
    }

    /// I2: lifting and stamping in the same place changes nothing, even with transparency on.
    @Test func stampInPlaceIsNoChange() {
        let editor = CanvasEditor(canvas: EditCanvas(columns: 4, height: 1))
        editor.setBackground(4)
        editor.type(" ")
        editor.setBackground(0)
        let before = editor.canvas
        let steps = editor.undoManager.undoActionName
        editor.transparentPaste = true
        editor.select(CellRect(x: 0, y: 0, width: 1, height: 1))
        editor.liftSelection()
        editor.stampFloating()
        #expect(editor.canvas == before && editor.undoManager.undoActionName == steps)
        #expect(editor.selection == CellRect(x: 0, y: 0, width: 1, height: 1))
    }

    /// M10: a move that keeps the original because of the setting is still called Move.
    @Test func settingCopyIsNamedMove() {
        let editor = CanvasEditor(canvas: EditCanvas(columns: 6, height: 1))
        editor.type("A")
        editor.select(CellRect(x: 0, y: 0, width: 1, height: 1))
        editor.leaveCopyWhenMoving = true
        editor.moveSelection(dx: 2, dy: 0)
        editor.stampFloating()
        #expect(editor.undoManager.undoActionName == "Move" && editor.canvas[0, 0].code == 0x41)
    }
}
