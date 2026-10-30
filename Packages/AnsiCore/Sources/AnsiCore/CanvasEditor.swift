import Foundation

/// A TheDraw style editing session over an `EditCanvas`: cursor, colours, block character sets,
/// selection, clipboard and undo. The app's editor view forwards keys and mouse events here.
public final class CanvasEditor {
    /// TheDraw / PabloDraw character sets, F1 to F10 in each (plan 6 ruling 7).
    public static let blockSets: [[UInt8]] = [
        [218, 191, 192, 217, 196, 179, 195, 180, 193, 194],
        [201, 187, 200, 188, 205, 186, 204, 185, 202, 203],
        [213, 184, 212, 190, 205, 179, 198, 181, 207, 209],
        [214, 183, 211, 189, 196, 186, 199, 182, 208, 210],
        [197, 206, 216, 215, 232, 233, 155, 156, 153, 239],
        [176, 177, 178, 219, 223, 220, 221, 222, 254, 250],
        [1, 2, 3, 4, 5, 6, 240, 14, 15, 32],
        [24, 25, 30, 31, 16, 17, 18, 29, 20, 21],
        [174, 175, 242, 243, 169, 170, 253, 246, 171, 172],
        [227, 241, 244, 245, 234, 157, 228, 248, 251, 252],
    ]

    /// Pasteboard type for copied cells (lossless: characters, exact colours and blink).
    public static let cellsPasteboardType = "com.traynham.ansiview.cells"

    public private(set) var canvas: EditCanvas
    public private(set) var cursor: (x: Int, y: Int) = (0, 0)
    public private(set) var selection: CellRect?
    /// VGA indexes of the drawing colours.
    public private(set) var foreground = 7
    public private(set) var background = 0
    /// The current character set, 0 to 9.
    public var blockSet = 5 {
        didSet { blockSet = min(9, max(0, blockSet)); changed() }
    }
    /// The block character most recently inserted, used by Fill with Character.
    public private(set) var lastBlockCharacter: UInt8 = 219
    public let undoManager: UndoManager
    /// Called after anything changes (cells, cursor, selection, colours).
    public var onChange: (() -> Void)?

    public var isModified: Bool { revision != savedRevision }

    private var revision = 0
    private var nextRevision = 1
    private var savedRevision = 0
    private var selectionAnchor: (x: Int, y: Int)?
    private var strokeStart: (canvas: EditCanvas, revision: Int)?

    public init(canvas: EditCanvas = EditCanvas()) {
        self.canvas = canvas
        undoManager = UndoManager()
        // Groups are opened and closed by each command, so undo works without a run loop.
        undoManager.groupsByEvent = false
    }

    public var foregroundColor: RGB { Palette.vga[foreground] }
    public var backgroundColor: RGB { Palette.vga[background] }

    // MARK: Cursor and selection

    public func moveCursor(dx: Int, dy: Int, extendSelection: Bool) {
        if extendSelection {
            if selectionAnchor == nil { selectionAnchor = cursor }
        } else {
            selectionAnchor = nil
            selection = nil
        }
        place(x: cursor.x + dx, y: cursor.y + dy)
        if let anchor = selectionAnchor { selection = CellRect.spanning(anchor, cursor) }
        changed()
    }

    /// Moves the cursor to a cell (a mouse click), dropping any selection.
    public func setCursor(x: Int, y: Int) {
        selectionAnchor = nil
        selection = nil
        place(x: x, y: y)
        changed()
    }

    public func moveToLineStart() { moveCursor(dx: -cursor.x, dy: 0, extendSelection: false) }
    public func moveToLineEnd() { moveCursor(dx: canvas.columns - 1 - cursor.x, dy: 0, extendSelection: false) }

    public func newline() {
        selectionAnchor = nil
        selection = nil
        place(x: 0, y: cursor.y + 1)
        changed()
    }

    public func select(_ rect: CellRect?) {
        selectionAnchor = nil
        selection = rect.flatMap { canvas.clip($0) }
        changed()
    }

    public func selectAll() {
        select(CellRect(x: 0, y: 0, width: canvas.columns, height: canvas.height))
    }

    // MARK: Typing

    /// Types text at the cursor. Characters without a CP437 code are skipped; a line break
    /// goes to the start of the next row.
    public func type(_ text: String) {
        perform("Typing") { editor in
            for scalar in text.unicodeScalars {
                if scalar == "\n" || scalar == "\r" {
                    editor.place(x: 0, y: editor.cursor.y + 1)
                } else if let code = CP437.code(for: scalar) {
                    editor.write(code)
                }
            }
        }
    }

    public func typeCode(_ code: UInt8) {
        perform("Typing") { $0.write(code) }
    }

    /// F1 to F10 (`index` 0 to 9): types the current set's character.
    public func insertBlock(_ index: Int) {
        guard (0..<10).contains(index) else { return }
        let code = Self.blockSets[blockSet][index]
        lastBlockCharacter = code
        typeCode(code)
    }

    public func backspace() {
        guard cursor.x > 0 else { return }
        perform("Typing") { editor in
            editor.cursor.x -= 1
            editor.canvas.set(AnsiCell(), x: editor.cursor.x, y: editor.cursor.y)
        }
    }

    /// Clears the selection, or the cell under the cursor.
    public func deleteForward() {
        if selection != nil { clearSelection(); return }
        perform("Delete") { editor in editor.canvas.set(AnsiCell(), x: editor.cursor.x, y: editor.cursor.y) }
    }

    // MARK: Colours

    public func setForeground(_ index: Int) {
        foreground = min(15, max(0, index))
        changed()
    }

    /// Sets the background; without iCE colours a bright colour becomes its dark half.
    public func setBackground(_ index: Int) {
        let clamped = min(15, max(0, index))
        background = !canvas.iceColors && clamped >= 8 ? clamped - 8 : clamped
        changed()
    }

    public func setIceColors(_ on: Bool) {
        perform(on ? "iCE Colours On" : "iCE Colours Off") { $0.canvas.setIceColors(on) }
        if !on, background >= 8 { background -= 8 }
        changed()
    }

    // MARK: Clipboard

    /// The selection as lossless cell data and as plain text, or nil with no selection.
    public func copySelection() -> (cells: Data, text: String)? {
        guard let selection else { return nil }
        let region = canvas.region(selection)
        let screen = AnsiScreen(columns: region.width, rows: region.cells)
        return (Self.encode(region), TextConvert.utf8Text(screen))
    }

    public func cut() -> (cells: Data, text: String)? {
        guard let copied = copySelection() else { return nil }
        clearSelection(name: "Cut")
        return copied
    }

    /// Pastes cells copied by `copySelection` with their top left at the cursor, then selects them.
    /// Data that is not cell data is ignored.
    public func paste(cells data: Data) {
        guard let region = Self.decode(data) else { return }
        let origin = cursor
        perform("Paste") { $0.canvas.paste(region, x: origin.x, y: origin.y) }
        selection = canvas.clip(CellRect(x: origin.x, y: origin.y, width: region.width, height: region.height))
        changed()
    }

    /// Pastes plain text line by line from the cursor in the current colours, clipped at the right edge.
    public func paste(text: String) {
        let origin = cursor
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
        let fg = foregroundColor, bg = backgroundColor
        perform("Paste") { editor in
            for (dy, line) in lines.enumerated() {
                for (dx, scalar) in line.unicodeScalars.enumerated() {
                    let code = scalar == "\t" ? 0x20 : (CP437.code(for: scalar) ?? 0x3F)
                    editor.canvas.set(AnsiCell(code: code, fg: fg, bg: bg), x: origin.x + dx, y: origin.y + dy)
                }
            }
        }
    }

    // MARK: Floating paste

    /// A pasted block that has not been placed yet (copy and paste plan, ruling 5).
    public struct FloatingPaste: Equatable {
        public let region: CanvasRegion
        public var x: Int
        public var y: Int
    }

    /// The block being placed, shown over the canvas until it is stamped or cancelled.
    public private(set) var floating: FloatingPaste?

    /// Blank characters in a pasted block leave what is underneath (ruling 6).
    public var transparentPaste = false {
        didSet { if transparentPaste != oldValue { changed() } }
    }

    /// The canvas as it looks with the floating block stamped where it is now.
    public var displayCanvas: EditCanvas {
        guard let floating else { return canvas }
        var shown = canvas
        shown.paste(floating.region, x: floating.x, y: floating.y, transparent: transparentPaste)
        return shown
    }

    /// Floats `region` with its top left at (`x`, `y`), or at the cursor. Replaces any floating block.
    public func beginFloating(_ region: CanvasRegion, x: Int? = nil, y: Int? = nil) {
        guard region.width > 0, region.height > 0 else { return }
        floating = FloatingPaste(region: region, x: 0, y: 0)
        moveFloating(toX: x ?? cursor.x, y: y ?? cursor.y)
    }

    /// Floats cells copied by AnsiView. False when the data is not cell data.
    @discardableResult
    public func beginFloating(cells data: Data, x: Int? = nil, y: Int? = nil) -> Bool {
        guard let region = Self.decode(data) else { return false }
        beginFloating(region, x: x, y: y)
        return true
    }

    /// Floats text as a block in the current colours.
    public func beginFloating(text: String, x: Int? = nil, y: Int? = nil) {
        beginFloating(Self.region(fromText: text, fg: foregroundColor, bg: backgroundColor), x: x, y: y)
    }

    public func moveFloating(dx: Int, dy: Int) {
        guard let floating else { return }
        moveFloating(toX: floating.x + dx, y: floating.y + dy)
    }

    /// Moves the floating block's top left to a cell, kept on the canvas (and above the row limit).
    public func moveFloating(toX x: Int, y: Int) {
        guard floating != nil else { return }
        floating?.x = min(canvas.columns - 1, max(0, x))
        floating?.y = min(AnsiTerminal.maxRows - 1, max(0, y))
        changed()
    }

    /// Places the floating block: one undo step named Paste; the pasted cells become the selection.
    public func stampFloating() {
        guard let block = floating else { return }
        floating = nil
        let transparent = transparentPaste
        perform("Paste") { $0.canvas.paste(block.region, x: block.x, y: block.y, transparent: transparent) }
        selectionAnchor = nil
        selection = canvas.clip(CellRect(x: block.x, y: block.y, width: block.region.width, height: block.region.height))
        cursor = (block.x, min(canvas.height - 1, block.y))
        changed()
    }

    public func cancelFloating() {
        guard floating != nil else { return }
        floating = nil
        changed()
    }

    /// Text as a rectangle of cells in the given colours: one row per line (a final line break
    /// adds none), short lines padded with spaces, tabs as spaces, unmappable characters as "?".
    public static func region(fromText text: String, fg: RGB, bg: RGB) -> CanvasRegion {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
        if lines.last?.isEmpty == true { lines.removeLast() }
        let rows = lines.prefix(AnsiTerminal.maxRows).map { line in
            line.unicodeScalars.prefix(EditCanvas.maxColumns).map { scalar in
                AnsiCell(code: scalar == "\t" ? 0x20 : (CP437.code(for: scalar) ?? 0x3F), fg: fg, bg: bg)
            }
        }
        let width = rows.map(\.count).max() ?? 0
        guard width > 0 else { return CanvasRegion(cells: []) }
        return CanvasRegion(cells: rows.map { $0 + Array(repeating: AnsiCell(code: 0x20, fg: fg, bg: bg), count: width - $0.count) })
    }

    // MARK: Fill and clear

    private var targetRect: CellRect {
        selection ?? CellRect(x: 0, y: 0, width: canvas.columns, height: canvas.height)
    }

    /// Fills the selection (or the whole canvas) with the last block character in the current colours.
    public func fillWithCharacter() {
        let cell = AnsiCell(code: lastBlockCharacter, fg: foregroundColor, bg: backgroundColor)
        let rect = targetRect
        perform("Fill with Character") { $0.canvas.fill(rect) { _ in cell } }
    }

    /// Recolours the selection (or the whole canvas), keeping its characters.
    public func fillWithColour() {
        let fg = foregroundColor, bg = backgroundColor
        let rect = targetRect
        perform("Fill with Colour") { editor in
            editor.canvas.fill(rect) { AnsiCell(code: $0.code, fg: fg, bg: bg, scalar: $0.scalar) }
        }
    }

    public func clearSelection() { clearSelection(name: "Clear") }

    private func clearSelection(name: String) {
        guard let rect = selection else { return }
        perform(name) { $0.canvas.fill(rect) { _ in AnsiCell() } }
    }

    // MARK: Drawing

    /// Starts a mouse stroke: everything painted until `endStroke` is one undo step.
    public func beginStroke() {
        strokeStart = (canvas, revision)
    }

    public func endStroke() {
        guard let start = strokeStart else { return }
        strokeStart = nil
        guard canvas != start.canvas else {
            revision = start.revision
            return
        }
        revision = newRevision()
        registerUndo(restoring: start, name: "Draw")
        changed()
    }

    /// Paints a half block in the foreground colour (or the background colour, for the right button).
    public func paint(x: Int, y: Int, half: HalfBlock, useBackground: Bool) {
        let color = useBackground ? backgroundColor : foregroundColor
        if strokeStart != nil {
            canvas.paintHalf(x: x, y: y, half: half, color: color)
            revision = -1
            changed()
        } else {
            perform("Draw") { $0.canvas.paintHalf(x: x, y: y, half: half, color: color) }
        }
    }

    // MARK: Canvas and metadata

    public func resize(columns: Int, height: Int) {
        perform("Canvas Size") { $0.canvas.resize(columns: columns, height: height) }
        clampToCanvas()
        changed()
    }

    public func setMetadata(title: String, author: String, group: String) {
        perform("Edit SAUCE") { editor in
            editor.canvas.title = String(title.prefix(35))
            editor.canvas.author = String(author.prefix(20))
            editor.canvas.group = String(group.prefix(20))
        }
    }

    /// Records that the canvas as it is now has been saved.
    public func markSaved() {
        savedRevision = revision
        changed()
    }

    // MARK: Helpers

    /// Runs one undoable change. Nothing is registered when the canvas did not change.
    private func perform(_ name: String, _ change: (CanvasEditor) -> Void) {
        let before = (canvas, revision)
        change(self)
        clampToCanvas()
        if canvas != before.0 {
            revision = newRevision()
            registerUndo(restoring: before, name: name)
        }
        changed()
    }

    private func registerUndo(restoring state: (canvas: EditCanvas, revision: Int), name: String) {
        undoManager.beginUndoGrouping()
        let current = (canvas, revision)
        undoManager.registerUndo(withTarget: self) { editor in
            editor.restore(state, redo: current, name: name)
        }
        undoManager.setActionName(name)
        undoManager.endUndoGrouping()
    }

    private func newRevision() -> Int {
        defer { nextRevision += 1 }
        return nextRevision
    }

    private func restore(_ state: (canvas: EditCanvas, revision: Int),
                         redo: (canvas: EditCanvas, revision: Int), name: String) {
        canvas = state.canvas
        revision = state.revision
        undoManager.registerUndo(withTarget: self) { editor in
            editor.restore(redo, redo: state, name: name)
        }
        undoManager.setActionName(name)
        clampToCanvas()
        changed()
    }

    /// Writes a character at the cursor in the current colours and advances, wrapping at the edge.
    private func write(_ code: UInt8) {
        canvas.set(AnsiCell(code: code, fg: foregroundColor, bg: backgroundColor), x: cursor.x, y: cursor.y)
        if cursor.x + 1 >= canvas.columns {
            place(x: 0, y: cursor.y + 1)
        } else {
            cursor.x += 1
        }
    }

    /// Moves the cursor, clamped to the width and the row limit; rows are added below as needed.
    private func place(x: Int, y: Int) {
        let row = min(AnsiTerminal.maxRows - 1, max(0, y))
        canvas.ensureHeight(row + 1)
        cursor = (min(canvas.columns - 1, max(0, x)), row)
    }

    private func clampToCanvas() {
        cursor = (min(canvas.columns - 1, max(0, cursor.x)), min(canvas.height - 1, max(0, cursor.y)))
        if let rect = selection { selection = canvas.clip(rect) }
    }

    private func changed() { onChange?() }

    // MARK: Cell data

    private static let magic = Array("AVCELLS1".utf8)

    /// Region as bytes: magic, width and height (16 bit little endian), then per cell the code,
    /// foreground RGB, background RGB and a blink byte.
    static func encode(_ region: CanvasRegion) -> Data {
        var out = magic
        out += [UInt8(region.width & 0xFF), UInt8(region.width >> 8), UInt8(region.height & 0xFF), UInt8(region.height >> 8)]
        for row in region.cells {
            for x in 0..<region.width {
                let cell = x < row.count ? row[x] : AnsiCell()
                out += [cell.code, cell.fg.r, cell.fg.g, cell.fg.b, cell.bg.r, cell.bg.g, cell.bg.b, cell.blink ? 1 : 0]
            }
        }
        return Data(out)
    }

    static func decode(_ data: Data) -> CanvasRegion? {
        let bytes = [UInt8](data)
        guard bytes.count >= magic.count + 4, Array(bytes.prefix(magic.count)) == magic else { return nil }
        let base = magic.count
        let width = Int(bytes[base]) | Int(bytes[base + 1]) << 8
        let height = Int(bytes[base + 2]) | Int(bytes[base + 3]) << 8
        guard width > 0, height > 0, width <= EditCanvas.maxColumns, height <= AnsiTerminal.maxRows,
              bytes.count == base + 4 + width * height * 8 else { return nil }
        var i = base + 4
        var cells: [[AnsiCell]] = []
        for _ in 0..<height {
            var row: [AnsiCell] = []
            for _ in 0..<width {
                row.append(AnsiCell(code: bytes[i], fg: RGB(r: bytes[i + 1], g: bytes[i + 2], b: bytes[i + 3]),
                                    bg: RGB(r: bytes[i + 4], g: bytes[i + 5], b: bytes[i + 6]), blink: bytes[i + 7] != 0))
                i += 8
            }
            cells.append(row)
        }
        return CanvasRegion(cells: cells)
    }
}
