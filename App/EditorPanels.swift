import AnsiCore
import AppKit

// MARK: Character picker (ruling 5)

/// The 256 CP437 characters in a 16 x 16 grid, then the favourites and recently used rows.
/// Click chooses; Option-click or right-click toggles a favourite; hovering shows the code and name.
final class CharacterPickerView: NSView {
    static let cell = NSSize(width: 20, height: 34)
    static let historyKey = "EditorCharacterHistory"
    var history: CharacterHistory
    var selected: UInt8 = 219 { didSet { needsDisplay = true } }
    var onChoose: ((UInt8) -> Void)?
    var onHover: ((String) -> Void)?
    private let sheet: CGImage?
    private var hovered: UInt8?

    init(defaults: UserDefaults = .standard) {
        history = CharacterHistory(plist: defaults.dictionary(forKey: Self.historyKey) ?? [:])
        // One render of all 256 glyphs, white on black, in the VGA font at twice size.
        let rows = (0..<16).map { row in (0..<16).map { AnsiCell(code: UInt8(row * 16 + $0), fg: Palette.vga[15]) } }
        sheet = AnsiRenderer.render(AnsiScreen(columns: 16, rows: rows), options: RenderOptions(font: .vga, scale: 2))?.image
        super.init(frame: NSRect(origin: .zero, size: NSSize(width: Self.cell.width * 16, height: Self.cell.height * 18 + 24)))
        setAccessibilityLabel("CP437 character picker")
        toolTip = "Click a character to make it the brush character; Option-click or right-click adds or removes a favourite"
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    /// The y where the favourites row starts (below the grid and its label).
    private var favouritesY: CGFloat { Self.cell.height * 16 + 12 }
    private var recentY: CGFloat { favouritesY + Self.cell.height + 12 }

    private func rect(gridIndex index: Int, rowY: CGFloat? = nil) -> NSRect {
        let column = index % 16, row = index / 16
        return NSRect(x: CGFloat(column) * Self.cell.width, y: rowY ?? CGFloat(row) * Self.cell.height,
                      width: Self.cell.width, height: Self.cell.height)
    }

    func code(at point: NSPoint) -> UInt8? {
        let column = Int(point.x / Self.cell.width)
        guard column >= 0, column < 16 else { return nil }
        if point.y < Self.cell.height * 16 { return UInt8(Int(point.y / Self.cell.height) * 16 + column) }
        if point.y >= favouritesY, point.y < favouritesY + Self.cell.height { return column < history.favourites.count ? history.favourites[column] : nil }
        if point.y >= recentY, point.y < recentY + Self.cell.height { return column < history.recent.count ? history.recent[column] : nil }
        return nil
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()
        NSGraphicsContext.current?.imageInterpolation = .none
        func glyph(_ code: UInt8, in target: NSRect) {
            guard let sheet else { return }
            let source = CGRect(x: Int(code) % 16 * 16, y: Int(code) / 16 * 32, width: 16, height: 32)
            guard let piece = sheet.cropping(to: source) else { return }
            NSImage(cgImage: piece, size: NSSize(width: 16, height: 32))
                .draw(in: NSRect(x: target.midX - 8, y: target.minY + 1, width: 16, height: 32))
        }
        for code in 0..<256 { glyph(UInt8(code), in: rect(gridIndex: code)) }
        NSColor(white: 0.3, alpha: 1).setStroke()
        for i in 0...16 {
            NSBezierPath.strokeLine(from: NSPoint(x: CGFloat(i) * Self.cell.width, y: 0), to: NSPoint(x: CGFloat(i) * Self.cell.width, y: Self.cell.height * 16))
            NSBezierPath.strokeLine(from: NSPoint(x: 0, y: CGFloat(i) * Self.cell.height), to: NSPoint(x: Self.cell.width * 16, y: CGFloat(i) * Self.cell.height))
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.lightGray]
        ("Favourites" as NSString).draw(at: NSPoint(x: 2, y: favouritesY - 12), withAttributes: attributes)
        ("Recently used" as NSString).draw(at: NSPoint(x: 2, y: recentY - 12), withAttributes: attributes)
        for (i, code) in history.favourites.prefix(16).enumerated() { glyph(code, in: rect(gridIndex: i, rowY: favouritesY)) }
        for (i, code) in history.recent.prefix(16).enumerated() { glyph(code, in: rect(gridIndex: i, rowY: recentY)) }
        func outline(_ code: UInt8, _ color: NSColor) {
            color.setStroke()
            NSBezierPath(rect: rect(gridIndex: Int(code)).insetBy(dx: 1, dy: 1)).stroke()
        }
        for code in history.favourites { outline(code, .systemPink) }
        outline(selected, .systemYellow)
        if let hovered { outline(hovered, .white) }
    }

    override func mouseMoved(with event: NSEvent) {
        let code = self.code(at: convert(event.locationInWindow, from: nil))
        if code != hovered {
            hovered = code
            needsDisplay = true
            if let code { onHover?(CharacterInfo(code: code).summary + (history.isFavourite(code) ? "  (favourite)" : "")) }
        }
    }

    override func mouseExited(with event: NSEvent) { hovered = nil; needsDisplay = true }

    override func mouseDown(with event: NSEvent) {
        guard let code = code(at: convert(event.locationInWindow, from: nil)) else { return }
        if event.modifierFlags.contains(.option) { toggleFavourite(code); return }
        choose(code)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let code = code(at: convert(event.locationInWindow, from: nil)) else { return }
        toggleFavourite(code)
    }

    func choose(_ code: UInt8) {
        selected = code
        history.use(code)
        save()
        onChoose?(code)
    }

    func toggleFavourite(_ code: UInt8) {
        history.toggleFavourite(code)
        save()
        needsDisplay = true
        onHover?(CharacterInfo(code: code).summary + (history.isFavourite(code) ? "  (favourite)" : "  (not a favourite)"))
    }

    var defaults = UserDefaults.standard
    private func save() { defaults.set(history.plist, forKey: Self.historyKey) }
}

/// A floating panel holding the character picker and its info line.
final class CharacterPickerPanel: NSPanel {
    let picker = CharacterPickerView()
    let info = NSTextField(wrappingLabelWithString: "Hover a character to see its code and name.")

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 340, height: 700), styleMask: [.titled, .closable, .utilityWindow],
                   backing: .buffered, defer: false)
        title = "CP437 Characters"
        isFloatingPanel = true
        hidesOnDeactivate = true
        info.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        info.maximumNumberOfLines = 2
        info.preferredMaxLayoutWidth = picker.frame.width
        info.toolTip = "The code (decimal and hex), Unicode scalar and Unicode name of the character under the mouse"
        picker.onHover = { [weak self] text in self?.info.stringValue = text }
        let stack = NSStackView(views: [picker, info])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        picker.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([picker.widthAnchor.constraint(equalToConstant: picker.frame.width),
                                     picker.heightAnchor.constraint(equalToConstant: picker.frame.height),
                                     info.widthAnchor.constraint(equalToConstant: picker.frame.width),
                                     info.heightAnchor.constraint(equalToConstant: 30)])
        contentView = stack
        setContentSize(stack.fittingSize)
    }
}

// MARK: Layers panel (ruling 10)

/// The layer list (top layer first) with buttons; every control has a tooltip.
final class LayersPanelView: NSStackView {
    weak var editor: CanvasEditor?
    var onRename: ((Int) -> Void)?
    private let list = NSStackView()
    private var signature = ""
    private var eyes: [NSButton] = []

    init(editor: CanvasEditor) {
        self.editor = editor
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 6
        edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        let heading = NSTextField(labelWithString: "Layers")
        heading.font = NSFont.boldSystemFont(ofSize: 12)
        heading.toolTip = "Layers: the top of the list is drawn on top. Plain saves flatten the visible layers; Save Project keeps them."
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 2
        func button(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
            let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!, target: self, action: action)
            b.bezelStyle = .regularSquare
            b.toolTip = tip
            return b
        }
        let row1 = NSStackView(views: [
            button("plus", "Add a layer above this one", #selector(add(_:))),
            button("minus", "Delete this layer (the last layer stays)", #selector(remove(_:))),
            button("plus.square.on.square", "Duplicate this layer", #selector(duplicate(_:))),
            button("arrow.up", "Move this layer up", #selector(up(_:))),
            button("arrow.down", "Move this layer down", #selector(down(_:))),
        ])
        row1.spacing = 2
        let row2 = NSStackView(views: [
            button("arrow.down.to.line", "Merge this layer into the one below", #selector(merge(_:))),
            button("square.stack.3d.down.forward", "Flatten: one layer with what is visible", #selector(flatten(_:))),
            button("pencil", "Rename this layer", #selector(rename(_:))),
        ])
        row2.spacing = 2
        for view in [heading, list, row1, row2] as [NSView] { addArrangedSubview(view) }
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Rebuilds the rows when the layers changed.
    func refresh() {
        guard let editor else { return }
        let layers = editor.layers
        // A checkbox the editor refused to apply (a block floating) shows the real state again (review I5).
        for eye in eyes where layers.indices.contains(eye.tag) { eye.state = layers[eye.tag].visible ? .on : .off }
        let key = layers.map { "\($0.name)|\($0.visible)" }.joined(separator: ",") + "#\(editor.activeLayer)"
        guard key != signature else { return }
        signature = key
        eyes = []
        for view in list.arrangedSubviews { view.removeFromSuperview() }
        for index in layers.indices.reversed() {
            let layer = layers[index]
            let eye = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleVisible(_:)))
            eye.state = layer.visible ? .on : .off
            eye.tag = index
            eyes.append(eye)
            eye.toolTip = "Show or hide \"\(layer.name)\" (hidden layers are not saved in plain files)"
            let name = NSButton(title: layer.name, target: self, action: #selector(choose(_:)))
            name.tag = index
            name.bezelStyle = .recessed
            name.showsBorderOnlyWhileMouseInside = index != editor.activeLayer
            name.font = index == editor.activeLayer ? NSFont.boldSystemFont(ofSize: 12) : NSFont.systemFont(ofSize: 12)
            name.toolTip = index == editor.activeLayer ? "\"\(layer.name)\" is being edited" : "Edit \"\(layer.name)\""
            let row = NSStackView(views: [eye, name])
            row.spacing = 4
            list.addArrangedSubview(row)
        }
    }

    @objc private func add(_ sender: Any?) { editor?.addLayer() }
    @objc private func remove(_ sender: Any?) { editor?.deleteLayer() }
    @objc private func duplicate(_ sender: Any?) { editor?.duplicateLayer() }
    @objc private func up(_ sender: Any?) { editor?.moveLayer(by: 1) }
    @objc private func down(_ sender: Any?) { editor?.moveLayer(by: -1) }
    @objc private func merge(_ sender: Any?) { editor?.mergeDown() }
    @objc private func flatten(_ sender: Any?) { editor?.flatten() }
    @objc private func rename(_ sender: Any?) { if let editor { onRename?(editor.activeLayer) } }
    @objc private func choose(_ sender: NSButton) { editor?.selectLayer(sender.tag) }
    @objc private func toggleVisible(_ sender: NSButton) {
        editor?.setLayerVisible(sender.tag, sender.state == .on)
        refresh()
    }
}

// MARK: Shortcuts preferences (ruling 13)

/// Records the next key pressed while it has focus.
final class KeyRecorderView: NSView {
    var onRecord: ((KeyCombo) -> Void)?
    var text = "Click, then press a key" { didSet { needsDisplay = true } }

    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); needsDisplay = true }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return true }

    override func keyDown(with event: NSEvent) {
        // The same mapping the canvas uses (Help counts as Insert). Command combinations belong
        // to the menus and never reach the editor's shortcuts, so they are not recorded (review M7).
        guard !event.modifierFlags.contains(.command) else { NSSound.beep(); text = "Command keys belong to the menus"; return }
        guard let combo = EditorCanvasView.combo(for: event) else { return }
        onRecord?(combo)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.type == .keyDown else { return false }
        keyDown(with: event)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        let focused = window?.firstResponder === self
        (focused ? NSColor.selectedControlColor : NSColor.controlBackgroundColor).setFill()
        bounds.fill()
        NSColor.separatorColor.setStroke()
        NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5)).stroke()
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor]
        (text as NSString).draw(at: NSPoint(x: 6, y: (bounds.height - 15) / 2), withAttributes: attributes)
    }
}

/// Editor Shortcuts...: every action with its key, conflicts in red, record a key, reset.
final class ShortcutsViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    let table = NSTableView()
    let recorder = KeyRecorderView()
    private let actions = EditorAction.allCases

    override func loadView() {
        for (id, title, width) in [("action", "Action", 250.0), ("key", "Key", 90.0), ("conflict", "Conflict", 200.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.toolTip = "Select an action, click the box below and press the new key"
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        recorder.toolTip = "Click here, then press the key (with Control, Option, Shift or Command) for the selected action"
        recorder.onRecord = { [weak self] combo in self?.record(combo) }
        let resetOne = NSButton(title: "Reset Selected", target: self, action: #selector(resetSelected(_:)))
        resetOne.toolTip = "Give the selected action its default key"
        let resetAll = NSButton(title: "Reset All to Defaults", target: self, action: #selector(resetAll(_:)))
        resetAll.toolTip = "Give every action its default key"
        let note = NSTextField(wrappingLabelWithString: "Plain letter keys work outside the Text tool; Control combinations work in every tool.")
        note.textColor = .secondaryLabelColor
        let buttons = NSStackView(views: [recorder, resetOne, resetAll])
        let root = NSStackView(views: [scroll, buttons, note])
        root.orientation = .vertical
        root.alignment = .leading
        root.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        for view in [scroll, recorder] as [NSView] { view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalToConstant: 560), scroll.heightAnchor.constraint(equalToConstant: 420),
            recorder.widthAnchor.constraint(equalToConstant: 200), recorder.heightAnchor.constraint(equalToConstant: 24),
            note.widthAnchor.constraint(equalToConstant: 560),
        ])
        view = root
        table.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { actions.count }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        let shortcuts = ShortcutStore.shared.shortcuts
        let action = actions[row]
        let text: String
        switch column?.identifier.rawValue {
        case "action": text = action.title
        case "key": text = shortcuts.combo(for: action).display
        default: text = shortcuts.conflicts(for: action).map(\.title).joined(separator: ", ")
        }
        let label = NSTextField(labelWithString: text)
        label.toolTip = column?.identifier.rawValue == "action" ? action.hint : nil
        if column?.identifier.rawValue == "conflict" { label.textColor = .systemRed }
        if column?.identifier.rawValue == "key", !shortcuts.conflicts(for: action).isEmpty { label.textColor = .systemRed }
        return label
    }

    func record(_ combo: KeyCombo) {
        let row = table.selectedRow
        guard row >= 0 else { recorder.text = "Select an action first"; return }
        ShortcutStore.shared.update { $0.set(combo, for: actions[row]) }
        recorder.text = "\(actions[row].title): \(combo.display)"
        table.reloadData()
        table.selectRowIndexes([row], byExtendingSelection: false)
    }

    @objc private func resetSelected(_ sender: Any?) {
        let row = table.selectedRow
        guard row >= 0 else { return }
        ShortcutStore.shared.update { $0.reset(actions[row]) }
        table.reloadData()
        table.selectRowIndexes([row], byExtendingSelection: false)
    }

    @objc private func resetAll(_ sender: Any?) {
        ShortcutStore.shared.update { $0.resetAll() }
        table.reloadData()
    }
}

final class ShortcutsWindowController: NSWindowController {
    static let shared = ShortcutsWindowController()

    init() {
        let window = NSWindow(contentViewController: ShortcutsViewController())
        window.title = "Editor Shortcuts"
        window.styleMask = [.titled, .closable]
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

// MARK: Replace (ruling 6)

/// The Replace dialog's fields: find a character and/or colours, replace with a character and/or colours.
final class ReplaceOptionsView: NSStackView {
    let findCharacter = NSTextField(string: "")
    let findForeground = NSPopUpButton()
    let findBackground = NSPopUpButton()
    let replaceCharacter = NSTextField(string: "")
    let replaceForeground = NSPopUpButton()
    let replaceBackground = NSPopUpButton()

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 420, height: 90))
        orientation = .vertical
        alignment = .leading
        for (popup, any) in [(findForeground, "Any foreground"), (findBackground, "Any background"),
                             (replaceForeground, "Keep foreground"), (replaceBackground, "Keep background")] {
            popup.addItems(withTitles: [any] + (0..<16).map { "Colour \($0)" })
        }
        findCharacter.placeholderString = "Any character"
        replaceCharacter.placeholderString = "Keep character"
        findCharacter.toolTip = "A character to find (or a code such as 219); empty matches any character"
        replaceCharacter.toolTip = "The character to put in its place (or a code); empty keeps each cell's character"
        findForeground.toolTip = "Only cells with this foreground colour"
        findBackground.toolTip = "Only cells with this background colour"
        replaceForeground.toolTip = "The new foreground colour"
        replaceBackground.toolTip = "The new background colour"
        for field in [findCharacter, replaceCharacter] {
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 110).isActive = true
        }
        addArrangedSubview(NSStackView(views: [NSTextField(labelWithString: "Find:"), findCharacter, findForeground, findBackground]))
        addArrangedSubview(NSStackView(views: [NSTextField(labelWithString: "Replace:"), replaceCharacter, replaceForeground, replaceBackground]))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// A typed character or a decimal code 0 to 255.
    static func code(_ text: String) -> UInt8? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.count > 1, let value = Int(trimmed), (0...255).contains(value) { return UInt8(value) }
        guard let scalar = text.unicodeScalars.first, text.unicodeScalars.count == 1 else { return nil }
        return CP437.code(for: scalar)
    }

    private static func colour(_ popup: NSPopUpButton) -> RGB? {
        popup.indexOfSelectedItem > 0 ? Palette.vga[popup.indexOfSelectedItem - 1] : nil
    }

    var find: CellPattern { CellPattern(code: Self.code(findCharacter.stringValue), fg: Self.colour(findForeground), bg: Self.colour(findBackground)) }
    var replacement: CellPattern {
        CellPattern(code: Self.code(replaceCharacter.stringValue), fg: Self.colour(replaceForeground), bg: Self.colour(replaceBackground))
    }
}
