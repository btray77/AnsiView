import Foundation
import Testing
@testable import AnsiCore

/// The iOS player's clock driven playback (plan 8).
@Suite struct ArtPlaybackTests {
    /// 400 bytes of text on one screen, redrawn after a clear: an animation.
    private var animated: ArtFile {
        art(bytes(String(repeating: "A", count: 200) + "\u{1B}[2J" + String(repeating: "B", count: 200)))
    }

    /// Text down to row 60: taller than the 25 row terminal window.
    private var tall: ArtFile {
        art(bytes((0..<60).map { "line \($0)" }.joined(separator: "\r\n")))
    }

    @Test func instantShowsFinal() {
        var playback = ArtPlayback(animated)
        playback.play(baud: 0, at: 10)
        #expect(playback.state == .finished)
        #expect(playback.displayedScreen.rows == playback.finalScreen.rows)
    }

    @Test func bytesFollowBaud() {
        var playback = ArtPlayback(animated)
        playback.play(baud: 2400, at: 10)
        #expect(playback.state == .playing)
        #expect(playback.position == 0)
        let changed = playback.tick(at: 11, baud: 2400)
        #expect(changed)
        // 8N1 framing: 2400 baud is 240 bytes a second.
        #expect(playback.position == 240)
        #expect(playback.state == .playing)
    }

    @Test func finishesAtEnd() {
        var playback = ArtPlayback(animated)
        playback.play(baud: 2400, at: 0)
        _ = playback.tick(at: 100, baud: 2400)
        #expect(playback.state == .finished)
        #expect(playback.displayedScreen.rows == playback.finalScreen.rows)
    }

    @Test func tallArtUsesTerminalWindow() {
        var playback = ArtPlayback(tall)
        #expect(playback.analysis.canvasRows == 60)
        #expect(!playback.isTerminalMode)
        #expect(playback.displayedScreen.rows.count == 60)
        playback.play(baud: 2400, at: 0)
        _ = playback.tick(at: 1, baud: 2400)
        #expect(playback.isTerminalMode)
        #expect(playback.displayedScreen.rows.count == TerminalViewport.rows)
    }

    /// Display link ticks carry fractions of a byte: 30 ticks of 1/30 s at 300 baud are 30 bytes.
    @Test func fractionalBytesCarry() {
        var playback = ArtPlayback(animated)
        playback.play(baud: 300, at: 0)
        for tick in 1...30 { _ = playback.tick(at: Double(tick) / 30, baud: 300) }
        #expect(playback.position == 30)
    }

    /// The 25 row window follows the cursor down tall art.
    @Test func windowFollowsCursor() {
        var playback = ArtPlayback(tall)
        playback.play(baud: 2400, at: 0)
        // "line N\r\n" is 8 or 9 bytes: 520 bytes reach about line 55.
        _ = playback.tick(at: 520.0 / 240, baud: 2400)
        let text = ArtText.plainText(playback.displayedScreen)
        #expect(text.contains("line 50"))
        #expect(!text.contains("line 20\n"))
    }

    /// Switching to Instant mid playback finishes it.
    @Test func instantMidPlaybackFinishes() {
        var playback = ArtPlayback(animated)
        playback.play(baud: 2400, at: 0)
        _ = playback.tick(at: 0.5, baud: 2400)
        _ = playback.tick(at: 0.6, baud: 0)
        #expect(playback.state == .finished)
    }

    @Test func pauseStopsAdvance() {
        var playback = ArtPlayback(animated)
        playback.play(baud: 1200, at: 0)
        _ = playback.tick(at: 1, baud: 1200)
        #expect(playback.position == 120)
        playback.pause()
        #expect(playback.state == .paused)
        let changedWhilePaused = playback.tick(at: 6, baud: 1200)
        #expect(!changedWhilePaused)
        #expect(playback.position == 120)
        playback.resume(at: 6)
        _ = playback.tick(at: 7, baud: 1200)
        #expect(playback.position == 240)
    }

    @Test func skipToEndShowsFinal() {
        var playback = ArtPlayback(animated)
        playback.play(baud: 300, at: 0)
        _ = playback.tick(at: 1, baud: 300)
        playback.skipToEnd()
        #expect(playback.state == .finished)
        #expect(playback.displayedScreen.rows == playback.finalScreen.rows)
    }

    @Test func emptyFileIsSafe() {
        var playback = ArtPlayback(ArtFile(data: Data(), fileExtension: "ans"))
        playback.play(baud: 2400, at: 0)
        _ = playback.tick(at: 1, baud: 2400)
        #expect(playback.state == .finished)
        #expect(playback.image(blinkVisible: true) != nil)
    }

    @Test func staticArtIsNotAnimated() {
        let playback = ArtPlayback(art(bytes("Hello")))
        #expect(!playback.isAnimated)
        #expect(ArtPlayback(animated).isAnimated)
    }

    @Test func imageIsVGASized() throws {
        let playback = ArtPlayback(art(bytes("Hello")))
        let rendered = try #require(playback.image(blinkVisible: true))
        #expect(rendered.image.width == 80 * 8 * rendered.scale)
    }
}
