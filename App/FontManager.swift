import AnsiCore
import AppKit

// The Font Manager window (fonts plan ruling 16): the installed fonts as a list with a preview of
// the sample text, favourites, search, import, remove and reveal.

final class FontManagerWindowController: NSWindowController, NSWindowDelegate {
    private(set) static var current: FontManagerWindowController?
    let viewController = FontManagerViewController()

    static func show() {
        let controller = current ?? FontManagerWindowController()
        current = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 620),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Font Manager"
        window.contentMinSize = NSSize(width: 760, height: 460)
        window.contentViewController = viewController
        window.setContentSize(NSSize(width: 980, height: 620))
        window.setFrameAutosaveName("FontManager")
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func windowWillClose(_ notification: Notification) { Self.current = nil }
}

final class FontManagerViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    let library = FontStore.library
    let table = NSTableView()
    let searchField = NSSearchField()
    let favouritesBox = NSButton(checkboxWithTitle: "Favourites only", target: nil, action: nil)
    let sampleField = NSTextField(string: "")
    let outlinePopup = NSPopUpButton()
    let previewView = NSImageView()
    let infoLabel = NSTextField(wrappingLabelWithString: "")
    let emptyNote = NSTextField(wrappingLabelWithString: FontHelp.emptyState)
    let removeButton = NSButton(title: "Remove...", target: nil, action: nil)
    let revealButton = NSButton(title: "Reveal in Finder", target: nil, action: nil)
    let editButton = NSButton(title: "Edit Font...", target: nil, action: nil)
    private(set) var rows: [FontEntry] = []
    private var observer: NSObjectProtocol?

    private var sampleObserver: NSObjectProtocol?

    deinit {
        for token in [observer, sampleObserver].compactMap({ $0 }) { NotificationCenter.default.removeObserver(token) }
    }

    override func loadView() {
        searchField.placeholderString = "Search name, file or kind"
        searchField.delegate = self
        searchField.toolTip = "Find fonts by name, file, kind (FIGlet, TDF outline, block, colour) or source"
        favouritesBox.target = self
        favouritesBox.action = #selector(reload(_:))
        favouritesBox.toolTip = "Show only starred fonts"
        let importButton = NSButton(title: "Import...", target: self, action: #selector(importFonts(_:)))
        importButton.toolTip = String(localized: "Import TheDraw (.tdf) and FIGlet (.flf, .tlf) fonts, folders of them or .zip packs. AnsiView copies them; the originals stay as they are.")
        removeButton.target = self
        removeButton.action = #selector(remove(_:))
        removeButton.toolTip = "Remove the selected font's file from AnsiView's font folder (fonts that come with AnsiView stay)"
        revealButton.target = self
        revealButton.action = #selector(reveal(_:))
        revealButton.toolTip = "Show the font file in the Finder"
        let typesHelp = Hint.button(.theDrawFonts, detail: FontHelp.tdfTypes)
        let top = NSStackView(views: [searchField, favouritesBox, NSView(), importButton, removeButton, revealButton, typesHelp])
        top.spacing = 8
        searchField.widthAnchor.constraint(equalToConstant: 220).isActive = true

        for (id, title, width) in [("star", "", 26.0), ("name", "Name", 170.0), ("kind", "Kind", 110.0), ("file", "File", 170.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
        table.target = self
        table.doubleAction = #selector(openTextToASCII(_:))
        table.toolTip = "Installed fonts; a TheDraw file with several fonts lists each one. Double-click to use it in Text to ASCII"
        let tableScroll = NSScrollView()
        tableScroll.documentView = table
        tableScroll.hasVerticalScroller = true
        tableScroll.borderType = .bezelBorder

        sampleField.stringValue = library.sampleText
        sampleField.placeholderString = "Sample text"
        sampleField.target = self
        sampleField.action = #selector(sampleChanged(_:))
        sampleField.toolTip = "The text every preview shows (kept between launches)"
        for style in 0..<19 { outlinePopup.addItem(withTitle: "Style \(style + 1)   \(TextArt.outlineSample(style))") }
        outlinePopup.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        outlinePopup.target = self
        outlinePopup.action = #selector(selectionChanged(_:))
        outlinePopup.toolTip = "Outline style for TheDraw outline fonts"
        let outlineHelp = TextArtImages.helpButton(FontHelp.outlineStyles, tooltip: "About outline styles")
        previewView.imageScaling = .scaleProportionallyDown
        previewView.setContentCompressionResistancePriority(.fittingSizeCompression, for: .horizontal)
        previewView.setContentCompressionResistancePriority(.fittingSizeCompression, for: .vertical)
        previewView.imageAlignment = .alignTopLeft
        previewView.wantsLayer = true
        previewView.layer?.backgroundColor = NSColor.black.cgColor
        previewView.toolTip = "The sample text drawn with AnsiView's renderer"
        infoLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        infoLabel.textColor = .secondaryLabelColor
        infoLabel.font = NSFont.systemFont(ofSize: 11)
        emptyNote.textColor = .secondaryLabelColor
        let openButton = NSButton(title: "Open in Text to ASCII", target: self, action: #selector(openTextToASCII(_:)))
        openButton.toolTip = "Type text and copy or insert it with this font"
        editButton.target = self
        editButton.action = #selector(editFont(_:))
        editButton.toolTip = "Open this TheDraw font in the TDF Font Editor (fonts that come with AnsiView open as a copy)"

        outlinePopup.controlSize = .small
        outlinePopup.font = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        sampleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        sampleField.widthAnchor.constraint(greaterThanOrEqualToConstant: 100).isActive = true
        let sampleRow = NSStackView(views: [NSTextField(labelWithString: "Sample:"), sampleField])
        sampleRow.spacing = 6
        let styleRow = NSStackView(views: [NSTextField(labelWithString: "Outline style:"), outlinePopup, outlineHelp])
        styleRow.spacing = 6
        let right = NSStackView(views: [sampleRow, styleRow, previewView, infoLabel, NSStackView(views: [openButton, editButton]), emptyNote])
        right.orientation = .vertical
        right.alignment = .leading
        right.spacing = 8
        previewView.translatesAutoresizingMaskIntoConstraints = false
        previewView.heightAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        previewView.widthAnchor.constraint(equalTo: right.widthAnchor).isActive = true
        sampleRow.widthAnchor.constraint(equalTo: right.widthAnchor).isActive = true
        infoLabel.widthAnchor.constraint(equalTo: right.widthAnchor).isActive = true
        emptyNote.widthAnchor.constraint(equalTo: right.widthAnchor).isActive = true

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(tableScroll)
        split.addArrangedSubview(right)
        tableScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 380).isActive = true
        right.widthAnchor.constraint(greaterThanOrEqualToConstant: 320).isActive = true

        let root = NSView()
        for view in [top, split] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            top.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            top.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            split.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 10),
            split.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            split.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            split.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
        ])
        view = root
        observer = NotificationCenter.default.addObserver(forName: .fontLibraryChanged, object: nil, queue: .main) { [weak self] _ in
            self?.reload(nil)
        }
        // The Text to ASCII window changed the shared sample text (review M14).
        sampleObserver = NotificationCenter.default.addObserver(forName: .fontSampleChanged, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.sampleField.stringValue != self.library.sampleText else { return }
            self.sampleField.stringValue = self.library.sampleText
            self.selectionChanged(nil)
        }
        reload(nil)
    }

    @objc func reload(_ sender: Any?) {
        let selected = selectedEntry?.id
        rows = library.search(searchField.stringValue, favouritesOnly: favouritesBox.state == .on)
        table.reloadData()
        let index = rows.firstIndex { $0.id == selected } ?? (rows.isEmpty ? -1 : 0)
        if index >= 0 { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
        emptyNote.isHidden = !library.userEntries.isEmpty
        selectionChanged(nil)
    }

    func controlTextDidChange(_ obj: Notification) {
        if (obj.object as? NSSearchField) === searchField { reload(nil) }
    }

    var selectedEntry: FontEntry? { table.selectedRow >= 0 && table.selectedRow < rows.count ? rows[table.selectedRow] : nil }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = rows[row]
        switch tableColumn?.identifier.rawValue {
        case "star":
            let button = NSButton(title: library.favourites.contains(entry.id) ? "★" : "☆", target: self, action: #selector(toggleStar(_:)))
            button.isBordered = false
            button.tag = row
            button.toolTip = "Favourite"
            return button
        case "name": return NSTextField(labelWithString: entry.name)
        case "kind": return NSTextField(labelWithString: entry.kindLabel)
        default:
            let label = NSTextField(labelWithString: entry.fileName)
            label.lineBreakMode = .byTruncatingMiddle
            return label
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) { selectionChanged(nil) }

    @objc func selectionChanged(_ sender: Any?) {
        guard let entry = selectedEntry else {
            previewView.image = nil
            infoLabel.stringValue = ""
            removeButton.isEnabled = false
            revealButton.isEnabled = false
            editButton.isEnabled = false
            return
        }
        var options = TextArtOptions()
        options.outlineStyle = max(0, outlinePopup.indexOfSelectedItem)
        options.foreground = 15
        let result = TextArt.render(sampleField.stringValue, font: entry.font, options: options)
        previewView.image = TextArtImages.image(result.region)
        outlinePopup.isEnabled = entry.category == .tdfOutline
        var info = "\(entry.name): \(entry.kindLabel), from \(entry.fileName) (\(entry.source.label))"
        switch entry.font {
        case .tdf(let font): info += ", \(font.glyphs.count) characters, spacing \(font.spacing)"
        case .figlet(let font): info += ", \(font.glyphs.count) characters, \(font.height) rows tall"
        }
        if !result.missing.isEmpty { info += ". Not in this font: \(String(result.missing))" }
        infoLabel.stringValue = info
        removeButton.isEnabled = entry.source == .user
        revealButton.isEnabled = entry.url != nil
        if case .tdf = entry.font { editButton.isEnabled = true } else { editButton.isEnabled = false }
    }

    @objc func sampleChanged(_ sender: Any?) {
        library.sampleText = sampleField.stringValue
        NotificationCenter.default.post(name: .fontSampleChanged, object: nil)
        selectionChanged(nil)
    }

    @objc func toggleStar(_ sender: NSButton) {
        guard sender.tag < rows.count else { return }
        let id = rows[sender.tag].id
        library.setFavourite(id, !library.favourites.contains(id))
        FontStore.changed()
    }

    @objc func importFonts(_ sender: Any?) { FontStore.chooseAndImport(from: view.window) }

    @objc func remove(_ sender: Any?) {
        guard let entry = selectedEntry else { return }
        FontStore.confirmRemove(entry, window: view.window)
    }

    @objc func reveal(_ sender: Any?) {
        guard let url = selectedEntry?.url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc func editFont(_ sender: Any?) {
        guard let entry = selectedEntry else { return }
        TDFFontEditorWindowController.edit(entry)
    }

    @objc func openTextToASCII(_ sender: Any?) {
        TextToASCIIWindowController.show(editor: nil)
        if let id = selectedEntry?.id { TextToASCIIWindowController.current?.viewController.select(id) }
    }
}
