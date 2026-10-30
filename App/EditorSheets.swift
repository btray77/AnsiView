import AnsiCore
import AppKit

/// Base for the editor's small sheets: a grid of labelled fields with Cancel and OK.
class EditorSheetController: NSViewController {
    private var hostWindow: NSWindow?

    /// Rows of (label, control) shown in a grid above the buttons.
    func rows() -> [(String, NSView)] { [] }
    /// Called for OK; return false to keep the sheet open.
    func accept() -> Bool { true }

    override func loadView() {
        let grid = NSGridView(views: rows().map { [NSTextField(labelWithString: $0.0), $0.1] })
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelPressed(_:)))
        cancel.keyEquivalent = "\u{1B}"
        let ok = NSButton(title: "OK", target: self, action: #selector(okPressed(_:)))
        ok.keyEquivalent = "\r"
        let buttons = NSStackView(views: [cancel, ok])
        let stack = NSStackView(views: [grid, buttons])
        stack.orientation = .vertical
        stack.alignment = .trailing
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 16, right: 20)
        view = stack
    }

    func present(on window: NSWindow) {
        let sheet = NSWindow(contentViewController: self)
        hostWindow = window
        window.beginSheet(sheet)
    }

    private func close() {
        guard let sheet = view.window else { return }
        hostWindow?.endSheet(sheet)
        hostWindow = nil
    }

    @objc private func cancelPressed(_ sender: Any?) { close() }
    @objc private func okPressed(_ sender: Any?) { if accept() { close() } }

    static func field(_ value: String, width: CGFloat = 260) -> NSTextField {
        let field = NSTextField(string: value)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: width).isActive = true
        return field
    }
}

/// Art > Edit SAUCE...: title (35 characters), author and group (20 each).
final class SauceSheetController: EditorSheetController {
    var onDone: ((_ title: String, _ author: String, _ group: String) -> Void)?
    private let titleField: NSTextField
    private let authorField: NSTextField
    private let groupField: NSTextField

    init(title: String, author: String, group: String) {
        titleField = Self.field(title)
        authorField = Self.field(author)
        groupField = Self.field(group)
        super.init(nibName: nil, bundle: nil)
        titleField.placeholderString = "Up to 35 characters"
        authorField.placeholderString = "Up to 20 characters"
        groupField.placeholderString = "Up to 20 characters"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func rows() -> [(String, NSView)] {
        [("Title:", titleField), ("Author:", authorField), ("Group:", groupField)]
    }

    override func accept() -> Bool {
        onDone?(titleField.stringValue, authorField.stringValue, groupField.stringValue)
        return true
    }
}

/// Art > Canvas Size...: columns 1 to 1000, rows 1 to 1500.
final class CanvasSizeSheetController: EditorSheetController {
    var onDone: ((_ columns: Int, _ rows: Int) -> Void)?
    private let columnsField: NSTextField
    private let rowsField: NSTextField

    init(columns: Int, rows: Int) {
        columnsField = Self.field(String(columns), width: 80)
        rowsField = Self.field(String(rows), width: 80)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func rows() -> [(String, NSView)] {
        [("Columns (1 to \(EditCanvas.maxColumns)):", columnsField), ("Rows (1 to \(AnsiTerminal.maxRows)):", rowsField)]
    }

    override func accept() -> Bool {
        guard let columns = Int(columnsField.stringValue), (1...EditCanvas.maxColumns).contains(columns),
              let rows = Int(rowsField.stringValue), (1...AnsiTerminal.maxRows).contains(rows) else {
            NSSound.beep()
            return false
        }
        onDone?(columns, rows)
        return true
    }
}

/// File > Import Image...: the conversion options, shown as an alert's accessory view.
/// The choices are remembered for the next import.
final class ImageImportOptionsView: NSView {
    private static let defaultsKey = "imageImportOptions"
    private let widthField = EditorSheetController.field("80", width: 70)
    private let modePopup = NSPopUpButton()
    private let palettePopup = NSPopUpButton()
    private let ditherPopup = NSPopUpButton()
    private let iceBox = NSButton(checkboxWithTitle: "iCE colours (bright backgrounds)", target: nil, action: nil)
    private let aspectBox = NSButton(checkboxWithTitle: "Correct for the 8x16 character cell", target: nil, action: nil)

    init(options: ImageToAnsi.Options = ImageImportOptionsView.remembered) {
        super.init(frame: NSRect(x: 0, y: 0, width: 420, height: 190))
        modePopup.addItems(withTitles: ImageToAnsi.Mode.allCases.map(\.label))
        palettePopup.addItems(withTitles: ImageToAnsi.PaletteChoice.allCases.map(\.label))
        ditherPopup.addItems(withTitles: ImageToAnsi.Dither.allCases.map(\.label))
        widthField.stringValue = String(options.columns)
        modePopup.selectItem(at: ImageToAnsi.Mode.allCases.firstIndex(of: options.mode) ?? 0)
        palettePopup.selectItem(at: ImageToAnsi.PaletteChoice.allCases.firstIndex(of: options.palette) ?? 0)
        ditherPopup.selectItem(at: ImageToAnsi.Dither.allCases.firstIndex(of: options.dither) ?? 0)
        iceBox.state = options.iceColors ? .on : .off
        aspectBox.state = options.aspectCorrection ? .on : .off
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Width (columns):"), widthField],
            [NSTextField(labelWithString: "Characters:"), modePopup],
            [NSTextField(labelWithString: "Colours:"), palettePopup],
            [NSTextField(labelWithString: "Dithering:"), ditherPopup],
            [NSGridCell.emptyContentView, iceBox],
            [NSGridCell.emptyContentView, aspectBox],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 6
        let size = grid.fittingSize
        setFrameSize(size)
        grid.frame = NSRect(origin: .zero, size: size)
        addSubview(grid)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The chosen options, or nil when the width is not 1 to 1000.
    var options: ImageToAnsi.Options? {
        guard let columns = Int(widthField.stringValue), (1...EditCanvas.maxColumns).contains(columns) else { return nil }
        var options = ImageToAnsi.Options()
        options.columns = columns
        options.mode = ImageToAnsi.Mode.allCases[max(0, modePopup.indexOfSelectedItem)]
        options.palette = ImageToAnsi.PaletteChoice.allCases[max(0, palettePopup.indexOfSelectedItem)]
        options.dither = ImageToAnsi.Dither.allCases[max(0, ditherPopup.indexOfSelectedItem)]
        options.iceColors = iceBox.state == .on
        options.aspectCorrection = aspectBox.state == .on
        return options
    }

    static var remembered: ImageToAnsi.Options {
        var options = ImageToAnsi.Options()
        guard let saved = UserDefaults.standard.dictionary(forKey: defaultsKey) else { return options }
        if let columns = saved["columns"] as? Int, (1...EditCanvas.maxColumns).contains(columns) { options.columns = columns }
        if let mode = (saved["mode"] as? String).flatMap(ImageToAnsi.Mode.init) { options.mode = mode }
        if let palette = (saved["palette"] as? String).flatMap(ImageToAnsi.PaletteChoice.init) { options.palette = palette }
        if let dither = (saved["dither"] as? String).flatMap(ImageToAnsi.Dither.init) { options.dither = dither }
        if let ice = saved["ice"] as? Bool { options.iceColors = ice }
        if let aspect = saved["aspect"] as? Bool { options.aspectCorrection = aspect }
        return options
    }

    static func remember(_ options: ImageToAnsi.Options) {
        UserDefaults.standard.set([
            "columns": options.columns, "mode": options.mode.rawValue, "palette": options.palette.rawValue,
            "dither": options.dither.rawValue, "ice": options.iceColors, "aspect": options.aspectCorrection,
        ] as [String: Any], forKey: defaultsKey)
    }
}
