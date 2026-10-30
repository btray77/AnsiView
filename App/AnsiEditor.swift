import AnsiCore
import AppKit
import UniformTypeIdentifiers

/// What the left mouse button does on the editor canvas.
enum EditorMode: Int { case draw, select }

/// The editor's canvas: draws the art with the bitmap font renderer, the cursor and the
/// selection, and turns keys and mouse events into `CanvasEditor` commands.
final class EditorCanvasView: NSView {
    unowned let editor: CanvasEditor
    weak var controller: EditorViewController?
    var mode = EditorMode.draw
    /// Screen points per font pixel.
    var zoom: CGFloat = 2 { didSet { refresh() } }
    var pasteboard = NSPasteboard.general

    /// Rows are rendered in bands, so a big canvas never hits the renderer's image size limit
    /// and a change re-renders only the bands it touched (and only when they are visible).
    static let bandRows = 32
    private var bandImages: [Int: CGImage] = [:]
    private var bandSources: [Int: ArraySlice<[AnsiCell]>] = [:]
    private var bandKey = ""
    private var dragAnchor: (x: Int, y: Int)?
    /// The last half block pixel painted in this stroke (column, half row), to fill gaps on fast drags.
    private var lastPixel: (x: Int, y: Int)?
    private var strokeUsesBackground = false
    /// A drag of the floating paste: the cell the mouse went down on, the block's origin then,
    /// and whether the mouse has moved to another cell (a click without movement stamps).
    private var floatDrag: (start: (x: Int, y: Int), origin: (x: Int, y: Int), moved: Bool)?
    /// The cell a context menu was opened on, where its Paste puts the block.
    private var contextCell: (x: Int, y: Int)?

    init(editor: CanvasEditor) {
        self.editor = editor
        super.init(frame: .zero)
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var undoManager: UndoManager? { editor.undoManager }

    private var cellSize: CGSize {
        let font = editor.canvas.font
        return CGSize(width: CGFloat(font.width) * zoom, height: CGFloat(font.height) * zoom)
    }

    func cellRect(column: Int, row: Int) -> NSRect {
        NSRect(x: CGFloat(column) * cellSize.width, y: CGFloat(row) * cellSize.height,
               width: cellSize.width, height: cellSize.height)
    }

    /// Resizes to the canvas and redraws; bands whose rows changed are re-rendered when drawn.
    func refresh() {
        let canvas = editor.displayCanvas
        let key = "\(canvas.columns)|\(canvas.fontName)"
        if key != bandKey {
            bandImages.removeAll()
            bandSources.removeAll()
            bandKey = key
        }
        let size = NSSize(width: CGFloat(canvas.columns) * cellSize.width, height: CGFloat(canvas.height) * cellSize.height)
        if frame.size != size { setFrameSize(size) }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()
        let canvas = editor.displayCanvas
        NSGraphicsContext.current?.imageInterpolation = .none
        let bandHeight = CGFloat(Self.bandRows) * cellSize.height
        let first = max(0, Int(floor(dirtyRect.minY / bandHeight)))
        let last = min((canvas.height - 1) / Self.bandRows, Int(floor(dirtyRect.maxY / bandHeight)))
        if first <= last {
            for band in first...last {
                guard let image = bandImage(band, canvas: canvas) else { continue }
                let drawn = NSRect(x: 0, y: CGFloat(band) * bandHeight,
                                   width: CGFloat(image.width) * zoom, height: CGFloat(image.height) * zoom)
                NSImage(cgImage: image, size: drawn.size).draw(in: drawn)
            }
        }
        // A floating paste hides the selection, so its colours show as they will be stamped.
        if editor.floating == nil, let selection = editor.selection {
            let rect = cellRect(column: selection.x, row: selection.y)
                .union(cellRect(column: selection.x + selection.width - 1, row: selection.y + selection.height - 1))
            NSColor.systemBlue.withAlphaComponent(0.3).setFill()
            rect.fill(using: .sourceOver)
            NSColor.systemBlue.setStroke()
            let path = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
            path.setLineDash([4, 3], count: 2, phase: 0)
            path.stroke()
        }
        if let floating = editor.floating {
            let rect = cellRect(column: floating.x, row: floating.y)
                .union(cellRect(column: min(canvas.columns - 1, floating.x + floating.region.width - 1),
                                row: floating.y + floating.region.height - 1))
            NSColor.black.setStroke()
            NSBezierPath(rect: rect.insetBy(dx: 1.5, dy: 1.5)).stroke()
            NSColor.systemYellow.setStroke()
            let path = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
            path.setLineDash([6, 3], count: 2, phase: 0)
            path.stroke()
            return
        }
        let cursor = cellRect(column: editor.cursor.x, row: editor.cursor.y)
        NSColor.black.setStroke()
        NSBezierPath(rect: cursor.insetBy(dx: 1.5, dy: 1.5)).stroke()
        NSColor.white.setStroke()
        NSBezierPath(rect: cursor.insetBy(dx: 0.5, dy: 0.5)).stroke()
        NSColor.white.setFill()
        NSRect(x: cursor.minX, y: cursor.maxY - max(2, cursor.height / 8), width: cursor.width, height: max(2, cursor.height / 8)).fill()
    }

    /// The rendered rows of one band, re-rendered only when those rows changed.
    private func bandImage(_ band: Int, canvas: EditCanvas) -> CGImage? {
        let start = band * Self.bandRows
        let rows = canvas.rows[start..<min(canvas.height, start + Self.bandRows)]
        if let cached = bandImages[band], bandSources[band] == rows { return cached }
        var screen = AnsiScreen(columns: canvas.columns, rows: Array(rows))
        screen.font = canvas.font
        let image = AnsiRenderer.render(screen, options: RenderOptions(font: canvas.font, scale: 1))?.image
        bandImages[band] = image
        bandSources[band] = rows
        return image
    }

    func scrollCursorVisible() {
        scrollToVisible(cellRect(column: editor.cursor.x, row: editor.cursor.y).insetBy(dx: -cellSize.width, dy: -cellSize.height))
    }

    // MARK: Keyboard

    /// Menu shortcuts without Command (Space for Play / Pause) would otherwise take keys meant
    /// for the canvas; the key window is asked before the menus, so plain keys are typed here.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, window?.firstResponder === self,
              event.modifierFlags.intersection([.command, .control]).isEmpty else {
            return super.performKeyEquivalent(with: event)
        }
        keyDown(with: event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) { super.keyDown(with: event); return }
        guard let characters = event.charactersIgnoringModifiers, let scalar = characters.unicodeScalars.first else { return }
        let shift = event.modifierFlags.contains(.shift)
        let value = Int(scalar.value)
        if editor.floating != nil { floatingKey(value, shift: shift); return }
        if (NSF1FunctionKey...NSF10FunctionKey).contains(value) {
            let index = value - NSF1FunctionKey
            if event.modifierFlags.contains(.option) { editor.blockSet = index } else { editor.insertBlock(index) }
            scrollCursorVisible()
            return
        }
        switch value {
        case NSLeftArrowFunctionKey: editor.moveCursor(dx: -1, dy: 0, extendSelection: shift)
        case NSRightArrowFunctionKey: editor.moveCursor(dx: 1, dy: 0, extendSelection: shift)
        case NSUpArrowFunctionKey: editor.moveCursor(dx: 0, dy: -1, extendSelection: shift)
        case NSDownArrowFunctionKey: editor.moveCursor(dx: 0, dy: 1, extendSelection: shift)
        case NSPageUpFunctionKey: editor.moveCursor(dx: 0, dy: -25, extendSelection: shift)
        case NSPageDownFunctionKey: editor.moveCursor(dx: 0, dy: 25, extendSelection: shift)
        case NSHomeFunctionKey: editor.moveToLineStart()
        case NSEndFunctionKey: editor.moveToLineEnd()
        case NSDeleteFunctionKey: editor.deleteForward()
        case 0x0D, 0x03: editor.newline()
        case 0x7F, 0x08: editor.backspace()
        case 0x1B: editor.select(nil)
        default:
            // Typed text (with Option for symbols) uses `characters`, not the unmodified key.
            let text = String((event.characters ?? "").unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F
                && !(0xF700...0xF8FF).contains($0.value) }.map(Character.init))
            if !text.isEmpty { editor.type(text) }
        }
        scrollCursorVisible()
    }

    /// Keys while a paste floats: arrows move it (Shift: 8 cells), Return or Enter places it,
    /// Escape cancels, T toggles transparency; anything else beeps.
    private func floatingKey(_ value: Int, shift: Bool) {
        let step = shift ? 8 : 1
        switch value {
        case NSLeftArrowFunctionKey: editor.moveFloating(dx: -step, dy: 0)
        case NSRightArrowFunctionKey: editor.moveFloating(dx: step, dy: 0)
        case NSUpArrowFunctionKey: editor.moveFloating(dx: 0, dy: -step)
        case NSDownArrowFunctionKey: editor.moveFloating(dx: 0, dy: step)
        case 0x0D, 0x03: editor.stampFloating()
        case 0x1B: editor.cancelFloating()
        case 0x74, 0x54: editor.transparentPaste.toggle()
        default: NSSound.beep()
        }
        scrollFloatingVisible()
    }

    private func scrollFloatingVisible() {
        guard let floating = editor.floating else { scrollCursorVisible(); return }
        scrollToVisible(cellRect(column: floating.x, row: floating.y).insetBy(dx: -cellSize.width, dy: -cellSize.height))
    }

    override func cancelOperation(_ sender: Any?) {
        if editor.floating != nil { editor.cancelFloating() } else { editor.select(nil) }
    }

    // MARK: Mouse

    /// The cell and half under a point in this view.
    private func location(_ event: NSEvent) -> (x: Int, y: Int, half: HalfBlock) {
        let p = convert(event.locationInWindow, from: nil)
        let column = Int(floor(p.x / cellSize.width))
        let rowPosition = p.y / cellSize.height
        let row = Int(floor(rowPosition))
        let half: HalfBlock = rowPosition - floor(rowPosition) < 0.5 ? .top : .bottom
        return (min(editor.canvas.columns - 1, max(0, column)), max(0, row), half)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.modifierFlags.contains(.control) {
            if let menu = menu(for: event) { NSMenu.popUpContextMenu(menu, with: event, for: self) }
            return
        }
        let at = location(event)
        if let floating = editor.floating {
            floatDrag = ((at.x, at.y), (floating.x, floating.y), false)
            return
        }
        if mode == .select {
            dragAnchor = (at.x, at.y)
            editor.setCursor(x: at.x, y: at.y)
            return
        }
        startStroke(at, background: false)
    }

    override func mouseDragged(with event: NSEvent) {
        let at = location(event)
        if let drag = floatDrag {
            let moved = drag.moved || at.x != drag.start.x || at.y != drag.start.y
            floatDrag?.moved = moved
            if moved { editor.moveFloating(toX: drag.origin.x + at.x - drag.start.x, y: drag.origin.y + at.y - drag.start.y) }
            autoscroll(with: event)
            return
        }
        if mode == .select, let anchor = dragAnchor {
            editor.select(CellRect.spanning(anchor, (at.x, at.y)))
            autoscroll(with: event)
            return
        }
        continueStroke(at)
        autoscroll(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if let drag = floatDrag {
            floatDrag = nil
            if !drag.moved { editor.stampFloating() }
            return
        }
        if mode == .select { dragAnchor = nil; return }
        editor.endStroke()
        lastPixel = nil
    }

    /// Right button: paints the background colour in Draw mode; opens the context menu in
    /// Select mode or while a paste floats (Control-click opens it in any mode).
    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if mode == .select || editor.floating != nil {
            if let menu = menu(for: event) { NSMenu.popUpContextMenu(menu, with: event, for: self) }
            return
        }
        startStroke(location(event), background: true)
    }

    override func rightMouseDragged(with event: NSEvent) {
        guard lastPixel != nil else { return }
        continueStroke(location(event))
    }

    override func rightMouseUp(with event: NSEvent) {
        guard lastPixel != nil else { return }
        editor.endStroke()
        lastPixel = nil
    }

    /// Cut, Copy, Copy As, Paste (at the clicked cell) and Select All.
    override func menu(for event: NSEvent) -> NSMenu? {
        let at = location(event)
        contextCell = (at.x, at.y)
        let menu = NSMenu()
        menu.addItem(withTitle: "Cut", action: #selector(cut(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "").target = self
        let copyAs = NSMenuItem(title: "Copy As", action: nil, keyEquivalent: "")
        copyAs.submenu = ArtPasteboard.copyAsMenu(target: self)
        menu.addItem(copyAs)
        menu.addItem(withTitle: "Paste", action: #selector(pasteAtContextCell(_:)), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Select All", action: #selector(selectAll(_:)), keyEquivalent: "").target = self
        return menu
    }

    private func startStroke(_ at: (x: Int, y: Int, half: HalfBlock), background: Bool) {
        strokeUsesBackground = background
        editor.beginStroke()
        let pixel = (at.x, at.y * 2 + (at.half == .top ? 0 : 1))
        paintPixel(pixel)
        lastPixel = pixel
    }

    /// Paints every half block pixel on the line from the last one, so fast drags leave no gaps.
    private func continueStroke(_ at: (x: Int, y: Int, half: HalfBlock)) {
        let target = (at.x, at.y * 2 + (at.half == .top ? 0 : 1))
        guard let start = lastPixel else { return }
        let steps = max(abs(target.0 - start.x), abs(target.1 - start.y))
        if steps > 0 {
            for step in 1...steps {
                let t = Double(step) / Double(steps)
                paintPixel((start.x + Int((Double(target.0 - start.x) * t).rounded()),
                            start.y + Int((Double(target.1 - start.y) * t).rounded())))
            }
        }
        lastPixel = target
    }

    private func paintPixel(_ pixel: (Int, Int)) {
        editor.paint(x: pixel.0, y: pixel.1 / 2, half: pixel.1 % 2 == 0 ? .top : .bottom, useBackground: strokeUsesBackground)
    }

    // MARK: Edit menu

    /// The selection as clipboard data, drawn with the canvas's font as the editor shows it.
    private var selectionClipboard: CellClipboard? {
        guard let selection = editor.selection else { return nil }
        return CellClipboard(region: editor.canvas.region(selection), font: editor.canvas.font)
    }

    private func copySelection(_ kind: CellClipboard.Kind) {
        guard editor.floating == nil, let clip = selectionClipboard, ArtPasteboard.write(clip, kind: kind, to: pasteboard) else {
            NSSound.beep()
            return
        }
    }

    @objc func copy(_ sender: Any?) { copySelection(.all) }
    @objc func copyAsText(_ sender: Any?) { copySelection(.text) }
    @objc func copyAsANSI(_ sender: Any?) { copySelection(.ansi) }
    @objc func copyAsImage(_ sender: Any?) { copySelection(.image) }

    @objc func cut(_ sender: Any?) {
        guard editor.floating == nil, let clip = selectionClipboard, ArtPasteboard.write(clip, kind: .all, to: pasteboard) else {
            NSSound.beep()
            return
        }
        _ = editor.cut()
    }

    /// Floats the pasteboard's cells, text or picture at the cursor (ruling 5).
    @objc func paste(_ sender: Any?) { paste(at: nil) }

    /// The context menu's Paste: floats at the cell that was clicked.
    @objc func pasteAtContextCell(_ sender: Any?) { paste(at: contextCell) }

    private func paste(at cell: (x: Int, y: Int)?) {
        switch ArtPasteboard.read(pasteboard) {
        case .cells(let region):
            editor.beginFloating(region, x: cell?.x, y: cell?.y)
        case .text(let text):
            editor.beginFloating(text: text, x: cell?.x, y: cell?.y)
            if editor.floating == nil { NSSound.beep() }
        case .image(let image):
            pasteImage(image, at: cell)
        case nil:
            NSSound.beep()
        }
        scrollFloatingVisible()
    }

    /// A picture becomes block art with the last Import Image options (ruling 7): as wide as the
    /// selection (and floated at its corner), else the image's pixel width up to the canvas width.
    private func pasteImage(_ image: CGImage, at cell: (x: Int, y: Int)?) {
        var options = ImageImportOptionsView.remembered
        let selection = editor.selection
        options.columns = CellClipboard.imageColumns(imageWidth: image.width, selectionWidth: selection?.width,
                                                     canvasColumns: editor.canvas.columns)
        options.iceColors = editor.canvas.iceColors
        let converted = ImageToAnsi.convert(image, options: options)
        let region = converted.region(CellRect(x: 0, y: 0, width: converted.columns, height: converted.height))
        editor.beginFloating(region, x: cell?.x ?? selection?.x, y: cell?.y ?? selection?.y)
    }

    @objc override func selectAll(_ sender: Any?) { editor.selectAll() }
    @objc func delete(_ sender: Any?) { editor.deleteForward() }

    // MARK: Art menu (forwarded to the controller)

    /// File > Save and Save As (the standard items send these through the responder chain).
    @objc func saveDocument(_ sender: Any?) { controller?.windowController?.save() }
    @objc func saveDocumentAs(_ sender: Any?) { controller?.windowController?.saveAs() }
    @objc func fillWithCharacter(_ sender: Any?) { editor.fillWithCharacter() }
    @objc func fillWithColour(_ sender: Any?) { editor.fillWithColour() }
    @objc func toggleIceColors(_ sender: Any?) { controller?.setIce(!editor.canvas.iceColors) }
    @objc func canvasSize(_ sender: Any?) { controller?.showCanvasSize() }
    @objc func editSauce(_ sender: Any?) { controller?.showSauce() }
    @objc func zoomIn(_ sender: Any?) { zoom = min(6, zoom + 1) }
    @objc func zoomOut(_ sender: Any?) { zoom = max(1, zoom - 1) }

    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)), #selector(cut(_:)), #selector(copyAsText(_:)), #selector(copyAsANSI(_:)),
             #selector(copyAsImage(_:)):
            return editor.selection != nil && editor.floating == nil
        case #selector(paste(_:)), #selector(pasteAtContextCell(_:)): return ArtPasteboard.canPaste(pasteboard)
        case #selector(toggleIceColors(_:)):
            item.state = editor.canvas.iceColors ? .on : .off
            return true
        default: return true
        }
    }
}

/// A colour swatch in the palette bar: click picks the foreground, Option-click or right-click the background.
final class ColourSwatch: NSView {
    let index: Int
    var onPick: ((_ index: Int, _ background: Bool) -> Void)?
    var isForeground = false { didSet { needsDisplay = true } }
    var isBackground = false { didSet { needsDisplay = true } }
    var isDimmed = false { didSet { needsDisplay = true } }

    init(index: Int) {
        self.index = index
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: 22), heightAnchor.constraint(equalToConstant: 22)])
        let c = Palette.vga[index]
        setAccessibilityLabel("Colour \(index)")
        toolTip = "Colour \(index) (\(String(format: "#%02X%02X%02X", c.r, c.g, c.b))): click for foreground, Option-click or right-click for background"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draw(_ dirtyRect: NSRect) {
        let c = Palette.vga[index]
        NSColor(srgbRed: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, alpha: 1).setFill()
        bounds.insetBy(dx: 1, dy: 1).fill()
        NSColor.gray.setStroke()
        NSBezierPath(rect: bounds.insetBy(dx: 1.5, dy: 1.5)).stroke()
        let mark: [(Bool, String)] = [(isForeground, "F"), (isBackground, "B")]
        let text = mark.filter(\.0).map(\.1).joined()
        if !text.isEmpty {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: 10),
                .foregroundColor: (Int(c.r) + Int(c.g) + Int(c.b)) > 380 ? NSColor.black : NSColor.white,
            ]
            (text as NSString).draw(at: NSPoint(x: 3, y: 4), withAttributes: attributes)
        }
        if isDimmed {
            NSColor.black.withAlphaComponent(0.55).setFill()
            NSRect(x: 1, y: 1, width: bounds.width - 2, height: 6).fill(using: .sourceOver)
        }
    }

    override func mouseDown(with event: NSEvent) { onPick?(index, event.modifierFlags.contains(.option)) }
    override func rightMouseDown(with event: NSEvent) { onPick?(index, true) }
}

/// The editor: palette bar, canvas in a scroll view, status line.
final class EditorViewController: NSViewController {
    let editor: CanvasEditor
    let canvasView: EditorCanvasView
    weak var windowController: EditorWindowController?
    /// Called after every change, for the window's edited state.
    var onChange: (() -> Void)?

    private let name: String
    private var swatches: [ColourSwatch] = []
    private var blockButtons: [NSButton] = []
    private let setPopup = NSPopUpButton()
    private let modeControl = NSSegmentedControl(labels: ["Draw", "Select"], trackingMode: .selectOne, target: nil, action: nil)
    private let iceBox = NSButton(checkboxWithTitle: "iCE colours", target: nil, action: nil)
    private let transparentBox = NSButton(checkboxWithTitle: "Transparent paste", target: nil, action: nil)
    private let status = NSTextField(labelWithString: "")
    private let preview = NSTextField(labelWithString: " Aa ")
    private var lastBlockSet = -1

    init(editor: CanvasEditor, name: String) {
        self.editor = editor
        self.name = name
        canvasView = EditorCanvasView(editor: editor)
        super.init(nibName: nil, bundle: nil)
        canvasView.controller = self
        editor.onChange = { [weak self] in self?.editorChanged() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var statusText: String { status.stringValue }

    override func loadView() {
        let scroll = NSScrollView()
        scroll.documentView = canvasView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.backgroundColor = NSColor(white: 0.12, alpha: 1)
        scroll.drawsBackground = true

        modeControl.selectedSegment = 0
        modeControl.target = self
        modeControl.action = #selector(modeChanged(_:))
        modeControl.toolTip = "Draw: left button paints foreground half blocks, right button background. Select: drag a rectangle."
        setPopup.addItems(withTitles: (1...10).map { "Set \($0)" })
        setPopup.target = self
        setPopup.action = #selector(setChanged(_:))
        setPopup.toolTip = "Character set for F1 to F10 (Option-F1 to Option-F10 choose a set)"
        for index in 0..<10 {
            let button = NSButton(title: "", target: self, action: #selector(blockClicked(_:)))
            button.tag = index
            button.bezelStyle = .rounded
            button.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
            blockButtons.append(button)
        }
        let topRow = NSStackView(views: [modeControl, setPopup] + blockButtons)
        topRow.spacing = 4

        for index in 0..<16 {
            let swatch = ColourSwatch(index: index)
            swatch.onPick = { [weak self] index, background in
                if background { self?.chooseBackground(index) } else { self?.chooseForeground(index) }
            }
            swatches.append(swatch)
        }
        iceBox.target = self
        iceBox.action = #selector(iceChanged(_:))
        iceBox.toolTip = "iCE colours: bright backgrounds instead of blinking text"
        preview.font = NSFont(name: "Menlo-Bold", size: 15)
        preview.drawsBackground = true
        preview.toolTip = "Current foreground on background"
        let colourLabel = NSTextField(labelWithString: "Colours:")
        transparentBox.target = self
        transparentBox.action = #selector(transparentChanged(_:))
        transparentBox.toolTip = "Spaces in a pasted block leave the art underneath (T while pasting)"
        let bottomRow = NSStackView(views: [colourLabel] + swatches + [preview, iceBox, transparentBox])
        bottomRow.spacing = 2
        bottomRow.setCustomSpacing(10, after: swatches.last!)
        bottomRow.setCustomSpacing(12, after: preview)

        status.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        status.textColor = .secondaryLabelColor

        let bar = NSStackView(views: [topRow, bottomRow])
        bar.orientation = .vertical
        bar.alignment = .leading
        bar.spacing = 6
        bar.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 6, right: 10)

        let root = NSView()
        for sub in [bar, scroll, status] as [NSView] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(sub)
        }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: root.topAnchor),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bar.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: bar.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            status.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 4),
            status.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            status.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -5),
        ])
        view = root
        editorChanged()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(canvasView)
    }

    // MARK: Controls

    func chooseForeground(_ index: Int) { editor.setForeground(index) }
    func chooseBackground(_ index: Int) { editor.setBackground(index) }
    func setIce(_ on: Bool) { editor.setIceColors(on) }

    func setMode(_ mode: EditorMode) {
        canvasView.mode = mode
        modeControl.selectedSegment = mode.rawValue
    }

    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        setMode(EditorMode(rawValue: sender.selectedSegment) ?? .draw)
        view.window?.makeFirstResponder(canvasView)
    }

    @objc private func setChanged(_ sender: NSPopUpButton) {
        editor.blockSet = sender.indexOfSelectedItem
        view.window?.makeFirstResponder(canvasView)
    }

    @objc private func blockClicked(_ sender: NSButton) {
        editor.insertBlock(sender.tag)
        view.window?.makeFirstResponder(canvasView)
    }

    @objc private func transparentChanged(_ sender: NSButton) {
        editor.transparentPaste = sender.state == .on
        view.window?.makeFirstResponder(canvasView)
    }

    @objc private func iceChanged(_ sender: NSButton) {
        setIce(sender.state == .on)
        view.window?.makeFirstResponder(canvasView)
    }

    private func editorChanged() {
        canvasView.refresh()
        guard isViewLoaded else { return }
        if lastBlockSet != editor.blockSet {
            lastBlockSet = editor.blockSet
            setPopup.selectItem(at: editor.blockSet)
            for (index, button) in blockButtons.enumerated() {
                let code = CanvasEditor.blockSets[editor.blockSet][index]
                button.title = "F\(index + 1) \(Character(CP437.unicode[Int(code)]))"
                button.toolTip = "F\(index + 1): type CP437 \(code)"
            }
        }
        for swatch in swatches {
            swatch.isForeground = swatch.index == editor.foreground
            swatch.isBackground = swatch.index == editor.background
            swatch.isDimmed = !editor.canvas.iceColors && swatch.index >= 8
        }
        func color(_ c: RGB) -> NSColor { NSColor(srgbRed: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, alpha: 1) }
        preview.textColor = color(editor.foregroundColor)
        preview.backgroundColor = color(editor.backgroundColor)
        iceBox.state = editor.canvas.iceColors ? .on : .off
        transparentBox.state = editor.transparentPaste ? .on : .off
        var text = "\(editor.cursor.x + 1), \(editor.cursor.y + 1)  |  \(editor.canvas.columns) x \(editor.canvas.height)"
        if let s = editor.selection { text += "  |  selection \(s.width) x \(s.height)" }
        text += "  |  set \(editor.blockSet + 1)  |  \(editor.canvas.fontName)"
        if let floating = editor.floating {
            text = "Pasting \(floating.region.width) x \(floating.region.height) at \(floating.x + 1), \(floating.y + 1)"
                + (editor.transparentPaste ? " (transparent)" : "")
                + "  |  arrows or drag to move, Return or click to place, Esc to cancel, T for transparent"
        }
        status.stringValue = text
        onChange?()
    }

    // MARK: Sheets

    func showCanvasSize() {
        guard let window = view.window else { return }
        let sheet = CanvasSizeSheetController(columns: editor.canvas.columns, rows: editor.canvas.height)
        sheet.onDone = { [weak self] columns, rows in self?.editor.resize(columns: columns, height: rows) }
        sheet.present(on: window)
    }

    func showSauce() {
        guard let window = view.window else { return }
        let canvas = editor.canvas
        let sheet = SauceSheetController(title: canvas.title, author: canvas.author, group: canvas.group)
        sheet.onDone = { [weak self] title, author, group in self?.editor.setMetadata(title: title, author: author, group: group) }
        sheet.present(on: window)
    }
}

/// One editor window. The first Save asks where (and in which format); later saves go there.
final class EditorWindowController: NSWindowController, NSWindowDelegate {
    private static var open: Set<EditorWindowController> = []
    let editorController: EditorViewController
    private(set) var fileURL: URL?
    private(set) var format: SaveFormat
    private let name: String

    @discardableResult
    static func open(canvas: EditCanvas, name: String, suggestedFormat: SaveFormat = .ansi) -> EditorWindowController {
        let controller = EditorWindowController(canvas: canvas, name: name, format: suggestedFormat)
        open.insert(controller)
        controller.showWindow(nil)
        return controller
    }

    enum UnsavedDecision { case save, discard, cancel }

    /// Asks about every editor with unsaved changes before the app quits. False cancels the quit.
    static func canTerminate(ask: (EditorWindowController) -> UnsavedDecision = askToSave) -> Bool {
        for controller in open where controller.editor.isModified {
            switch ask(controller) {
            case .save: if !controller.save() { return false }
            case .discard: continue
            case .cancel: return false
            }
        }
        return true
    }

    static func askToSave(_ controller: EditorWindowController) -> UnsavedDecision {
        controller.window?.makeKeyAndOrderFront(nil)
        let alert = NSAlert()
        alert.messageText = "Save changes to \"\(controller.window?.title ?? controller.name)\" before quitting?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save...")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .save
        case .alertThirdButtonReturn: return .discard
        default: return .cancel
        }
    }

    /// File > New ANSI Art.
    static func newArt() {
        let count = open.count
        open(canvas: EditCanvas(), name: count == 0 ? "Untitled" : "Untitled \(count + 1)")
    }

    /// File > Edit Art: the focused art window's finished screen, as an untitled copy.
    static func editFocusedArt() {
        guard let player = focusedPlayer() else {
            let alert = NSAlert()
            alert.messageText = "No art to edit"
            alert.informativeText = "Open an art file first, then choose File > Edit Art to edit a copy of it."
            alert.runModal()
            return
        }
        let base = player.fileURL.map { $0.deletingPathExtension().lastPathComponent } ?? player.artName ?? "Art"
        open(canvas: EditCanvas(file: player.source), name: "\(base) (edited)",
             suggestedFormat: SaveFormat.suggested(for: player.source.format))
    }

    /// File > Import Image...: converts a picture to block characters and opens it for touching up.
    static func importImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = "Choose an image to convert to ANSI art."
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let alert = NSAlert()
        alert.messageText = "Import \(url.lastPathComponent)"
        alert.informativeText = "The image becomes block characters in a new editor window."
        alert.addButton(withTitle: "Import")
        alert.addButton(withTitle: "Cancel")
        let optionsView = ImageImportOptionsView()
        alert.accessoryView = optionsView
        while true {
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            if optionsView.options != nil { break }
            NSSound.beep()
        }
        guard let options = optionsView.options else { return }
        ImageImportOptionsView.remember(options)
        do {
            let name = url.deletingPathExtension().lastPathComponent
            let canvas = try ImageToAnsi.convert(data: try Data(contentsOf: url), options: options, title: name)
            open(canvas: canvas, name: "\(name) (imported)")
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private static func focusedPlayer() -> AnsiPlayerViewController? {
        func find(_ view: NSView) -> AnsiPlayerViewController? {
            if let canvas = view as? AnsiCanvasView { return canvas.player }
            for subview in view.subviews { if let found = find(subview) { return found } }
            return nil
        }
        let windows = [NSApp.keyWindow, NSApp.mainWindow].compactMap { $0 } + NSApp.orderedWindows
        for window in windows where window.isVisible {
            if let player = window.contentView.flatMap(find) { return player }
        }
        return nil
    }

    private init(canvas: EditCanvas, name: String, format: SaveFormat) {
        self.name = name
        self.format = format
        editorController = EditorViewController(editor: CanvasEditor(canvas: canvas), name: name)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1340, height: 900),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.minSize = NSSize(width: 640, height: 360)
        window.title = name
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self
        window.contentViewController = editorController
        window.setContentSize(NSSize(width: 1340, height: 900))
        window.center()
        editorController.windowController = self
        editorController.onChange = { [weak self] in self?.updateEdited() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private var editor: CanvasEditor { editorController.editor }

    private func updateEdited() {
        window?.isDocumentEdited = editor.isModified
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { editor.undoManager }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard editor.isModified else { return true }
        let alert = NSAlert()
        alert.messageText = "Save changes to \"\(window?.title ?? name)\"?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save...")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return save()
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }

    func windowWillClose(_ notification: Notification) {
        Self.open.remove(self)
    }

    /// Saves to the file chosen before, or asks. Returns false when nothing was saved.
    @discardableResult
    func save() -> Bool {
        guard let fileURL else { return saveAs() }
        return write(to: fileURL, format: format)
    }

    @discardableResult
    func saveAs() -> Bool {
        guard let window else { return false }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(fileURL?.deletingPathExtension().lastPathComponent ?? name).\(format.fileExtension)"
        panel.allowedContentTypes = [Self.contentType(format)]
        panel.allowsOtherFileTypes = false
        panel.isExtensionHidden = false
        panel.message = "Saves with a SAUCE record (title, author, group, width, iCE colours)."
        let popup = NSPopUpButton()
        popup.addItems(withTitles: SaveFormat.allCases.map(\.label))
        popup.selectItem(at: SaveFormat.allCases.firstIndex(of: format) ?? 0)
        let chooser = FormatChooser(panel: panel, popup: popup)
        popup.target = chooser
        popup.action = #selector(FormatChooser.changed(_:))
        let label = NSTextField(labelWithString: "Format:")
        let accessory = NSStackView(views: [label, popup])
        accessory.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        panel.accessoryView = accessory
        _ = window
        let response = panel.runModal()
        withExtendedLifetime(chooser) {}
        guard response == .OK, let url = panel.url else { return false }
        let chosen = SaveFormat.allCases[max(0, popup.indexOfSelectedItem)]
        guard write(to: url, format: chosen) else { return false }
        fileURL = url
        format = chosen
        window.title = url.lastPathComponent
        window.representedURL = url
        return true
    }

    private func write(to url: URL, format: SaveFormat) -> Bool {
        do {
            try ArtWriter.data(editor.canvas, format: format).write(to: url, options: .atomic)
            editor.markSaved()
            return true
        } catch {
            NSAlert(error: error).runModal()
            return false
        }
    }

    static func contentType(_ format: SaveFormat) -> UTType {
        UTType(filenameExtension: format.fileExtension) ?? .data
    }

    /// Keeps the save panel's extension in step with the format popup.
    private final class FormatChooser: NSObject {
        let panel: NSSavePanel
        let popup: NSPopUpButton
        init(panel: NSSavePanel, popup: NSPopUpButton) {
            self.panel = panel
            self.popup = popup
        }

        @objc func changed(_ sender: Any?) {
            let format = SaveFormat.allCases[max(0, popup.indexOfSelectedItem)]
            panel.allowedContentTypes = [EditorWindowController.contentType(format)]
            let base = (panel.nameFieldStringValue as NSString).deletingPathExtension
            panel.nameFieldStringValue = "\(base).\(format.fileExtension)"
        }
    }
}
