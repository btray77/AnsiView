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

// MARK: Per file speed

@Test func identityIsStableAndContentBased() {
    let a = art(bytes("Hello"), ext: "ans")
    let b = art(bytes("Hello"), ext: "asc")
    let c = art(bytes("Hellp"), ext: "ans")
    #expect(a.identity == b.identity)
    #expect(a.identity != c.identity)
    #expect(a.identity.count == 16)
    #expect(a.identity.allSatisfy { "0123456789abcdef".contains($0) })
}

@Test func rememberAndRecall() {
    var memory = SpeedMemory(serialized: nil)
    #expect(memory.speed(for: "abc") == nil)
    memory.set(9600, for: "abc")
    #expect(memory.speed(for: "abc") == 9600)
    let restored = SpeedMemory(serialized: memory.serialized)
    #expect(restored.speed(for: "abc") == 9600)
}

@Test func setMovesToEnd() {
    var memory = SpeedMemory(serialized: nil)
    memory.set(300, for: "a")
    memory.set(1200, for: "b")
    memory.set(2400, for: "a")
    #expect(memory.serialized == ["b=1200", "a=2400"])
}

@Test func limitDropsOldest() {
    var memory = SpeedMemory(serialized: nil)
    for i in 0...SpeedMemory.limit { memory.set(2400, for: "k\(i)") }
    #expect(memory.speed(for: "k0") == nil)
    #expect(memory.speed(for: "k\(SpeedMemory.limit)") == 2400)
    #expect(memory.serialized.count == SpeedMemory.limit)
}

@Test func corruptEntriesAreIgnored() {
    let memory = SpeedMemory(serialized: ["x", "a=b", "k=2400", 5] as [Any])
    #expect(memory.speed(for: "k") == 2400)
    #expect(memory.speed(for: "a") == nil)
    #expect(memory.serialized == ["k=2400"])
    #expect(SpeedMemory(serialized: 7).serialized.isEmpty)
}

// MARK: Terminal viewport

@Test func viewportStartsAtTop() {
    #expect(TerminalViewport.follow(cursorRow: 3, previousTop: nil, canvasRows: 60) == 0)
}

@Test func viewportFollowsDown() {
    #expect(TerminalViewport.follow(cursorRow: 30, previousTop: 0, canvasRows: 60) == 6)
}

@Test func viewportStaysWhileInside() {
    #expect(TerminalViewport.follow(cursorRow: 10, previousTop: 6, canvasRows: 60) == 6)
}

@Test func viewportFollowsUp() {
    #expect(TerminalViewport.follow(cursorRow: 2, previousTop: 6, canvasRows: 60) == 2)
}

@Test func viewportClampsToCanvas() {
    #expect(TerminalViewport.follow(cursorRow: 999, previousTop: 0, canvasRows: 40) == 15)
    #expect(TerminalViewport.follow(cursorRow: 5, previousTop: 50, canvasRows: 40) == 5)
    #expect(TerminalViewport.follow(cursorRow: 5, previousTop: nil, canvasRows: 10) == 0)
}

@Test func windowPastEndIsPadded() {
    let screen = parse(bytes("A\r\nB\r\nC"))
    let window = screen.window(top: 2, rows: 25)
    #expect(window.rows.count == 25)
    #expect(window.rows[0] == screen.rows[2])
    #expect(window.rows[1] == Array(repeating: AnsiCell(), count: screen.columns))
    #expect(window.columns == screen.columns)
}
