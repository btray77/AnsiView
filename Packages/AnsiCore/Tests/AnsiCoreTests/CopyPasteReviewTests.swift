import Foundation
import ImageIO
import Testing
@testable import AnsiCore

/// Fixes from the copy and paste final review.
@Suite struct CopyPasteReviewTests {
    static let sample = CellClipboardTests.sample

    // Important 2: the picture is supplied on demand, not encoded on every copy.
    @Test func picturesAreDeferred() throws {
        let clip = CellClipboard(region: Self.sample)
        #expect(clip.immediateRepresentations(.all).map(\.type) == [CellClipboard.cellsType, CellClipboard.textType, CellClipboard.ansiType])
        #expect(clip.deferredImageTypes(.all) == [CellClipboard.pngType, CellClipboard.tiffType])
        #expect(clip.immediateRepresentations(.image).isEmpty)
        #expect(clip.deferredImageTypes(.image) == [CellClipboard.pngType, CellClipboard.tiffType])
        #expect(clip.deferredImageTypes(.text).isEmpty && clip.deferredImageTypes(.ansi).isEmpty)
        let png = try #require(clip.imageData(forType: CellClipboard.pngType))
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 48 && image.height == 64)
        #expect(clip.imageData(forType: CellClipboard.tiffType) != nil)
        #expect(clip.imageData(forType: "public.jpeg") == nil)
        // A selection too big to draw offers no picture, decided without rendering.
        let row = Array(repeating: AnsiCell(code: 0xDB), count: 1000)
        let huge = CellClipboard(region: CanvasRegion(cells: Array(repeating: row, count: 1500)))
        #expect(huge.deferredImageTypes(.all).isEmpty)
    }

    // Important 3: ANSI text pastes back as art.
    @Test func ansiPastesAsCells() throws {
        typealias C = CellClipboard
        #expect(C.pasteChoice(types: [C.textType, C.ansiType, C.pngType]) == .ansi)
        #expect(C.pasteChoice(types: [C.cellsType, C.ansiType]) == .cells)
        let clip = CellClipboard(region: Self.sample)
        let region = try #require(C.region(fromANSI: clip.ansiText))
        #expect(region.width == 3 && region.height == 2)
        #expect(region.cells[0][0] == Self.sample.cells[0][0])
        #expect(region.cells[1][1].blink && region.cells[1][1].bg == Palette.vga[4])
        #expect(region.cells[0][2].bg == Palette.vga[12])
        #expect(C.looksLikeANSI("x\u{1B}[31my") && !C.looksLikeANSI("plain"))
        #expect(C.region(fromANSI: "") == nil)
    }

    // Important 4: nothing else edits the canvas while a paste floats.
    @Test func editsWaitForTheFloatingPaste() {
        let editor = CanvasEditor(canvas: EditCanvas(columns: 10, height: 4))
        editor.select(CellRect(x: 0, y: 0, width: 3, height: 3))
        editor.beginFloating(Self.sample)
        let before = editor.canvas
        editor.fillWithCharacter()
        editor.clearSelection()
        editor.deleteForward()
        editor.type("abc")
        editor.setIceColors(true)
        editor.resize(columns: 4, height: 4)
        #expect(editor.canvas == before)
        #expect(!editor.undoManager.canUndo)
        #expect(editor.floating != nil)
        editor.stampFloating()
        #expect(editor.undoManager.undoActionName == "Paste")
    }

    @Test func floatingStaysOnACanvasThatShrinksOnUndo() {
        let editor = CanvasEditor(canvas: EditCanvas(columns: 10, height: 4))
        editor.resize(columns: 20, height: 4)
        editor.beginFloating(Self.sample, x: 18, y: 0)
        editor.undoManager.undo()
        #expect(editor.canvas.columns == 10)
        #expect(editor.floating?.x == 9)
    }

    // Important 5: pasted cells follow the canvas's iCE setting.
    @Test func pastedCellsFollowTheCanvasIce() throws {
        let bright = AnsiCell(code: 0x41, fg: Palette.vga[15], bg: Palette.vga[12])
        let blinking = AnsiCell(code: 0x42, fg: Palette.vga[15], bg: Palette.vga[4], blink: true)
        let region = CanvasRegion(cells: [[bright, blinking]])
        let plain = CanvasEditor(canvas: EditCanvas(columns: 10, height: 2))
        plain.beginFloating(region)
        let a = try #require(plain.floating?.region.cells[0][0])
        #expect(a.bg == Palette.vga[4] && a.blink)
        #expect(plain.floating?.region.cells[0][1] == blinking)
        var iceCanvas = EditCanvas(columns: 10, height: 2)
        iceCanvas.setIceColors(true)
        let ice = CanvasEditor(canvas: iceCanvas)
        ice.beginFloating(region)
        #expect(ice.floating?.region.cells[0][0] == bright)
        let b = try #require(ice.floating?.region.cells[0][1])
        #expect(b.bg == Palette.vga[12] && !b.blink)
    }
}
