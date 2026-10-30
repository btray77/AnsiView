import AnsiCore
import AppKit

/// Screen > Component Library...: built-in headers, frames, legends, status lines, separators and
/// logos plus the user's own components. Insert floats the component in the frontmost editor
/// (the editor's floating paste: move it, then click or press Return to place it).
final class ComponentLibraryWindowController: NSWindowController, NSWindowDelegate {
    private(set) static var current: ComponentLibraryWindowController?
    let viewController = ComponentLibraryViewController()

    static func show() {
        let controller = current ?? ComponentLibraryWindowController()
        current = controller
        controller.showWindow(nil)
        controller.window?.orderFront(nil)
    }

    /// Screen > Save Selection as Component...
    static func saveSelection() {
        guard let editor = ScreenDesigner.requireEditor("save a component from") else { return }
        guard let rect = editor.editor.selection else {
            let alert = NSAlert()
            alert.messageText = "Select the cells to save first"
            alert.informativeText = "Drag with the Select tool over the header, frame or legend to keep, then choose Save Selection as Component again."
            alert.runModal()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Save as component"
        alert.informativeText = "\(rect.width) x \(rect.height) cells. It appears under My components in the Component Library."
        let name = NSTextField(string: "My component")
        name.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = name
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try ScreenDesignerSettings.shared.components.save(name: name.stringValue, region: editor.editor.flattenedCanvas.region(rect))
            current?.viewController.reload()
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    init() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 820, height: 560),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        panel.title = "Component Library"
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentMinSize = NSSize(width: 640, height: 400)
        super.init(window: panel)
        panel.contentViewController = viewController
        panel.setContentSize(NSSize(width: 820, height: 560))
        panel.setFrameAutosaveName("ComponentLibrary")
        panel.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func windowWillClose(_ notification: Notification) { Self.current = nil }
}

final class ComponentLibraryViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    enum Row { case group(String), builtIn(ScreenComponent), saved(SavedComponent) }

    let table = NSTableView()
    let preview = NSImageView()
    let widthField = NSTextField(string: "78")
    let heightField = NSTextField(string: "8")
    let textField = NSTextField(string: "Title")
    let colourPopup = TextArtImages.colourPopup(selected: 9, tooltip: "The component's main colour")
    let fontPopup = NSPopUpButton()
    let helpLabel = ScreenDesigner.label("", size: 11, secondary: true)
    let deleteButton = NSButton(title: "Delete...", target: nil, action: nil)
    private(set) var rows: [Row] = []
    private var fonts: [TextArtFont] = []

    override func loadView() {
        for (id, title) in [("name", "Component")] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = 250
            table.addTableColumn(column)
        }
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(insert(_:))
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.widthAnchor.constraint(equalToConstant: 270).isActive = true

        fonts = OriginalFonts.tdfFonts.map { .tdf($0) } + [OriginalFonts.figletFont.map { .figlet($0) }].compactMap { $0 }
            + FontStore.library.entries.prefix(200).map(\.font)
        for font in fonts { fontPopup.addItem(withTitle: font.name) }
        fontPopup.toolTip = "Logo font: AnsiView's own fonts first, then the fonts installed in the Font Manager"
        for field in [widthField, heightField] { field.widthAnchor.constraint(equalToConstant: 50).isActive = true }
        widthField.toolTip = "Width in columns (78 leaves the last two columns of an 80 column screen free)"
        heightField.toolTip = "Height in rows (frames)"
        textField.toolTip = "The header's title or the logo's text"
        textField.widthAnchor.constraint(equalToConstant: 180).isActive = true
        for control in [widthField, heightField, textField] as [NSControl] { control.target = self; control.action = #selector(optionsChanged) }
        for popup in [colourPopup, fontPopup] { popup.target = self; popup.action = #selector(optionsChanged) }
        preview.imageScaling = .scaleProportionallyDown
        preview.imageAlignment = .alignTopLeft
        preview.wantsLayer = true
        preview.layer?.backgroundColor = NSColor.black.cgColor
        preview.setContentCompressionResistancePriority(.fittingSizeCompression, for: .horizontal)
        preview.setContentCompressionResistancePriority(.fittingSizeCompression, for: .vertical)
        let insert = NSButton(title: "Insert", target: self, action: #selector(insert(_:)))
        insert.keyEquivalent = "\r"
        insert.toolTip = "Floats the component at the editor's cursor; move it and click to place it"
        deleteButton.target = self
        deleteButton.action = #selector(deleteSaved(_:))
        deleteButton.toolTip = "Deletes the selected component of yours"
        let help = TextArtImages.helpButton(
            "Components are pieces you reuse across screens. Built-in ones are drawn to the width, height, colour and text you set; status lines use the display codes of the package chosen in the code picker. Save Selection as Component (Screen menu) keeps any part of your own art here. Insert floats it in the editor like a paste.",
            tooltip: "About components")
        let options = ScreenDesigner.column([
            ScreenDesigner.row([ScreenDesigner.label("Width:"), widthField, ScreenDesigner.label("Height:"), heightField, colourPopup]),
            ScreenDesigner.row([ScreenDesigner.label("Text:"), textField, ScreenDesigner.label("Font:"), fontPopup]),
        ])
        helpLabel.preferredMaxLayoutWidth = 480
        let right = ScreenDesigner.column([options, preview, helpLabel, ScreenDesigner.row([deleteButton, NSView(), help, insert])], spacing: 10)
        preview.widthAnchor.constraint(equalTo: right.widthAnchor).isActive = true
        preview.heightAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        let split = ScreenDesigner.row([scroll, right], spacing: 14)
        split.alignment = .top
        split.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        scroll.heightAnchor.constraint(equalTo: split.heightAnchor, constant: -24).isActive = true
        view = ScreenDesigner.container(split)
        reload()
    }

    func reload() {
        rows = []
        for group in ComponentGroup.allCases {
            rows.append(.group(group.label))
            rows += ScreenComponents.all.filter { $0.group == group }.map(Row.builtIn)
        }
        let saved = ScreenDesignerSettings.shared.components.all()
        if !saved.isEmpty { rows.append(.group("My components")); rows += saved.map(Row.saved) }
        table.reloadData()
        if let first = rows.firstIndex(where: { if case .group = $0 { return false }; return true }) {
            table.selectRowIndexes(IndexSet(integer: first), byExtendingSelection: false)
        }
        optionsChanged()
    }

    var options: ComponentOptions {
        var o = ComponentOptions(width: Int(widthField.stringValue) ?? 78, height: Int(heightField.stringValue) ?? 8,
                                 colour: colourPopup.indexOfSelectedItem, text: textField.stringValue,
                                 package: ScreenDesignerSettings.shared.package, samples: ScreenDesignerSettings.shared.samples)
        if fonts.indices.contains(fontPopup.indexOfSelectedItem) { o.font = fonts[fontPopup.indexOfSelectedItem] }
        return o
    }

    /// The selected component drawn with the current options.
    var selectedRegion: CanvasRegion? {
        guard table.selectedRow >= 0, rows.indices.contains(table.selectedRow) else { return nil }
        switch rows[table.selectedRow] {
        case .group: return nil
        case .builtIn(let component): return component.make(options)
        case .saved(let saved): return saved.region
        }
    }

    @objc func optionsChanged() {
        preview.image = selectedRegion.flatMap { TextArtImages.image($0, scale: 1) }
        if table.selectedRow >= 0, rows.indices.contains(table.selectedRow) {
            switch rows[table.selectedRow] {
            case .builtIn(let c): helpLabel.stringValue = c.help; deleteButton.isEnabled = false
            case .saved(let s): helpLabel.stringValue = "Saved \(DateFormatter.localizedString(from: s.created, dateStyle: .medium, timeStyle: .short))."; deleteButton.isEnabled = true
            case .group: break
            }
        }
    }

    @objc func insert(_ sender: Any?) {
        guard let region = selectedRegion else { NSSound.beep(); return }
        guard let editor = ScreenDesigner.requireEditor("insert a component into") else { return }
        editor.editor.beginFloating(region)
        editor.window?.makeKeyAndOrderFront(nil)
    }

    @objc func deleteSaved(_ sender: Any?) {
        guard table.selectedRow >= 0, case .saved(let saved) = rows[table.selectedRow] else { return }
        let alert = NSAlert()
        alert.messageText = "Delete \"\(saved.name)\"?"
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        try? ScreenDesignerSettings.shared.components.delete(saved.id)
        reload()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .group = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { !self.tableView(tableView, isGroupRow: row) }

    func tableViewSelectionDidChange(_ notification: Notification) { optionsChanged() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTextField(labelWithString: "")
        switch rows[row] {
        case .group(let title): cell.stringValue = title; cell.font = NSFont.boldSystemFont(ofSize: 12)
        case .builtIn(let c): cell.stringValue = c.title; cell.toolTip = c.help
        case .saved(let s): cell.stringValue = s.name
        }
        return cell
    }
}
