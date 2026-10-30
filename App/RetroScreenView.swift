import AnsiCore
import AppKit

/// Shows a retro text screen (the dialing directory, entry editor and dial panel) drawn by
/// `AnsiRenderer` with a bitmap font, scaled to fit with square pixels, and turns keys and
/// clicks into `FormKey`s and cell positions.
final class RetroScreenView: NSView {
    var font: BitmapFont = .vga { didSet { rendered = nil; needsDisplay = true } }
    var onKey: ((FormKey) -> Void)?
    /// Row and column of a click, and the click count.
    var onClick: ((Int, Int, Int) -> Void)?
    /// A drag from one row to another (mouse down row, mouse up row).
    var onDrag: ((Int, Int) -> Void)?
    var onScroll: ((Int) -> Void)?
    private var screen: AnsiScreen?
    private var rendered: CGImage?
    private var dragStartRow: Int?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func show(_ screen: AnsiScreen) {
        self.screen = screen
        rendered = nil
        needsDisplay = true
    }

    /// The rendered screen (for tests and the harness).
    func renderedImage() -> CGImage? {
        if rendered == nil, var screen {
            screen.font = font
            rendered = AnsiRenderer.render(screen, options: RenderOptions(font: font, scale: 1, blinkVisible: true))?.image
        }
        return rendered
    }

    private var artRect: NSRect {
        guard let screen else { return .zero }
        let width = CGFloat(screen.columns * font.width)
        let height = CGFloat(screen.rows.count * font.height)
        guard width > 0, height > 0 else { return .zero }
        // Nearest neighbour scaling to fit, as the terminal window does.
        let scale = min(bounds.width / width, bounds.height / height)
        let size = NSSize(width: (width * scale).rounded(), height: (height * scale).rounded())
        return NSRect(x: ((bounds.width - size.width) / 2).rounded(), y: ((bounds.height - size.height) / 2).rounded(),
                      width: size.width, height: size.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()
        guard let image = renderedImage(), let context = NSGraphicsContext.current?.cgContext else { return }
        let rect = artRect
        context.interpolationQuality = .none
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }

    /// The text cell under a point in the view, if any.
    func cell(at point: NSPoint) -> (row: Int, column: Int)? {
        guard let screen else { return nil }
        let rect = artRect
        guard rect.contains(point), rect.width > 0 else { return nil }
        let column = Int((point.x - rect.minX) / rect.width * CGFloat(screen.columns))
        let row = Int((point.y - rect.minY) / rect.height * CGFloat(screen.rows.count))
        return (min(screen.rows.count - 1, row), min(screen.columns - 1, column))
    }

    // MARK: Input

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, window?.firstResponder === self,
              !event.modifierFlags.contains(.command) else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) { super.keyDown(with: event); return }
        if let key = Self.formKey(for: event) { onKey?(key) }
    }

    static func formKey(for event: NSEvent) -> FormKey? {
        let flags = event.modifierFlags
        switch event.keyCode {
        case 126: return flags.contains(.option) ? .moveUp : .up
        case 125: return flags.contains(.option) ? .moveDown : .down
        case 123: return .left
        case 124: return .right
        case 36, 76: return .enter
        case 53: return .escape
        case 48: return flags.contains(.shift) ? .backTab : .tab
        case 51: return .backspace
        case 117: return .forwardDelete
        case 115: return .home
        case 119: return .end
        case 116: return .pageUp
        case 121: return .pageDown
        default:
            guard let characters = event.characters, let first = characters.first,
                  !first.unicodeScalars.contains(where: { (0xF700...0xF8FF).contains($0.value) || $0.value < 0x20 }) else { return nil }
            return .character(first)
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        guard let cell = cell(at: point) else { return }
        dragStartRow = cell.row
        onClick?(cell.row, cell.column, event.clickCount)
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStartRow = nil }
        let point = convert(event.locationInWindow, from: nil)
        guard let start = dragStartRow, let cell = cell(at: point), cell.row != start else { return }
        onDrag?(start, cell.row)
    }

    override func scrollWheel(with event: NSEvent) {
        let lines = Int((event.scrollingDeltaY / (event.hasPreciseScrollingDeltas ? 16 : 1)).rounded())
        if lines != 0 { onScroll?(lines) }
    }
}
