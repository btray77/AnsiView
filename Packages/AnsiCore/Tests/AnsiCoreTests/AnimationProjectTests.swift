import Foundation
import Testing
@testable import AnsiCore

/// Ruling 9: `.ansiproj` version 2 keeps every frame.
@Suite struct AnimationProjectTests {
    typealias Kit = AnimationTestKit

    private func json(_ project: ArtProject) throws -> String {
        String(decoding: try project.data(), as: UTF8.self)
    }

    @Test func framesRoundTrip() throws {
        var second = Kit.frame(columns: 10, rows: 4, delay: 1.25, [(1, 1, Kit.cell("Q", fg: 12))],
                               edits: [CellEdit(x: 1, y: 1, time: 0.5), CellEdit(x: 2, y: 1)])
        second.layers.append(CanvasLayer(name: "Top", visible: false, canvas: EditCanvas(columns: 10, height: 4)))
        second.activeLayer = 1
        let frames = [Kit.frame(columns: 10, rows: 4, delay: 0.2, [(0, 0, Kit.cell("P"))], edits: [CellEdit(x: 0, y: 0)]), second]
        let project = ArtProject(frames: frames, currentFrame: 1)
        let text = try json(project)
        #expect(text.contains("\"version\":2"))
        let back = try ArtProject(data: try project.data())
        #expect(back.frames == frames)
        #expect(back.currentFrame == 1)
        #expect(back.layers.count == 2 && back.activeLayer == 1)
    }

    @Test func aSingleFrameWithoutALogIsVersionOneAsBefore() throws {
        let project = ArtProject(layers: [CanvasLayer(name: "Background", canvas: EditCanvas(columns: 4, height: 2))])
        let text = try json(project)
        #expect(text.contains("\"version\":1"))
        #expect(!text.contains("delay") && !text.contains("currentFrame") && !text.contains("edits"))
        let back = try ArtProject(data: try project.data())
        #expect(back.frames.count == 1 && back.frames[0].delay == AnimationFrame.defaultDelay)
    }

    @Test func versionThreeIsRefused() throws {
        let data = Data(#"{"format": "AnsiView project", "version": 3}"#.utf8)
        #expect(throws: ArtProject.ProjectError.newerVersion(3)) { try ArtProject(data: data) }
    }

    @Test func anEditorSavesAndReopensItsFrames() throws {
        let editor = CanvasEditor(canvas: EditCanvas(columns: 10, height: 4))
        editor.tracksEdits = true
        editor.type("A")
        editor.addFrame()
        editor.type("B")
        editor.setFrameDelay(1, seconds: 2)
        let reopened = CanvasEditor(project: try ArtProject(data: try editor.project.data()))
        #expect(reopened.frames == editor.frames)
        #expect(reopened.currentFrame == 1)
    }
}
