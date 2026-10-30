import AnsiCore
import AppKit
import UniformTypeIdentifiers

/// The editor's canvas: draws the art with the bitmap font renderer, the cursor, selection and
/// grid, and turns keys and mouse events into `CanvasEditor` commands for the current tool.
final class EditorCanvasView: NSView {
    unowned let editor: CanvasEditor
    weak var controller: EditorViewController?
    var tool = EditorTool.draw {
        didSet {
            if tool != oldValue { controller?.toolChanged() }
            window?.invalidateCursorRects(for: self)
        }
    }
    /// Plan 6's name for the tool.
    var mode: EditorTool {
        get { tool }
        set { tool = newValue }
    }
    /// Screen points per font pixel.
    var zoom: CGFloat = 2 { didSet { refresh() } }
    var showGrid = false { didSet { needsDisplay = true } }
    var pasteboard = NSPasteboard.general
    var settings: ToolSettings { controller?.optionsBar.settings ?? ToolSettings() }

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
    /// The last cell of a Line or Brush stroke, and where a Box drag started.
    private var lastCell: (x: Int, y: Int)?
    private var shapeAnchor: (x: Int, y: Int)?
    private var strokeErases = false
    /// A drag of the floating block: the cell the mouse went down on, the block's origin then,
    /// and whether the mouse has moved to another cell (a click without movement stamps).
    private var floatDrag: (start: (x: Int, y: Int), origin: (x: Int, y: Int), moved: Bool)?
    /// The cell a context menu was opened on, where its Paste puts the block.
    private var contextCell: (x: Int, y: Int)?
    /// Space held (outside the Text tool), or the middle button: the mouse pans.
    private(set) var spaceHeld = false
    private var panStart: (point: NSPoint, origin: NSPoint)?
    private var magnifyTotal: CGFloat = 0

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

    private func rect(of cells: CellRect) -> NSRect {
        cellRect(column: cells.x, row: cells.y).union(cellRect(column: cells.x + cells.width - 1, row: cells.y + cells.height - 1))
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
        window?.invalidateCursorRects(for: self)
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
        if showGrid, cellSize.width >= 6 { drawGrid(dirtyRect, canvas: canvas) }
        // A floating block hides the selection, so its colours show as they will be stamped.
        if editor.floating == nil, let selection = editor.selection {
            let rect = self.rect(of: selection)
            NSColor.systemBlue.withAlphaComponent(0.3).setFill()
            rect.fill(using: .sourceOver)
            NSColor.systemBlue.setStroke()
            let path = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
            path.setLineDash([4, 3], count: 2, phase: 0)
            path.stroke()
        }
        if let floating = editor.floating {
            if let source = floating.liftedFrom {
                // Where a moved block came from, so the move is visible.
                NSColor.systemOrange.withAlphaComponent(0.8).setStroke()
                let path = NSBezierPath(rect: rect(of: source).insetBy(dx: 0.5, dy: 0.5))
                path.setLineDash([2, 3], count: 2, phase: 0)
                path.stroke()
            }
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
        (editor.insertMode ? NSColor.systemGreen : NSColor.white).setStroke()
        NSBezierPath(rect: cursor.insetBy(dx: 0.5, dy: 0.5)).stroke()
        (editor.insertMode ? NSColor.systemGreen : NSColor.white).setFill()
        // Insert mode shows a bar on the left, overwrite an underline.
        if editor.insertMode {
            NSRect(x: cursor.minX, y: cursor.minY, width: max(2, cursor.width / 6), height: cursor.height).fill()
        } else {
            NSRect(x: cursor.minX, y: cursor.maxY - max(2, cursor.height / 8), width: cursor.width, height: max(2, cursor.height / 8)).fill()
        }
    }

    private func drawGrid(_ dirtyRect: NSRect, canvas: EditCanvas) {
        NSColor.white.withAlphaComponent(0.14).setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1
        let c0 = max(0, Int(dirtyRect.minX / cellSize.width)), c1 = min(canvas.columns, Int(dirtyRect.maxX / cellSize.width) + 1)
        let r0 = max(0, Int(dirtyRect.minY / cellSize.height)), r1 = min(canvas.height, Int(dirtyRect.maxY / cellSize.height) + 1)
        for c in c0...c1 {
            let x = CGFloat(c) * cellSize.width + 0.5
            path.move(to: NSPoint(x: x, y: CGFloat(r0) * cellSize.height))
            path.line(to: NSPoint(x: x, y: CGFloat(r1) * cellSize.height))
        }
        for r in r0...r1 {
            let y = CGFloat(r) * cellSize.height + 0.5
            path.move(to: NSPoint(x: CGFloat(c0) * cellSize.width, y: y))
            path.line(to: NSPoint(x: CGFloat(c1) * cellSize.width, y: y))
        }
        path.stroke()
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

    // MARK: Pointer

    override func resetCursorRects() {
        addCursorRect(visibleRect, cursor: spaceHeld ? .openHand : tool.cursor)
        if editor.floating == nil, tool == .select, let selection = editor.selection {
            // Inside a selection the block can be dragged away (ruling 8).
            addCursorRect(rect(of: selection).intersection(visibleRect), cursor: .openHand)
        }
        if let floating = editor.floating {
            addCursorRect(rect(of: CellRect(x: floating.x, y: floating.y, width: floating.region.width,
                                            height: floating.region.height)).intersection(visibleRect), cursor: .openHand)
        }
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

    /// The key of an event as a `KeyCombo` (Command is not part of editor shortcuts).
    static func combo(for event: NSEvent) -> KeyCombo? {
        guard let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first else { return nil }
        let flags = event.modifierFlags
        var name = KeyCombo.keyName(scalar: scalar.value)
        // The Help key sits where Insert is on extended Mac keyboards.
        if name == "help" { name = "insert" }
        return KeyCombo(name, control: flags.contains(.control), option: flags.contains(.option),
                        shift: flags.contains(.shift), command: flags.contains(.command))
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) { super.keyDown(with: event); return }
        guard let characters = event.charactersIgnoringModifiers, let scalar = characters.unicodeScalars.first else { return }
        let shift = event.modifierFlags.contains(.shift)
        let option = event.modifierFlags.contains(.option)
        let value = Int(scalar.value)
        if editor.floating != nil { floatingKey(value, shift: shift); return }
        if let combo = Self.combo(for: event), !(combo.isPlain && tool == .text),
           let action = ShortcutStore.shared.shortcuts.action(for: combo) {
            controller?.run(action)
            return
        }
        if value == 0x20, tool != .text {
            if !event.isARepeat { spaceHeld = true; window?.invalidateCursorRects(for: self) }
            return
        }
        if (NSF1FunctionKey...NSF10FunctionKey).contains(value) {
            let index = value - NSF1FunctionKey
            if option { editor.blockSet = index } else { editor.insertBlock(index) }
            scrollCursorVisible()
            return
        }
        let arrows: [Int: (Int, Int)] = [NSLeftArrowFunctionKey: (-1, 0), NSRightArrowFunctionKey: (1, 0),
                                         NSUpArrowFunctionKey: (0, -1), NSDownArrowFunctionKey: (0, 1)]
        if let (dx, dy) = arrows[value] {
            if tool == .line, !shift {
                // Line mode: the arrows draw behind the cursor; Option erases.
                editor.lineStep(dx: dx, dy: dy, style: settings.lineStyle, erase: option)
            } else if option, editor.selection != nil {
                // Option-arrow moves the selection like a floating paste (Shift: 8 cells).
                let step = shift ? 8 : 1
                editor.moveSelection(dx: dx * step, dy: dy * step)
                scrollFloatingVisible()
                return
            } else {
                editor.moveCursor(dx: dx, dy: dy, extendSelection: shift)
            }
            scrollCursorVisible()
            return
        }
        switch value {
        case NSPageUpFunctionKey: editor.moveCursor(dx: 0, dy: -25, extendSelection: shift)
        case NSPageDownFunctionKey: editor.moveCursor(dx: 0, dy: 25, extendSelection: shift)
        case NSHomeFunctionKey: editor.moveToLineStart()
        case NSEndFunctionKey: editor.moveToLineEnd()
        case NSDeleteFunctionKey: editor.deleteForward()
        case 0x0D, 0x03: editor.newline()
        case 0x7F, 0x08: editor.backspace()
        case 0x1B: editor.select(nil)
        default:
            guard !event.modifierFlags.contains(.control) else { return }
            // Typed text (with Option for symbols) uses `characters`, not the unmodified key.
            let text = String((event.characters ?? "").unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F
                && !(0xF700...0xF8FF).contains($0.value) }.map(Character.init))
            if !text.isEmpty { editor.type(text) }
        }
        scrollCursorVisible()
    }

    override func keyUp(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " ", spaceHeld {
            spaceHeld = false
            window?.invalidateCursorRects(for: self)
        }
    }

    /// Keys while a block floats: arrows move it (Shift: 8 cells; Option-arrows too), Return or
    /// Enter places it, Escape cancels (a lifted selection goes back), T toggles transparency.
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

    // MARK: Zoom and pan

    override func magnify(with event: NSEvent) {
        magnifyTotal += event.magnification
        if magnifyTotal > 0.25 { zoomIn(nil); magnifyTotal = 0 }
        if magnifyTotal < -0.25 { zoomOut(nil); magnifyTotal = 0 }
    }

    override func scrollWheel(with event: NSEvent) {
        // Control-scroll zooms; plain scrolling pans (the scroll view).
        if event.modifierFlags.contains(.control) {
            if event.scrollingDeltaY > 0.5 { zoomIn(nil) } else if event.scrollingDeltaY < -0.5 { zoomOut(nil) }
            return
        }
        super.scrollWheel(with: event)
    }

    private func startPan(_ event: NSEvent) {
        guard let clip = enclosingScrollView?.contentView else { return }
        panStart = (event.locationInWindow, clip.bounds.origin)
        NSCursor.closedHand.set()
    }

    private func continuePan(_ event: NSEvent) {
        guard let start = panStart, let scroll = enclosingScrollView else { return }
        let p = event.locationInWindow
        var origin = NSPoint(x: start.origin.x - (p.x - start.point.x), y: start.origin.y + (p.y - start.point.y))
        let maxX = max(0, frame.width - scroll.contentView.bounds.width), maxY = max(0, frame.height - scroll.contentView.bounds.height)
        origin = NSPoint(x: min(maxX, max(0, origin.x)), y: min(maxY, max(0, origin.y)))
        scroll.contentView.scroll(to: origin)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    override func otherMouseDown(with event: NSEvent) { startPan(event) }
    override func otherMouseDragged(with event: NSEvent) { continuePan(event) }
    override func otherMouseUp(with event: NSEvent) { panStart = nil }

    // MARK: Mouse

    /// The cell and half under a point in this view.
    private func location(_ event: NSEvent) -> (x: Int, y: Int, half: HalfBlock) {
        let p = convert(event.locationInWindow, from: nil)
        let column = Int(floor(p.x / cellSize.width))
        let rowPosition = p.y / cellSize.height
        let row = Int(floor(rowPosition))
        let half: HalfBlock = rowPosition - floor(rowPosition) < 0.5 ? .top : .bottom
        return (min(editor.canvas.columns - 1, max(0, column)), min(AnsiTerminal.maxRows - 1, max(0, row)), half)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.modifierFlags.contains(.control) {
            if let menu = menu(for: event) { NSMenu.popUpContextMenu(menu, with: event, for: self) }
            return
        }
        if spaceHeld { startPan(event); return }
        let at = location(event)
        let option = event.modifierFlags.contains(.option)
        if let floating = editor.floating {
            let block = CellRect(x: floating.x, y: floating.y, width: floating.region.width, height: floating.region.height)
            // A click outside the block places it; inside, the block follows the mouse.
            if !block.contains(x: at.x, y: at.y) { editor.stampFloating(); return }
            floatDrag = ((at.x, at.y), (floating.x, floating.y), false)
            return
        }
        switch tool {
        case .select:
            if let selection = editor.selection, selection.contains(x: at.x, y: at.y) {
                // Dragging a selection lifts it (Option: a copy) and moves it like a paste (ruling 8).
                editor.liftSelection(duplicate: option)
                floatDrag = ((at.x, at.y), (selection.x, selection.y), false)
                controller?.transientHint = option ? "Moving a copy: release to drop it, then Return or click outside to place, Esc to cancel"
                    : "Moving: release to drop it, then Return or click outside to place, Esc to put it back"
                NSCursor.closedHand.set()
                return
            }
            dragAnchor = (at.x, at.y)
            editor.setCursor(x: at.x, y: at.y)
        case .draw:
            startStroke(at, background: false)
        case .line:
            strokeErases = option
            editor.setCursor(x: at.x, y: at.y)
            editor.beginStroke()
            lastCell = (at.x, at.y)
        case .box:
            shapeAnchor = (at.x, at.y)
            updateShapePreview(to: (at.x, at.y))
        case .fill:
            editor.floodFill(x: at.x, y: at.y, matchBy: settings.fillMatch, apply: settings.fillApply)
        case .text:
            editor.setCursor(x: at.x, y: at.y)
        case .brush:
            strokeUsesBackground = false
            editor.beginStroke()
            editor.brush(x: at.x, y: at.y, colourOnly: settings.colourOnlyBrush, useBackground: false)
            lastCell = (at.x, at.y)
        case .eyedropper:
            editor.pickColours(x: at.x, y: at.y, includeCharacter: option)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if panStart != nil { continuePan(event); return }
        let at = location(event)
        if let drag = floatDrag {
            let moved = drag.moved || at.x != drag.start.x || at.y != drag.start.y
            floatDrag?.moved = moved
            if moved { editor.moveFloating(toX: drag.origin.x + at.x - drag.start.x, y: drag.origin.y + at.y - drag.start.y) }
            autoscroll(with: event)
            return
        }
        switch tool {
        case .select:
            if let anchor = dragAnchor { editor.select(CellRect.spanning(anchor, (at.x, at.y))) }
        case .draw:
            continueStroke(at)
        case .line:
            if let last = lastCell, last != (at.x, at.y) {
                editor.strokeLine(from: last, to: (at.x, at.y), style: settings.lineStyle, erase: strokeErases)
                lastCell = (at.x, at.y)
            }
        case .box:
            updateShapePreview(to: (at.x, at.y))
        case .brush:
            brushLine(to: (at.x, at.y))
        default:
            break
        }
        autoscroll(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if panStart != nil { panStart = nil; window?.invalidateCursorRects(for: self); return }
        if let drag = floatDrag {
            floatDrag = nil
            controller?.transientHint = nil
            // A click without movement places the block; after a drag it stays lifted to nudge or place.
            if !drag.moved { editor.stampFloating() }
            window?.invalidateCursorRects(for: self)
            return
        }
        switch tool {
        case .select: dragAnchor = nil
        case .draw: editor.endStroke(); lastPixel = nil
        case .line:
            editor.endStroke()
            if let last = lastCell { editor.setCursor(x: last.x, y: last.y) }
            lastCell = nil
        case .box:
            if let anchor = shapeAnchor { commitShape(from: anchor, to: (location(event).x, location(event).y)) }
            shapeAnchor = nil
        case .brush: editor.endStroke(); lastCell = nil
        default: break
        }
    }

    /// Right button: paints the background colour in Draw and Brush, erases in Line; opens the
    /// context menu otherwise or while a block floats (Control-click opens it in any tool).
    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let at = location(event)
        guard editor.floating == nil else {
            if let menu = menu(for: event) { NSMenu.popUpContextMenu(menu, with: event, for: self) }
            return
        }
        switch tool {
        case .draw: startStroke(at, background: true)
        case .brush:
            strokeUsesBackground = true
            editor.beginStroke()
            editor.brush(x: at.x, y: at.y, colourOnly: settings.colourOnlyBrush, useBackground: true)
            lastCell = (at.x, at.y)
        case .line:
            strokeErases = true
            editor.beginStroke()
            lastCell = (at.x, at.y)
        default:
            if let menu = menu(for: event) { NSMenu.popUpContextMenu(menu, with: event, for: self) }
        }
    }

    override func rightMouseDragged(with event: NSEvent) {
        let at = location(event)
        switch tool {
        case .draw: if lastPixel != nil { continueStroke(at) }
        case .brush: brushLine(to: (at.x, at.y))
        case .line:
            if let last = lastCell, last != (at.x, at.y) {
                editor.strokeLine(from: last, to: (at.x, at.y), style: settings.lineStyle, erase: true)
                lastCell = (at.x, at.y)
            }
        default: break
        }
    }

    override func rightMouseUp(with event: NSEvent) {
        if lastPixel != nil || lastCell != nil { editor.endStroke() }
        lastPixel = nil
        lastCell = nil
    }

    /// Cut, Copy, Copy As, Paste (at the clicked cell), Select All and the selection commands.
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
        menu.addItem(.separator())
        for (title, action) in [("Move Selection", #selector(liftSelection(_:))), ("Mirror Horizontally", #selector(mirrorHorizontally(_:))),
                                ("Mirror Vertically", #selector(mirrorVertically(_:))), ("Rotate 180", #selector(rotate180(_:))),
                                ("Rotate 90 Clockwise", #selector(rotateClockwise(_:))), ("Crop to Selection", #selector(cropToSelection(_:)))] {
            menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
        }
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

    /// Brushes every cell on the line from the last brushed one.
    private func brushLine(to cell: (x: Int, y: Int)) {
        guard let last = lastCell, last != cell else { return }
        for (x, y) in EditCanvas.bresenham(from: last, to: cell).dropFirst() {
            editor.brush(x: x, y: y, colourOnly: settings.colourOnlyBrush, useBackground: strokeUsesBackground)
        }
        lastCell = cell
    }

    // MARK: Shapes

    /// The shape between two cells with the current options, as a change to a canvas.
    func shapeChange(from a: (x: Int, y: Int), to b: (x: Int, y: Int)) -> (inout EditCanvas) -> Void {
        let s = settings
        let style = s.boxStyle.style(brush: editor.brushCharacter)
        let fg = editor.foregroundColor, bg = editor.backgroundColor
        let rect = CellRect.spanning((a.x, a.y), (b.x, b.y))
        let fillCode = s.fillWithBrush ? editor.brushCharacter : 0x20
        switch s.shape {
        case .rectangle:
            return { $0.drawRectangle(rect, style: style, fg: fg, bg: bg, filled: s.filled, fillCode: fillCode, shadow: s.shadow, title: s.title) }
        case .line:
            return { $0.drawStraightLine(from: (a.x, a.y), to: (b.x, b.y), style: style, fg: fg, bg: bg) }
        case .ellipse:
            return { $0.drawEllipse(in: rect, color: fg) }
        }
    }

    private func updateShapePreview(to cell: (x: Int, y: Int)) {
        guard let anchor = shapeAnchor else { return }
        editor.setPreview(shapeChange(from: anchor, to: cell))
        let rect = CellRect.spanning((anchor.x, anchor.y), (cell.x, cell.y))
        controller?.transientHint = "\(settings.shape.title) \(rect.width) x \(rect.height): release to draw"
    }

    func commitShape(from a: (x: Int, y: Int), to b: (x: Int, y: Int)) {
        editor.setPreview(nil)
        controller?.transientHint = nil
        let s = settings
        let style = s.boxStyle.style(brush: editor.brushCharacter)
        let rect = CellRect.spanning((a.x, a.y), (b.x, b.y))
        switch s.shape {
        case .rectangle:
            editor.drawRectangle(rect, style: style, filled: s.filled, fillCode: s.fillWithBrush ? editor.brushCharacter : 0x20,
                                 shadow: s.shadow, title: s.title)
        case .line: editor.drawStraightLine(from: (a.x, a.y), to: (b.x, b.y), style: style)
        case .ellipse: editor.drawEllipse(in: rect)
        }
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

    /// Floats the pasteboard's cells, text or picture at the cursor (copy and paste ruling 5).
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

    /// A picture becomes block art with the last Import Image options (copy and paste ruling 7).
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

    // MARK: Art and Tools menus (forwarded to the editor or the controller)

    /// File > Save and Save As (the standard items send these through the responder chain).
    @objc func saveDocument(_ sender: Any?) { controller?.windowController?.save() }
    @objc func saveDocumentAs(_ sender: Any?) { controller?.windowController?.saveAs() }
    @objc func saveProject(_ sender: Any?) { controller?.windowController?.saveProject() }
    @objc func fillWithCharacter(_ sender: Any?) { editor.fillWithCharacter() }
    @objc func fillWithColour(_ sender: Any?) { editor.fillWithColour() }
    @objc func toggleIceColors(_ sender: Any?) { controller?.setIce(!editor.canvas.iceColors) }
    @objc func canvasSize(_ sender: Any?) { controller?.showCanvasSize() }
    @objc func editSauce(_ sender: Any?) { controller?.showSauce() }
    @objc func zoomIn(_ sender: Any?) { zoom = min(8, zoom + 1); controller?.editorChanged() }
    @objc func zoomOut(_ sender: Any?) { zoom = max(1, zoom - 1); controller?.editorChanged() }

    @objc func chooseDrawTool(_ sender: Any?) { controller?.setTool(.draw) }
    @objc func chooseSelectTool(_ sender: Any?) { controller?.setTool(.select) }
    @objc func chooseLineTool(_ sender: Any?) { controller?.setTool(.line) }
    @objc func chooseBoxTool(_ sender: Any?) { controller?.setTool(.box) }
    @objc func chooseFillTool(_ sender: Any?) { controller?.setTool(.fill) }
    @objc func chooseTextTool(_ sender: Any?) { controller?.setTool(.text) }
    @objc func chooseBrushTool(_ sender: Any?) { controller?.setTool(.brush) }
    @objc func chooseEyedropperTool(_ sender: Any?) { controller?.setTool(.eyedropper) }
    @objc func showCharacterPicker(_ sender: Any?) { controller?.run(.characterPicker) }
    @objc func swapColours(_ sender: Any?) { controller?.run(.swapColours) }
    @objc func toggleInsertMode(_ sender: Any?) { controller?.run(.toggleInsert) }
    @objc func insertLine(_ sender: Any?) { controller?.run(.insertLine) }
    @objc func deleteLine(_ sender: Any?) { controller?.run(.deleteLine) }
    @objc func insertColumn(_ sender: Any?) { controller?.run(.insertColumn) }
    @objc func deleteColumn(_ sender: Any?) { controller?.run(.deleteColumn) }
    @objc func liftSelection(_ sender: Any?) { controller?.run(.liftSelection) }
    @objc func mirrorHorizontally(_ sender: Any?) { controller?.run(.mirrorHorizontal) }
    @objc func mirrorVertically(_ sender: Any?) { controller?.run(.mirrorVertical) }
    @objc func rotate180(_ sender: Any?) { controller?.run(.rotate180) }
    @objc func rotateClockwise(_ sender: Any?) { controller?.run(.rotateClockwise) }
    @objc func cropToSelection(_ sender: Any?) { editor.cropToSelection() }
    @objc func swapSelectionColours(_ sender: Any?) { editor.swapSelectionColours() }
    @objc func showReplace(_ sender: Any?) { controller?.showReplace() }
    @objc func addLayer(_ sender: Any?) { editor.addLayer() }
    @objc func mergeLayerDown(_ sender: Any?) { editor.mergeDown() }
    @objc func flattenLayers(_ sender: Any?) { editor.flatten() }
    @objc func toggleGrid(_ sender: Any?) { controller?.run(.toggleGrid) }
    @objc func toggleRetroTheme(_ sender: Any?) { controller?.toggleTheme() }

    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let floating = editor.floating != nil
        switch item.action {
        case #selector(copy(_:)), #selector(cut(_:)), #selector(copyAsText(_:)), #selector(copyAsANSI(_:)),
             #selector(copyAsImage(_:)):
            return editor.selection != nil && !floating
        case #selector(paste(_:)), #selector(pasteAtContextCell(_:)): return ArtPasteboard.canPaste(pasteboard)
        case #selector(liftSelection(_:)), #selector(cropToSelection(_:)), #selector(swapSelectionColours(_:)):
            return editor.selection != nil && !floating
        case #selector(mirrorHorizontally(_:)): return editor.canTransformSelection(.mirrorHorizontal)
        case #selector(mirrorVertically(_:)): return editor.canTransformSelection(.mirrorVertical)
        case #selector(rotate180(_:)): return editor.canTransformSelection(.rotate180)
        case #selector(rotateClockwise(_:)): return editor.canTransformSelection(.rotateClockwise)
        case #selector(mergeLayerDown(_:)): return editor.activeLayer > 0 && !floating
        case #selector(flattenLayers(_:)): return editor.layers.count > 1 && !floating
        case #selector(toggleInsertMode(_:)): item.state = editor.insertMode ? .on : .off; return true
        case #selector(toggleGrid(_:)): item.state = showGrid ? .on : .off; return true
        case #selector(toggleRetroTheme(_:)): item.state = EditorTheme.current == .retro ? .on : .off; return true
        case #selector(chooseDrawTool(_:)), #selector(chooseSelectTool(_:)), #selector(chooseLineTool(_:)),
             #selector(chooseBoxTool(_:)), #selector(chooseFillTool(_:)), #selector(chooseTextTool(_:)),
             #selector(chooseBrushTool(_:)), #selector(chooseEyedropperTool(_:)):
            let tools: [Selector: EditorTool] = [#selector(chooseDrawTool(_:)): .draw, #selector(chooseSelectTool(_:)): .select,
                                                 #selector(chooseLineTool(_:)): .line, #selector(chooseBoxTool(_:)): .box,
                                                 #selector(chooseFillTool(_:)): .fill, #selector(chooseTextTool(_:)): .text,
                                                 #selector(chooseBrushTool(_:)): .brush, #selector(chooseEyedropperTool(_:)): .eyedropper]
            item.state = tools[item.action!] == tool ? .on : .off
            return true
        // A floating block is placed or cancelled before anything else changes the canvas.
        case #selector(delete(_:)), #selector(fillWithCharacter(_:)), #selector(fillWithColour(_:)),
             #selector(toggleIceColors(_:)), #selector(canvasSize(_:)), #selector(editSauce(_:)),
             #selector(insertLine(_:)), #selector(deleteLine(_:)), #selector(insertColumn(_:)), #selector(deleteColumn(_:)),
             #selector(showReplace(_:)), #selector(addLayer(_:)), #selector(saveProject(_:)):
            if floating { return false }
            if item.action == #selector(toggleIceColors(_:)) { item.state = editor.canvas.iceColors ? .on : .off }
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


/// The editor: palette bar and tool options on top, tools on the left, the canvas, layers on
/// the right, and a status bar with the position and a hint for whatever is under the mouse.
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
    let palette = ToolPaletteView()
    let optionsBar = ToolOptionsBar()
    private(set) lazy var layersPanel = LayersPanelView(editor: editor)
    private let iceBox = NSButton(checkboxWithTitle: "iCE colours", target: nil, action: nil)
    private let transparentBox = NSButton(checkboxWithTitle: "Transparent paste", target: nil, action: nil)
    private let status = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "")
    private let preview = NSTextField(labelWithString: " Aa ")
    private let insertLabel = NSTextField(labelWithString: "OVR")
    private var lastBlockSet = -1
    private let hints = HintTracker()
    private var root = NSView()
    private var chrome: [NSView] = []
    private var shortcutObserver: NSObjectProtocol?
    private(set) lazy var characterPanel: CharacterPickerPanel = {
        let panel = CharacterPickerPanel()
        panel.picker.onChoose = { [weak self] code in
            self?.editor.brushCharacter = code
            self?.view.window?.makeFirstResponder(self?.canvasView)
        }
        return panel
    }()

    /// The hint under the mouse (a control's tooltip), and one for a drag in progress.
    var hoverHint: String? { didSet { updateHint() } }
    var transientHint: String? { didSet { updateHint() } }

    init(editor: CanvasEditor, name: String) {
        self.editor = editor
        self.name = name
        canvasView = EditorCanvasView(editor: editor)
        super.init(nibName: nil, bundle: nil)
        canvasView.controller = self
        editor.onChange = { [weak self] in self?.editorChanged() }
    }

    deinit {
        if let shortcutObserver { NotificationCenter.default.removeObserver(shortcutObserver) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var statusText: String { status.stringValue }
    var hintText: String { hintLabel.stringValue }

    override func loadView() {
        let scroll = NSScrollView()
        scroll.documentView = canvasView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.backgroundColor = NSColor(white: 0.12, alpha: 1)
        scroll.drawsBackground = true

        palette.onPick = { [weak self] tool in self?.setTool(tool) }
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
        let topRow = NSStackView(views: [setPopup] + blockButtons)
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
        preview.toolTip = "Current colours: foreground on background (\(ShortcutStore.shared.shortcuts.combo(for: .swapColours).display) swaps them)"
        let colourLabel = NSTextField(labelWithString: "Colours:")
        colourLabel.toolTip = "Click a colour for the foreground; Option-click or right-click for the background"
        transparentBox.target = self
        transparentBox.action = #selector(transparentChanged(_:))
        transparentBox.toolTip = "Spaces in a pasted or moved block leave the art underneath (T while it floats)"
        insertLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)
        insertLabel.toolTip = "Overwrite (OVR) replaces characters; insert (INS) shifts the row right (\(ShortcutStore.shared.shortcuts.combo(for: .toggleInsert).display) switches)"
        let bottomRow = NSStackView(views: [colourLabel] + swatches + [preview, iceBox, transparentBox, insertLabel])
        bottomRow.spacing = 2
        bottomRow.setCustomSpacing(10, after: swatches.last!)
        bottomRow.setCustomSpacing(12, after: preview)
        bottomRow.setCustomSpacing(12, after: transparentBox)
        optionsBar.onChange = { [weak self] in self?.optionsChanged() }
        optionsBar.onPickCharacter = { [weak self] in self?.run(.characterPicker) }

        status.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        status.textColor = .secondaryLabelColor
        status.toolTip = "Cursor column and row, canvas size, insert mode, layer, character set and font"
        hintLabel.font = NSFont.systemFont(ofSize: 11)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.lineBreakMode = .byTruncatingTail

        let bar = NSStackView(views: [topRow, bottomRow, optionsBar])
        bar.orientation = .vertical
        bar.alignment = .leading
        bar.spacing = 6
        bar.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 2, right: 10)

        let root = NSView()
        self.root = root
        for sub in [bar, palette, scroll, layersPanel, status, hintLabel] as [NSView] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(sub)
        }
        chrome = [bar, palette, layersPanel]
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: root.topAnchor),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bar.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor),
            palette.topAnchor.constraint(equalTo: bar.bottomAnchor),
            palette.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.topAnchor.constraint(equalTo: bar.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: palette.trailingAnchor),
            scroll.trailingAnchor.constraint(equalTo: layersPanel.leadingAnchor),
            layersPanel.topAnchor.constraint(equalTo: bar.bottomAnchor),
            layersPanel.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            layersPanel.widthAnchor.constraint(equalToConstant: 190),
            status.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 4),
            status.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            status.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -5),
            hintLabel.centerYAnchor.constraint(equalTo: status.centerYAnchor),
            hintLabel.leadingAnchor.constraint(equalTo: status.trailingAnchor, constant: 16),
            hintLabel.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -10),
        ])
        status.setContentCompressionResistancePriority(.required, for: .horizontal)
        hintLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view = root
        layersPanel.onRename = { [weak self] index in self?.renameLayer(index) }
        hints.show = { [weak self] text in self?.hoverHint = text }
        shortcutObserver = NotificationCenter.default.addObserver(forName: ShortcutStore.changed, object: nil, queue: .main) { [weak self] _ in
            self?.palette.refreshTooltips()
        }
        setTool(.draw)
        applyTheme()
        editorChanged()
        hints.track(root)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(canvasView)
    }

    // MARK: Tools

    func setTool(_ tool: EditorTool) {
        if editor.floating != nil, tool != canvasView.tool { editor.stampFloating() }
        canvasView.tool = tool
        toolChanged()
        view.window?.makeFirstResponder(canvasView)
    }

    /// Plan 6's name.
    func setMode(_ mode: EditorMode) { setTool(mode) }

    func toolChanged() {
        palette.select(canvasView.tool)
        optionsBar.show(for: canvasView.tool, brush: editor.brushCharacter)
        updateHint()
    }

    private func optionsChanged() {
        editor.leaveCopyWhenMoving = optionsBar.settings.leaveCopy
        optionsBar.show(for: canvasView.tool, brush: editor.brushCharacter)
        view.window?.makeFirstResponder(canvasView)
    }

    /// Runs a keyboard action (ruling 13).
    func run(_ action: EditorAction) {
        switch action {
        case .toolDraw: setTool(.draw)
        case .toolSelect: setTool(.select)
        case .toolLine: setTool(.line)
        case .toolBox: setTool(.box)
        case .toolFill: setTool(.fill)
        case .toolText: setTool(.text)
        case .toolBrush: setTool(.brush)
        case .toolEyedropper: setTool(.eyedropper)
        case .swapColours: editor.swapDrawingColours()
        case .toggleInsert: editor.insertMode.toggle()
        case .insertLine: editor.insertLine()
        case .deleteLine: editor.deleteLine()
        case .insertColumn: editor.insertColumn()
        case .deleteColumn: editor.deleteColumn()
        case .liftSelection: if !editor.liftSelection() { NSSound.beep() }
        case .mirrorHorizontal: if !editor.transformSelection(.mirrorHorizontal) { NSSound.beep() }
        case .mirrorVertical: if !editor.transformSelection(.mirrorVertical) { NSSound.beep() }
        case .rotate180: if !editor.transformSelection(.rotate180) { NSSound.beep() }
        case .rotateClockwise: if !editor.transformSelection(.rotateClockwise) { NSSound.beep() }
        case .characterPicker:
            characterPanel.picker.selected = editor.brushCharacter
            if characterPanel.isVisible { characterPanel.orderOut(nil) } else { characterPanel.orderFront(nil) }
        case .nextLineStyle:
            let all = LineStyle.allCases
            optionsBar.setLineStyle(all[((all.firstIndex(of: optionsBar.settings.lineStyle) ?? 0) + 1) % all.count])
            transientHint = "Line style: \(optionsBar.settings.lineStyle.label)"
        case .toggleGrid: canvasView.showGrid.toggle()
        }
        editorChanged()
    }

    // MARK: Controls

    func chooseForeground(_ index: Int) { editor.setForeground(index) }
    func chooseBackground(_ index: Int) { editor.setBackground(index) }
    func setIce(_ on: Bool) { editor.setIceColors(on) }

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

    func editorChanged() {
        canvasView.refresh()
        guard isViewLoaded else { return }
        if lastBlockSet != editor.blockSet {
            lastBlockSet = editor.blockSet
            setPopup.selectItem(at: editor.blockSet)
            for (index, button) in blockButtons.enumerated() {
                let code = CanvasEditor.blockSets[editor.blockSet][index]
                button.title = "F\(index + 1) \(Character(CP437.unicode[Int(code)]))"
                button.toolTip = "F\(index + 1): type \(CharacterInfo(code: code).summary)"
            }
            hints.track(root)
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
        insertLabel.stringValue = editor.insertMode ? "INS" : "OVR"
        optionsBar.show(for: canvasView.tool, brush: editor.brushCharacter)
        let layers = editor.layers
        var text = "\(editor.cursor.x + 1), \(editor.cursor.y + 1)  |  \(editor.canvas.columns) x \(editor.canvas.height)"
        if let s = editor.selection { text += "  |  selection \(s.width) x \(s.height)" }
        text += "  |  \(editor.insertMode ? "INS" : "OVR")"
        text += "  |  layer \(editor.activeLayer + 1)/\(layers.count) \(layers[editor.activeLayer].name)"
        text += "  |  set \(editor.blockSet + 1)  |  zoom \(Int(canvasView.zoom))x  |  \(editor.canvas.fontName)"
        if let floating = editor.floating {
            let verb = floating.liftedFrom == nil ? "Pasting" : (floating.leavesCopy ? "Moving a copy" : "Moving")
            text = "\(verb) \(floating.region.width) x \(floating.region.height) at \(floating.x + 1), \(floating.y + 1)"
                + (editor.transparentPaste ? " (transparent)" : "")
        }
        status.stringValue = text
        layersPanel.refresh()
        hints.track(layersPanel)
        updateHint()
        onChange?()
    }

    /// The hint line: a drag in progress, else the control under the mouse, else the floating
    /// block's keys, else the current tool's hint.
    private func updateHint() {
        guard isViewLoaded else { return }
        if let transientHint { hintLabel.stringValue = transientHint; return }
        if let hoverHint { hintLabel.stringValue = hoverHint; return }
        if let floating = editor.floating {
            hintLabel.stringValue = floating.liftedFrom == nil
                ? "Arrows or drag to move, Return or click outside to place, Esc to cancel, T for transparent"
                : "Arrows or drag to move, Return or click outside to place, Esc puts it back, T for transparent"
            return
        }
        hintLabel.stringValue = canvasView.tool.tooltip(ShortcutStore.shared.shortcuts)
    }

    // MARK: Theme (ruling 14)

    func toggleTheme() {
        EditorTheme.current = EditorTheme.current == .retro ? .native : .retro
        applyTheme()
    }

    func applyTheme() {
        guard isViewLoaded else { return }
        let retro = EditorTheme.current == .retro
        root.wantsLayer = true
        root.layer?.backgroundColor = retro ? EditorTheme.dosBlue.cgColor : nil
        root.appearance = retro ? NSAppearance(named: .darkAqua) : nil
        status.textColor = retro ? EditorTheme.dosYellow : .secondaryLabelColor
        hintLabel.textColor = retro ? .white : .secondaryLabelColor
        let font = retro ? NSFont.monospacedSystemFont(ofSize: 11, weight: .bold) : NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        status.font = font
        hintLabel.font = retro ? NSFont.monospacedSystemFont(ofSize: 11, weight: .regular) : NSFont.systemFont(ofSize: 11)
        insertLabel.textColor = retro ? EditorTheme.dosCyan : .labelColor
        for view in chrome {
            view.wantsLayer = true
            view.layer?.backgroundColor = retro ? EditorTheme.dosBlue.cgColor : nil
        }
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

    func renameLayer(_ index: Int) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Rename Layer"
        let field = NSTextField(string: editor.layers[index].name)
        field.frame = NSRect(x: 0, y: 0, width: 220, height: 24)
        field.toolTip = "The layer's name (kept in the project file)"
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.editor.renameLayer(index, to: field.stringValue) }
        }
    }

    func showReplace() {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = editor.selection == nil ? "Replace in the whole canvas" : "Replace in the selection"
        alert.informativeText = "Cells that match every part you set are changed; parts left empty or set to Any / Keep are ignored."
        let options = ReplaceOptionsView()
        alert.accessoryView = options
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let count = self.editor.replace(matching: options.find, with: options.replacement)
            self.transientHint = "Replaced \(count) \(count == 1 ? "cell" : "cells")"
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.transientHint = nil }
        }
    }
}

/// One editor window. The first Save asks where (and in which format); later saves go there.
final class EditorWindowController: NSWindowController, NSWindowDelegate {
    private static var open: Set<EditorWindowController> = []
    let editorController: EditorViewController
    private(set) var fileURL: URL?
    private(set) var format: SaveFormat
    private let name: String

    /// Where Save Project writes (chosen on the first Save Project, or the project that was opened).
    private(set) var projectURL: URL?

    @discardableResult
    static func open(canvas: EditCanvas, name: String, suggestedFormat: SaveFormat = .ansi) -> EditorWindowController {
        open(editor: CanvasEditor(canvas: canvas), name: name, format: suggestedFormat)
    }

    @discardableResult
    static func open(editor: CanvasEditor, name: String, format: SaveFormat = .ansi) -> EditorWindowController {
        let controller = EditorWindowController(editor: editor, name: name, format: format)
        open.insert(controller)
        controller.showWindow(nil)
        return controller
    }

    static let projectType = UTType(filenameExtension: ArtProject.fileExtension, conformingTo: .json) ?? .json

    /// Tools > Open Project...: a layered `.ansiproj` file (ruling 11).
    static func openProject() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [projectType]
        panel.message = "Choose an AnsiView project (.ansiproj) to edit with its layers."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let project = try ArtProject(data: try Data(contentsOf: url))
            let controller = open(editor: CanvasEditor(project: project), name: url.deletingPathExtension().lastPathComponent)
            controller.projectURL = url
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    /// Tools > Save Project...: keeps the layers. The art files themselves always flatten.
    @discardableResult
    func saveProject() -> Bool {
        var url = projectURL
        if url == nil {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [Self.projectType]
            panel.nameFieldStringValue = "\(fileURL?.deletingPathExtension().lastPathComponent ?? name).\(ArtProject.fileExtension)"
            panel.message = "Saves every layer. ANSI, BinaryText and XBin saves write the visible layers flattened."
            guard panel.runModal() == .OK else { return false }
            url = panel.url
        }
        guard let url else { return false }
        do {
            try editor.project.data().write(to: url, options: .atomic)
            projectURL = url
            editor.markSaved()
            return true
        } catch {
            NSAlert(error: error).runModal()
            return false
        }
    }

    /// Tells the user what an opened file carries that the editor cannot keep (ruling 12).
    func showOpenReport(_ notes: [String]) {
        guard !notes.isEmpty, let window else { return }
        let alert = NSAlert()
        alert.messageText = "Some parts of this file cannot be kept"
        alert.informativeText = notes.map { "\u{2022} " + $0 }.joined(separator: "\n")
            + "\n\nEverything else (SAUCE title, author, group, comments, font, flags and date) is kept."
        alert.beginSheetModal(for: window)
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
        let controller = open(canvas: EditCanvas(file: player.source), name: "\(base) (edited)",
                              suggestedFormat: SaveFormat.suggested(for: player.source.format))
        if let url = player.fileURL, let data = try? Data(contentsOf: url) {
            controller.showOpenReport(SaucePreservation.openReport(data: data, fileExtension: url.pathExtension))
        }
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

    private init(editor: CanvasEditor, name: String, format: SaveFormat) {
        self.name = name
        self.format = format
        editorController = EditorViewController(editor: editor, name: name)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1340, height: 900),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.minSize = NSSize(width: 640, height: 360)
        window.title = name
        window.tabbingMode = .disallowed
        // Full screen editing (the green button, View > Enter Full Screen, Tools > Full Screen Editing).
        window.collectionBehavior.insert(.fullScreenPrimary)
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

    /// Plain art files hold the visible layers flattened (ruling 10); anything the format cannot
    /// hold is reported first and the user may cancel (ruling 12).
    private func write(to url: URL, format: SaveFormat) -> Bool {
        let flat = editor.flattenedCanvas
        var notes = SaucePreservation.saveReport(flat, format: format)
        if editor.layers.count > 1 {
            notes.append("The \(editor.layers.count) layers are saved flattened (hidden layers left out); Tools > Save Project keeps them.")
        }
        if !notes.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Saving as \(format.label) changes some things"
            alert.informativeText = notes.map { "\u{2022} " + $0 }.joined(separator: "\n")
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
        }
        do {
            try ArtWriter.data(flat, format: format).write(to: url, options: .atomic)
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
