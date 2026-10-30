import Foundation

/// The editor v2 drawing commands (editor tools plan). Each is one undo step, or part of a
/// mouse stroke between `beginStroke` and `endStroke`; none runs while a block floats.
extension CanvasEditor {
    /// Runs `change` inside the current stroke, or as its own undo step.
    private func strokeOrPerform(_ name: String, _ change: (CanvasEditor) -> Void) {
        guard floating == nil else { return }
        if strokeStart != nil {
            strokeName = name
            change(self)
            clampToCanvas()
            revision = -1
            changed()
        } else {
            perform(name, change)
        }
    }

    // MARK: Line mode (rulings 2 and 3)

    /// Moves the cursor one cell drawing (or erasing) a box line behind it.
    public func lineStep(dx: Int, dy: Int, style: LineStyle, erase: Bool = false) {
        guard floating == nil else { return }
        let from = cursor
        let to = (from.x + dx, from.y + dy)
        guard to.0 >= 0, to.0 < canvas.columns, to.1 >= 0, to.1 < AnsiTerminal.maxRows else { return }
        let fg = foregroundColor, bg = backgroundColor
        perform(erase ? "Erase Line" : "Line") { editor in
            if erase {
                editor.canvas.eraseLine(path: [(from.x, from.y), to], fg: fg, bg: bg)
            } else {
                editor.canvas.drawLine(path: [(from.x, from.y), to], style: style, fg: fg, bg: bg)
            }
            editor.place(x: to.0, y: to.1)
        }
        selection = nil
        selectionAnchor = nil
        changed()
    }

    /// A mouse drag in the Line tool: the Manhattan path between two cells.
    public func strokeLine(from a: (Int, Int), to b: (Int, Int), style: LineStyle, erase: Bool = false) {
        let path = BoxDrawing.manhattanPath(from: a, to: b)
        let fg = foregroundColor, bg = backgroundColor
        strokeOrPerform(erase ? "Erase Line" : "Line") { editor in
            if erase { editor.canvas.eraseLine(path: path, fg: fg, bg: bg) }
            else { editor.canvas.drawLine(path: path, style: style, fg: fg, bg: bg) }
        }
    }

    // MARK: Shapes (ruling 4)

    public func drawRectangle(_ rect: CellRect, style: ShapeStyle, filled: Bool = false, fillCode: UInt8 = 0x20,
                              shadow: Bool = false, title: String = "") {
        let fg = foregroundColor, bg = backgroundColor
        perform("Rectangle") {
            $0.canvas.drawRectangle(rect, style: style, fg: fg, bg: bg, filled: filled, fillCode: fillCode,
                                    shadow: shadow, title: title)
        }
    }

    public func drawStraightLine(from a: (Int, Int), to b: (Int, Int), style: ShapeStyle) {
        let fg = foregroundColor, bg = backgroundColor
        perform("Line") { $0.canvas.drawStraightLine(from: a, to: b, style: style, fg: fg, bg: bg) }
    }

    public func drawEllipse(in rect: CellRect) {
        let fg = foregroundColor
        perform("Ellipse") { $0.canvas.drawEllipse(in: rect, color: fg) }
    }

    // MARK: Brushes (ruling 5)

    /// The character the brush, fills and Fill with Character use.
    public var brushCharacter: UInt8 {
        get { lastBlockCharacter }
        set { lastBlockCharacter = newValue; changed() }
    }

    /// The drawing colours, swapped for the right button. Without iCE a bright colour moving
    /// to the background becomes its dark half.
    func colours(swapped: Bool) -> (fg: RGB, bg: RGB) {
        guard swapped else { return (foregroundColor, backgroundColor) }
        return (backgroundColor, canvas.iceColors ? foregroundColor : EditCanvas.darkened(foregroundColor))
    }

    /// Paints the brush character in the current colours, or only the colours.
    public func brush(x: Int, y: Int, colourOnly: Bool, useBackground: Bool) {
        guard x >= 0, x < canvas.columns, y >= 0, y < AnsiTerminal.maxRows else { return }
        let (fg, bg) = colours(swapped: useBackground)
        let code = brushCharacter
        strokeOrPerform(colourOnly ? "Colour Brush" : "Brush") { editor in
            var cell = editor.canvas[x, y]
            if !colourOnly { cell.code = code; cell.scalar = nil }
            cell.fg = fg
            cell.bg = bg
            cell.blink = false
            editor.canvas.set(cell, x: x, y: y)
        }
    }

    /// Eyedropper: takes a cell's colours as the drawing colours (and its character for the brush).
    public func pickColours(x: Int, y: Int, includeCharacter: Bool) {
        let cell = displayCanvas[x, y]
        foreground = Palette.nearestVGA(cell.fg)
        background = Palette.nearestVGA(cell.bg, allowed: canvas.iceColors ? 0...15 : 0...7)
        if includeCharacter, cell.scalar == nil { lastBlockCharacter = cell.code }
        changed()
    }

    // MARK: Fill, replace, swap (ruling 6)

    /// Flood fills from a cell with the brush character and the current colours.
    public func floodFill(x: Int, y: Int, matchBy: CellParts, apply: CellParts) {
        let cell = AnsiCell(code: brushCharacter, fg: foregroundColor, bg: backgroundColor)
        perform("Fill") { $0.canvas.floodFill(x: x, y: y, matchBy: matchBy, apply: apply, with: cell) }
    }

    /// Global replace in the selection (or the whole canvas). Returns how many cells changed.
    @discardableResult
    public func replace(matching pattern: CellPattern, with replacement: CellPattern) -> Int {
        let rect = targetRect
        var count = 0
        perform("Replace") { count = $0.canvas.replace(in: rect, matching: pattern, with: replacement) }
        return count
    }

    /// Swaps each cell's foreground and background in the selection (or the canvas).
    public func swapSelectionColours() {
        let rect = targetRect
        perform("Swap Colours") { $0.canvas.swapColours(in: rect) }
    }

    /// X: swaps the drawing colours.
    public func swapDrawingColours() {
        let oldForeground = foreground
        foreground = background
        background = !canvas.iceColors && oldForeground >= 8 ? oldForeground - 8 : oldForeground
        changed()
    }

    // MARK: Lines and columns (ruling 7)

    public func insertLine() {
        let y = cursor.y, blank = vacatedCell
        perform("Insert Line") { $0.canvas.insertRow(at: y, blank: blank) }
    }

    public func deleteLine() {
        let y = cursor.y, blank = vacatedCell
        perform("Delete Line") { $0.canvas.deleteRow(at: y, blank: blank) }
    }

    public func insertColumn() {
        let x = cursor.x, blank = vacatedCell
        perform("Insert Column") { $0.canvas.insertColumn(at: x, blank: blank) }
    }

    public func deleteColumn() {
        let x = cursor.x, blank = vacatedCell
        perform("Delete Column") { $0.canvas.deleteColumn(at: x, blank: blank) }
    }
}
