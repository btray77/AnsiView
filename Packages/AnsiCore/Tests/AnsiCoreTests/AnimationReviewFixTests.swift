import Foundation
import Testing
@testable import AnsiCore

/// Fixes from the final review of the animation branch.
@Suite struct AnimationReviewFixTests {
    typealias Kit = AnimationTestKit

    // Review I2: the log keeps one entry per cell (its last edit), so it never outgrows the canvas.
    @Test func aCellIsLoggedOnceAtItsLastEdit() {
        let editor = CanvasEditor(canvas: EditCanvas(columns: 10, height: 4))
        editor.tracksEdits = true
        editor.type("A")
        editor.type("B")
        editor.setCursor(x: 0, y: 0)
        editor.type("C")
        #expect(editor.frames[0].edits == [CellEdit(x: 1, y: 0), CellEdit(x: 0, y: 0)])
        for code: UInt8 in [65, 66, 67] {
            editor.selectAll()
            editor.typeCode(code)
            editor.fillWithCharacter()
        }
        #expect(editor.frames[0].edits.count <= 40)
    }

    // Review I8: a marker always ends a frame, and with markers in the stream nothing else splits.
    @Test func markersKeepUnchangedFramesAndIgnoreRecordedPauses() {
        let a = Kit.frame(delay: 0.5, [(1, 1, Kit.cell("A"))])
        let same = Kit.frame(delay: 1.0, [(1, 1, Kit.cell("A"))])
        let ab = Kit.frame(delay: 0.5, [(1, 1, Kit.cell("A")), (2, 1, Kit.cell("B"))])
        let stream = AnimationEncoder.encode([a, same, ab], options: AnimationExportOptions(order: .asDrawn, frameMarkers: true))
        let frames = AnimationImporter.frames(ArtFile(data: stream.data, fileExtension: "ans"))
        #expect(frames.count == 3)
        #expect(frames.map(\.delay) == [0.5, 1.0, 0.5])

        let paused = Kit.frame([(1, 1, Kit.cell("A")), (2, 1, Kit.cell("B"))],
                               edits: [CellEdit(x: 1, y: 1, time: 0), CellEdit(x: 2, y: 1, time: 1)])
        let recorded = AnimationEncoder.encode([Kit.frame(), paused], options: AnimationExportOptions(order: .asDrawn, frameMarkers: true))
        #expect(AnimationImporter.frames(ArtFile(data: recorded.data, fileExtension: "ans")).count == 2)
    }

    // Review I6: what a real 25 line terminal would do differently is reported before export.
    @Test func bottomRightCellAndTallFramesAreReported() {
        var full = Kit.frame(columns: 80, rows: 25)
        #expect(AnimationEncoder.terminalWarnings([full]).isEmpty)
        full.layers[0].canvas.set(Kit.cell("X"), x: 79, y: 24)
        #expect(AnimationEncoder.terminalWarnings([full]).contains { $0.contains("bottom right") })
        let tall = Kit.frame(columns: 80, rows: 30, [(0, 27, Kit.cell("T"))])
        #expect(AnimationEncoder.terminalWarnings([tall]).contains { $0.contains("25 rows") })
        // Blank rows below 25 do not matter.
        #expect(AnimationEncoder.terminalWarnings([Kit.frame(columns: 80, rows: 30)]).isEmpty)
    }

    // Review I7: unchanged rows are compared by identity, so a long, tall stream imports quickly.
    @Test func longTallStreamsImportQuickly() {
        var text = ""
        for i in 0..<4_000 { text += "\u{1B}[\(i % 400 + 1);\(i % 80 + 1)H\(Character(Unicode.Scalar(65 + i % 26)!))" }
        let file = ArtFile(data: Data(text.utf8), fileExtension: "ans")
        let start = Date()
        let frames = AnimationImporter.frames(file)
        let seconds = Date().timeIntervalSince(start)
        print("import of 4000 writes over 400 rows (debug build): \(frames.count) frames in \(String(format: "%.2f", seconds)) s")
        #expect(frames.count == 10)
        // Full width rows are passed through, not copied, so unchanged rows compare by identity.
        let row = Array(repeating: AnsiCell(code: 65), count: 80)
        let screen = AnsiScreen(columns: 80, rows: [row])
        let grid = AnimationImporter.grid(screen, columns: 80, rows: 3)
        let same = row.withUnsafeBufferPointer { a in grid[0].withUnsafeBufferPointer { $0.baseAddress == a.baseAddress } }
        let blanksShared = grid[1].withUnsafeBufferPointer { a in grid[2].withUnsafeBufferPointer { $0.baseAddress == a.baseAddress } }
        #expect(same && blanksShared)
    }

    // Review M15: a frame whose only layer is hidden exports what the editor shows and saves.
    @Test func aSingleHiddenLayerMatchesThePlainSave() {
        let editor = CanvasEditor(canvas: EditCanvas(columns: 4, height: 1))
        editor.type("A")
        editor.setLayerVisible(0, false)
        #expect(editor.frames[0].composite == editor.flattenedCanvas)
    }
}
