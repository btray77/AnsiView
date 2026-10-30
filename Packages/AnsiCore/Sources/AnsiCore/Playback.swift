import Foundation

/// The playback position of a stream file, measured in bytes, divided into frames for stepping.
/// A frame is one export frame at the default speed: 1/15 s at 2400 baud (16 bytes). Slices that
/// change nothing on screen merge into the next, so each step shows something new.
public struct PlaybackTimeline {
    public static let bytesPerFrame = 16

    /// Bytes in the stream (0 for binary formats).
    public let length: Int
    /// Byte positions where each frame ends, strictly increasing; the last is `length`.
    public let frameEnds: [Int]

    public init(_ file: ArtFile) {
        var terminal = AnsiTerminal(file)
        let length = file.stream.count
        var ends: [Int] = []
        var lastEdits = 0
        while !terminal.isFinished {
            terminal.advance(byteCount: Self.bytesPerFrame)
            if terminal.edits != lastEdits {
                lastEdits = terminal.edits
                ends.append(terminal.position)
            }
        }
        // Trailing bytes that change nothing belong to the last frame.
        if length > 0 {
            if ends.isEmpty { ends.append(length) } else { ends[ends.count - 1] = length }
        }
        self.length = length
        self.frameEnds = ends
    }

    /// Number of frames complete at `position`.
    public func frameIndex(at position: Int) -> Int {
        firstIndex(where: { $0 > position })
    }

    /// The position one frame forward (+1) or back (-1) from `position`.
    public func step(from position: Int, by delta: Int) -> Int {
        guard !frameEnds.isEmpty, delta != 0 else { return min(max(0, position), length) }
        if delta > 0 {
            let index = firstIndex(where: { $0 > position })
            return index + delta - 1 < frameEnds.count ? frameEnds[index + delta - 1] : length
        }
        let index = firstIndex(where: { $0 >= position }) + delta
        return index >= 0 ? frameEnds[index] : 0
    }

    public func fraction(at position: Int) -> Double {
        length > 0 ? Double(min(max(0, position), length)) / Double(length) : 0
    }

    public func position(atFraction fraction: Double) -> Int {
        Int((min(1, max(0, fraction)) * Double(length)).rounded())
    }

    /// Binary search: the first index whose end satisfies `predicate` (monotonic), or the count.
    private func firstIndex(where predicate: (Int) -> Bool) -> Int {
        var low = 0, high = frameEnds.count
        while low < high {
            let mid = (low + high) / 2
            if predicate(frameEnds[mid]) { high = mid } else { low = mid + 1 }
        }
        return low
    }
}

/// Playback speeds remembered per file, most recently set last, capped at `limit` files.
/// Stored in user defaults as strings of the form "key=baud".
public struct SpeedMemory {
    public static let limit = 500

    private var entries: [(key: String, baud: Int)] = []

    /// Reads a stored value; anything that is not a list of "key=baud" strings is ignored.
    public init(serialized: Any?) {
        guard let list = serialized as? [Any] else { return }
        for item in list {
            guard let text = item as? String, let equals = text.lastIndex(of: "=") else { continue }
            let key = String(text[..<equals])
            guard !key.isEmpty, let baud = Int(text[text.index(after: equals)...]) else { continue }
            set(baud, for: key)
        }
    }

    public var serialized: [String] { entries.map { "\($0.key)=\($0.baud)" } }

    public func speed(for key: String) -> Int? {
        entries.last { $0.key == key }?.baud
    }

    public mutating func set(_ baud: Int, for key: String) {
        entries.removeAll { $0.key == key }
        entries.append((key, baud))
        if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
    }
}

/// While tall art plays, the player shows a 25 line window that follows the cursor the way a DOS
/// terminal screen would, moving as little as possible to keep the cursor in view.
public enum TerminalViewport {
    public static let rows = 25

    /// The top row of the window. Without a previous window the cursor sits on the bottom line
    /// (or the window starts at row 0).
    public static func follow(cursorRow: Int, previousTop: Int?, canvasRows: Int) -> Int {
        let maxTop = max(0, canvasRows - rows)
        let cursor = max(0, cursorRow)
        var top = previousTop ?? max(0, cursor - (rows - 1))
        if cursor < top { top = cursor }
        if cursor >= top + rows { top = cursor - (rows - 1) }
        return min(max(0, top), maxTop)
    }
}

extension AnsiScreen {
    /// Exactly `rows` rows starting at `top`, padded with blank cells past the end.
    public func window(top: Int, rows count: Int) -> AnsiScreen {
        let start = min(max(0, top), rows.count)
        var slice = Array(rows[start..<min(rows.count, start + count)])
        while slice.count < count { slice.append(Array(repeating: AnsiCell(), count: columns)) }
        var result = self
        result.rows = slice
        return result
    }
}
