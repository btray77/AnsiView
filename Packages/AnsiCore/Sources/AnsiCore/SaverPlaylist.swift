import Foundation

/// The screen saver's list of pieces (plan 10 ruling 13).
public enum SaverPlaylist {
    /// File extensions the saver plays.
    public static let artExtensions: Set<String> = ["ans", "asc", "ice", "nfo", "diz", "bin", "xb", "adf", "idf", "pcb", "avt"]

    /// The art file names among `names`, hidden files left out, in Finder order.
    public static func artFiles(_ names: [String]) -> [String] {
        names.filter { !$0.hasPrefix(".") && artExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// `items` in an order that depends only on `seed` (xorshift Fisher-Yates).
    public static func shuffled<T>(_ items: [T], seed: UInt64) -> [T] {
        var result = items
        var state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
        func next() -> UInt64 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return state
        }
        if result.count > 1 {
            for i in stride(from: result.count - 1, to: 0, by: -1) {
                result.swapAt(i, Int(next() % UInt64(i + 1)))
            }
        }
        return result
    }
}

/// One piece playing in the screen saver: drawn at `baud` (0 at once), then held, then finished.
/// Tall art shows a 25 line window that follows the cursor, as the viewer's playback does.
public struct SaverPlayback {
    public enum Phase: Equatable { case drawing, holding, finished }

    public let baud: Int
    public let holdSeconds: Double
    public private(set) var phase = Phase.drawing
    private var terminal: AnsiTerminal
    private let canvasRows: Int
    private var credit = 0.0
    private var held = 0.0
    private var viewportTop: Int?

    public init(file: ArtFile, baud: Int, holdSeconds: Double) {
        self.baud = baud
        self.holdSeconds = holdSeconds
        terminal = AnsiTerminal(file)
        canvasRows = AnsiAnalysis(file).canvasRows
    }

    /// Bytes drawn so far.
    public var position: Int { terminal.position }

    public mutating func advance(seconds: Double) {
        switch phase {
        case .drawing:
            if baud <= 0 {
                terminal.runToEnd()
            } else {
                // 8N1: ten bits a byte.
                credit += seconds * Double(baud) / 10
                let count = Int(credit)
                credit -= Double(count)
                if count > 0 { terminal.advance(byteCount: count) }
            }
            viewportTop = TerminalViewport.follow(cursorRow: terminal.cursorRow, previousTop: viewportTop, canvasRows: canvasRows)
            if terminal.isFinished { phase = .holding }
        case .holding:
            held += seconds
            if held >= holdSeconds { phase = .finished }
        case .finished:
            break
        }
    }

    /// What is on screen now.
    public var screen: AnsiScreen {
        let full = terminal.screen(minimumRows: min(canvasRows, TerminalViewport.rows))
        guard full.rows.count > TerminalViewport.rows else { return full }
        return full.window(top: viewportTop ?? 0, rows: TerminalViewport.rows)
    }
}
