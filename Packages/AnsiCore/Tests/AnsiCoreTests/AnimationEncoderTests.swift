import Foundation
import Testing
@testable import AnsiCore

/// Helpers shared by the animation tests: frames from text, and a byte by byte replay through
/// AnsiView's own player terminal.
enum AnimationTestKit {
    static func cell(_ char: Character, fg: Int = 7, bg: Int = 0) -> AnsiCell {
        AnsiCell(code: CP437.code(for: char.unicodeScalars.first!) ?? 0x3F, fg: Palette.vga[fg], bg: Palette.vga[bg])
    }

    /// A frame of `columns` x `rows` with `marks` written in.
    static func frame(columns: Int = 20, rows: Int = 6, delay: Double = 0.5, ice: Bool = false,
                      _ marks: [(x: Int, y: Int, cell: AnsiCell)] = [], edits: [CellEdit] = []) -> AnimationFrame {
        var canvas = EditCanvas(columns: columns, height: rows)
        canvas.setIceColors(ice)
        for m in marks { canvas.set(m.cell, x: m.x, y: m.y) }
        return AnimationFrame(layers: [CanvasLayer(name: "Background", canvas: canvas)], delay: delay, edits: edits)
    }

    /// A small colourful three frame animation: a box that moves right and changes colour.
    static func movingBox(delays: [Double] = [0.5, 0.25, 1.0], ice: Bool = false) -> [AnimationFrame] {
        (0..<3).map { step in
            var marks: [(x: Int, y: Int, cell: AnsiCell)] = []
            for y in 1...3 {
                for x in (2 + step * 3)...(7 + step * 3) {
                    marks.append((x, y, cell(y == 2 ? "#" : "\u{2588}", fg: 9 + step, bg: ice ? 8 + step : step + 1)))
                }
            }
            marks.append((0, 0, cell(Character(String(step)), fg: 15)))
            return frame(delay: delays[step], ice: ice, marks)
        }
    }

    /// The cells the player shows, `rows` high (blank padded), plus whether anything lies below.
    static func grid(_ terminal: AnsiTerminal, columns: Int, rows: Int) -> (cells: [[AnsiCell]], spill: Bool) {
        let screen = terminal.screen(minimumRows: rows)
        let cells = screen.rows.prefix(rows).map { row in
            Array(row.prefix(columns)) + Array(repeating: AnsiCell(), count: max(0, columns - row.count))
        }
        let spill = screen.rows.dropFirst(rows).contains { $0.contains { $0 != AnsiCell() } }
        return (cells, spill)
    }

    /// The written form of each frame, padded to `rows`.
    static func targets(_ frames: [AnimationFrame], rows: Int) -> [[[AnsiCell]]] {
        frames.map { frame in
            let canvas = frame.composite
            return (0..<rows).map { y in (0..<canvas.columns).map { AnimationEncoder.written(canvas[$0, y]) } }
        }
    }

    struct Replay {
        /// Byte position at which each frame first showed exactly.
        var reached: [Int] = []
        /// Characters each frame stayed exactly on screen (to the next change or the end).
        var holds: [Int] = []
        var spilled = false
    }

    /// Plays `stream` one step at a time and records when each frame shows and for how long.
    static func replay(_ stream: AnimationStream, _ frames: [AnimationFrame]) -> Replay {
        let file = ArtFile(data: stream.data, fileExtension: "ans")
        let columns = frames[0].composite.columns
        let rows = frames.map(\.composite.height).max() ?? 25
        let wanted = targets(frames, rows: rows)
        var terminal = AnsiTerminal(file)
        var result = Replay()
        var k = 0
        var start: Int?
        while !terminal.isFinished, k < frames.count {
            terminal.advance(byteCount: 1)
            let (cells, spill) = grid(terminal, columns: columns, rows: rows)
            if spill { result.spilled = true }
            if let s = start {
                if cells != wanted[k] {
                    result.holds.append(terminal.position - s)
                    start = nil
                    k += 1
                    if k < frames.count, cells == wanted[k] { start = terminal.position; result.reached.append(terminal.position) }
                }
            } else if cells == wanted[k] {
                start = terminal.position
                result.reached.append(terminal.position)
            }
        }
        if let s = start, k < frames.count { result.holds.append(file.stream.count - s) }
        return result
    }
}

@Suite struct AnimationEncoderTests {
    typealias Kit = AnimationTestKit

    @Test func paddingMath() {
        #expect(PaddingDelay.characterTime(baud: 2400) == 10.0 / 2400)
        #expect(PaddingDelay.characters(seconds: 0.5, baud: 2400) == 120)
        #expect(PaddingDelay.characters(seconds: 1, baud: 300) == 30)
        #expect(PaddingDelay.characters(seconds: 1, baud: 0) == 0)
        #expect(PaddingDelay.characters(seconds: -1, baud: 2400) == 0)
        #expect(PaddingDelay.byte == 0x0D)
    }

    @Test(arguments: AnimationOrder.allCases)
    func everyOrderReproducesEveryFrame(_ order: AnimationOrder) {
        for ice in [false, true] {
            let frames = Kit.movingBox(ice: ice)
            let stream = AnimationEncoder.encode(frames, options: AnimationExportOptions(order: order))
            let replay = Kit.replay(stream, frames)
            #expect(replay.reached.count == 3, "order \(order) ice \(ice): reached \(replay.reached)")
            #expect(!replay.spilled)
            // The encoder's own boundaries are where the replay found each frame complete.
            #expect(replay.reached == stream.boundaries)
        }
    }

    @Test(arguments: [300, 1200, 2400, 9600, 14400, 28800])
    func holdsMatchRequestedDelays(_ baud: Int) {
        // At least the next frame's lead in at 300 baud (a shorter delay is reported, see below).
        let delays = [0.5, 0.75, 1.0]
        for order in AnimationOrder.allCases {
            let frames = Kit.movingBox(delays: delays)
            let stream = AnimationEncoder.encode(frames, options: AnimationExportOptions(order: order, baud: baud))
            let replay = Kit.replay(stream, frames)
            let c = PaddingDelay.characterTime(baud: baud)
            #expect(replay.holds.count == 3)
            for (k, hold) in replay.holds.enumerated() {
                let seconds = Double(hold) * c
                #expect(abs(seconds - delays[k]) <= c, "baud \(baud) \(order) frame \(k): \(seconds) s for \(delays[k]) s")
            }
            #expect(replay.holds == stream.holds)
        }
    }

    @Test func delayShorterThanLeadInReportsTheLeadIn() {
        let frames = Kit.movingBox(delays: [0, 0, 0])
        let stream = AnimationEncoder.encode(frames, options: AnimationExportOptions(order: .topDown, baud: 2400))
        let replay = Kit.replay(stream, frames)
        #expect(replay.holds == stream.holds)
        #expect(stream.holds[0] > 0 && stream.holds[0] < 20)
        #expect(!stream.body.contains(PaddingDelay.byte) || stream.holds[2] == 0)
    }

    private func order(of chars: [Character], in body: [UInt8]) -> [Int] {
        chars.map { ch in body.firstIndex(of: UInt8(ascii: Unicode.Scalar(String(ch))!))! }
    }

    @Test func topDownWritesRowByRow() {
        let first = Kit.frame()
        let second = Kit.frame([(5, 3, Kit.cell("c")), (1, 1, Kit.cell("a")), (9, 1, Kit.cell("b"))],
                               edits: [CellEdit(x: 5, y: 3), CellEdit(x: 1, y: 1), CellEdit(x: 9, y: 1)])
        let stream = AnimationEncoder.encode([first, second], options: AnimationExportOptions(order: .topDown))
        let at = order(of: ["a", "b", "c"], in: stream.body)
        #expect(at[0] < at[1] && at[1] < at[2])
    }

    @Test func asDrawnFollowsTheEditLog() {
        let first = Kit.frame()
        let second = Kit.frame([(5, 3, Kit.cell("c")), (1, 1, Kit.cell("a")), (9, 1, Kit.cell("b")), (0, 5, Kit.cell("d"))],
                               edits: [CellEdit(x: 9, y: 1), CellEdit(x: 5, y: 3), CellEdit(x: 1, y: 1), CellEdit(x: 9, y: 1)])
        let stream = AnimationEncoder.encode([first, second], options: AnimationExportOptions(order: .asDrawn))
        // Last log entry wins for b (edited twice); d is not in the log and comes last.
        let at = order(of: ["c", "a", "b", "d"], in: stream.body)
        #expect(at[0] < at[1] && at[1] < at[2] && at[2] < at[3])
    }

    @Test func fullRedrawClearsEveryFrame() {
        let frames = Kit.movingBox()
        let body = AnimationEncoder.encode(frames, options: AnimationExportOptions(order: .fullRedraw)).body
        let clears = body.indices.filter { Array(body[$0..<min(body.count, $0 + 4)]) == Array("\u{1B}[2J".utf8) }.count
        #expect(clears == 3)
        let topDown = AnimationEncoder.encode(frames, options: AnimationExportOptions(order: .topDown)).body
        let topClears = topDown.indices.filter { Array(topDown[$0..<min(topDown.count, $0 + 4)]) == Array("\u{1B}[2J".utf8) }.count
        #expect(topClears == 1)
    }

    @Test func lastColumnAndBottomRightCells() {
        let a = Kit.frame([(19, 0, Kit.cell("x")), (0, 1, Kit.cell("y")), (19, 5, Kit.cell("z"))])
        let b = Kit.frame([(19, 1, Kit.cell("p")), (0, 2, Kit.cell("q")), (19, 5, Kit.cell("r")), (18, 5, Kit.cell("s"))])
        for order in AnimationOrder.allCases {
            let frames = [a, b]
            let replay = Kit.replay(AnimationEncoder.encode(frames, options: AnimationExportOptions(order: order)), frames)
            #expect(replay.reached.count == 2, "\(order)")
            #expect(!replay.spilled)
        }
    }

    @Test func controlCodesAreWrittenAsLookalikes() {
        var esc = Kit.cell("a"); esc.code = 0x1B
        var cr = Kit.cell("a"); cr.code = 0x0D
        var smile = Kit.cell("a"); smile.code = 0x01
        let frames = [Kit.frame([(1, 1, esc), (2, 1, cr), (3, 1, smile)]), Kit.frame([(1, 1, smile)])]
        let stream = AnimationEncoder.encode(frames, options: AnimationExportOptions(order: .topDown))
        #expect(Kit.replay(stream, frames).reached.count == 2)
        #expect(AnimationEncoder.written(esc).code == 0x3C)
        #expect(AnimationEncoder.written(smile).code == 0x01)
        for i in stream.body.indices where stream.body[i] == 0x1B { #expect(stream.body[i + 1] == UInt8(ascii: "[")) }
    }

    @Test func iceAnimationCarriesTheSauceFlag() {
        let frames = Kit.movingBox(ice: true)
        let stream = AnimationEncoder.encode(frames, options: AnimationExportOptions(order: .topDown))
        let file = ArtFile(data: stream.data, fileExtension: "ans")
        #expect(file.iceColors)
        #expect(file.columns == 20)
    }

    @Test func frameMarkersAreAnExtensionThePlayerIgnores() {
        let frames = Kit.movingBox()
        let plain = AnimationEncoder.encode(frames, options: AnimationExportOptions(order: .asDrawn))
        let marked = AnimationEncoder.encode(frames, options: AnimationExportOptions(order: .asDrawn, frameMarkers: true))
        #expect(!AnimationStreamCheck.usesExtension(plain.body))
        #expect(AnimationStreamCheck.usesExtension(marked.body))
        #expect(marked.body.count == plain.body.count)  // markers come out of the padding budget
        let a = Kit.replay(plain, frames), b = Kit.replay(marked, frames)
        #expect(a.holds == b.holds && b.reached.count == 3)
        #expect(String(decoding: marked.body, as: UTF8.self).contains("\u{1B}[?2416;1;250z"))
    }

    @Test func recordedPausesReplayInAsDrawnOrder() {
        let first = Kit.frame()
        let second = Kit.frame([(1, 1, Kit.cell("A")), (2, 1, Kit.cell("B"))],
                               edits: [CellEdit(x: 1, y: 1, time: 10.0), CellEdit(x: 2, y: 1, time: 10.5)])
        let baud = 2400
        var options = AnimationExportOptions(order: .asDrawn, baud: baud)
        let paused = AnimationEncoder.encode([first, second], options: options).body
        options.replayPauses = false
        let straight = AnimationEncoder.encode([first, second], options: options).body
        let a = paused.firstIndex(of: UInt8(ascii: "A"))!, b = paused.firstIndex(of: UInt8(ascii: "B"))!
        let gap = Double(b - a) * PaddingDelay.characterTime(baud: baud)
        #expect(abs(gap - 0.5) <= 2 * PaddingDelay.characterTime(baud: baud) + 0.01, "gap \(gap)")
        #expect(straight.count < paused.count)
        // Pauses are capped at two seconds.
        let long = Kit.frame([(1, 1, Kit.cell("A")), (2, 1, Kit.cell("B"))],
                             edits: [CellEdit(x: 1, y: 1, time: 0), CellEdit(x: 2, y: 1, time: 100)])
        let capped = AnimationEncoder.encode([first, long], options: AnimationExportOptions(order: .asDrawn, baud: baud)).body
        #expect(capped.count < straight.count + 2 * 240 + 30)
    }

    @Test func framesOfDifferentHeightsComparePadded() {
        let short = Kit.frame(rows: 3, [(1, 1, Kit.cell("A"))])
        let tall = Kit.frame(rows: 6, [(1, 5, Kit.cell("B"))])
        let frames = [short, tall, short]
        for order in AnimationOrder.allCases {
            #expect(Kit.replay(AnimationEncoder.encode(frames, options: AnimationExportOptions(order: order)), frames).reached.count == 3)
        }
    }

    @Test func unlimitedBaudWritesNoPadding() {
        let stream = AnimationEncoder.encode(Kit.movingBox(), options: AnimationExportOptions(order: .topDown, baud: 0))
        #expect(!stream.body.contains(PaddingDelay.byte))
    }

    @Test func sizesPerOrder() {
        // An 80 x 25 animation: a 20 x 8 block moving across six frames.
        let frames: [AnimationFrame] = (0..<6).map { step in
            var marks: [(x: Int, y: Int, cell: AnsiCell)] = []
            for y in 8..<16 { for x in (step * 10)..<(step * 10 + 20) { marks.append((x, y, Kit.cell("\u{2593}", fg: 14, bg: 1))) } }
            marks.append((2, 1, Kit.cell(Character(String(step)), fg: 15)))
            return Kit.frame(columns: 80, rows: 25, delay: 0.2, marks)
        }
        var sizes: [String] = []
        for order in AnimationOrder.allCases {
            let stream = AnimationEncoder.encode(frames, options: AnimationExportOptions(order: order, baud: 0))
            #expect(Kit.replay(stream, frames).reached.count == 6)
            sizes.append("\(order.rawValue)=\(stream.body.count)")
        }
        print("animation sizes (80x25, 6 frames, no padding): " + sizes.joined(separator: " "))
    }
}
