import AnsiCore
import AppKit

/// Screen > Insert Display Code...: a searchable list of the chosen package's codes, grouped,
/// with what each shows. Double-click or Insert types the code at the editor's cursor.
final class DisplayCodePickerWindowController: NSWindowController, NSWindowDelegate {
    private(set) static var current: DisplayCodePickerWindowController?
    let viewController = DisplayCodePickerViewController()

    static func show() {
        let controller = current ?? DisplayCodePickerWindowController()
        current = controller
        controller.showWindow(nil)
        controller.window?.orderFront(nil)
    }

    init() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 600),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        panel.title = "Display Codes"
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentMinSize = NSSize(width: 420, height: 360)
        super.init(window: panel)
        panel.contentViewController = viewController
        panel.setContentSize(NSSize(width: 520, height: 600))
        panel.setFrameAutosaveName("DisplayCodePicker")
        panel.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func windowWillClose(_ notification: Notification) { Self.current = nil }
}

final class DisplayCodePickerViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    enum Row { case group(DisplayCodeGroup), code(DisplayCode) }

    lazy var packagePopup = ScreenDesigner.packagePopup(selected: ScreenDesignerSettings.shared.package,
                                                        tooltip: "Whose codes to show: the package your BBS runs")
    let searchField = NSSearchField()
    let table = NSTableView()
    let sourceLabel = ScreenDesigner.label("", size: 10, secondary: true)
    private(set) var rows: [Row] = []

    override func loadView() {
        packagePopup.target = self
        packagePopup.action = #selector(packageChanged)
        searchField.placeholderString = "Search codes: name, time, clear..."
        searchField.delegate = self
        searchField.toolTip = "Finds codes by their text, name or what they show"
        let help = TextArtImages.helpButton(
            "Display codes are text the BBS replaces as it sends the screen: the caller's name, the time left, the node, a clear screen, a colour. They go into the art as the exact characters the BBS reads, so they show as typed in the editor. Screen > Sample Values Preview and Preview as Caller show them replaced by sample values. Codes of another package are flagged in the caller preview, because the chosen BBS would print them as text.",
            term: .displayCodes)
        for (id, title, width) in [("code", "Code", 110.0), ("shows", "Shows", 330.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(insert(_:))
        table.usesAlternatingRowBackgroundColors = true
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let insert = NSButton(title: "Insert", target: self, action: #selector(insert(_:)))
        insert.keyEquivalent = "\r"
        insert.toolTip = "Types the code at the cursor of the frontmost editor"
        let samples = NSButton(title: "Sample Values...", target: self, action: #selector(showSamples))
        samples.toolTip = "The values the previews show for each code"
        let top = ScreenDesigner.row([packagePopup, searchField, help])
        let bottom = ScreenDesigner.row([sourceLabel, NSView(), samples, insert])
        sourceLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = ScreenDesigner.column([top, scroll, bottom], spacing: 10)
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        for view in [top, scroll, bottom] { view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true }
        view = ScreenDesigner.container(stack)
        reload()
    }

    var package: BBSPackage { ScreenDesigner.package(of: packagePopup) }

    func reload() {
        rows = DisplayCodeCatalog.search(searchField.stringValue, package: package).flatMap { group in
            [Row.group(group.group)] + group.codes.map(Row.code)
        }
        sourceLabel.stringValue = "Source: " + package.source
        sourceLabel.toolTip = package.source
        table.reloadData()
    }

    @objc func packageChanged() {
        ScreenDesignerSettings.shared.package = package
        reload()
    }

    func controlTextDidChange(_ obj: Notification) { reload() }

    @objc func showSamples() { SampleValuesWindowController.show() }

    @objc func insert(_ sender: Any?) {
        guard table.selectedRow >= 0, case .code(let code) = rows[table.selectedRow] else { NSSound.beep(); return }
        guard let editor = ScreenDesigner.requireEditor("insert a code into") else { return }
        ScreenDesigner.insert(code.token, into: editor.editor)
        editor.window?.makeKeyAndOrderFront(nil)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .group = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { !self.tableView(tableView, isGroupRow: row) }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTextField(labelWithString: "")
        cell.lineBreakMode = .byTruncatingTail
        switch rows[row] {
        case .group(let group):
            cell.stringValue = group.label
            cell.font = NSFont.boldSystemFont(ofSize: 12)
        case .code(let code):
            if tableColumn?.identifier.rawValue == "code" {
                cell.stringValue = DisplayCodeCatalog.printable(code.token)
                cell.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
            } else {
                let sample = code.field.map { " (sample: \(ScreenDesignerSettings.shared.samples[$0]))" } ?? ""
                cell.stringValue = code.title + sample
            }
            cell.toolTip = code.help
        }
        return cell
    }
}

/// Screen > Sample Values...: what the previews show for each value code.
final class SampleValuesWindowController: NSWindowController {
    private static var current: SampleValuesWindowController?
    private var fields: [ScreenField: NSTextField] = [:]

    static func show() {
        let controller = current ?? SampleValuesWindowController()
        current = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 560), styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "Sample Values"
        super.init(window: window)
        let samples = ScreenDesignerSettings.shared.samples
        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.rowSpacing = 6
        for field in ScreenField.allCases {
            let text = NSTextField(string: samples[field])
            text.widthAnchor.constraint(equalToConstant: 240).isActive = true
            text.toolTip = "Shown wherever a code for the \(field.label.lowercased()) appears"
            fields[field] = text
            grid.addRow(with: [ScreenDesigner.label(field.label + ":"), text])
        }
        let note = ScreenDesigner.label("The previews put these in place of the codes. Values longer than their code push the rest of the line right, as on the BBS.", size: 11, secondary: true)
        note.preferredMaxLayoutWidth = 400
        let reset = NSButton(title: "Defaults", target: self, action: #selector(resetDefaults))
        let save = NSButton(title: "Save", target: self, action: #selector(save))
        save.keyEquivalent = "\r"
        reset.toolTip = String(localized: "Puts back AnsiView's own sample values")
        save.toolTip = String(localized: "Keeps these values for every preview")
        let stack = ScreenDesigner.column([grid, note, ScreenDesigner.row([NSView(), reset, save])], spacing: 12)
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        window.contentView = ScreenDesigner.container(stack)
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc func resetDefaults() {
        for (field, text) in fields { text.stringValue = field.defaultSample }
    }

    @objc func save() {
        var samples = SampleValues()
        for (field, text) in fields where text.stringValue != field.defaultSample { samples[field] = text.stringValue }
        ScreenDesignerSettings.shared.samples = samples
        window?.close()
    }
}

/// Screen > Sample Values Preview: the frontmost editor's screen as the chosen BBS sends it, with
/// the sample values in place of the codes; follows edits live.
final class SampleValuesPreviewWindowController: NSWindowController, NSWindowDelegate {
    private static var current: SampleValuesPreviewWindowController?
    let imageView = NSImageView()
    let info = ScreenDesigner.label("", size: 11, secondary: true)
    lazy var packagePopup = ScreenDesigner.packagePopup(selected: ScreenDesignerSettings.shared.package,
                                                        tooltip: "Read the codes as this BBS package does")
    private var timer: Timer?
    private var shown: (EditCanvas, BBSPackage, SampleValues)?

    static func show() {
        let controller = current ?? SampleValuesPreviewWindowController()
        current = controller
        controller.showWindow(nil)
        controller.window?.orderFront(nil)
        controller.update()
    }

    init() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 700, height: 520),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        panel.title = "Sample Values Preview"
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        super.init(window: panel)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.backgroundColor = NSColor.black.cgColor
        imageView.setContentCompressionResistancePriority(.fittingSizeCompression, for: .horizontal)
        imageView.setContentCompressionResistancePriority(.fittingSizeCompression, for: .vertical)
        packagePopup.target = self
        packagePopup.action = #selector(packageChanged)
        let stack = ScreenDesigner.column([ScreenDesigner.row([packagePopup, info]), imageView], spacing: 8)
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        imageView.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20).isActive = true
        panel.contentView = ScreenDesigner.container(stack)
        panel.setFrameAutosaveName("SampleValuesPreview")
        panel.delegate = self
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.update() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        Self.current = nil
    }

    @objc func packageChanged() {
        ScreenDesignerSettings.shared.package = ScreenDesigner.package(of: packagePopup)
        shown = nil
        update()
    }

    func update() {
        guard let editor = ScreenDesigner.focusedEditor?.editor else { info.stringValue = "No editor open"; return }
        let canvas = editor.flattenedCanvas
        let package = ScreenDesigner.package(of: packagePopup)
        let samples = ScreenDesignerSettings.shared.samples
        if let shown, shown.0 == canvas, shown.1 == package, shown.2 == samples { return }
        shown = (canvas, package, samples)
        imageView.image = Self.substituted(canvas, package: package, samples: samples).flatMap { ScreenDesigner.image($0) }
        let foreign = BBSDisplay.foreignCodes(in: ArtWriter.ansiBody(canvas), package: package)
        info.stringValue = foreign.isEmpty ? "Codes read as \(package.displayName)" : "Not \(package.displayName) codes: " + foreign.joined(separator: " ")
    }

    /// The canvas as the BBS would show it with sample values (rows as tall as the art).
    static func substituted(_ canvas: EditCanvas, package: BBSPackage, samples: SampleValues) -> EditCanvas? {
        let sent = BBSDisplay.render(ArtWriter.ansiBody(canvas), package: package, samples: samples)
        let screen = BBSDisplay.screen(sent, columns: canvas.columns, iceColors: canvas.iceColors)
        var result = EditCanvas(screen: screen, iceColors: canvas.iceColors)
        result.resize(columns: canvas.columns, height: max(canvas.height, result.height))
        return result
    }
}
