import Foundation
import Testing
@testable import AnsiCore

func art(_ raw: [UInt8], ext: String? = nil) -> ArtFile { ArtFile(data: Data(raw), fileExtension: ext) }

// MARK: Timeline

@Test func framesEndAtLength() {
    let file = art(bytes(String(repeating: "A", count: 30) + "\u{1B}[2J" + String(repeating: "B", count: 40)))
    let timeline = PlaybackTimeline(file)
    #expect(timeline.length == 74)
    #expect(timeline.frameEnds.last == 74)
    #expect(zip(timeline.frameEnds, timeline.frameEnds.dropFirst()).allSatisfy { $0 < $1 })
}

@Test func unchangedSlicesMerge() {
    let moves = String(repeating: "\u{1B}[C", count: 22) // 66 bytes of cursor moves
    let file = art(bytes(String(repeating: "A", count: 16) + moves + "B"))
    let timeline = PlaybackTimeline(file)
    let moveRun = 17..<(16 + moves.utf8.count)
    #expect(!timeline.frameEnds.contains { moveRun.contains($0) })
    #expect(timeline.frameEnds == [16, timeline.length])
}

@Test func stepForwardAndBack() {
    let timeline = PlaybackTimeline(art(bytes(String(repeating: "A", count: 64))))
    let ends = timeline.frameEnds
    #expect(ends == [16, 32, 48, 64])
    #expect(timeline.step(from: 0, by: 1) == ends[0])
    #expect(timeline.step(from: ends[1], by: -1) == ends[0])
    #expect(timeline.step(from: ends[0], by: -1) == 0)
    #expect(timeline.step(from: timeline.length, by: 1) == timeline.length)
    #expect(timeline.step(from: 20, by: 1) == 32)
    #expect(timeline.step(from: 20, by: -1) == 16)
}

@Test func frameIndexCounts() {
    let timeline = PlaybackTimeline(art(bytes(String(repeating: "A", count: 64))))
    #expect(timeline.frameIndex(at: 0) == 0)
    #expect(timeline.frameIndex(at: 20) == 1)
    #expect(timeline.frameIndex(at: timeline.length) == timeline.frameEnds.count)
}

@Test func binaryFileHasNoFrames() {
    let timeline = PlaybackTimeline(art([UInt8](repeating: 0x41, count: 640), ext: "bin"))
    #expect(timeline.length == 0)
    #expect(timeline.frameEnds.isEmpty)
    #expect(timeline.step(from: 0, by: 1) == 0)
    #expect(timeline.step(from: 0, by: -1) == 0)
    #expect(timeline.fraction(at: 0) == 0)
    #expect(timeline.position(atFraction: 0.5) == 0)
}

@Test func seekClamps() {
    var terminal = AnsiTerminal(art(bytes("Hello")))
    terminal.seek(to: -5)
    #expect(terminal.position == 0)
    terminal.seek(to: 10_000)
    #expect(terminal.isFinished)
}

@Test func seekInsideEscapeFinishesIt() {
    let file = art(bytes("\u{1B}[31mX"))
    var seeking = AnsiTerminal(file)
    seeking.seek(to: 1)
    var advancing = AnsiTerminal(file)
    advancing.advance(byteCount: 1)
    #expect(seeking.position == advancing.position)
    #expect(seeking.screen().rows == advancing.screen().rows)
}

@Test func seekBackMatchesFreshPlay() {
    let file = art(bytes(String(repeating: "AB\r\n", count: 20)))
    var terminal = AnsiTerminal(file)
    terminal.seek(to: 50)
    terminal.seek(to: 10)
    var fresh = AnsiTerminal(file)
    fresh.advance(byteCount: 10)
    #expect(terminal.position == 10)
    #expect(terminal.screen().rows == fresh.screen().rows)
    #expect(terminal.cursorRow == fresh.cursorRow)
}

@Test func cursorRowTracksLines() {
    var terminal = AnsiTerminal(art(bytes("A\r\nB\r\nC")))
    terminal.runToEnd()
    #expect(terminal.cursorRow == 2)
}

@Test func fractionRoundTrips() {
    let timeline = PlaybackTimeline(art(bytes(String(repeating: "A", count: 64))))
    #expect(timeline.position(atFraction: timeline.fraction(at: 40)) == 40)
    #expect(timeline.position(atFraction: -1) == 0)
    #expect(timeline.position(atFraction: 2) == 64)
}
