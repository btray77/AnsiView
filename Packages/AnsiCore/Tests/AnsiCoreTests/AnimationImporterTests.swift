import Foundation
import Testing
@testable import AnsiCore

@Suite struct AnimationImporterTests {
    typealias Kit = AnimationTestKit

    private func file(_ text: String) -> ArtFile { ArtFile(data: Data(text.utf8), fileExtension: "ans") }

    private func text(_ frame: AnimationFrame, row: Int = 0, count: Int = 5) -> String {
        String((0..<count).map { Character(CP437.unicode[Int(frame.composite[$0, row].code)]) })
    }

    @Test func splitsAtAClearScreen() {
        let frames = AnimationImporter.frames(file("AB\u{1B}[2JCD"))
        #expect(frames.map { text($0) } == ["AB   ", "CD   "])
        #expect(frames.allSatisfy { $0.composite.height == 25 })
    }

    @Test func splitsAtAnIdleRun() {
        let stream = "AB" + String(repeating: "\r", count: 60) + "\u{1B}[1;6HX"
        let frames = AnimationImporter.frames(file(stream))
        #expect(frames.map { text($0, count: 6) } == ["AB    ", "AB   X"])
        // Held from the B to the X: 60 CRs, the 6 byte move and the X itself.
        #expect(abs(frames[0].delay - 67 * PaddingDelay.characterTime(baud: 2400)) < 0.0005)
        let fast = AnimationImporter.frames(file(stream), options: AnimationImportOptions(idleBytes: 80))
        #expect(fast.count == 1)
    }

    @Test func splitsWhereACellIsDrawnAgain() {
        let frames = AnimationImporter.frames(file("ABC\u{1B}[1;1HZ\u{1B}[1;1HY"))
        #expect(frames.map { text($0, count: 3) } == ["ABC", "ZBC", "YBC"])
        #expect(frames[0].delay == 0)
    }

    @Test func aStillIsOneFrameEqualToTheFinalScreen() {
        let art = file("\u{1B}[1;31mHello\r\n\u{1B}[0mWorld")
        let frames = AnimationImporter.frames(art)
        #expect(frames.count == 1)
        let final = AnsiAnalysis(art).finalScreen
        #expect(text(frames[0]) == "Hello" && text(frames[0], row: 1) == "World")
        #expect(frames[0].composite[0, 0] == final.rows[0][0])
    }

    @Test func defaultIdleIsFortyEightBytes() {
        #expect(AnimationImportOptions().idleBytes == 48)
        // 40 bytes of cursor and colour changes between two writes are drawing, not a pause.
        let noise = "AB" + String(repeating: "\u{1B}[40m", count: 8) + "\u{1B}[1;6HX"
        #expect(AnimationImporter.frames(file(noise)).count == 1)
    }

    @Test func invisibleChangesDoNotSplit() {
        // A space recoloured (same black background) looks the same, so drawing over it is not a redraw.
        let frames = AnimationImporter.frames(file("\u{1B}[32m \u{1B}[1;1H\u{1B}[37mA"))
        #expect(frames.count == 1)
        #expect(text(frames[0], count: 1) == "A")
    }

    @Test func editLogsFollowTheStream() {
        let frames = AnimationImporter.frames(file("\u{1B}[1;5HB\u{1B}[1;1HA"))
        #expect(frames.count == 1)
        #expect(frames[0].edits == [CellEdit(x: 4, y: 0), CellEdit(x: 0, y: 0)])
    }

    @Test func frameMarkersGiveExactFramesAndDelays() {
        let source = Kit.movingBox(delays: [0.5, 0.25, 1.0])
        let stream = AnimationEncoder.encode(source, options: AnimationExportOptions(order: .asDrawn, frameMarkers: true))
        let frames = AnimationImporter.frames(ArtFile(data: stream.data, fileExtension: "ans"))
        #expect(frames.count == 3)
        #expect(frames.map(\.delay) == [0.5, 0.25, 1.0])
        let rows = 6
        let wanted = Kit.targets(source, rows: rows)
        for (k, frame) in frames.enumerated() {
            let got = (0..<rows).map { y in (0..<20).map { frame.composite[$0, y] } }
            #expect(got == wanted[k], "frame \(k)")
        }
    }

    @Test(arguments: AnimationOrder.allCases)
    func exportThenImportWithoutMarkers(_ order: AnimationOrder) {
        let source = Kit.movingBox(delays: [0.5, 0.25, 1.0])
        let stream = AnimationEncoder.encode(source, options: AnimationExportOptions(order: order))
        let frames = AnimationImporter.frames(ArtFile(data: stream.data, fileExtension: "ans"))
        #expect(frames.count == 3)
        let c = PaddingDelay.characterTime(baud: 2400)
        for (k, frame) in frames.enumerated() {
            #expect(abs(frame.delay - [0.5, 0.25, 1.0][k]) <= c + 0.001, "\(order) frame \(k): \(frame.delay)")
        }
        let wanted = Kit.targets(source, rows: 6)
        for (k, frame) in frames.enumerated() {
            #expect((0..<6).map { y in (0..<20).map { frame.composite[$0, y] } } == wanted[k])
        }
    }

    @Test func importedFramesReplayInTheirOriginalOrder() {
        // Re-exporting imported frames as drawn writes the changes in the stream's order.
        let art = file("ABC\u{1B}[1;3HZ\u{1B}[1;1HY")
        let frames = AnimationImporter.frames(art)
        #expect(frames.count == 2)
        let body = AnimationEncoder.encode(frames, options: AnimationExportOptions(order: .asDrawn, baud: 0)).body
        let z = body.firstIndex(of: UInt8(ascii: "Z"))!, y = body.firstIndex(of: UInt8(ascii: "Y"))!
        #expect(z < y)
        #expect(Kit.replay(AnimationEncoder.encode(frames, options: AnimationExportOptions()), frames).reached.count == 2)
    }
}
