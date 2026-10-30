import Foundation
import Testing
@testable import AnsiCore

@Suite struct LayerTests {
    /// Bottom layer "AAAA", an upper layer with "B" at column 1.
    private func twoLayers() -> CanvasEditor {
        let editor = CanvasEditor(canvas: EditCanvas(columns: 4, height: 2))
        editor.type("AAAA")
        editor.addLayer()
        editor.setCursor(x: 1, y: 0)
        editor.type("B")
        return editor
    }

    @Test func compositeShowsUnsetCellsAsTransparent() {
        let editor = twoLayers()
        #expect(editor.layers.count == 2 && editor.activeLayer == 1)
        #expect(editor.canvas[0, 0] == AnsiCell()) // the active (upper) layer
        let shown = editor.displayCanvas
        #expect(shown[0, 0].code == 0x41 && shown[1, 0].code == 0x42 && shown[2, 0].code == 0x41)
        #expect(editor.flattenedCanvas == shown)
    }

    @Test func hiddenLayersAreNotShownOrSaved() throws {
        let editor = twoLayers()
        editor.setLayerVisible(1, false)
        #expect(editor.displayCanvas[1, 0].code == 0x41)
        let saved = try ArtWriter.data(editor.flattenedCanvas, format: .ansi, date: Date(timeIntervalSince1970: 0))
        var single = EditCanvas(columns: 4, height: 2)
        for x in 0..<4 { single.set(AnsiCell(code: 0x41), x: x, y: 0) }
        #expect(saved == (try ArtWriter.data(single, format: .ansi, date: Date(timeIntervalSince1970: 0))))
    }

    @Test func plainSaveOfLayersEqualsFlattenedCanvas() throws {
        let editor = twoLayers()
        let date = Date(timeIntervalSince1970: 1_000_000)
        let flat = try ArtWriter.data(editor.flattenedCanvas, format: .ansi, date: date)
        editor.flatten()
        #expect(editor.layers.count == 1)
        #expect(try ArtWriter.data(editor.canvas, format: .ansi, date: date) == flat)
        #expect(editor.canvas[1, 0].code == 0x42)
    }

    @Test func mergeDownAndOrder() {
        let editor = twoLayers()
        editor.addLayer()
        editor.setCursor(x: 3, y: 1)
        editor.type("C")
        #expect(editor.layers.count == 3)
        editor.moveLayer(by: -1)
        #expect(editor.activeLayer == 1 && editor.layers[1].canvas[3, 1].code == 0x43)
        editor.mergeDown()
        #expect(editor.layers.count == 2 && editor.activeLayer == 0)
        #expect(editor.canvas[3, 1].code == 0x43 && editor.canvas[0, 0].code == 0x41)
        #expect(editor.displayCanvas[1, 0].code == 0x42)
        // The bottom layer cannot merge down; the last layer cannot be deleted.
        editor.mergeDown()
        #expect(editor.layers.count == 2)
        editor.deleteLayer()
        editor.deleteLayer()
        #expect(editor.layers.count == 1)
    }

    @Test func layerCommandsUndo() {
        let editor = twoLayers()
        let before = editor.layers
        editor.mergeDown()
        #expect(editor.layers.count == 1)
        editor.undoManager.undo()
        #expect(editor.layers == before && editor.activeLayer == 1)
        editor.duplicateLayer()
        #expect(editor.layers.count == 3 && editor.layers[2].name.hasSuffix("copy"))
        editor.undoManager.undo()
        #expect(editor.layers.count == 2)
        editor.renameLayer(0, to: "Back")
        #expect(editor.layers[0].name == "Back")
    }

    @Test func sizeIceAndMetadataApplyToAllLayers() {
        let editor = twoLayers()
        editor.resize(columns: 6, height: 3)
        editor.setIceColors(true)
        editor.setMetadata(title: "T", author: "A", group: "G")
        for layer in editor.layers {
            #expect(layer.canvas.columns == 6 && layer.canvas.iceColors && layer.canvas.title == "T")
        }
        #expect(editor.flattenedCanvas.columns == 6 && editor.flattenedCanvas.title == "T")
    }

    @Test func movingOnAnUpperLayerLeavesItTransparent() {
        let editor = twoLayers()
        editor.setBackground(4)
        editor.select(CellRect(x: 1, y: 0, width: 1, height: 1))
        editor.moveSelection(dx: 1, dy: 0)
        editor.stampFloating()
        #expect(editor.canvas[1, 0] == AnsiCell())
        #expect(editor.displayCanvas[1, 0].code == 0x41 && editor.displayCanvas[2, 0].code == 0x42)
    }

    @Test func switchingLayersEditsTheChosenOne() {
        let editor = twoLayers()
        editor.selectLayer(0)
        editor.setCursor(x: 0, y: 1)
        editor.type("Z")
        #expect(editor.layers[0].canvas[0, 1].code == 0x5A && editor.layers[1].canvas[0, 1] == AnsiCell())
    }
}

@Suite struct ProjectFileTests {
    @Test func projectRoundTripKeepsLayers() throws {
        var start = EditCanvas(columns: 5, height: 2)
        start.sauceDate = DateComponents(year: 1995, month: 1, day: 2)
        start.sauceTInfo34 = [3, 4]
        let editor = CanvasEditor(canvas: start)
        editor.setMetadata(title: "Proj", author: "Me", group: "Us")
        editor.type("Hi")
        editor.addLayer()
        editor.setForeground(12)
        editor.type("X")
        editor.renameLayer(1, to: "Top")
        editor.setLayerVisible(1, false)
        var withScalar = editor.canvas
        withScalar.set(AnsiCell(code: 0x3F, scalar: "€"), x: 4, y: 1)
        let project = ArtProject(layers: [editor.layers[0], CanvasLayer(name: "Top", visible: false, canvas: withScalar)],
                                 activeLayer: 1)
        let data = try project.data()
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"format\":\"AnsiView project\"") || text.contains("\"format\" : \"AnsiView project\""))
        #expect(text.contains("frames"))
        let read = try ArtProject(data: data)
        #expect(read == project)
        #expect(read.layers[1].canvas[4, 1].scalar == "€")
        let reopened = CanvasEditor(project: read)
        #expect(reopened.layers.count == 2 && reopened.activeLayer == 1 && reopened.flattenedCanvas.title == "Proj")
    }

    @Test func rejectsOtherFilesAndNewerVersions() {
        #expect(throws: ArtProject.ProjectError.self) { try ArtProject(data: Data("not json".utf8)) }
        let newer = Data(#"{"format":"AnsiView project","version":2,"frames":[]}"#.utf8)
        #expect(throws: ArtProject.ProjectError.newerVersion(2)) { try ArtProject(data: newer) }
        let other = Data(#"{"format":"Something else","version":1}"#.utf8)
        #expect(throws: ArtProject.ProjectError.notAProject) { try ArtProject(data: other) }
    }

    @Test func projectKeepsFittedPalette() throws {
        var canvas = EditCanvas(columns: 2, height: 1)
        canvas.palette = (0..<16).map { RGB(r: UInt8($0 * 16), g: 7, b: UInt8(255 - $0)) }
        let project = ArtProject(layers: [CanvasLayer(name: "Base", canvas: canvas)])
        let read = try ArtProject(data: try project.data())
        #expect(read.layers[0].canvas.palette == canvas.palette)
    }
}
