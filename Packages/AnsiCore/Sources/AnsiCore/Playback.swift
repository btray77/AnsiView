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
