import Foundation

/// Settings for writing an animation as an ANSI stream (rulings 4 to 6).
public struct AnimationExportOptions: Equatable {
    public var order: AnimationOrder
    /// The baud rate the delays are padded for (0 writes no padding).
    public var baud: Int
    /// As drawn only: pauses recorded in record mode become padding.
    public var replayPauses: Bool
    /// AnsiView frame markers, a custom extension (off by default, ruling 6).
    public var frameMarkers: Bool
    /// The SAUCE date when the frames have none.
    public var date: Date

    public init(order: AnimationOrder = .asDrawn, baud: Int = 2400, replayPauses: Bool = true,
                frameMarkers: Bool = false, date: Date = Date()) {
        self.order = order
        self.baud = baud
        self.replayPauses = replayPauses
        self.frameMarkers = frameMarkers
        self.date = date
    }

    public static func == (a: Self, b: Self) -> Bool {
        a.order == b.order && a.baud == b.baud && a.replayPauses == b.replayPauses && a.frameMarkers == b.frameMarkers
    }
}

/// An exported animation.
public struct AnimationStream {
    /// The file: the stream followed by SAUCE.
    public let data: Data
    /// The stream alone.
    public let body: [UInt8]
    /// Byte position (in `body`) at which each frame is completely on screen.
    public let boundaries: [Int]
    /// Characters each frame stays on screen: padding plus the next frame's lead in (ruling 5).
    public let holds: [Int]
}

/// Writes animation frames as one ANSI stream that redraws only what changes (ruling 4), with
/// delays made of padding characters (ruling 5).
public enum AnimationEncoder {
    static let header = Array("\u{1B}[0m\u{1B}[2J\u{1B}[H".utf8)
    static let trailer = Array("\u{1B}[0m".utf8)
    static let clear = Array("\u{1B}[0m\u{1B}[2J".utf8)
    /// The custom frame marker's first parameter (ruling 6): `ESC[?2416;<frame>;<ms>z`.
    public static let markerTag = 2416
    /// Recorded pauses shorter than this are drawing speed, not pauses (ruling 3).
    public static let minimumPause = 0.05
    public static let maximumPause = 2.0

    /// A cell as an exported stream can show it: codes a terminal would act on become their
    /// lookalikes, and UTF-8 only characters their CP437 stand in.
    public static func written(_ cell: AnsiCell) -> AnsiCell {
        var result = cell
        result.code = TextConvert.lookalikes[cell.code] ?? cell.code
        result.scalar = nil
        return result
    }

    public static func marker(frame: Int, delay: Double) -> [UInt8] {
        Array("\u{1B}[?\(markerTag);\(frame);\(Int((delay * 1000).rounded()))z".utf8)
    }

    public static func encode(_ frames: [AnimationFrame], options: AnimationExportOptions) -> AnimationStream {
        let composites = frames.map(\.composite)
        guard let first = composites.first else {
            return AnimationStream(data: Data(), body: [], boundaries: [], holds: [])
        }
        let columns = first.columns
        let rows = composites.map(\.height).max() ?? first.height
        let ice = first.iceColors
        var writer = Writer(columns: columns, rows: rows, ice: ice)
        writer.out = header
        var boundaries: [Int] = []
        var holds: [Int] = []
        /// Characters owed to the previous frame's delay, and its marker.
        var owed: (characters: Int, marker: [UInt8])?

        for (k, canvas) in composites.enumerated() {
            let target: [[AnsiCell]] = (0..<rows).map { y in (0..<columns).map { written(canvas[$0, y]) } }
            let mark = writer.out.count
            writer.cursor = nil  // every frame starts with an absolute move (ruling 4)
            writer.firstVisible = nil
            writeFrame(target, frame: frames[k], options: options, writer: &writer)
            let chunk = Array(writer.out[mark...])
            writer.out.removeSubrange(mark...)
            let leadIn = writer.firstVisible.map { $0 - mark } ?? chunk.count
            if let owed {
                let padding = max(0, owed.characters - leadIn - owed.marker.count)
                writer.out += owed.marker + Array(repeating: PaddingDelay.byte, count: padding)
                holds.append(owed.marker.count + padding + leadIn)
            }
            writer.out += chunk
            boundaries.append(writer.out.count)
            owed = (PaddingDelay.characters(seconds: frames[k].delay, baud: options.baud),
                    options.frameMarkers ? marker(frame: k, delay: frames[k].delay) : [])
        }
        if let owed {
            let padding = max(0, owed.characters - trailer.count - owed.marker.count)
            writer.out += owed.marker + Array(repeating: PaddingDelay.byte, count: padding)
            holds.append(owed.marker.count + padding + trailer.count)
        }
        writer.out += trailer
        let body = writer.out
        return AnimationStream(data: Data(body + sauce(first, rows: rows, date: options.date).encoded(fileSize: body.count)),
                               body: body, boundaries: boundaries, holds: holds)
    }

    // MARK: Frames

    private static func writeFrame(_ target: [[AnsiCell]], frame: AnimationFrame, options: AnimationExportOptions,
                                   writer: inout Writer) {
        let columns = writer.columns
        if options.order == .fullRedraw {
            let blankScreen = Writer.blankScreen(columns: columns, rows: writer.rows)
            // The first frame starts on the header's cleared screen.
            if writer.screen != blankScreen {
                writer.out += clear
                writer.sgr = SGRState()
                writer.firstVisible = writer.out.count
                writer.screen = blankScreen
            }
            let blank = AnsiCell()
            // A cleared screen: start each row with an absolute move.
            for y in target.indices {
                writer.cursor = nil
                for x in 0..<columns where target[y][x] != blank { writer.put(target[y][x], x: x, y: y) }
            }
            return
        }
        var changed: [(x: Int, y: Int)] = []
        for y in target.indices {
            for x in 0..<columns where writer.screen[y][x] != target[y][x] { changed.append((x, y)) }
        }
        var times: [Double?] = Array(repeating: nil, count: changed.count)
        if options.order == .asDrawn {
            var last: [Int: (index: Int, time: Double?)] = [:]
            for (index, edit) in frame.edits.enumerated() where edit.x >= 0 && edit.x < columns && edit.y >= 0 {
                last[edit.y * columns + edit.x] = (index, edit.time)
            }
            let ordered = changed.enumerated().sorted { a, b in
                let ka = last[a.element.y * columns + a.element.x]?.index ?? Int.max
                let kb = last[b.element.y * columns + b.element.x]?.index ?? Int.max
                return ka != kb ? ka < kb : a.offset < b.offset
            }
            changed = ordered.map(\.element)
            times = changed.map { last[$0.y * columns + $0.x]?.time }
        }
        var previousTime: Double?
        for (i, cell) in changed.enumerated() {
            if options.order == .asDrawn, options.replayPauses, let time = times[i] {
                if let previousTime, time - previousTime >= minimumPause {
                    writer.pad(PaddingDelay.characters(seconds: min(maximumPause, time - previousTime), baud: options.baud))
                }
                previousTime = time
            }
            writer.put(target[cell.y][cell.x], x: cell.x, y: cell.y)
        }
    }

    private static func sauce(_ canvas: EditCanvas, rows: Int, date: Date) -> Sauce {
        let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)
        return Sauce(title: canvas.title, author: canvas.author, group: canvas.group,
                     date: canvas.sauceDate ?? DateComponents(year: parts.year, month: parts.month, day: parts.day),
                     dataType: 1, fileType: 1,
                     tInfo: [UInt16(canvas.columns), UInt16(min(rows, 65535))] + canvas.sauceTInfo34.prefix(2),
                     flags: (canvas.sauceFlags & ~0x01) | (canvas.iceColors ? 0x01 : 0),
                     fontName: canvas.fontName, comments: canvas.comments)
    }

    /// The stream being written and what the screen shows at its end.
    struct Writer {
        let columns: Int
        let rows: Int
        let ice: Bool
        var out: [UInt8] = []
        var sgr = SGRState()
        /// Where the next character lands, or nil when it is not known for every terminal.
        var cursor: (x: Int, y: Int)? = (0, 0)
        var screen: [[AnsiCell]]
        /// Position just after the frame's first visible change.
        var firstVisible: Int?

        init(columns: Int, rows: Int, ice: Bool) {
            self.columns = columns
            self.rows = rows
            self.ice = ice
            screen = Self.blankScreen(columns: columns, rows: rows)
        }

        static func blankScreen(columns: Int, rows: Int) -> [[AnsiCell]] {
            Array(repeating: Array(repeating: AnsiCell(), count: columns), count: rows)
        }

        mutating func put(_ cell: AnsiCell, x: Int, y: Int) {
            move(x: x, y: y)
            out += sgr.transition(to: SGRState.wanted(for: cell, ice: ice))
            out.append(cell.code)
            if screen[y][x] != cell, firstVisible == nil { firstVisible = out.count }
            screen[y][x] = cell
            // After the last column ANSI.SYS has wrapped and VT100 terminals have not (ruling 4).
            cursor = x == columns - 1 ? nil : (x + 1, y)
        }

        /// Padding characters (ruling 5): the cursor ends in column 1 of its row.
        mutating func pad(_ count: Int) {
            guard count > 0 else { return }
            out += Array(repeating: PaddingDelay.byte, count: count)
            if let c = cursor { cursor = (0, c.y) }
        }

        private mutating func move(x: Int, y: Int) {
            if let c = cursor, c.x == x, c.y == y { return }
            var best = Self.cup(x: x, y: y)
            if let c = cursor {
                var options: [[UInt8]] = []
                if c.y == y {
                    if x > c.x {
                        options.append(Self.csi(x - c.x, "C"))
                        if let bridge = bridge(from: c.x, to: x, y: y) { options.append(bridge) }
                    } else {
                        options.append(Self.csi(c.x - x, "D"))
                        if x == 0 { options.append([0x0D]) }
                    }
                } else if c.x == x {
                    options.append(Self.csi(abs(y - c.y), y < c.y ? "A" : "B"))
                }
                for option in options where option.count < best.count { best = option }
            }
            out += best
            cursor = (x, y)
        }

        /// Rewrites up to 3 unchanged cells instead of a cursor move, when no colour changes.
        private func bridge(from start: Int, to end: Int, y: Int) -> [UInt8]? {
            guard end - start <= 3 else { return nil }
            var probe = sgr
            var bytes: [UInt8] = []
            for gx in start..<end {
                let cell = screen[y][gx]
                guard probe.transition(to: SGRState.wanted(for: cell, ice: ice)).isEmpty else { return nil }
                bytes.append(cell.code)
            }
            return bytes
        }

        static func csi(_ count: Int, _ final: Character) -> [UInt8] {
            Array("\u{1B}[\(count == 1 ? "" : String(count))\(final)".utf8)
        }

        static func cup(x: Int, y: Int) -> [UInt8] {
            if x == 0 && y == 0 { return Array("\u{1B}[H".utf8) }
            if x == 0 { return Array("\u{1B}[\(y + 1)H".utf8) }
            return Array("\u{1B}[\(y + 1);\(x + 1)H".utf8)
        }
    }
}

/// Tells standard ANSI apart from AnsiView's own extension (ruling 6).
public enum AnimationStreamCheck {
    /// True when the stream contains an AnsiView frame marker.
    public static func usesExtension(_ bytes: [UInt8]) -> Bool {
        let tag = Array("\u{1B}[?\(AnimationEncoder.markerTag);".utf8)
        guard bytes.count >= tag.count else { return false }
        for i in 0...(bytes.count - tag.count) where bytes[i] == 0x1B {
            if Array(bytes[i..<i + tag.count]) == tag { return true }
        }
        return false
    }

    /// A one line description for the export sheet.
    public static func summary(_ bytes: [UInt8]) -> String {
        usesExtension(bytes)
            ? "Uses an AnsiView extension (frame markers); other terminals should ignore it"
            : "Standard ANSI only: cursor moves, colours, clear screen and CR padding"
    }
}
