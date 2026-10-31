import Foundation

// The TheDraw font editor's model (docs/superpowers/plans/2026-10-30-ansiview-2.0-tdf-editor.md,
// rulings 1 to 7): limits, the glyph canvas, what a file can hold, copying glyphs between
// font types, and the open collection with its commands and undo.

/// The limits of Roy/SAC's TDF specification (ruling 1).
public enum TDFLimits {
    public static let maxWidth = 30
    public static let maxHeight = 12
    public static let spacing = 0...40
    public static let maxNameLength = 12

    /// Why `name` cannot be a font name, or nil when it can.
    public static func nameProblem(_ name: String) -> String? {
        if name.isEmpty { return "A font needs a name." }
        if name.unicodeScalars.count > maxNameLength { return "A TheDraw font name has at most 12 characters." }
        if let bad = name.unicodeScalars.first(where: { CP437.code(for: $0) == nil }) {
            return "\"\(Character(bad))\" is not a DOS (CP437) character, so a TheDraw font name cannot hold it."
        }
        return nil
    }
}

/// One placeholder of an outline font, with what it stands for.
public struct TDFOutlineCode: Equatable {
    public let code: UInt8
    public let role: String
}

public enum TDFOutlineCodes {
    /// A to R and `@` (Roy/SAC's table for E to L and O, `@`; the style table for the rest).
    public static let all: [TDFOutlineCode] = [
        ("A", "Horizontal edge (top or bottom)"), ("B", "Horizontal edge (the other line)"),
        ("C", "Vertical edge (left or right)"), ("D", "Vertical edge (the other line)"),
        ("E", "Upper left outer corner"), ("F", "Upper right outer corner"),
        ("G", "Upper left inner corner"), ("H", "Upper right inner corner"),
        ("I", "Lower left inner corner"), ("J", "Lower right inner corner"),
        ("K", "Lower left outer corner"), ("L", "Lower right outer corner"),
        ("M", "Joint on the right edge"), ("N", "Joint on the left edge"),
        ("O", "Hard space inside a letter"), ("P", "Space"), ("Q", "Space"), ("R", "Space"),
        ("@", "Filler: leading space, left transparent"),
    ].map { TDFOutlineCode(code: UInt8(ascii: $0.0), role: $0.1) }

    /// The character `code` draws in outline style `style` (0 to 18), as the renderer draws it.
    public static func drawn(_ code: UInt8, style: Int) -> UInt8 {
        let codes = TextArt.outlineStyles[min(18, max(0, style))]
        switch code {
        case UInt8(ascii: "@"), UInt8(ascii: "O"), UInt8(ascii: "R"): return 0x20
        case UInt8(ascii: "A")...UInt8(ascii: "Q"): return codes[Int(code) - 65]
        default: return code
        }
    }

    static func isPlaceholder(_ code: UInt8) -> Bool {
        (UInt8(ascii: "A")...UInt8(ascii: "R")).contains(code)
    }
}

/// A glyph as an editor canvas and back (rulings 2 and 3).
public enum TDFGlyphCanvas {
    /// The cell used for padding short rows: a space, light grey on black.
    public static let blank = AnsiCell()

    /// The size of a new glyph in `font`: its most common height and width, else 6 x 4.
    public static func newGlyphSize(for font: TDFFont) -> (width: Int, height: Int) {
        func common(_ values: [Int], _ fallback: Int, _ limit: Int) -> Int {
            let counts = Dictionary(values.map { ($0, 1) }, uniquingKeysWith: +)
            guard let best = counts.max(by: { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value })?.key else { return fallback }
            return min(limit, max(1, best))
        }
        return (common(font.glyphs.values.map(\.columns), 6, TDFLimits.maxWidth),
                common(font.glyphs.values.map(\.rows.count), 4, TDFLimits.maxHeight))
    }

    public static func cell(_ cell: TDFCell, type: TDFFontType) -> AnsiCell {
        switch type {
        case .block: return AnsiCell(code: cell.code)
        case .outline:
            let fg = TDFOutlineCodes.isPlaceholder(cell.code) ? 11 : cell.code == UInt8(ascii: "@") ? 8 : 7
            return AnsiCell(code: cell.code, fg: Palette.vga[fg])
        case .color:
            let a = cell.attribute
            let bg = Int((a >> 4) & 7) + (a & 0x80 != 0 ? 8 : 0)
            return AnsiCell(code: cell.code, fg: Palette.vga[Int(a & 15)], bg: Palette.vga[bg])
        }
    }

    public static func cell(_ cell: AnsiCell, type: TDFFontType) -> TDFCell {
        guard type == .color else { return TDFCell(code: cell.code) }
        let fg = Palette.nearestVGA(cell.fg), bg = Palette.nearestVGA(cell.bg)
        let blink = cell.blink || bg >= 8
        return TDFCell(code: cell.code, attribute: UInt8(fg) | UInt8(bg & 7) << 4 | (blink ? 0x80 : 0))
    }

    /// The canvas showing `glyph` (a blank one of the new glyph size when nil).
    public static func canvas(_ glyph: TDFGlyph?, type: TDFFontType, size: (width: Int, height: Int) = (6, 4)) -> EditCanvas {
        let width = glyph.map { max(1, $0.columns) } ?? size.width
        let height = glyph.map { max(1, $0.rows.count) } ?? size.height
        var canvas = EditCanvas(columns: width, height: height)
        canvas.setIceColors(type == .color)
        for (y, row) in (glyph?.rows ?? []).enumerated() {
            for (x, item) in row.cells.enumerated() { canvas.set(cell(item, type: type), x: x, y: y) }
        }
        return canvas
    }

    /// The glyph `canvas` shows, keeping `original`'s row lengths and descender flags (ruling 3).
    public static func glyph(from canvas: EditCanvas, type: TDFFontType, original: TDFGlyph?) -> TDFGlyph {
        let rows = canvas.rows.enumerated().map { y, line -> TDFRow in
            var cells = line.map { cell($0, type: type) }
            if let original, y < original.rows.count {
                let length = original.rows[y].cells.count
                if length <= line.count, line[length...].allSatisfy({ $0 == blank }) { cells = Array(cells.prefix(length)) }
                return TDFRow(cells: cells, descender: original.rows[y].descender)
            }
            return TDFRow(cells: cells)
        }
        return TDFGlyph(rows: rows)
    }

    /// The glyph after editing, or nil when the canvas still shows `original` unchanged.
    public static func edited(_ canvas: EditCanvas, type: TDFFontType, original: TDFGlyph?,
                              size: (width: Int, height: Int) = (6, 4)) -> TDFGlyph? {
        let before = Self.canvas(original, type: type, size: size)
        if before.columns == canvas.columns, before.rows == canvas.rows { return nil }
        return glyph(from: canvas, type: type, original: original)
    }
}

/// What a TDF file can hold (ruling 4, fonts plan deferred minor M9).
public enum TDFStorage {
    static func label(_ code: UInt8) -> String {
        "\"\(Character(Unicode.Scalar(code)))\""
    }

    /// `glyph` as it can be written and read back the same, and what was changed.
    public static func storable(_ glyph: TDFGlyph, type: TDFFontType) -> (glyph: TDFGlyph, notes: [String]) {
        var glyph = glyph
        var notes: [String] = []
        if glyph.rows.isEmpty { glyph.rows = [TDFRow(cells: [])] }
        if glyph.rows.count > TDFFile.maxRows { glyph.rows.removeSubrange(TDFFile.maxRows...) }
        for y in glyph.rows.indices {
            var cells = glyph.rows[y].cells
            if cells.count > TDFFile.maxRowCells { cells.removeSubrange(TDFFile.maxRowCells...) }
            for x in cells.indices where cells[x].code == 0 || cells[x].code == 0x0D {
                notes.append("row \(y + 1): character code \(cells[x].code) cannot be stored and became a space")
                cells[x].code = 0x20
            }
            if type == .color {
                for x in cells.indices where cells[x].code == 0x26 && (cells[x].attribute == 0 || cells[x].attribute == 0x0D) {
                    notes.append(cells[x].attribute == 0
                        ? "row \(y + 1): a black on black & became a black space (it would read back as a descender mark)"
                        : "row \(y + 1): an & in light magenta on black cannot be stored and became a space")
                    cells[x].code = 0x20
                }
            } else if !glyph.rows[y].descender, cells.last?.code == 0x26, cells.count < TDFFile.maxRowCells {
                notes.append("row \(y + 1): a space was added after the & at the end of the row (so it is not read as a descender mark)")
                cells.append(TDFCell(code: 0x20))
            }
            glyph.rows[y].cells = cells
        }
        return (glyph, notes)
    }

    /// Every glyph of `font` made storable; notes start with the character.
    public static func storable(_ font: TDFFont) -> (font: TDFFont, notes: [String]) {
        var font = font
        var notes: [String] = []
        for code in font.glyphs.keys.sorted() {
            let (glyph, glyphNotes) = storable(font.glyphs[code]!, type: font.type)
            font.glyphs[code] = glyph
            notes += glyphNotes.map { "\(font.name), \(label(code)) \($0)." }
        }
        return (font, notes)
    }
}

/// A glyph copied into a font of another type (ruling 6).
public enum TDFGlyphConvert {
    public static func convert(_ glyph: TDFGlyph, from source: TDFFontType, to target: TDFFontType) -> TDFGlyph {
        guard source != target else { return glyph }
        var glyph = glyph
        for y in glyph.rows.indices {
            glyph.rows[y].cells = glyph.rows[y].cells.map { cell in
                let code = source == .outline ? TDFOutlineCodes.drawn(cell.code, style: 0) : cell.code
                switch target {
                case .color: return TDFCell(code: code, attribute: source == .color ? cell.attribute : 0x07)
                case .block, .outline: return TDFCell(code: code)
                }
            }
        }
        return glyph
    }
}

/// The glyph clipboard: a one font TDF file (ruling 6).
public enum TDFGlyphClipboard {
    public static let pasteboardType = "com.traynham.ansiview.tdfglyph"

    public static func data(_ glyph: TDFGlyph, type: TDFFontType) -> Data? {
        let stored = TDFStorage.storable(glyph, type: type).glyph
        return try? TDFFile.write([TDFFont(name: "Clipboard", type: type, spacing: 0, glyphs: [33: stored])])
    }

    public static func glyph(from data: Data) -> (glyph: TDFGlyph, type: TDFFontType)? {
        guard let font = try? TDFFile.parse(data).fonts.first, let glyph = font.glyphs.values.first else { return nil }
        return (glyph, font.type)
    }
}

public enum TDFFontEditorError: LocalizedError, Equatable {
    case badName(String)

    public var errorDescription: String? {
        switch self {
        case .badName(let reason): return reason
        }
    }
}

/// The open font collection and every command on it (rulings 5 to 7). Main thread only.
public final class TDFFontEditorModel {
    public private(set) var fonts: [TDFFont]
    public private(set) var selectedFont = 0
    /// Warnings from reading the file (fonts that could not be read).
    public private(set) var openWarnings: [String] = []
    public let undoManager: UndoManager
    /// Called after anything changes.
    public var onChange: (() -> Void)?
    /// Called after an undo or redo replaced the fonts (an open glyph canvas must reload).
    public var onRestore: (() -> Void)?

    public var font: TDFFont { fonts[selectedFont] }
    public var isModified: Bool { revision != savedRevision }

    private var revision = 0
    private var nextRevision = 1
    private var savedRevision = 0

    /// The glyph being edited on a canvas, and the glyph it started as.
    public private(set) var editingCode: UInt8?
    private var sessionStart: (glyph: TDFGlyph?, state: State)?
    private var sessionRegistered = false
    private var sessionHeight = 0

    private struct State {
        var fonts: [TDFFont]
        var selectedFont: Int
        var revision: Int
    }

    private var state: State { State(fonts: fonts, selectedFont: selectedFont, revision: revision) }

    public init(fonts: [TDFFont]) {
        self.fonts = fonts.isEmpty ? [Self.newFont(name: "Untitled", type: .color)] : fonts
        undoManager = UndoManager()
        undoManager.groupsByEvent = false
    }

    public convenience init(data: Data) throws {
        let result = try TDFFile.parse(data)
        self.init(fonts: result.fonts)
        openWarnings = result.warnings
    }

    public static func newFont(name: String, type: TDFFontType, spacing: Int = 1) -> TDFFont {
        TDFFont(name: name, type: type, spacing: min(TDFLimits.spacing.upperBound, max(0, spacing)), glyphs: [:])
    }

    public func glyph(_ code: UInt8) -> TDFGlyph? { font.glyphs[code] }

    public func selectFont(_ index: Int) {
        guard fonts.indices.contains(index), index != selectedFont else { return }
        endEditing()
        selectedFont = index
        onChange?()
    }

    // MARK: Collection commands (ruling 5)

    public func addFont(name: String, type: TDFFontType, spacing: Int = 1) throws {
        if let problem = TDFLimits.nameProblem(name) { throw TDFFontEditorError.badName(problem) }
        perform("Add Font") { model in
            model.fonts.append(Self.newFont(name: name, type: type, spacing: spacing))
            model.selectedFont = model.fonts.count - 1
        }
    }

    public func duplicateFont() {
        let base = font.name
        var name = base
        var number = 2
        while fonts.contains(where: { $0.name == name }) {
            let suffix = " \(number)"
            name = String(base.prefix(TDFLimits.maxNameLength - suffix.count)) + suffix
            number += 1
        }
        perform("Duplicate Font") { model in
            var copy = model.font
            copy.name = name
            model.fonts.insert(copy, at: model.selectedFont + 1)
            model.selectedFont += 1
        }
    }

    /// Deletes a font; false (nothing changes) for the last one, since a file needs a font.
    @discardableResult
    public func deleteFont(_ index: Int) -> Bool {
        guard fonts.count > 1, fonts.indices.contains(index) else { return false }
        perform("Delete Font") { model in
            model.fonts.remove(at: index)
            if index < model.selectedFont { model.selectedFont -= 1 }
            model.selectedFont = min(model.fonts.count - 1, model.selectedFont)
        }
        return true
    }

    public func renameFont(_ index: Int, to name: String) throws {
        if let problem = TDFLimits.nameProblem(name) { throw TDFFontEditorError.badName(problem) }
        guard fonts.indices.contains(index) else { return }
        perform("Rename Font") { $0.fonts[index].name = name }
    }

    public func moveFont(from: Int, to: Int) {
        guard fonts.indices.contains(from), fonts.indices.contains(to), from != to else { return }
        perform("Move Font") { model in
            let moved = model.fonts.remove(at: from)
            model.fonts.insert(moved, at: to)
            model.selectedFont = to
        }
    }

    public func setSpacing(_ spacing: Int) {
        let value = min(TDFLimits.spacing.upperBound, max(TDFLimits.spacing.lowerBound, spacing))
        perform("Letter Spacing") { $0.fonts[$0.selectedFont].spacing = value }
    }

    // MARK: Glyph commands (ruling 6)

    public func setGlyph(_ code: UInt8, _ glyph: TDFGlyph?, actionName: String = "Change Glyph") {
        perform(actionName) { $0.fonts[$0.selectedFont].glyphs[code] = glyph }
    }

    public func clearGlyph(_ code: UInt8) { setGlyph(code, nil, actionName: "Clear Glyph") }

    /// The glyph as clipboard data, or nil when it does not exist.
    public func copyGlyph(_ code: UInt8) -> Data? {
        glyph(code).flatMap { TDFGlyphClipboard.data($0, type: font.type) }
    }

    /// Pastes clipboard data as `code`'s glyph, converted to this font's type. False for bad data.
    @discardableResult
    public func pasteGlyph(_ code: UInt8, data: Data) -> Bool {
        guard let (glyph, type) = TDFGlyphClipboard.glyph(from: data) else { return false }
        setGlyph(code, TDFGlyphConvert.convert(glyph, from: type, to: font.type), actionName: "Paste Glyph")
        return true
    }

    /// Copies `code` of another font into `target` here, converted to this font's type.
    public func copyGlyph(from other: TDFFont, code: UInt8, to target: UInt8) {
        guard let glyph = other.glyphs[code] else { return }
        setGlyph(target, TDFGlyphConvert.convert(glyph, from: other.type, to: font.type), actionName: "Copy Glyph from Font")
    }

    /// Resizes a glyph to `width` by `height` (clamped to the limits), creating it when missing.
    public func resizeGlyph(_ code: UInt8, width: Int, height: Int) {
        let w = min(TDFLimits.maxWidth, max(1, width)), h = min(TDFLimits.maxHeight, max(1, height))
        let pad = font.type == .color ? TDFCell(code: 0x20, attribute: 0x07) : TDFCell(code: 0x20)
        var rows = glyph(code)?.rows ?? []
        if rows.count > h { rows.removeSubrange(h...) }
        while rows.count < h { rows.append(TDFRow(cells: [])) }
        for y in rows.indices {
            if rows[y].cells.count > w { rows[y].cells.removeSubrange(w...) }
            rows[y].cells += Array(repeating: pad, count: w - rows[y].cells.count)
        }
        setGlyph(code, TDFGlyph(rows: rows), actionName: "Glyph Size")
    }

    /// Marks the last `count` rows as below the baseline (descender rows).
    public func setDescenderRows(_ code: UInt8, _ count: Int) {
        guard var rows = glyph(code)?.rows else { return }
        for y in rows.indices { rows[y].descender = y >= rows.count - max(0, count) }
        setGlyph(code, TDFGlyph(rows: rows), actionName: "Rows Below Baseline")
    }

    // MARK: Editing session (ruling 7)

    /// Starts editing `code` on a canvas; returns the canvas to show.
    public func beginEditing(_ code: UInt8) -> EditCanvas {
        endEditing()
        editingCode = code
        sessionStart = (glyph(code), state)
        sessionRegistered = false
        let canvas = TDFGlyphCanvas.canvas(glyph(code), type: font.type, size: TDFGlyphCanvas.newGlyphSize(for: font))
        sessionHeight = canvas.height
        return canvas
    }

    /// The canvas of the open glyph changed: the glyph follows it (one undo step per session).
    public func updateEditing(_ canvas: EditCanvas) {
        guard let code = editingCode, let start = sessionStart else { return }
        var canvas = canvas
        // Rows the cursor added below the glyph are dropped while they are blank.
        while canvas.height > sessionHeight, canvas.rows.last?.allSatisfy({ $0 == TDFGlyphCanvas.blank }) == true {
            canvas.resize(columns: canvas.columns, height: canvas.height - 1)
        }
        let size = TDFGlyphCanvas.newGlyphSize(for: font)
        let updated = TDFGlyphCanvas.edited(canvas, type: font.type, original: start.glyph, size: size) ?? start.glyph
        guard updated != glyph(code) else { return }
        fonts[selectedFont].glyphs[code] = updated
        revision = updated == start.glyph ? start.state.revision : newRevision()
        if !sessionRegistered {
            sessionRegistered = true
            register(restoring: start.state, name: "Edit Glyph \(Character(Unicode.Scalar(code)))")
        }
        onChange?()
    }

    public func endEditing() {
        editingCode = nil
        sessionStart = nil
        sessionRegistered = false
    }

    // MARK: Files

    /// The collection as a TDF file. The model is made storable first (ruling 4), so the file
    /// reads back as exactly the fonts the model then holds; `notes` say what changed.
    public func fileData() throws -> (data: Data, notes: [String]) {
        var notes: [String] = []
        var stored: [TDFFont] = []
        for font in fonts {
            let (fixed, fontNotes) = TDFStorage.storable(font)
            stored.append(fixed)
            notes += fontNotes
        }
        let data = try TDFFile.write(stored)
        let readBack = try TDFFile.parse(data).fonts
        if readBack != fonts {
            fonts = readBack
            if let code = editingCode { sessionStart?.glyph = glyph(code) }
            onChange?()
        }
        return (data, notes)
    }

    /// The fonts as they are now have been saved.
    public func markSaved() {
        savedRevision = revision
        onChange?()
    }

    // MARK: Undo

    private func perform(_ name: String, _ change: (TDFFontEditorModel) -> Void) {
        endEditing()
        let before = state
        change(self)
        guard fonts != before.fonts || selectedFont != before.selectedFont else { return }
        revision = newRevision()
        register(restoring: before, name: name)
        onChange?()
    }

    private func register(restoring before: State, name: String) {
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: self) { $0.restore(before, name: name) }
        undoManager.setActionName(name)
        undoManager.endUndoGrouping()
    }

    private func restore(_ saved: State, name: String) {
        let current = state
        endEditing()
        fonts = saved.fonts
        selectedFont = min(fonts.count - 1, saved.selectedFont)
        revision = saved.revision
        undoManager.registerUndo(withTarget: self) { $0.restore(current, name: name) }
        undoManager.setActionName(name)
        onRestore?()
        onChange?()
    }

    private func newRevision() -> Int {
        defer { nextRevision += 1 }
        return nextRevision
    }
}
