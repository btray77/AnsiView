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

    public internal(set) var canvas: EditCanvas
    public internal(set) var cursor: (x: Int, y: Int) = (0, 0)
    public internal(set) var selection: CellRect?
    /// VGA indexes of the drawing colours.
    public internal(set) var foreground = 7
    public internal(set) var background = 0
    /// The current character set, 0 to 9.
    public var blockSet = 5 {
        didSet { blockSet = min(9, max(0, blockSet)); changed() }
    }
    /// The block character most recently inserted, used by Fill with Character.
    public internal(set) var lastBlockCharacter: UInt8 = 219
    public let undoManager: UndoManager
    /// Called after anything changes (cells, cursor, selection, colours).
    public var onChange: (() -> Void)?

    public var isModified: Bool { revision != savedRevision }

    var revision = 0
    private var nextRevision = 1
    private var savedRevision = 0
    var selectionAnchor: (x: Int, y: Int)?
    var strokeStart: Snapshot?

    public init(canvas: EditCanvas = EditCanvas()) {
        self.canvas = canvas
        layerStore = [CanvasLayer(name: "Background", canvas: canvas)]
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

    /// Insert mode (ruling 7): typing shifts the rest of the row right; Backspace and Delete
    /// close the gap. Overwrite mode (the default) replaces and clears.
    public var insertMode = false {
        didSet { if insertMode != oldValue { changed() } }
    }

    public func backspace() {
        guard cursor.x > 0 else { return }
        perform("Typing") { editor in
            editor.cursor.x -= 1
            if editor.insertMode {
                editor.canvas.deleteCell(x: editor.cursor.x, y: editor.cursor.y)
            } else {
                editor.canvas.set(AnsiCell(), x: editor.cursor.x, y: editor.cursor.y)
            }
        }
    }

    /// Clears the selection, or the cell under the cursor (insert mode: deletes it, closing the gap).
    public func deleteForward() {
        if selection != nil { clearSelection(); return }
        perform("Delete") { editor in
            if editor.insertMode {
                editor.canvas.deleteCell(x: editor.cursor.x, y: editor.cursor.y)
            } else {
                editor.canvas.set(AnsiCell(), x: editor.cursor.x, y: editor.cursor.y)
            }
        }
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
        guard floating == nil else { return }
        perform(on ? "iCE Colours On" : "iCE Colours Off") { $0.forEachLayer { $0.setIceColors(on) } }
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
        /// Where a lifted selection came from (a move); nil for a paste.
        public var liftedFrom: CellRect? = nil
        /// A lifted block that leaves the original in place (Option-drag, or the setting).
        public var leavesCopy = false
    }

    /// The block being placed, shown over the canvas until it is stamped or cancelled.
    public private(set) var floating: FloatingPaste?

    /// Blank characters in a pasted block leave what is underneath (ruling 6).
    public var transparentPaste = false {
        didSet { if transparentPaste != oldValue { changed() } }
    }

    /// The canvas as it looks with the floating block stamped where it is now.
    public var displayCanvas: EditCanvas {
        let active = activeWithFloating
        guard layerStore.count > 1 else { return active }
        var list = layerStore
        list[activeLayer].canvas = active
        return LayerStack.composite(list)
    }

    /// The active layer with the floating block stamped where it is now.
    /// A shape being dragged out, shown on the active layer but not applied (no undo step).
    var preview: ((inout EditCanvas) -> Void)?

    /// Shows `change` over the canvas until it is cleared (nil) or the shape is drawn.
    public func setPreview(_ change: ((inout EditCanvas) -> Void)?) {
        preview = change
        changed()
    }

    private var activeWithFloating: EditCanvas {
        if let preview {
            var shown = canvas
            preview(&shown)
            return shown
        }
        guard let floating else { return canvas }
        var shown = canvas
        if let source = floating.liftedFrom, !floating.leavesCopy {
            let vacated = vacatedCell
            shown.fill(source) { _ in vacated }
        }
        shown.paste(floating.region, x: floating.x, y: floating.y, transparent: transparentPaste)
        return shown
    }

    /// Floats `region` with its top left at (`x`, `y`), or at the cursor. Replaces any floating block.
    public func beginFloating(_ region: CanvasRegion, x: Int? = nil, y: Int? = nil) {
        guard region.width > 0, region.height > 0 else { return }
        // Cells copied from art with other colour rules are converted the way this canvas holds them.
        let ice = canvas.iceColors
        let converted = CanvasRegion(cells: region.cells.map { $0.map { EditCanvas.cell($0, iceColors: ice) } })
        floating = FloatingPaste(region: converted, x: 0, y: 0)
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
        let vacated = vacatedCell
        let name = block.liftedFrom == nil ? "Paste" : (block.leavesCopy ? "Duplicate" : "Move")
        perform(name) { editor in
            if let source = block.liftedFrom, !block.leavesCopy { editor.canvas.fill(source) { _ in vacated } }
            editor.canvas.paste(block.region, x: block.x, y: block.y, transparent: transparent)
        }
        selectionAnchor = nil
        selection = canvas.clip(CellRect(x: block.x, y: block.y, width: block.region.width, height: block.region.height))
        cursor = (block.x, min(canvas.height - 1, block.y))
        changed()
    }

    // MARK: Moving a selection (owner request, ruling 8)

    /// Moving a selection keeps the original in place (a copy) instead of clearing it.
    public var leaveCopyWhenMoving = false

    /// What a moved block leaves behind: a space in the current background on the bottom
    /// layer; on an upper layer the unset (transparent) cell.
    public var vacatedCell: AnsiCell {
        activeLayer == 0 ? AnsiCell(code: 0x20, fg: Palette.vga[7], bg: backgroundColor) : AnsiCell()
    }

    /// Lifts the selection into a floating block that moves like a paste. Nothing changes
    /// until it is stamped; cancelling leaves the canvas as it was. False without a selection.
    @discardableResult
    public func liftSelection(duplicate: Bool = false) -> Bool {
        guard floating == nil, let rect = selection else { return false }
        floating = FloatingPaste(region: canvas.region(rect), x: rect.x, y: rect.y, liftedFrom: rect,
                                 leavesCopy: duplicate || leaveCopyWhenMoving)
        changed()
        return true
    }

    /// Option-arrow: moves the selection (lifting it first) or the floating block.
    public func moveSelection(dx: Int, dy: Int, duplicate: Bool = false) {
        if floating == nil, !liftSelection(duplicate: duplicate) { return }
        moveFloating(dx: dx, dy: dy)
    }

    // MARK: Transforms

    /// Whether `transform` can apply to the selection: a quarter turn needs the turned block
    /// to fit the canvas width from the selection's left edge.
    public func canTransformSelection(_ transform: CellTransform) -> Bool {
        guard floating == nil, let rect = selection else { return false }
        return !transform.swapsSize || rect.x + rect.height <= canvas.columns
    }

    /// Mirrors or rotates the selection in place (one undo step); the selection follows the block.
    @discardableResult
    public func transformSelection(_ transform: CellTransform) -> Bool {
        guard canTransformSelection(transform), let rect = selection else { return false }
        let turned = canvas.region(rect).transformed(transform)
        let vacated = vacatedCell
        perform(transform.title) { editor in
            if transform.swapsSize { editor.canvas.fill(rect) { _ in vacated } }
            editor.canvas.paste(turned, x: rect.x, y: rect.y)
        }
        selection = canvas.clip(CellRect(x: rect.x, y: rect.y, width: turned.width, height: turned.height))
        changed()
        return true
    }

    /// Replaces the canvas (every layer) with the selection.
    public func cropToSelection() {
        guard floating == nil, let rect = selection else { return }
        perform("Crop to Selection") { editor in editor.forEachLayer { $0.crop(to: rect) } }
        selection = canvas.clip(CellRect(x: 0, y: 0, width: rect.width, height: rect.height))
        cursor = (0, 0)
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

    var targetRect: CellRect {
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
        strokeStart = snapshot
    }

    public func endStroke() {
        guard let start = strokeStart else { return }
        strokeStart = nil
        guard !snapshot.sameContent(as: start) else {
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
        perform("Canvas Size") { $0.forEachLayer { $0.resize(columns: columns, height: height) } }
        clampToCanvas()
        changed()
    }

    public func setMetadata(title: String, author: String, group: String) {
        perform("Edit SAUCE") { editor in
            editor.forEachLayer { canvas in
                canvas.title = String(title.prefix(35))
                canvas.author = String(author.prefix(20))
                canvas.group = String(group.prefix(20))
            }
        }
    }

    /// Records that the canvas as it is now has been saved.
    public func markSaved() {
        savedRevision = revision
        changed()
    }

    // MARK: Layers (ruling 10)

    /// The layer being edited (0 is the bottom). `canvas` is that layer's cells.
    public private(set) var activeLayer = 0
    /// Every layer; the active one's entry is refreshed from `canvas` when read.
    private var layerStore: [CanvasLayer] = []

    /// All layers, bottom first.
    public var layers: [CanvasLayer] {
        var list = layerStore
        list[activeLayer].canvas = canvas
        return list
    }

    /// What the layers look like together (visible layers only): what a plain save writes.
    public var flattenedCanvas: EditCanvas {
        layerStore.count == 1 ? canvas : LayerStack.composite(layers)
    }

    /// The layers as a project file.
    public var project: ArtProject { ArtProject(layers: layers, activeLayer: activeLayer) }

    public convenience init(project: ArtProject) {
        self.init(canvas: project.layers[project.activeLayer].canvas)
        layerStore = project.layers
        activeLayer = project.activeLayer
    }

    /// Applies a change to every layer (size, iCE and metadata changes).
    func forEachLayer(_ body: (inout EditCanvas) -> Void) {
        body(&canvas)
        for index in layerStore.indices where index != activeLayer { body(&layerStore[index].canvas) }
    }

    private func syncActiveLayer() { layerStore[activeLayer].canvas = canvas }

    private func activate(_ index: Int) {
        activeLayer = min(layerStore.count - 1, max(0, index))
        canvas = layerStore[activeLayer].canvas
    }

    /// Edits another layer (not an undo step).
    public func selectLayer(_ index: Int) {
        guard floating == nil, layerStore.indices.contains(index), index != activeLayer else { return }
        syncActiveLayer()
        activate(index)
        clampToCanvas()
        changed()
    }

    /// Adds an empty layer above the active one and edits it.
    public func addLayer(name: String? = nil) {
        perform("Add Layer") { editor in
            editor.syncActiveLayer()
            var blank = editor.canvas
            blank.clearCells()
            let title = name ?? "Layer \(editor.layerStore.count + 1)"
            editor.layerStore.insert(CanvasLayer(name: title, canvas: blank), at: editor.activeLayer + 1)
            editor.activate(editor.activeLayer + 1)
        }
    }

    public func duplicateLayer() {
        perform("Duplicate Layer") { editor in
            editor.syncActiveLayer()
            var copy = editor.layerStore[editor.activeLayer]
            copy.name += " copy"
            editor.layerStore.insert(copy, at: editor.activeLayer + 1)
            editor.activate(editor.activeLayer + 1)
        }
    }

    /// Deletes the active layer; the last layer stays.
    public func deleteLayer() {
        guard layerStore.count > 1 else { return }
        perform("Delete Layer") { editor in
            editor.layerStore.remove(at: editor.activeLayer)
            editor.activate(max(0, editor.activeLayer - 1))
        }
    }

    /// Moves the active layer up (+1) or down (-1) in the stack.
    public func moveLayer(by offset: Int) {
        let target = activeLayer + offset
        guard layerStore.indices.contains(target), offset != 0 else { return }
        perform(offset > 0 ? "Move Layer Up" : "Move Layer Down") { editor in
            editor.syncActiveLayer()
            editor.layerStore.swapAt(editor.activeLayer, target)
            editor.activate(target)
        }
    }

    public func setLayerVisible(_ index: Int, _ visible: Bool) {
        guard layerStore.indices.contains(index), layerStore[index].visible != visible else { return }
        perform(visible ? "Show Layer" : "Hide Layer") { editor in
            editor.syncActiveLayer()
            editor.layerStore[index].visible = visible
        }
    }

    public func renameLayer(_ index: Int, to name: String) {
        guard layerStore.indices.contains(index), !name.isEmpty else { return }
        perform("Rename Layer") { editor in
            editor.syncActiveLayer()
            editor.layerStore[index].name = name
        }
    }

    /// Draws the active layer onto the one below and removes it.
    public func mergeDown() {
        guard activeLayer > 0 else { return }
        perform("Merge Down") { editor in
            editor.syncActiveLayer()
            let upper = editor.layerStore.remove(at: editor.activeLayer)
            editor.layerStore[editor.activeLayer - 1].canvas.overlay(upper.canvas)
            editor.activate(editor.activeLayer - 1)
        }
    }

    /// Replaces all layers with one holding what is visible.
    public func flatten() {
        guard layerStore.count > 1 else { return }
        perform("Flatten") { editor in
            let flat = editor.flattenedCanvas
            editor.layerStore = [CanvasLayer(name: "Background", canvas: flat)]
            editor.activate(0)
        }
    }

    // MARK: Helpers

    /// Everything one undo step restores.
    struct Snapshot {
        var canvas: EditCanvas
        var layers: [CanvasLayer]
        var activeLayer: Int
        var revision: Int

        func sameContent(as other: Snapshot) -> Bool {
            canvas == other.canvas && activeLayer == other.activeLayer && layers == other.layers
        }
    }

    var snapshot: Snapshot { Snapshot(canvas: canvas, layers: layerStore, activeLayer: activeLayer, revision: revision) }

    /// Runs one undoable change. Nothing is registered when nothing changed. Nothing
    /// runs while a paste floats: it is placed or cancelled first.
    func perform(_ name: String, _ change: (CanvasEditor) -> Void) {
        guard floating == nil else { return }
        let before = snapshot
        change(self)
        clampToCanvas()
        if !snapshot.sameContent(as: before) {
            revision = newRevision()
            registerUndo(restoring: before, name: name)
        }
        changed()
    }

    private func registerUndo(restoring state: Snapshot, name: String) {
        undoManager.beginUndoGrouping()
        let current = snapshot
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

    private func restore(_ state: Snapshot, redo: Snapshot, name: String) {
        canvas = state.canvas
        layerStore = state.layers
        activeLayer = state.activeLayer
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
        if insertMode { canvas.insertCell(x: cursor.x, y: cursor.y) }
        canvas.set(AnsiCell(code: code, fg: foregroundColor, bg: backgroundColor), x: cursor.x, y: cursor.y)
        if cursor.x + 1 >= canvas.columns {
            place(x: 0, y: cursor.y + 1)
        } else {
            cursor.x += 1
        }
    }

    /// Moves the cursor, clamped to the width and the row limit; rows are added below as needed.
    func place(x: Int, y: Int) {
        let row = min(AnsiTerminal.maxRows - 1, max(0, y))
        canvas.ensureHeight(row + 1)
        cursor = (min(canvas.columns - 1, max(0, x)), row)
    }

    func clampToCanvas() {
        cursor = (min(canvas.columns - 1, max(0, cursor.x)), min(canvas.height - 1, max(0, cursor.y)))
        if let rect = selection { selection = canvas.clip(rect) }
        if let block = floating, block.x >= canvas.columns { floating?.x = canvas.columns - 1 }
    }

    func changed() { onChange?() }

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
