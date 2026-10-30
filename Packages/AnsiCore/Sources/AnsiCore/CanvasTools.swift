import Foundation

/// Which parts of a cell a fill matches or changes (editor tools plan, ruling 6).
public struct CellParts: OptionSet, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let character = CellParts(rawValue: 1)
    /// Foreground, background and blink.
    public static let colour = CellParts(rawValue: 2)
    public static let both: CellParts = [.character, .colour]
}

/// A cell pattern for global replace: nil parts match anything and are left alone.
public struct CellPattern: Equatable {
    public var code: UInt8?
    public var fg: RGB?
    public var bg: RGB?

    public init(code: UInt8? = nil, fg: RGB? = nil, bg: RGB? = nil) {
        self.code = code
        self.fg = fg
        self.bg = bg
    }

    public var isEmpty: Bool { code == nil && fg == nil && bg == nil }

    public func matches(_ cell: AnsiCell) -> Bool {
        (code == nil || (cell.code == code && cell.scalar == nil)) && (fg == nil || cell.fg == fg) && (bg == nil || cell.bg == bg)
    }

    public func applied(to cell: AnsiCell) -> AnsiCell {
        var result = cell
        if let code { result.code = code; result.scalar = nil }
        if let fg { result.fg = fg }
        if let bg { result.bg = bg }
        return result
    }
}

extension AnsiCell {
    /// True when the two cells agree in `parts`.
    public func matches(_ other: AnsiCell, by parts: CellParts) -> Bool {
        if parts.contains(.character), code != other.code || scalar != other.scalar { return false }
        if parts.contains(.colour), fg != other.fg || bg != other.bg || blink != other.blink { return false }
        return true
    }

    /// This cell with `parts` taken from `source`.
    public func taking(_ parts: CellParts, from source: AnsiCell) -> AnsiCell {
        var result = self
        if parts.contains(.character) { result.code = source.code; result.scalar = source.scalar }
        if parts.contains(.colour) { result.fg = source.fg; result.bg = source.bg; result.blink = source.blink }
        return result
    }
}

extension EditCanvas {
    /// Fills the 4-connected area around (`x`, `y`) whose cells match the start cell in
    /// `matchBy`, giving each the `apply` parts of `cell`. Returns how many cells changed.
    @discardableResult
    public mutating func floodFill(x: Int, y: Int, matchBy: CellParts, apply: CellParts, with cell: AnsiCell) -> Int {
        guard x >= 0, x < columns, y >= 0, y < height, !matchBy.isEmpty, !apply.isEmpty else { return 0 }
        let start = rows[y][x]
        let width = columns, rowCount = height
        var visited = [Bool](repeating: false, count: width * rowCount)
        var stack = [(x, y)]
        visited[y * width + x] = true
        var changed = 0
        while let (cx, cy) = stack.popLast() {
            let current = rows[cy][cx]
            let replaced = current.taking(apply, from: cell)
            if replaced != current { rows[cy][cx] = replaced; changed += 1 }
            for (nx, ny) in [(cx - 1, cy), (cx + 1, cy), (cx, cy - 1), (cx, cy + 1)]
            where nx >= 0 && nx < width && ny >= 0 && ny < rowCount && !visited[ny * width + nx] {
                if rows[ny][nx].matches(start, by: matchBy) {
                    visited[ny * width + nx] = true
                    stack.append((nx, ny))
                }
            }
        }
        return changed
    }

    /// Replaces the parts of every cell in `rect` that matches `pattern`. Returns the count changed.
    @discardableResult
    public mutating func replace(in rect: CellRect, matching pattern: CellPattern, with replacement: CellPattern) -> Int {
        guard let clipped = clip(rect), !pattern.isEmpty, !replacement.isEmpty else { return 0 }
        var changed = 0
        for y in clipped.y..<clipped.y + clipped.height {
            for x in clipped.x..<clipped.x + clipped.width where pattern.matches(rows[y][x]) {
                let new = replacement.applied(to: rows[y][x])
                if new != rows[y][x] { rows[y][x] = new; changed += 1 }
            }
        }
        return changed
    }

    /// Swaps each cell's foreground and background. Without iCE a bright colour moving to the
    /// background becomes its dark half.
    public mutating func swapColours(in rect: CellRect) {
        let ice = iceColors
        fill(rect) { cell in
            var swapped = cell
            swapped.fg = cell.bg
            swapped.bg = ice ? cell.fg : Self.darkened(cell.fg)
            return swapped
        }
    }

    /// Insert mode typing: shifts the row right from `x` (the last cell falls off) and puts `blank` at `x`.
    public mutating func insertCell(x: Int, y: Int, blank: AnsiCell = AnsiCell()) {
        guard x >= 0, x < columns, y >= 0, y < AnsiTerminal.maxRows else { return }
        ensureHeight(y + 1)
        rows[y].insert(blank, at: x)
        rows[y].removeLast()
    }

    /// Removes the cell at `x`, shifting the rest of the row left; `blank` fills the end.
    public mutating func deleteCell(x: Int, y: Int, blank: AnsiCell = AnsiCell()) {
        guard x >= 0, x < columns, y >= 0, y < height else { return }
        rows[y].remove(at: x)
        rows[y].append(blank)
    }

    /// Inserts a blank row at `y`; at the row limit the last row falls off.
    public mutating func insertRow(at y: Int, blank: AnsiCell = AnsiCell()) {
        guard y >= 0, y <= height, y < AnsiTerminal.maxRows else { return }
        rows.insert(Array(repeating: blank, count: columns), at: y)
        if rows.count > AnsiTerminal.maxRows { rows.removeLast() }
    }

    /// Removes row `y`; the last remaining row is cleared instead.
    public mutating func deleteRow(at y: Int, blank: AnsiCell = AnsiCell()) {
        guard y >= 0, y < height else { return }
        if height == 1 {
            rows[0] = Array(repeating: blank, count: columns)
        } else {
            rows.remove(at: y)
        }
    }

    /// Inserts a blank column at `x` in every row; the last column falls off (the width stays).
    public mutating func insertColumn(at x: Int, blank: AnsiCell = AnsiCell()) {
        guard x >= 0, x < columns else { return }
        for y in rows.indices { rows[y].insert(blank, at: x); rows[y].removeLast() }
    }

    /// Removes column `x` from every row; a blank column fills the right edge.
    public mutating func deleteColumn(at x: Int, blank: AnsiCell = AnsiCell()) {
        guard x >= 0, x < columns else { return }
        for y in rows.indices { rows[y].remove(at: x); rows[y].append(blank) }
    }
}
