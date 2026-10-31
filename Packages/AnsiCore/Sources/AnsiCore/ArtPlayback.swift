import CoreGraphics
import Foundation

/// Plays an art file at modem speed on a caller supplied clock, with no view: the iPhone and iPad
/// player and its Quick Look preview drive it from a display link. The rules are the macOS
/// player's (`Shared/AnsiPlayer.swift`): 8N1 framing (baud / 10 bytes a second), tall art plays in
/// a 25 row terminal window that follows the cursor, and the finished art is shown when the bytes
/// run out. ANSI music and modem sounds are not part of it.
public struct ArtPlayback {
    public enum State: Equatable {
        /// The finished art is on screen (before any playback, or after it ends).
        case finished
        case playing
        case paused
    }

    public let file: ArtFile
    public let analysis: AnsiAnalysis
    /// The finished art padded to the full canvas height.
    public let finalScreen: AnsiScreen
    public private(set) var state: State = .finished

    private var terminal: AnsiTerminal
    private var screen: AnsiScreen
    private var viewportTop: Int?
    private var lastTime: Double = 0
    private var byteCredit: Double = 0

    public init(_ file: ArtFile) {
        self.file = file
        analysis = AnsiAnalysis(file)
        var padded = analysis.finalScreen
        while padded.rows.count < analysis.canvasRows {
            padded.rows.append(Array(repeating: AnsiCell(), count: file.columns))
        }
        finalScreen = padded
        screen = padded
        terminal = AnsiTerminal(file)
    }

    /// True when the file redraws over itself (it replays by itself when opened).
    public var isAnimated: Bool { analysis.isAnimated }
    /// Bytes played so far.
    public var position: Int { terminal.position }
    /// The bytes in the file's stream (0 for binary screen formats).
    public var length: Int { file.stream.count }
    /// True while tall art is mid playback and only the 25 row terminal window is shown.
    public var isTerminalMode: Bool { analysis.canvasRows > TerminalViewport.rows && state != .finished }

    /// The screen to draw now.
    public var displayedScreen: AnsiScreen {
        guard state != .finished else { return finalScreen }
        if isTerminalMode { return screen.window(top: viewportTop ?? 0, rows: TerminalViewport.rows) }
        var padded = screen
        while padded.rows.count < analysis.canvasRows {
            padded.rows.append(Array(repeating: AnsiCell(), count: file.columns))
        }
        return padded
    }

    /// Starts from the first byte. Baud 0 (instant), or a file with nothing to play, shows the finished art.
    public mutating func play(baud: Int, at now: Double) {
        terminal = AnsiTerminal(file)
        viewportTop = nil
        guard baud > 0, length > 0 else {
            skipToEnd()
            return
        }
        state = .playing
        lastTime = now
        byteCredit = 0
        showTerminal()
    }

    /// Moves playback on to `now`. Returns true when the displayed screen changed.
    public mutating func tick(at now: Double, baud: Int) -> Bool {
        guard state == .playing else { return false }
        guard baud > 0 else {
            skipToEnd()
            return true
        }
        byteCredit += max(0, now - lastTime) * Double(baud) / 10
        lastTime = now
        // A whole byte that floating point sums leave a hair short of 1 still counts.
        let count = Int(byteCredit + 1e-9)
        guard count > 0 else { return false }
        byteCredit -= Double(count)
        terminal.advance(byteCount: count)
        if terminal.isFinished {
            skipToEnd()
        } else {
            showTerminal()
        }
        return true
    }

    public mutating func pause() {
        if state == .playing { state = .paused }
    }

    public mutating func resume(at now: Double) {
        guard state == .paused else { return }
        state = .playing
        lastTime = now
        byteCredit = 0
    }

    public mutating func skipToEnd() {
        state = .finished
        viewportTop = nil
        screen = finalScreen
    }

    /// The displayed screen rendered at the renderer's preferred scale for its height.
    public func image(blinkVisible: Bool) -> RenderedAnsi? {
        let shown = displayedScreen
        var options = RenderOptions(for: finalScreen)
        options.ninePixel = file.ninePixel
        options.scale = AnsiRenderer.preferredScale(rows: shown.rows.count)
        options.blinkVisible = blinkVisible
        return AnsiRenderer.render(shown, options: options)
    }

    private mutating func showTerminal() {
        screen = terminal.screen(minimumRows: analysis.canvasRows)
        viewportTop = TerminalViewport.follow(cursorRow: terminal.cursorRow, previousTop: viewportTop,
                                              canvasRows: analysis.canvasRows)
    }
}
