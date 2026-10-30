import Foundation

public struct AnimationImportOptions: Equatable {
    /// Bytes that change nothing visible before the screen counts as settled (48 is 0.2 s at 2400
    /// baud; shorter runs of cursor and colour changes are common inside one picture).
    public var idleBytes: Int
    /// The baud rate delays are measured at.
    public var baud: Int

    public init(idleBytes: Int = 48, baud: Int = 2400) {
        self.idleBytes = max(1, idleBytes)
        self.baud = baud > 0 ? baud : 2400
    }
}

/// Splits an ANSI stream into animation frames where the screen settles (animation plan, ruling 7):
/// at an AnsiView frame marker, a clear screen after drawing, a run of `idleBytes` bytes that
/// change nothing, or a change to a cell that already changed in the frame being collected.
public enum AnimationImporter {
    public static func frames(_ file: ArtFile, options: AnimationImportOptions = AnimationImportOptions()) -> [AnimationFrame] {
        let analysis = AnsiAnalysis(file)
        let columns = file.columns
        let rows = analysis.canvasRows
        func frame(_ cells: [[AnsiCell]], delay: Double, edits: [CellEdit]) -> AnimationFrame {
            var screen = AnsiScreen(columns: columns, rows: cells, title: file.title)
            screen.sauce = file.sauce
            screen.font = file.font
            var canvas = EditCanvas(screen: screen, iceColors: file.iceColors)
            canvas.ensureHeight(rows)
            return AnimationFrame(layers: [CanvasLayer(name: "Background", canvas: canvas)], delay: delay, edits: edits)
        }
        guard file.format.isStream else {
            return [frame(grid(analysis.finalScreen, columns: columns, rows: rows), delay: AnimationFrame.defaultDelay, edits: [])]
        }

        let bytes = file.stream
        let characterTime = PaddingDelay.characterTime(baud: options.baud)
        let clearSequence = Array("\u{1B}[2J".utf8)
        let markerPrefix = Array("\u{1B}[?\(AnimationEncoder.markerTag);".utf8)
        var terminal = AnsiTerminal(file)
        var shown = grid(AnsiScreen(columns: columns, rows: []), columns: columns, rows: rows)
        var touched = Set<Int>()
        var edits: [CellEdit] = []
        var dirty = false
        var idle = 0
        var lastChangeEnd = 0
        var result: [AnimationFrame] = []
        // With AnsiView frame markers the markers alone say where frames end (review I8).
        let marked = AnimationStreamCheck.usesExtension(bytes)

        func close(delay: Double, always: Bool = false) {
            guard dirty || always else { return }
            result.append(frame(shown, delay: (delay * 1000).rounded() / 1000, edits: edits))
            touched.removeAll()
            edits.removeAll()
            dirty = false
        }

        while !terminal.isFinished {
            let start = terminal.position
            let edited = terminal.edits
            terminal.advance(byteCount: 1)
            let end = terminal.position
            let step = bytes[start..<end]
            if step.starts(with: markerPrefix) {
                let parameters = String(decoding: step.dropFirst(markerPrefix.count).dropLast(), as: UTF8.self).split(separator: ";")
                let ms = parameters.count >= 2 ? Double(parameters[1]) ?? 0 : 0
                close(delay: ms / 1000, always: true)
                idle = 0
                continue
            }
            guard terminal.edits != edited else {
                idle += end - start
                continue
            }
            let now = grid(terminal.screen(minimumRows: rows), columns: columns, rows: rows)
            var changed: [Int] = []
            for y in 0..<rows where now[y] != shown[y] {
                for x in 0..<columns where now[y][x] != shown[y][x] { changed.append(y * columns + x) }
            }
            let visible = changed.filter { !Self.looksSame(shown[$0 / columns][$0 % columns], now[$0 / columns][$0 % columns]) }
            guard !visible.isEmpty else {
                // Nothing that can be seen changed (a recoloured space): still settled.
                shown = now
                idle += end - start
                continue
            }
            changed = visible
            let isClear = step.elementsEqual(clearSequence)
            if !marked, idle >= options.idleBytes || isClear || changed.contains(where: touched.contains) {
                let held = idle >= options.idleBytes ? Double(end - lastChangeEnd) * characterTime : 0
                close(delay: held)
            }
            shown = now
            dirty = true
            if !isClear {
                for index in changed {
                    touched.insert(index)
                    edits.append(CellEdit(x: index % columns, y: index / columns))
                }
            }
            idle = 0
            lastChangeEnd = end
        }
        close(delay: !marked && idle >= options.idleBytes ? Double(bytes.count - lastChangeEnd) * characterTime : 0)
        if result.isEmpty { result.append(frame(shown, delay: AnimationFrame.defaultDelay, edits: [])) }
        return result
    }

    /// Whether two cells look the same: equal, or both blank glyphs on the same background.
    static func looksSame(_ a: AnsiCell, _ b: AnsiCell) -> Bool {
        if a == b { return true }
        let blanks: Set<UInt8> = [0x00, 0x20, 0xFF]
        return a.scalar == nil && b.scalar == nil && blanks.contains(a.code) && blanks.contains(b.code) && a.bg == b.bg
    }

    /// Exactly `rows` x `columns` cells of `screen` (blank padded).
    static func grid(_ screen: AnsiScreen, columns: Int, rows: Int) -> [[AnsiCell]] {
        // Rows are passed through (and blank rows shared) so unchanged rows compare by identity
        // in constant time (review I7).
        let blank = Array(repeating: AnsiCell(), count: columns)
        return (0..<rows).map { y in
            guard y < screen.rows.count else { return blank }
            let row = screen.rows[y]
            if row.count == columns { return row }
            return row.count > columns ? Array(row.prefix(columns)) : row + Array(repeating: AnsiCell(), count: columns - row.count)
        }
    }
}
