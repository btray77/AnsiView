import Foundation
import Testing
@testable import AnsiCore

@Suite struct AnimationEditorTests {
    private func editor() -> CanvasEditor {
        let editor = CanvasEditor(canvas: EditCanvas(columns: 10, height: 4))
        editor.tracksEdits = true
        return editor
    }

    private func row(_ canvas: EditCanvas, _ y: Int = 0) -> String {
        String((0..<canvas.columns).map { Character(CP437.unicode[Int(canvas[$0, y].code)]) })
    }

    @Test func newFrameCopiesTheCurrentFrameWithAnEmptyLog() {
        let e = editor()
        e.type("AB")
        e.addFrame()
        #expect(e.frames.count == 2 && e.currentFrame == 1)
        #expect(row(e.canvas) == "AB        ")
        #expect(e.frames[1].edits.isEmpty)
        #expect(e.frames[0].edits == [CellEdit(x: 0, y: 0), CellEdit(x: 1, y: 0)])
        e.setCursor(x: 2, y: 0)
        e.type("C")
        #expect(row(e.frames[0].composite) == "AB        ")
        #expect(row(e.frames[1].composite) == "ABC       ")
    }

    @Test func drawingLogsCellsInTheOrderTheyChanged() {
        let e = editor()
        e.setCursor(x: 5, y: 1)
        e.type("X")
        e.setCursor(x: 0, y: 0)
        e.type("Y")
        e.setCursor(x: 0, y: 0)
        e.type("Z")  // the same cell again, last in the log already: not added twice
        e.beginStroke()
        e.paint(x: 3, y: 2, half: .top, useBackground: false)
        e.paint(x: 4, y: 2, half: .top, useBackground: false)
        e.endStroke()
        #expect(e.frames[0].edits == [CellEdit(x: 5, y: 1), CellEdit(x: 0, y: 0), CellEdit(x: 3, y: 2), CellEdit(x: 4, y: 2)])
    }

    @Test func nothingIsLoggedWhileTrackingIsOff() {
        let e = CanvasEditor(canvas: EditCanvas(columns: 10, height: 4))
        e.type("AB")
        #expect(e.frames[0].edits.isEmpty)
    }

    @Test func undoRestoresFramesAndTheLog() {
        let e = editor()
        e.type("A")
        e.addFrame()
        e.setCursor(x: 3, y: 0)
        e.type("Z")
        #expect(e.frames[1].edits == [CellEdit(x: 3, y: 0)])
        e.undoManager.undo()
        #expect(e.frames[1].edits.isEmpty && row(e.canvas) == "A         ")
        e.undoManager.undo()
        #expect(e.frames.count == 1 && e.currentFrame == 0)
        #expect(e.frames[0].edits == [CellEdit(x: 0, y: 0)])
        e.undoManager.redo()
        e.undoManager.redo()
        #expect(e.frames.count == 2 && row(e.canvas) == "A  Z      ")
        #expect(e.frames[1].edits == [CellEdit(x: 3, y: 0)])
    }

    @Test func deleteKeepsTheLastFrame() {
        let e = editor()
        e.addFrame()
        e.deleteFrame()
        #expect(e.frames.count == 1)
        e.deleteFrame()
        #expect(e.frames.count == 1)
    }

    @Test func framesReorderAndTheCurrentFrameFollows() {
        let e = editor()
        e.type("0")
        e.addFrame(); e.setCursor(x: 0, y: 0); e.type("1")
        e.addFrame(); e.setCursor(x: 0, y: 0); e.type("2")
        e.moveFrame(from: 2, to: 0)
        #expect(e.frames.map { row($0.composite).prefix(1) } == ["2", "0", "1"])
        #expect(e.currentFrame == 0)
        e.moveFrame(from: 1, to: 2)
        #expect(e.frames.map { row($0.composite).prefix(1) } == ["2", "1", "0"])
        #expect(e.currentFrame == 0)
        e.undoManager.undo()
        #expect(e.frames.map { row($0.composite).prefix(1) } == ["2", "0", "1"])
    }

    @Test func choosingAFrameIsNotAnUndoStep() {
        let e = editor()
        e.addFrame()
        let undoName = e.undoManager.undoActionName
        e.selectFrame(0)
        #expect(e.currentFrame == 0)
        #expect(e.undoManager.undoActionName == undoName)
    }

    @Test func delaysAreClamped() {
        let e = editor()
        e.setFrameDelay(0, seconds: 100)
        #expect(e.frames[0].delay == 60)
        e.setFrameDelay(0, seconds: -1)
        #expect(e.frames[0].delay == 0)
        e.setFrameDelay(0, seconds: 0.25)
        #expect(e.frames[0].delay == 0.25)
        e.undoManager.undo()
        #expect(e.frames[0].delay == 0)
    }

    @Test func sizeAndIceApplyToEveryFrame() {
        let e = editor()
        e.addFrame()
        e.addLayer()
        e.resize(columns: 40, height: 10)
        e.setIceColors(true)
        for frame in e.frames {
            for layer in frame.layers {
                #expect(layer.canvas.columns == 40 && layer.canvas.iceColors)
            }
        }
    }

    @Test func layersBelongToTheirFrame() {
        let e = editor()
        e.addFrame()
        e.addLayer()
        #expect(e.frames[1].layers.count == 2 && e.frames[0].layers.count == 1)
    }

    @Test func recordModeStampsTimes() {
        let e = editor()
        var now = 100.0
        e.clock = { now }
        e.recording = true
        now = 101
        e.type("A")
        now = 101.5
        e.type("B")
        e.recording = false
        e.type("C")
        #expect(e.frames[0].edits == [CellEdit(x: 0, y: 0, time: 1), CellEdit(x: 1, y: 0, time: 1.5), CellEdit(x: 2, y: 0)])
    }

    @Test func onionSkinShowsThePreviousFrame() {
        let e = editor()
        #expect(e.previousFrameComposite == nil)
        e.type("A")
        e.addFrame()
        e.type("B")
        #expect(e.previousFrameComposite.map { row($0) } == "A         ")
    }

    @Test func anEditorOpensFrames() {
        let frames = [AnimationTestKit.frame(columns: 10, rows: 4, delay: 1, [(0, 0, AnimationTestKit.cell("P"))]),
                      AnimationTestKit.frame(columns: 10, rows: 4, delay: 2, [(0, 0, AnimationTestKit.cell("Q"))])]
        let e = CanvasEditor(frames: frames, current: 1)
        #expect(e.currentFrame == 1 && row(e.canvas).hasPrefix("Q"))
        #expect(e.frames.map(\.delay) == [1, 2])
        #expect(!e.isModified)
    }
}
