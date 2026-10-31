import AnsiCore
import AppKit
import UniformTypeIdentifiers

// The TheDraw font editor window (docs/superpowers/plans/2026-10-30-ansiview-2.0-tdf-editor.md):
// the fonts of one .TDF file, a grid of the 94 characters, the glyph on the ANSI editor's own
// canvas and tools, outline codes and styles, and a live preview drawn by TextArt.render.

/// One font editor window per file. The first Save of a new file asks where.
final class TDFFontEditorWindowController: NSWindowController, NSWindowDelegate {
    private(set) static var open: Set<TDFFontEditorWindowController> = []
    let model: TDFFontEditorModel
    let viewController: TDFFontEditorViewController
    private(set) var fileURL: URL?
    private let untitledName: String
    /// Tests and harnesses answer the save panel and alerts here instead of a person.
    static var chooseSaveURL: ((String) -> URL?)?
    static var report: ((String, String) -> Void)?

    init(model: TDFFontEditorModel, url: URL?, name: String = "Untitled.tdf") {
        self.model = model
        fileURL = url
        untitledName = name
        viewController = TDFFontEditorViewController(model: model)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1340, height: 900),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.contentMinSize = NSSize(width: 1100, height: 760)
        window.contentViewController = viewController
        window.setContentSize(NSSize(width: 1340, height: 900))
        super.init(window: window)
        window.delegate = self
        viewController.windowController = self
        updateTitle()
        window.center()
        model.onChange = { [weak self] in self?.modelChanged() }
        Self.open.insert(self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: Entry points

    /// Tools > TDF Font Editor: create a new font (name, type, spacing) or open a .TDF file.
    static func showNewOrOpen() {
        guard let request = NewFontDialog.run(title: "New TheDraw Font", allowOpen: true) else { return }
        switch request {
        case .open: openPanel()
        case let .create(name, type, spacing):
            present(TDFFontEditorWindowController(model: TDFFontEditorModel(fonts: [TDFFontEditorModel.newFont(name: name, type: type, spacing: spacing)]),
                                                 url: nil, name: "\(name).tdf"))
        }
    }

    static func openPanel() {
        let panel = NSOpenPanel()
        panel.title = "Open TheDraw Font"
        panel.message = "Choose a TheDraw font file (.tdf). A file can hold several fonts."
        panel.allowedContentTypes = [UTType(filenameExtension: "tdf") ?? .data]
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url: url, select: 0)
    }

    /// Opens a file (the window already showing it comes to the front).
    @discardableResult
    static func open(url: URL, select index: Int) -> TDFFontEditorWindowController? {
        if let existing = Self.open.first(where: { $0.fileURL?.standardizedFileURL == url.standardizedFileURL }) {
            existing.model.selectFont(index)
            existing.showWindow(nil)
            return existing
        }
        do {
            let model = try TDFFontEditorModel(data: Data(contentsOf: url))
            model.selectFont(min(index, model.fonts.count - 1))
            let controller = TDFFontEditorWindowController(model: model, url: url)
            present(controller)
            if !model.openWarnings.isEmpty {
                tell("Some fonts in \(url.lastPathComponent) could not be read", model.openWarnings.prefix(8).joined(separator: "\n"))
            }
            return controller
        } catch {
            tell("\(url.lastPathComponent) could not be opened", error.localizedDescription)
            return nil
        }
    }

    /// Font Manager > Edit Font: a user font opens its file in AnsiView's font folder; a font
    /// that comes with AnsiView opens as an untitled copy (Save As).
    static func edit(_ entry: FontEntry) {
        guard case .tdf = entry.font else { NSSound.beep(); return }
        if entry.source == .user, let url = entry.url {
            open(url: url, select: entry.index)
            return
        }
        let model = TDFFontEditorModel(fonts: OriginalFonts.tdfFonts)
        model.selectFont(min(entry.index, model.fonts.count - 1))
        present(TDFFontEditorWindowController(model: model, url: nil, name: "AnsiView copy.tdf"))
    }

    /// Harnesses keep windows off the screen.
    static var showsWindows = true

    static func present(_ controller: TDFFontEditorWindowController) {
        guard showsWindows else { return }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    static func tell(_ message: String, _ detail: String) {
        if let report { report(message, detail); return }
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.runModal()
    }

    // MARK: State

    private func updateTitle() {
        window?.title = (fileURL?.lastPathComponent ?? untitledName) + "  (TheDraw Font Editor)"
        window?.representedURL = fileURL
        window?.isDocumentEdited = model.isModified
    }

    private func modelChanged() {
        window?.isDocumentEdited = model.isModified
        viewController.modelChanged()
    }

    /// Undo goes to the glyph canvas while it has the keyboard, else to the font (ruling 7).
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        if let canvas = viewController.glyphEditor?.canvasView, window.firstResponder === canvas {
            return canvas.editor.undoManager
        }
        return model.undoManager
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard model.isModified else { return true }
        switch askToSave("Save changes to \"\(fileURL?.lastPathComponent ?? untitledName)\"?") {
        case .save: return save()
        case .discard: return true
        case .cancel: return false
        }
    }

    func windowWillClose(_ notification: Notification) {
        viewController.glyphEditor?.closePanels()
        Self.open.remove(self)
    }

    enum Decision { case save, discard, cancel }

    static var decide: ((String) -> Decision)?

    private func askToSave(_ message: String) -> Decision {
        if let decide = Self.decide { return decide(message) }
        window?.makeKeyAndOrderFront(nil)
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = "Your changes to the font will be lost if you don't save them."
        alert.addButton(withTitle: "Save...")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .save
        case .alertThirdButtonReturn: return .discard
        default: return .cancel
        }
    }

    /// Quitting asks about every font editor with unsaved changes.
    static func canTerminate() -> Bool {
        for controller in open where controller.model.isModified {
            switch controller.askToSave("Save changes to \"\(controller.fileURL?.lastPathComponent ?? controller.untitledName)\" before quitting?") {
            case .save: if !controller.save() { return false }
            case .discard: continue
            case .cancel: return false
            }
        }
        return true
    }

    // MARK: Saving (ruling 8)

    @objc func saveDocument(_ sender: Any?) { save() }
    @objc func saveDocumentAs(_ sender: Any?) { saveAs() }

    @discardableResult
    func save() -> Bool {
        guard let fileURL else { return saveAs() }
        return write(to: fileURL)
    }

    @discardableResult
    func saveAs() -> Bool {
        let suggested = fileURL?.lastPathComponent ?? untitledName
        let chosen: URL?
        if let choose = Self.chooseSaveURL {
            chosen = choose(suggested)
        } else {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = suggested
            panel.allowedContentTypes = [UTType(filenameExtension: "tdf") ?? .data]
            panel.isExtensionHidden = false
            panel.message = "Saves every font of this window in one TheDraw font file (.tdf)."
            chosen = panel.runModal() == .OK ? panel.url : nil
        }
        guard let url = chosen, write(to: url) else { return false }
        fileURL = url
        updateTitle()
        return true
    }

    var isInFontFolder: Bool {
        fileURL?.deletingLastPathComponent().standardizedFileURL.path == FontStore.library.directory.standardizedFileURL.path
    }

    private func write(to url: URL) -> Bool {
        viewController.commitGlyph()
        do {
            let (data, notes) = try model.fileData()
            try data.write(to: url, options: .atomic)
            model.markSaved()
            fileURL = url
            updateTitle()
            if isInFontFolder {
                FontStore.library.reload()
                FontStore.changed()
            }
            if !notes.isEmpty {
                Self.tell("Saved, with \(notes.count) change\(notes.count == 1 ? "" : "s") a TheDraw font file needs",
                          notes.prefix(8).joined(separator: "\n") + (notes.count > 8 ? "\n...and \(notes.count - 8) more." : ""))
            }
            viewController.reopenGlyph()
            return true
        } catch {
            Self.tell("The font could not be saved", error.localizedDescription)
            return false
        }
    }

    /// Copies the saved file into AnsiView's font folder (Font Manager and Text to ASCII).
    @objc func install(_ sender: Any?) {
        if isInFontFolder {
            guard !model.isModified || save() else { return }
            Self.tell("This font is in AnsiView's font folder", "Font Manager and Text to ASCII already list it; saving updates them.")
            return
        }
        guard (fileURL != nil && !model.isModified) || save(), let fileURL else { return }
        let report = FontStore.library.importFonts(from: [fileURL])
        FontStore.changed()
        Self.tell(report.summary, report.failures.map { "\($0.file): \($0.reason)" }.joined(separator: "\n"))
    }
}

/// The New Font question: a name, a type and a spacing (or Open for an existing file).
enum NewFontDialog {
    enum Request: Equatable {
        case create(name: String, type: TDFFontType, spacing: Int)
        case open
    }

    static var answer: ((Bool) -> Request?)?

    static func run(title: String, allowOpen: Bool) -> Request? {
        if let answer { return answer(allowOpen) }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = TDFEditorHelp.newFont
        let name = NSTextField(string: "Untitled")
        name.toolTip = "The font's name, at most 12 DOS (CP437) characters"
        let type = NSPopUpButton()
        for kind in TDFFontType.allCases { type.addItem(withTitle: kind.label) }
        type.selectItem(at: Int(TDFFontType.color.rawValue))
        type.toolTip = "Outline: shapes drawn with an outline style. Block: characters in the user's colours. Colour: characters with their own colours"
        let spacing = NSTextField(string: "1")
        spacing.toolTip = "Columns between letters, 0 to 40"
        let grid = NSGridView(views: [[NSTextField(labelWithString: "Name:"), name],
                                      [NSTextField(labelWithString: "Kind:"), type],
                                      [NSTextField(labelWithString: "Letter spacing:"), spacing]])
        grid.frame = NSRect(x: 0, y: 0, width: 300, height: 90)
        name.widthAnchor.constraint(equalToConstant: 180).isActive = true
        alert.accessoryView = grid
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        if allowOpen { alert.addButton(withTitle: "Open Existing...") }
        alert.window.initialFirstResponder = name
        while true {
            let response = alert.runModal()
            if response == .alertThirdButtonReturn { return .open }
            guard response == .alertFirstButtonReturn else { return nil }
            if let problem = TDFLimits.nameProblem(name.stringValue) {
                TDFFontEditorWindowController.tell("Choose another name", problem)
                continue
            }
            let kind = TDFFontType(rawValue: UInt8(max(0, type.indexOfSelectedItem))) ?? .color
            return .create(name: name.stringValue, type: kind, spacing: min(40, max(0, spacing.integerValue)))
        }
    }
}

/// The window's content.
final class TDFFontEditorViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    let model: TDFFontEditorModel
    weak var windowController: TDFFontEditorWindowController?
    let fontTable = NSTableView()
    let grid = TDFGlyphGridView()
    private(set) var glyphEditor: EditorViewController?
    let editorHost = NSView()
    let glyphLabel = NSTextField(labelWithString: "")
    let widthStepper = NSStepper(), heightStepper = NSStepper(), descenderStepper = NSStepper()
    let widthField = NSTextField(labelWithString: ""), heightField = NSTextField(labelWithString: ""), descenderField = NSTextField(labelWithString: "")
    let spacingStepper = NSStepper()
    let spacingField = NSTextField(labelWithString: "")
    let kindLabel = NSTextField(labelWithString: "")
    let sampleField = NSTextField(string: "TheDraw 2002")
    let stylePopup = NSPopUpButton()
    let previewView = NSImageView()
    let previewNote = NSTextField(labelWithString: "")
    let outlineRow = NSStackView()
    let styleStrip = NSStackView()
    private(set) var codeButtons: [NSButton] = []
    private(set) var styleButtons: [NSButton] = []
    let copyFromPopup = NSPopUpButton(frame: .zero, pullsDown: true)
    private(set) var buttons: [String: NSButton] = [:]

    init(model: TDFFontEditorModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
        model.onRestore = { [weak self] in self?.reopenGlyph() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var selectedCode: UInt8 { grid.selected }

    private func button(_ key: String, _ title: String, _ tip: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.toolTip = tip
        button.controlSize = .small
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        buttons[key] = button
        return button
    }

    private func stepper(_ stepper: NSStepper, _ field: NSTextField, range: ClosedRange<Int>, tip: String, _ action: Selector) -> NSStackView {
        stepper.minValue = Double(range.lowerBound)
        stepper.maxValue = Double(range.upperBound)
        stepper.increment = 1
        stepper.valueWraps = false
        stepper.target = self
        stepper.action = action
        stepper.toolTip = tip
        stepper.controlSize = .small
        field.toolTip = tip
        field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        field.alignment = .right
        field.widthAnchor.constraint(equalToConstant: 24).isActive = true
        let stack = NSStackView(views: [field, stepper])
        stack.spacing = 2
        stack.setHuggingPriority(.required, for: .horizontal)
        return stack
    }

    /// Takes the spare width of a row, so its controls stay together.
    static func spacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.init(1), for: .horizontal)
        return view
    }

    private func label(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12)
        return label
    }

    override func loadView() {
        // Fonts in the file.
        for (id, title, width) in [("name", "Font", 140.0), ("kind", "Kind", 90.0), ("count", "Glyphs", 50.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            fontTable.addTableColumn(column)
        }
        fontTable.dataSource = self
        fontTable.delegate = self
        fontTable.usesAlternatingRowBackgroundColors = true
        fontTable.target = self
        fontTable.doubleAction = #selector(renameFont(_:))
        fontTable.toolTip = "The fonts in this file; one TheDraw file can hold many. Double-click a font to rename it"
        let tableScroll = NSScrollView()
        tableScroll.documentView = fontTable
        tableScroll.hasVerticalScroller = true
        tableScroll.borderType = .bezelBorder
        tableScroll.translatesAutoresizingMaskIntoConstraints = false
        tableScroll.heightAnchor.constraint(equalToConstant: 120).isActive = true
        let fontButtons = NSStackView(views: [
            button("add", "Add...", "Add a new empty font (outline, block or colour) to this file", #selector(addFont(_:))),
            button("duplicate", "Duplicate", "Add a copy of the selected font to this file", #selector(duplicateFont(_:))),
            button("rename", "Rename...", "Rename the selected font (at most 12 characters)", #selector(renameFont(_:))),
            button("delete", "Delete", "Remove the selected font from this file (a file keeps at least one font)", #selector(deleteFont(_:))),
            button("up", "Up", "Move the selected font earlier in the file", #selector(moveFontUp(_:))),
            button("down", "Down", "Move the selected font later in the file", #selector(moveFontDown(_:))),
        ])
        fontButtons.spacing = 4
        kindLabel.textColor = .secondaryLabelColor
        kindLabel.font = .systemFont(ofSize: 11)
        kindLabel.toolTip = "The selected font's kind; it is chosen when the font is made"
        let spacingRow = NSStackView(views: [label("Letter spacing:"),
                                             stepper(spacingStepper, spacingField, range: TDFLimits.spacing,
                                                     tip: "Columns between letters when text is drawn with this font (0 to 40)", #selector(spacingChanged(_:))),
                                             kindLabel, Hint.button(FontHelp.tdfTypes, title: "TheDraw font kinds")])
        spacingRow.spacing = 6

        // The 94 characters.
        grid.onSelect = { [weak self] code in self?.openGlyph(code) }
        grid.onCommand = { [weak self] command in self?.gridCommand(command) }
        copyFromPopup.addItem(withTitle: "Copy from Font")
        copyFromPopup.toolTip = "Copy this character's glyph from another installed TheDraw font (converted to this font's kind)"
        copyFromPopup.controlSize = .small
        copyFromPopup.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        copyFromPopup.menu?.delegate = self
        let glyphButtons = NSStackView(views: [
            button("copy", "Copy", "Copy the selected glyph (paste it on another character or in another font)", #selector(copyGlyph(_:))),
            button("paste", "Paste", "Paste a copied glyph onto the selected character", #selector(pasteGlyph(_:))),
            button("clear", "Clear", "Remove the selected character's glyph from the font", #selector(clearGlyph(_:))),
            copyFromPopup,
        ])
        glyphButtons.spacing = 4
        let gridTitle = label("Characters (dim tiles are not in the font yet):")
        gridTitle.font = .boldSystemFont(ofSize: 12)

        let left = NSStackView(views: [label("Fonts in this file:"), tableScroll, fontButtons, spacingRow, gridTitle, grid, glyphButtons])
        left.orientation = .vertical
        left.alignment = .leading
        left.spacing = 6
        tableScroll.widthAnchor.constraint(equalTo: left.widthAnchor).isActive = true
        grid.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([grid.widthAnchor.constraint(equalToConstant: grid.intrinsicContentSize.width),
                                     grid.heightAnchor.constraint(equalToConstant: grid.intrinsicContentSize.height)])

        // Glyph controls above the canvas.
        glyphLabel.font = .boldSystemFont(ofSize: 13)
        glyphLabel.toolTip = "The character being edited"
        let sizeRow = NSStackView(views: [
            glyphLabel,
            label("Width:"), stepper(widthStepper, widthField, range: 1...TDFLimits.maxWidth, tip: "Glyph width in columns (1 to 30)", #selector(sizeChanged(_:))),
            label("Height:"), stepper(heightStepper, heightField, range: 1...TDFLimits.maxHeight, tip: "Glyph height in rows (1 to 12)", #selector(sizeChanged(_:))),
            label("Rows below baseline:"), stepper(descenderStepper, descenderField, range: 0...TDFLimits.maxHeight,
                                                   tip: "Rows that hang below the line (descenders of g, j, p, q, y)", #selector(descenderChanged(_:))),
            Hint.button(TDFEditorHelp.glyph, title: "Editing a glyph"),
            Self.spacer(),
        ])
        sizeRow.spacing = 6
        sizeRow.setCustomSpacing(18, after: glyphLabel)


        // Outline codes and styles (outline fonts only).
        for code in TDFOutlineCodes.all {
            let codeButton = NSButton(title: "", target: self, action: #selector(codeClicked(_:)))
            codeButton.tag = Int(code.code)
            codeButton.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            codeButton.controlSize = .small
            codeButton.bezelStyle = .rounded
            codeButtons.append(codeButton)
        }
        let codeTitle = label("Outline codes:")
        // Two rows of codes, so the row never widens the window.
        let firstCodes = NSStackView(views: [codeTitle] + Array(codeButtons.prefix(10)) + [Hint.button(TDFEditorHelp.outlineCodes, title: "Outline codes")])
        let secondCodes = NSStackView(views: [label("")] + Array(codeButtons.suffix(from: 10)))
        for row in [firstCodes, secondCodes] { row.spacing = 2 }
        codeTitle.widthAnchor.constraint(equalToConstant: 92).isActive = true
        secondCodes.views.first?.widthAnchor.constraint(equalToConstant: 92).isActive = true
        outlineRow.orientation = .vertical
        outlineRow.alignment = .leading
        outlineRow.setViews([firstCodes, secondCodes], in: .leading)
        outlineRow.spacing = 2
        for style in 0..<19 {
            let styleButton = NSButton(title: "", target: self, action: #selector(styleClicked(_:)))
            styleButton.tag = style
            styleButton.isBordered = false
            styleButton.imagePosition = .imageOnly
            styleButton.imageScaling = .scaleProportionallyDown
            styleButton.toolTip = "The glyph in outline style \(style + 1) (\(TextArt.outlineSample(style))); click to preview with it"
            styleButton.translatesAutoresizingMaskIntoConstraints = false
            styleButton.widthAnchor.constraint(equalToConstant: 40).isActive = true
            styleButton.heightAnchor.constraint(equalToConstant: 36).isActive = true
            styleButtons.append(styleButton)
        }
        styleStrip.setViews(styleButtons, in: .leading)
        styleStrip.spacing = 3

        // Preview.
        sampleField.toolTip = "Type text to see it drawn with this font as you edit (the Text to ASCII renderer)"
        sampleField.delegate = self
        sampleField.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
        for style in 0..<19 { stylePopup.addItem(withTitle: "Style \(style + 1)   \(TextArt.outlineSample(style))") }
        stylePopup.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        stylePopup.target = self
        stylePopup.action = #selector(previewStyleChanged(_:))
        stylePopup.toolTip = "The outline style the preview and the outline codes use (outline fonts)"
        previewView.imageScaling = .scaleProportionallyDown
        previewView.imageAlignment = .alignTopLeft
        previewView.wantsLayer = true
        previewView.layer?.backgroundColor = NSColor.black.cgColor
        previewView.toolTip = "The sample text drawn with this font, as Text to ASCII and Font Manager draw it"
        previewView.setContentCompressionResistancePriority(.fittingSizeCompression, for: .horizontal)
        previewView.setContentCompressionResistancePriority(.fittingSizeCompression, for: .vertical)
        previewNote.textColor = .secondaryLabelColor
        previewNote.font = .systemFont(ofSize: 11)
        previewNote.lineBreakMode = .byTruncatingTail
        previewNote.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let previewRow = NSStackView(views: [label("Preview:"), sampleField, stylePopup, previewNote])
        previewRow.spacing = 6

        // File buttons.
        let fileRow = NSStackView(views: [
            button("new", "New Font File...", "Start another TheDraw font file in a new window", #selector(newFile(_:))),
            button("open", "Open...", "Open a TheDraw font file (.tdf)", #selector(openFile(_:))),
            button("save", "Save", "Save every font of this window to its .tdf file", #selector(save(_:))),
            button("saveAs", "Save As...", "Save this file under a new name or place", #selector(saveAs(_:))),
            button("install", "Install in Font Manager", "Copy the saved file into AnsiView's font folder, so Font Manager and Text to ASCII list it",
                   #selector(install(_:))),
        ])
        fileRow.spacing = 6

        editorHost.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        let right = NSStackView(views: [fileRow, sizeRow, outlineRow, editorHost, styleStrip, previewRow, previewView])
        right.orientation = .vertical
        right.alignment = .leading
        right.spacing = 6
        for view in [left, right] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        previewView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            left.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            left.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            left.widthAnchor.constraint(equalToConstant: grid.intrinsicContentSize.width),
            left.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -12),
            right.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            right.leadingAnchor.constraint(equalTo: left.trailingAnchor, constant: 14),
            right.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            right.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            editorHost.widthAnchor.constraint(equalTo: right.widthAnchor),
            editorHost.heightAnchor.constraint(greaterThanOrEqualToConstant: 380),
            previewView.widthAnchor.constraint(equalTo: right.widthAnchor),
            previewView.heightAnchor.constraint(equalToConstant: 150),
        ])
        editorHost.setContentHuggingPriority(.defaultLow, for: .vertical)
        view = root
        reloadFonts()
        openGlyph(UInt8(ascii: "A"))
    }

    // MARK: Model to view

    func modelChanged() {
        guard isViewLoaded else { return }
        reloadFonts()
        refreshPreview()
    }

    private func reloadFonts() {
        fontTable.reloadData()
        if fontTable.selectedRow != model.selectedFont {
            fontTable.selectRowIndexes(IndexSet(integer: model.selectedFont), byExtendingSelection: false)
        }
        let font = model.font
        grid.font = font
        grid.outlineStyle = stylePopup.indexOfSelectedItem
        spacingStepper.integerValue = font.spacing
        spacingField.integerValue = font.spacing
        kindLabel.stringValue = "\(font.type.label) font, \(font.glyphs.count) of 94 characters"
        buttons["delete"]?.isEnabled = model.fonts.count > 1
        buttons["up"]?.isEnabled = model.selectedFont > 0
        buttons["down"]?.isEnabled = model.selectedFont < model.fonts.count - 1
        buttons["copy"]?.isEnabled = model.glyph(selectedCode) != nil
        buttons["clear"]?.isEnabled = model.glyph(selectedCode) != nil
        buttons["paste"]?.isEnabled = NSPasteboard.general.data(forType: Self.glyphType) != nil
        let outline = font.type == .outline
        outlineRow.isHidden = !outline
        styleStrip.isHidden = !outline
        stylePopup.isEnabled = outline
        for button in codeButtons {
            let code = UInt8(button.tag)
            let drawn = TDFOutlineCodes.drawn(code, style: stylePopup.indexOfSelectedItem)
            button.title = "\(Character(Unicode.Scalar(code))) \(Character(CP437.unicode[Int(drawn)]))"
            let role = TDFOutlineCodes.all.first { $0.code == code }?.role ?? ""
            button.toolTip = "\(Character(Unicode.Scalar(code))): \(role). Click to type it at the cursor; the Brush and fills use it too"
        }
        refreshGlyphControls()
    }

    private func refreshGlyphControls() {
        let code = selectedCode
        let glyph = model.glyph(code)
        let ch = Character(Unicode.Scalar(code))
        glyphLabel.stringValue = glyph == nil ? "\"\(ch)\" (new)" : "\"\(ch)\""
        let size = glyph.map { ($0.columns, $0.rows.count) } ?? TDFGlyphCanvas.newGlyphSize(for: model.font)
        widthStepper.integerValue = size.0
        widthField.integerValue = size.0
        heightStepper.integerValue = size.1
        heightField.integerValue = size.1
        let below = glyph.map { rows in rows.rows.reversed().prefix { $0.descender }.count } ?? 0
        descenderStepper.integerValue = below
        descenderField.integerValue = below
        descenderStepper.maxValue = Double(max(0, size.1 - 1))
        descenderStepper.isEnabled = glyph != nil
        refreshStyleStrip()
    }

    private func refreshStyleStrip() {
        guard model.font.type == .outline else { return }
        let single = TDFFont(name: "", type: .outline, spacing: 0, glyphs: model.glyph(selectedCode).map { [selectedCode: $0] } ?? [:])
        for (style, button) in styleButtons.enumerated() {
            var options = TextArtOptions()
            options.outlineStyle = style
            options.foreground = 15
            let region = TextArt.render(String(Character(Unicode.Scalar(selectedCode))), font: .tdf(single), options: options).region
            button.image = TextArtImages.image(region)
            button.alphaValue = style == stylePopup.indexOfSelectedItem ? 1 : 0.75
        }
    }

    /// The sample text rendered with the font (ruling 9).
    func refreshPreview() {
        var options = TextArtOptions()
        options.outlineStyle = max(0, stylePopup.indexOfSelectedItem)
        options.foreground = 15
        let result = TextArt.render(sampleField.stringValue, font: .tdf(model.font), options: options)
        previewView.image = TextArtImages.image(result.region)
        previewNote.stringValue = result.missing.isEmpty ? "" : "Not in this font yet: \(String(result.missing))"
        lastPreview = result
    }

    private(set) var lastPreview: TextArtResult?

    // MARK: Glyph editing (rulings 2, 3, 7)

    /// Shows `code` on the editor canvas (the ANSI editor with all its tools).
    func openGlyph(_ code: UInt8) {
        commitGlyph()
        grid.selected = code
        let canvas = model.beginEditing(code)
        let editor = CanvasEditor(canvas: canvas)
        if model.font.type == .color { editor.setIceColors(true) }
        if model.font.type == .outline { editor.brushCharacter = UInt8(ascii: "A") }
        let controller = EditorViewController(editor: editor, name: "Glyph")
        glyphEditor?.closePanels()
        glyphEditor?.view.removeFromSuperview()
        glyphEditor?.removeFromParent()
        addChild(controller)
        let editorView = controller.view
        editorView.translatesAutoresizingMaskIntoConstraints = false
        editorHost.addSubview(editorView)
        NSLayoutConstraint.activate([
            editorView.leadingAnchor.constraint(equalTo: editorHost.leadingAnchor),
            editorView.trailingAnchor.constraint(equalTo: editorHost.trailingAnchor),
            editorView.topAnchor.constraint(equalTo: editorHost.topAnchor),
            editorView.bottomAnchor.constraint(equalTo: editorHost.bottomAnchor),
        ])
        controller.canvasView.zoom = canvas.columns <= 16 && canvas.height <= 8 ? 4 : 3
        controller.canvasView.showGrid = true
        controller.editorChanged()
        controller.onChange = { [weak self, weak controller] in
            guard let self, let controller, controller === self.glyphEditor else { return }
            self.model.updateEditing(controller.editor.flattenedCanvas)
        }
        glyphEditor = controller
        reloadFonts()
        refreshPreview()
        view.window?.makeFirstResponder(controller.canvasView)
    }

    /// Hands the canvas's last change to the model (a floating block is placed first).
    func commitGlyph() {
        guard let editor = glyphEditor?.editor, model.editingCode != nil else { return }
        if editor.floating != nil { editor.stampFloating() }
        model.updateEditing(editor.flattenedCanvas)
    }

    /// Reloads the open glyph (after undo, a size change or a save).
    func reopenGlyph() {
        guard isViewLoaded else { return }
        model.endEditing()
        openGlyph(selectedCode)
    }

    private func gridCommand(_ command: TDFGlyphGridView.Command) {
        switch command {
        case .copy: copyGlyph(nil)
        case .paste: pasteGlyph(nil)
        case .clear: clearGlyph(nil)
        }
    }

    // MARK: Actions

    static let glyphType = NSPasteboard.PasteboardType(TDFGlyphClipboard.pasteboardType)

    @objc func copyGlyph(_ sender: Any?) {
        commitGlyph()
        guard let data = model.copyGlyph(selectedCode), let glyph = model.glyph(selectedCode) else { NSSound.beep(); return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(data, forType: Self.glyphType)
        let single = TDFFont(name: "", type: model.font.type, spacing: 0, glyphs: [selectedCode: glyph])
        var options = TextArtOptions()
        options.outlineStyle = stylePopup.indexOfSelectedItem
        pasteboard.setString(TextArtOutput.plainText(TextArt.render(String(Character(Unicode.Scalar(selectedCode))), font: .tdf(single),
                                                                     options: options).region), forType: .string)
        reloadFonts()
    }

    @objc func pasteGlyph(_ sender: Any?) {
        commitGlyph()
        guard let data = NSPasteboard.general.data(forType: Self.glyphType), model.pasteGlyph(selectedCode, data: data) else { NSSound.beep(); return }
        reopenGlyph()
    }

    @objc func clearGlyph(_ sender: Any?) {
        commitGlyph()
        guard model.glyph(selectedCode) != nil else { NSSound.beep(); return }
        model.clearGlyph(selectedCode)
        reopenGlyph()
    }

    @objc func copyFromFont(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let entry = FontStore.library.entry(id: id),
              case .tdf(let font) = entry.font else { return }
        guard let source = sourceCode(in: font) else {
            NSSound.beep()
            return
        }
        commitGlyph()
        model.copyGlyph(from: font, code: source, to: selectedCode)
        reopenGlyph()
    }

    /// The selected character in `font`, else its other case (as the renderer falls back).
    func sourceCode(in font: TDFFont) -> UInt8? {
        if font.glyphs[selectedCode] != nil { return selectedCode }
        let ch = Character(Unicode.Scalar(selectedCode))
        guard let other = (ch.isUppercase ? ch.lowercased() : ch.uppercased()).first?.asciiValue, font.glyphs[other] != nil else { return nil }
        return other
    }

    @objc func sizeChanged(_ sender: NSStepper) {
        commitGlyph()
        model.resizeGlyph(selectedCode, width: widthStepper.integerValue, height: heightStepper.integerValue)
        reopenGlyph()
    }

    @objc func descenderChanged(_ sender: NSStepper) {
        commitGlyph()
        model.setDescenderRows(selectedCode, descenderStepper.integerValue)
        reopenGlyph()
    }

    @objc func spacingChanged(_ sender: NSStepper) {
        commitGlyph()
        model.setSpacing(sender.integerValue)
        reopenGlyph()
    }

    @objc func codeClicked(_ sender: NSButton) {
        guard let editor = glyphEditor?.editor else { return }
        editor.brushCharacter = UInt8(sender.tag)
        editor.typeCode(UInt8(sender.tag))
        glyphEditor?.focusCanvas()
    }

    @objc func styleClicked(_ sender: NSButton) {
        stylePopup.selectItem(at: sender.tag)
        previewStyleChanged(stylePopup)
    }

    @objc func previewStyleChanged(_ sender: Any?) {
        grid.outlineStyle = stylePopup.indexOfSelectedItem
        reloadFonts()
        refreshPreview()
    }

    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSTextField) === sampleField else { return }
        refreshPreview()
    }

    @objc func addFont(_ sender: Any?) {
        guard case let .create(name, type, spacing)? = NewFontDialog.run(title: "Add a Font to This File", allowOpen: false) else { return }
        commitGlyph()
        do { try model.addFont(name: name, type: type, spacing: spacing) } catch {
            TDFFontEditorWindowController.tell("The font could not be added", error.localizedDescription)
        }
        reopenGlyph()
    }

    @objc func duplicateFont(_ sender: Any?) { commitGlyph(); model.duplicateFont(); reopenGlyph() }

    @objc func deleteFont(_ sender: Any?) {
        commitGlyph()
        if !model.deleteFont(model.selectedFont) { NSSound.beep() }
        reopenGlyph()
    }

    static var renameAnswer: ((String) -> String?)?

    @objc func renameFont(_ sender: Any?) {
        let current = model.font.name
        let newName: String?
        if let answer = Self.renameAnswer {
            newName = answer(current)
        } else {
            let alert = NSAlert()
            alert.messageText = "Rename Font"
            alert.informativeText = "A TheDraw font name has at most 12 DOS (CP437) characters."
            let field = NSTextField(string: current)
            field.frame = NSRect(x: 0, y: 0, width: 220, height: 24)
            field.toolTip = "The font's new name"
            alert.accessoryView = field
            alert.addButton(withTitle: "Rename")
            alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = field
            newName = alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
        }
        guard let newName, newName != current else { return }
        commitGlyph()
        do { try model.renameFont(model.selectedFont, to: newName) } catch {
            TDFFontEditorWindowController.tell("The font could not be renamed", error.localizedDescription)
        }
        reopenGlyph()
    }

    @objc func moveFontUp(_ sender: Any?) { commitGlyph(); model.moveFont(from: model.selectedFont, to: model.selectedFont - 1); reopenGlyph() }
    @objc func moveFontDown(_ sender: Any?) { commitGlyph(); model.moveFont(from: model.selectedFont, to: model.selectedFont + 1); reopenGlyph() }

    @objc func newFile(_ sender: Any?) { TDFFontEditorWindowController.showNewOrOpen() }
    @objc func openFile(_ sender: Any?) { TDFFontEditorWindowController.openPanel() }
    @objc func save(_ sender: Any?) { windowController?.save() }
    @objc func saveAs(_ sender: Any?) { windowController?.saveAs() }
    @objc func install(_ sender: Any?) { windowController?.install(sender) }

    // MARK: Font table

    func numberOfRows(in tableView: NSTableView) -> Int { model.fonts.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let font = model.fonts[row]
        switch tableColumn?.identifier.rawValue {
        case "name": return NSTextField(labelWithString: font.name)
        case "kind": return NSTextField(labelWithString: font.type.label.replacingOccurrences(of: "TDF ", with: ""))
        default: return NSTextField(labelWithString: "\(font.glyphs.count)")
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = fontTable.selectedRow
        guard row >= 0, row != model.selectedFont else { return }
        commitGlyph()
        model.selectFont(row)
        reopenGlyph()
    }
}

extension TDFFontEditorViewController: NSMenuDelegate {
    /// The Copy from Font menu lists installed TheDraw fonts that have the selected character.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === copyFromPopup.menu else { return }
        while menu.items.count > 1 { menu.removeItem(at: 1) }
        let ch = Character(Unicode.Scalar(selectedCode))
        let fonts = FontStore.library.entries.filter {
            if case .tdf(let font) = $0.font { return self.sourceCode(in: font) != nil }
            return false
        }
        if fonts.isEmpty {
            menu.addItem(withTitle: "No installed TheDraw font has \"\(ch)\"", action: nil, keyEquivalent: "")
        }
        for entry in fonts.prefix(300) {
            let item = NSMenuItem(title: "\(entry.name) (\(entry.kindLabel), \(entry.fileName))", action: #selector(copyFromFont(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = entry.id
            menu.addItem(item)
        }
    }
}

/// The 94 printable characters as tiles: each shows its glyph, dim when missing.
final class TDFGlyphGridView: NSView {
    enum Command { case copy, paste, clear }
    static let columns = 10
    static let tile = NSSize(width: 42, height: 40)
    var font = TDFFont(name: "", type: .color, spacing: 0, glyphs: [:]) { didSet { if font != oldValue { needsDisplay = true; rebuildTips() } } }
    var outlineStyle = 0 { didSet { if outlineStyle != oldValue { thumbnails.removeAll(); needsDisplay = true } } }
    var selected: UInt8 = 65 { didSet { if selected != oldValue { needsDisplay = true } } }
    var onSelect: ((UInt8) -> Void)?
    var onCommand: ((Command) -> Void)?
    private var thumbnails: [UInt8: (glyph: TDFGlyph, image: NSImage?)] = [:]

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize {
        NSSize(width: CGFloat(Self.columns) * Self.tile.width, height: CGFloat((94 + Self.columns - 1) / Self.columns) * Self.tile.height)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        toolTip = nil
        setAccessibilityRole(.grid)
        setAccessibilityLabel("Characters of the font")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    static func code(at index: Int) -> UInt8 { UInt8(33 + index) }

    func rect(for code: UInt8) -> NSRect {
        let index = Int(code) - 33
        return NSRect(x: CGFloat(index % Self.columns) * Self.tile.width, y: CGFloat(index / Self.columns) * Self.tile.height,
                      width: Self.tile.width, height: Self.tile.height)
    }

    private func thumbnail(_ code: UInt8) -> NSImage? {
        guard let glyph = font.glyphs[code] else { return nil }
        if let cached = thumbnails[code], cached.glyph == glyph { return cached.image }
        var options = TextArtOptions()
        options.outlineStyle = outlineStyle
        options.foreground = 15
        let single = TDFFont(name: "", type: font.type, spacing: 0, glyphs: [code: glyph])
        let image = TextArtImages.image(TextArt.render(String(Character(Unicode.Scalar(code))), font: .tdf(single), options: options).region)
        thumbnails[code] = (glyph, image)
        return image
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()
        NSGraphicsContext.current?.imageInterpolation = .none
        for index in 0..<94 {
            let code = Self.code(at: index)
            let rect = self.rect(for: code).insetBy(dx: 1, dy: 1)
            guard rect.intersects(dirtyRect) else { continue }
            let exists = font.glyphs[code] != nil
            (exists ? NSColor.black : NSColor(white: 0.5, alpha: 0.18)).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
            if let image = thumbnail(code) {
                let area = rect.insetBy(dx: 3, dy: 3).offsetBy(dx: 0, dy: 5)
                let scale = min(area.width / image.size.width, (area.height - 5) / image.size.height, 2)
                let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
                image.draw(in: NSRect(x: area.midX - size.width / 2, y: area.minY + (area.height - 5 - size.height) / 2,
                                      width: size.width, height: size.height),
                           from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .bold),
                .foregroundColor: exists ? NSColor.systemYellow : NSColor.secondaryLabelColor,
            ]
            NSAttributedString(string: String(Character(Unicode.Scalar(code))), attributes: attributes)
                .draw(at: NSPoint(x: rect.minX + 3, y: rect.minY + 1))
            if code == selected {
                NSColor.controlAccentColor.setStroke()
                let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
                path.lineWidth = 2.5
                path.stroke()
            }
        }
    }

    private func rebuildTips() {
        removeAllToolTips()
        for index in 0..<94 { addToolTip(rect(for: Self.code(at: index)), owner: self, userData: nil) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        rebuildTips()
    }

    /// The tooltip of one tile.
    func tip(for code: UInt8) -> String {
        let ch = Character(Unicode.Scalar(code))
        guard let glyph = font.glyphs[code] else {
            return "\"\(ch)\" is not in this font yet: click to draw it"
        }
        return "\"\(ch)\": \(glyph.columns) x \(glyph.rows.count). Click to edit; Command-C copies, Command-V pastes, Delete clears"
    }

    func code(at point: NSPoint) -> UInt8? {
        let column = Int(point.x / Self.tile.width), row = Int(point.y / Self.tile.height)
        let index = row * Self.columns + column
        guard column >= 0, column < Self.columns, row >= 0, (0..<94).contains(index) else { return nil }
        return Self.code(at: index)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let code = code(at: convert(event.locationInWindow, from: nil)) else { return }
        if code != selected { onSelect?(code) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        if let code = code(at: convert(event.locationInWindow, from: nil)), code != selected { onSelect?(code) }
        let menu = NSMenu()
        for (title, action) in [("Copy Glyph", #selector(copy(_:))), ("Paste Glyph", #selector(paste(_:))), ("Clear Glyph", #selector(delete(_:)))] {
            menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
        }
        return menu
    }

    override func keyDown(with event: NSEvent) {
        let index = Int(selected) - 33
        var next = index
        switch event.keyCode {
        case 123: next = index - 1
        case 124: next = index + 1
        case 125: next = index + Self.columns
        case 126: next = index - Self.columns
        case 51, 117: onCommand?(.clear); return
        default: super.keyDown(with: event); return
        }
        if (0..<94).contains(next) { onSelect?(Self.code(at: next)) }
    }

    @objc func copy(_ sender: Any?) { onCommand?(.copy) }
    @objc func paste(_ sender: Any?) { onCommand?(.paste) }
    @objc func delete(_ sender: Any?) { onCommand?(.clear) }
}

extension TDFGlyphGridView: NSViewToolTipOwner {
    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        code(at: point).map(tip(for:)) ?? ""
    }
}
