import Foundation
import Testing
@testable import AnsiCore

private func art(_ text: String) -> ArtFile { ArtFile(data: Data(text.utf8), fileExtension: "ans") }

@Suite struct SaverPlaylistTests {
    @Test func listsOnlyArt() {
        let names = ["b.ANS", "a.ans", "notes.pdf", ".hidden.ans", "c.xb", "d.bin", "e.asc", "f.png", "FILE_ID.DIZ"]
        #expect(SaverPlaylist.artFiles(names) == ["a.ans", "b.ANS", "c.xb", "d.bin", "e.asc", "FILE_ID.DIZ"])
    }

    @Test func shuffleIsStableForSeed() {
        let items = Array(0..<20)
        let a = SaverPlaylist.shuffled(items, seed: 42)
        #expect(a == SaverPlaylist.shuffled(items, seed: 42))
        #expect(a.sorted() == items)
        #expect(a != items)
        #expect(SaverPlaylist.shuffled(items, seed: 43) != a)
        #expect(SaverPlaylist.shuffled([Int](), seed: 1).isEmpty)
    }

    @Test func drawsAtBaudThenHoldsThenFinishes() {
        // 100 bytes at 1000 baud (100 bytes a second) take one second.
        var playback = SaverPlayback(file: art(String(repeating: "A", count: 100)), baud: 1000, holdSeconds: 2)
        #expect(playback.phase == .drawing)
        playback.advance(seconds: 0.5)
        #expect(playback.phase == .drawing)
        #expect(playback.position == 50)
        playback.advance(seconds: 0.6)
        #expect(playback.phase == .holding)
        playback.advance(seconds: 1.5)
        #expect(playback.phase == .holding)
        playback.advance(seconds: 1)
        #expect(playback.phase == .finished)
    }

    @Test func instantDrawsAtOnce() {
        var playback = SaverPlayback(file: art("HELLO"), baud: 0, holdSeconds: 1)
        playback.advance(seconds: 0.01)
        #expect(playback.phase == .holding)
        #expect(playback.screen.rows[0].prefix(5).map(\.code) == Array("HELLO".utf8))
    }

    @Test func tallArtShowsAWindowFollowingTheCursor() {
        let lines = (0..<60).map { "line \($0)" }.joined(separator: "\r\n")
        var playback = SaverPlayback(file: art(lines), baud: 0, holdSeconds: 1)
        playback.advance(seconds: 0.1)
        let screen = playback.screen
        #expect(screen.rows.count == TerminalViewport.rows)
        let last = String(decoding: screen.rows[24].prefix(7).map(\.code), as: UTF8.self)
        #expect(last == "line 59")
    }

    @Test func shortArtKeepsItsHeight() {
        var playback = SaverPlayback(file: art("A\r\nB"), baud: 0, holdSeconds: 1)
        playback.advance(seconds: 0.1)
        #expect(playback.screen.rows.count >= 2)
        #expect(playback.screen.rows.count <= TerminalViewport.rows)
    }
}
