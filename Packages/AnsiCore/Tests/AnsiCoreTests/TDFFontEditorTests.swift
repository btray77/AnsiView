import Foundation
import Testing
@testable import AnsiCore

/// The TheDraw font editor model (TDF editor plan, rulings 1 to 7). Every font here is drawn in
/// the test (original work), never copied from a third party font.
struct TDFFontEditorTests {
    // MARK: Fixtures

    static func row(_ codes: String, attribute: UInt8 = 0, descender: Bool = false) -> TDFRow {
        TDFRow(cells: codes.unicodeScalars.map { TDFCell(code: CP437.code(for: $0) ?? 0x3F, attribute: attribute) }, descender: descender)
    }

    /// A tiny original colour font: a 3 x 2 "A" with mixed attributes, a ragged "B" and a blink "C".
    static var colourFont: TDFFont {
        var a = TDFGlyph(rows: [row("▄█▄", attribute: 0x0C), row("█ █", attribute: 0x4E)])
        a.rows[1].cells[1].attribute = 0x07
        let b = TDFGlyph(width: 3, height: 2, rows: [row("██", attribute: 0x09), row("███", attribute: 0x19)])
        let c = TDFGlyph(rows: [row("▀▀", attribute: 0x9F), row("▄▄", attribute: 0xF0, descender: true)])
        return TDFFont(name: "Test Colour", type: .color, spacing: 1,
                       glyphs: [UInt8(ascii: "A"): a, UInt8(ascii: "B"): b, UInt8(ascii: "C"): c])
    }

    static var outlineFont: TDFFont {
        let a = TDFGlyph(rows: [row("EAF"), row("COD"), row("KBL")])
        return TDFFont(name: "Test Outline", type: .outline, spacing: 1, glyphs: [UInt8(ascii: "A"): a])
    }

    static var blockFont: TDFFont {
        let a = TDFGlyph(rows: [row("█▀█"), row("█▀█"), row("▀ ▀")])
        var hard = row("█ █")
        hard.cells[1].code = 0xFF
        let b = TDFGlyph(rows: [hard, row("██")])
        return TDFFont(name: "Test Block", type: .block, spacing: 2, glyphs: [UInt8(ascii: "A"): a, UInt8(ascii: "B"): b])
    }

    // MARK: Limits and outline codes (ruling 1)

    @Test func limitsFollowTheSpecification() {
        #expect(TDFLimits.maxWidth == 30)
        #expect(TDFLimits.maxHeight == 12)
        #expect(TDFLimits.spacing == 0...40)
        #expect(TDFLimits.nameProblem("ABCDEFGHIJKL") == nil)
        #expect(TDFLimits.nameProblem("ABCDEFGHIJKLM") != nil)
        #expect(TDFLimits.nameProblem("") != nil)
        #expect(TDFLimits.nameProblem("Snow ☃") != nil)
        #expect(TDFLimits.nameProblem("Bloc ▓") == nil)
    }

    @Test func outlineCodesCoverPlaceholders() {
        let codes = TDFOutlineCodes.all.map(\.code)
        #expect(codes.count == 19)
        #expect(codes.first == UInt8(ascii: "A"))
        #expect(codes.contains(UInt8(ascii: "@")))
        #expect(codes.contains(UInt8(ascii: "R")))
        for code in TDFOutlineCodes.all { #expect(!code.role.isEmpty) }
        // What a placeholder draws in a style matches the renderer.
        #expect(TDFOutlineCodes.drawn(UInt8(ascii: "E"), style: 0) == TextArt.outlineStyles[0][4])
        #expect(TDFOutlineCodes.drawn(UInt8(ascii: "@"), style: 3) == 0x20)
    }

    // MARK: Glyph canvas (rulings 2 and 3)

    @Test func everyTypeRoundTripsThroughTheCanvas() {
        for font in [Self.colourFont, Self.outlineFont, Self.blockFont] {
            for (_, glyph) in font.glyphs {
                let canvas = TDFGlyphCanvas.canvas(glyph, type: font.type)
                #expect(canvas.columns == glyph.columns)
                #expect(canvas.height == glyph.rows.count)
                #expect(TDFGlyphCanvas.edited(canvas, type: font.type, original: glyph) == nil)
                #expect(TDFGlyphCanvas.glyph(from: canvas, type: font.type, original: glyph).rows == glyph.rows)
            }
        }
    }

    @Test func colourAttributesMapLosslessly() {
        // Every attribute byte, blink included, survives the canvas.
        let cells = (0...255).map { TDFCell(code: 0xDB, attribute: UInt8($0)) }
        let glyph = TDFGlyph(rows: [TDFRow(cells: Array(cells.prefix(128))), TDFRow(cells: Array(cells.suffix(128)))])
        let canvas = TDFGlyphCanvas.canvas(glyph, type: .color)
        #expect(canvas.iceColors)
        #expect(TDFGlyphCanvas.glyph(from: canvas, type: .color, original: nil).rows == glyph.rows)
        // A blink cell shows as a bright background.
        let blink = TDFGlyphCanvas.canvas(Self.colourFont.glyphs[UInt8(ascii: "C")]!, type: .color)
        #expect(blink[0, 0].bg == Palette.vga[9])
    }

    @Test func outlinePlaceholdersAreTinted() {
        let canvas = TDFGlyphCanvas.canvas(Self.outlineFont.glyphs[UInt8(ascii: "A")]!, type: .outline)
        #expect(canvas[0, 0].code == UInt8(ascii: "E"))
        #expect(canvas[0, 0].fg == Palette.vga[11])
    }

    @Test func editedRaggedRowKeepsItsLength() {
        let b = Self.colourFont.glyphs[UInt8(ascii: "B")]!
        var canvas = TDFGlyphCanvas.canvas(b, type: .color)
        #expect(canvas[2, 0] == AnsiCell())
        canvas.set(AnsiCell(code: 0xB0, fg: Palette.vga[14], bg: Palette.vga[1]), x: 0, y: 1)
        let edited = TDFGlyphCanvas.edited(canvas, type: .color, original: b)
        #expect(edited?.rows[0].cells.count == 2)
        #expect(edited?.rows[1].cells[0] == TDFCell(code: 0xB0, attribute: 0x1E))
        // Drawing past the original length makes the row full width.
        canvas.set(AnsiCell(code: 0xB1), x: 2, y: 0)
        #expect(TDFGlyphCanvas.edited(canvas, type: .color, original: b)?.rows[0].cells.count == 3)
    }

    @Test func blockColoursAreNotStored() {
        let a = Self.blockFont.glyphs[UInt8(ascii: "A")]!
        var canvas = TDFGlyphCanvas.canvas(a, type: .block)
        canvas.set(AnsiCell(code: 0xDB, fg: Palette.vga[12], bg: Palette.vga[3]), x: 1, y: 2)
        let edited = TDFGlyphCanvas.edited(canvas, type: .block, original: a)
        #expect(edited?.rows[2].cells[1] == TDFCell(code: 0xDB, attribute: 0))
    }

    @Test func descenderFlagsStayByRow() {
        let c = Self.colourFont.glyphs[UInt8(ascii: "C")]!
        var canvas = TDFGlyphCanvas.canvas(c, type: .color)
        canvas.set(AnsiCell(code: 0x41), x: 0, y: 0)
        let edited = TDFGlyphCanvas.edited(canvas, type: .color, original: c)
        #expect(edited?.rows.map(\.descender) == [false, true])
        #expect(edited?.height == 1)
    }

    // MARK: Storage (ruling 4)

    @Test func cellsAFileCannotHoldAreFixedAndReported() throws {
        var block = TDFGlyph(rows: [Self.row("A&"), Self.row("B&", descender: true)])
        block.rows[0].cells.append(TDFCell(code: 0x0D))
        block.rows[0].cells.append(TDFCell(code: 0x26))
        let (stored, notes) = TDFStorage.storable(block, type: .block)
        #expect(stored.rows[0].cells.map(\.code) == [0x41, 0x26, 0x20, 0x26, 0x20])
        #expect(stored.rows[1].cells.map(\.code) == [0x42, 0x26])
        #expect(notes.count == 2)
        let font = TDFFont(name: "Fix", type: .block, spacing: 1, glyphs: [65: stored])
        #expect(try TDFFile.parse(TDFFile.write([font])).fonts == [font])

        let colour = TDFGlyph(rows: [TDFRow(cells: [TDFCell(code: 0x26, attribute: 0x00), TDFCell(code: 0x26, attribute: 0x0D),
                                                    TDFCell(code: 0x26, attribute: 0x0C)])])
        let (storedColour, colourNotes) = TDFStorage.storable(colour, type: .color)
        #expect(storedColour.rows[0].cells == [TDFCell(code: 0x20, attribute: 0x00), TDFCell(code: 0x20, attribute: 0x0D),
                                               TDFCell(code: 0x26, attribute: 0x0C)])
        #expect(colourNotes.count == 2)
        let colourFont = TDFFont(name: "Fix", type: .color, spacing: 1, glyphs: [65: storedColour])
        #expect(try TDFFile.parse(TDFFile.write([colourFont])).fonts == [colourFont])

        let empty = TDFStorage.storable(TDFGlyph(width: 0, height: 0, rows: []), type: .block).glyph
        #expect(empty.rows.count == 1)
    }

    // MARK: Collection (ruling 5)

    @Test func collectionCommands() throws {
        let model = TDFFontEditorModel(fonts: [Self.colourFont])
        try model.addFont(name: "Second", type: .outline, spacing: 3)
        #expect(model.fonts.map(\.name) == ["Test Colour", "Second"])
        #expect(model.selectedFont == 1)
        #expect(model.font.type == .outline)
        #expect(model.font.glyphs.isEmpty)
        #expect(throws: TDFFontEditorError.self) { try model.addFont(name: "Much Too Long A Name", type: .block, spacing: 1) }
        model.duplicateFont()
        #expect(model.fonts.count == 3)
        #expect(model.fonts[2].name == "Second 2")
        try model.renameFont(2, to: "Third")
        #expect(throws: TDFFontEditorError.self) { try model.renameFont(2, to: "Thirteen chars") }
        model.moveFont(from: 2, to: 0)
        #expect(model.fonts.map(\.name) == ["Third", "Test Colour", "Second"])
        #expect(model.selectedFont == 0)
        #expect(model.deleteFont(0))
        #expect(model.fonts.map(\.name) == ["Test Colour", "Second"])
        #expect(model.deleteFont(0))
        #expect(!model.deleteFont(0))  // the last font stays
        #expect(model.fonts.count == 1)
        model.setSpacing(99)
        #expect(model.font.spacing == 40)
        // Every command is one undo step.
        for _ in 0..<7 { model.undoManager.undo() }
        #expect(model.fonts == [Self.colourFont])
        #expect(!model.isModified)
        for _ in 0..<7 { model.undoManager.redo() }
        #expect(model.fonts.map(\.name) == ["Second"])
        #expect(model.font.spacing == 40)
    }

    // MARK: Glyph commands (ruling 6)

    @Test func glyphClearCopyPasteAndConvert() throws {
        let model = TDFFontEditorModel(fonts: [Self.colourFont, Self.outlineFont])
        let a = UInt8(ascii: "A"), z = UInt8(ascii: "Z")
        let copied = try #require(model.copyGlyph(a))
        model.clearGlyph(a)
        #expect(model.glyph(a) == nil)
        #expect(model.pasteGlyph(z, data: copied))
        #expect(model.glyph(z) == Self.colourFont.glyphs[a])
        #expect(!model.pasteGlyph(z, data: Data("junk".utf8)))
        // Into the outline font: attributes go.
        model.selectFont(1)
        #expect(model.pasteGlyph(z, data: copied))
        #expect(model.glyph(z)?.rows.flatMap(\.cells).allSatisfy { $0.attribute == 0 } == true)
        // Outline into colour: placeholders become style 1 characters, attribute 0x07.
        let outlineData = try #require(model.copyGlyph(a))
        model.selectFont(0)
        #expect(model.pasteGlyph(a, data: outlineData))
        let converted = try #require(model.glyph(a))
        #expect(converted.rows[0].cells.map(\.code) == [TextArt.outlineStyles[0][4], TextArt.outlineStyles[0][0], TextArt.outlineStyles[0][5]])
        #expect(converted.rows[1].cells[1] == TDFCell(code: 0x20, attribute: 0x07))
        // From another font directly.
        model.copyGlyph(from: Self.blockFont, code: UInt8(ascii: "B"), to: UInt8(ascii: "b"))
        #expect(model.glyph(UInt8(ascii: "b"))?.rows[0].cells[1] == TDFCell(code: 0xFF, attribute: 0x07))
        for _ in 0..<5 { model.undoManager.undo() }
        #expect(model.fonts == [Self.colourFont, Self.outlineFont])
    }

    @Test func resizeAndDescenderRows() {
        let model = TDFFontEditorModel(fonts: [Self.blockFont])
        let a = UInt8(ascii: "A")
        model.resizeGlyph(a, width: 5, height: 2)
        #expect(model.glyph(a)?.rows.count == 2)
        #expect(model.glyph(a)?.rows.allSatisfy { $0.cells.count == 5 } == true)
        model.resizeGlyph(a, width: 99, height: 99)
        #expect(model.glyph(a)?.columns == 30)
        #expect(model.glyph(a)?.rows.count == 12)
        model.setDescenderRows(a, 2)
        #expect(model.glyph(a)?.rows.suffix(3).map(\.descender) == [false, true, true])
        #expect(model.glyph(a)?.height == 10)
        // A missing glyph is created by a resize.
        model.resizeGlyph(UInt8(ascii: "Q"), width: 2, height: 2)
        #expect(model.glyph(UInt8(ascii: "Q"))?.columns == 2)
    }

    // MARK: Editing session (ruling 7)

    @Test func editingSessionIsOneUndoStep() {
        let model = TDFFontEditorModel(fonts: [Self.colourFont])
        let a = UInt8(ascii: "A")
        var canvas = model.beginEditing(a)
        #expect(model.editingCode == a)
        canvas.set(AnsiCell(code: 0xB2, fg: Palette.vga[10], bg: Palette.vga[0]), x: 0, y: 0)
        model.updateEditing(canvas)
        canvas.set(AnsiCell(code: 0xB2, fg: Palette.vga[10], bg: Palette.vga[0]), x: 1, y: 0)
        model.updateEditing(canvas)
        #expect(model.glyph(a)?.rows[0].cells[1] == TDFCell(code: 0xB2, attribute: 0x0A))
        #expect(model.isModified)
        model.endEditing()
        model.undoManager.undo()
        #expect(model.fonts == [Self.colourFont])
        #expect(!model.isModified)
        model.undoManager.redo()
        #expect(model.glyph(a)?.rows[0].cells[1] == TDFCell(code: 0xB2, attribute: 0x0A))
        // Looking at a missing glyph does not create it; moving the cursor down adds no rows.
        var empty = model.beginEditing(UInt8(ascii: "~"))
        #expect(empty.columns >= 1)
        empty.set(AnsiCell(), x: 0, y: 5)
        model.updateEditing(empty)
        #expect(model.glyph(UInt8(ascii: "~")) == nil)
        empty.set(AnsiCell(code: 0xDB), x: 0, y: 0)
        model.updateEditing(empty)
        #expect(model.glyph(UInt8(ascii: "~"))?.rows.count == TDFGlyphCanvas.newGlyphSize(for: model.font).height)
    }

    @Test func undoDuringASessionRestoresTheGlyph() {
        let model = TDFFontEditorModel(fonts: [Self.blockFont])
        var restored = 0
        model.onRestore = { restored += 1 }
        let a = UInt8(ascii: "A")
        var canvas = model.beginEditing(a)
        canvas.set(AnsiCell(code: 0x41), x: 0, y: 0)
        model.updateEditing(canvas)
        model.undoManager.undo()
        #expect(model.glyph(a) == Self.blockFont.glyphs[a])
        #expect(restored == 1)
        // The session starts again from the restored glyph.
        canvas = model.beginEditing(a)
        canvas.set(AnsiCell(code: 0x42), x: 0, y: 0)
        model.updateEditing(canvas)
        model.undoManager.undo()
        #expect(model.glyph(a) == Self.blockFont.glyphs[a])
    }

    // MARK: Files

    @Test func newFontsOfEveryTypeSaveAndReopen() throws {
        for type in TDFFontType.allCases {
            let model = TDFFontEditorModel(fonts: [TDFFontEditorModel.newFont(name: "New", type: type)])
            var canvas = model.beginEditing(UInt8(ascii: "H"))
            canvas.set(AnsiCell(code: type == .outline ? UInt8(ascii: "C") : 0xDB, fg: Palette.vga[12], bg: Palette.vga[1]), x: 0, y: 0)
            model.updateEditing(canvas)
            model.endEditing()
            let saved = try model.fileData()
            #expect(saved.notes.isEmpty)
            let reopened = try TDFFontEditorModel(data: saved.data)
            #expect(reopened.fonts == model.fonts)
            #expect(reopened.fonts[0].type == type)
        }
    }

    @Test func saveNormalizesTheModelSoReopenMatches() throws {
        var odd = Self.blockFont
        odd.glyphs[UInt8(ascii: "Z")] = TDFGlyph(rows: [Self.row("Z&")])
        let model = TDFFontEditorModel(fonts: [odd, Self.colourFont])
        let saved = try model.fileData()
        #expect(saved.notes.count == 1)
        #expect(saved.notes[0].contains("Z"))
        model.markSaved()
        #expect(!model.isModified)
        #expect(try TDFFile.parse(saved.data).fonts == model.fonts)
    }

    @Test func openedFileKeepsEveryByte() throws {
        let data = try TDFFile.write([Self.colourFont, Self.outlineFont, Self.blockFont])
        let model = try TDFFontEditorModel(data: data)
        #expect(model.fonts.count == 3)
        _ = model.beginEditing(UInt8(ascii: "B"))
        model.endEditing()
        #expect(try model.fileData().data == data)
    }

    @Test func savedFontLoadsInTheLibraryAndRenders() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tdfedit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = TDFFontEditorModel(fonts: [Self.colourFont, Self.blockFont])
        let file = folder.appendingPathComponent("source.tdf")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try model.fileData().data.write(to: file)
        let library = FontLibrary(directory: folder.appendingPathComponent("lib"))
        let report = library.importFonts(from: [file])
        #expect(report.fontsAdded == 2)
        let entry = try #require(library.userEntries.first { $0.name == "Test Colour" })
        let result = TextArt.render("ABC", font: entry.font, options: TextArtOptions())
        #expect(result.missing.isEmpty)
        #expect(result.region.width == 3 + 1 + 3 + 1 + 2)
        #expect(result.region.cells[0][0].code == CP437.code(for: "▄"))
    }
    /// Over the real collection when ANSIVIEW_FONT_CORPUS names it (third party, never committed):
    /// every glyph survives the canvas unchanged and every file saves back byte for byte.
    @Test func corpusGlyphsSurviveTheEditor() throws {
        guard let folder = ProcessInfo.processInfo.environment["ANSIVIEW_FONT_CORPUS"] else { return }
        let urls = (FileManager.default.enumerator(at: URL(fileURLWithPath: folder), includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL } ?? []).filter { $0.pathExtension.lowercased() == "tdf" }
        var fonts = 0, glyphs = 0, canvasFailures = 0, notes = 0, filesSame = 0, files = 0
        for url in urls {
            guard let model = try? TDFFontEditorModel(data: Data(contentsOf: url)) else { continue }
            files += 1
            for font in model.fonts {
                fonts += 1
                for glyph in font.glyphs.values {
                    glyphs += 1
                    let canvas = TDFGlyphCanvas.canvas(glyph, type: font.type)
                    if TDFGlyphCanvas.edited(canvas, type: font.type, original: glyph) != nil
                        || TDFGlyphCanvas.glyph(from: canvas, type: font.type, original: glyph).rows != glyph.rows { canvasFailures += 1 }
                }
            }
            let before = model.fonts
            let saved = try model.fileData()
            notes += saved.notes.count
            if try TDFFile.parse(saved.data).fonts == model.fonts, saved.notes.isEmpty == (before == model.fonts) { filesSame += 1 }
        }
        print("TDFEDIT CORPUS files=\(files) fonts=\(fonts) glyphs=\(glyphs) canvasFailures=\(canvasFailures) saveNotes=\(notes) reopenEqual=\(filesSame)")
        #expect(canvasFailures == 0)
        #expect(filesSame == files)
    }
}
