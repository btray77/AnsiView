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
