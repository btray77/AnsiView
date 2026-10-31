import AnsiCore
import AppKit
import UniformTypeIdentifiers

/// One side of a comparison.
struct ComparePiece {
    let name: String
    let file: ArtFile
}

/// Two pieces side by side with the cells that look different tinted (plan 9 item 39, ruling 3).
/// The panes scroll together; Cmd-G and Cmd-Shift-G (or the arrows in the bar) step through the
/// rows that have differences.
final class CompareViewController: NSViewController {
    let left: ComparePiece
    let right: ComparePiece
    let diff: CellDiff
    let leftCanvas: CompareCanvas
    let rightCanvas: CompareCanvas
    let leftScroll = NSScrollView()
    let rightScroll = NSScrollView()
    private let summaryLabel = NSTextField(labelWithString: "")
    private let highlightBox = NSButton(checkboxWithTitle: "Highlight differences", target: nil, action: nil)
    private var syncing = false
    private(set) var currentRow: Int?

    init(left: ComparePiece, right: ComparePiece) {
        self.left = left
        self.right = right
        let a = AnsiAnalysis(left.file).finalScreen, b = AnsiAnalysis(right.file).finalScreen
        diff = CellDiff(a, b)
        leftCanvas = CompareCanvas(screen: a, file: left.file, diff: diff)
        rightCanvas = CompareCanvas(screen: b, file: right.file, diff: diff)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// "3 of 2,000 cells differ, on 2 rows", or that nothing differs.
    var summary: String {
        guard diff.count > 0 else { return "No differences: every cell looks the same" }
        let number = NumberFormatter()
        number.numberStyle = .decimal
        let rows = diff.rowsWithDifferences.count
        return "\(number.string(from: diff.count as NSNumber) ?? "\(diff.count)") of "
            + "\(number.string(from: diff.total as NSNumber) ?? "\(diff.total)") cells differ, on \(rows) row\(rows == 1 ? "" : "s")"
    }

    var highlightsOn = true {
        didSet {
            leftCanvas.overlayHidden = !highlightsOn
            rightCanvas.overlayHidden = !highlightsOn
            highlightBox.state = highlightsOn ? .on : .off
        }
    }

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(white: 0.08, alpha: 1).cgColor
        func title(_ text: String) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: 12, weight: .semibold)
            label.textColor = .white
            label.lineBreakMode = .byTruncatingMiddle
            label.translatesAutoresizingMaskIntoConstraints = false
            return label
        }
        let leftTitle = title(left.name), rightTitle = title(right.name)
        summaryLabel.stringValue = summary
        summaryLabel.textColor = diff.count == 0 ? .systemGreen : NSColor(white: 0.9, alpha: 1)
        highlightBox.state = .on
        highlightBox.target = self
        highlightBox.action = #selector(highlightToggled(_:))
        highlightBox.toolTip = "Tint the cells that look different in red. Cells only one piece has (different sizes) count as different."
        let previous = NSButton(image: NSImage(systemSymbolName: "chevron.up", accessibilityDescription: "Previous difference")!,
                                target: self, action: #selector(previousPressed(_:)))
        previous.toolTip = "Previous row with a difference (Cmd-Shift-G)"
        let next = NSButton(image: NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Next difference")!,
                            target: self, action: #selector(nextPressed(_:)))
        next.toolTip = "Next row with a difference (Cmd-G)"
        let help = Hint.button(.compare)
        let bar = NSStackView(views: [summaryLabel, highlightBox, previous, next, help])
        bar.spacing = 10
        bar.appearance = NSAppearance(named: .darkAqua)
        bar.translatesAutoresizingMaskIntoConstraints = false
        for (scroll, canvas) in [(leftScroll, leftCanvas), (rightScroll, rightCanvas)] {
            let clip = NSClipView()
            clip.drawsBackground = true
            clip.backgroundColor = .black
            scroll.contentView = clip
            scroll.documentView = canvas
            scroll.hasVerticalScroller = true
            scroll.hasHorizontalScroller = true
            scroll.autohidesScrollers = true
            scroll.backgroundColor = .black
            scroll.translatesAutoresizingMaskIntoConstraints = false
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(clipMoved(_:)),
                                                   name: NSView.boundsDidChangeNotification, object: clip)
            container.addSubview(scroll)
        }
        for view in [leftTitle, rightTitle, bar] as [NSView] { container.addSubview(view) }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            bar.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            leftTitle.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 8),
            leftTitle.leadingAnchor.constraint(equalTo: leftScroll.leadingAnchor),
            leftTitle.trailingAnchor.constraint(lessThanOrEqualTo: leftScroll.trailingAnchor),
            rightTitle.topAnchor.constraint(equalTo: leftTitle.topAnchor),
            rightTitle.leadingAnchor.constraint(equalTo: rightScroll.leadingAnchor),
            rightTitle.trailingAnchor.constraint(lessThanOrEqualTo: rightScroll.trailingAnchor),
            leftScroll.topAnchor.constraint(equalTo: leftTitle.bottomAnchor, constant: 4),
            rightScroll.topAnchor.constraint(equalTo: leftScroll.topAnchor),
            leftScroll.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
            rightScroll.bottomAnchor.constraint(equalTo: leftScroll.bottomAnchor),
            leftScroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            rightScroll.leadingAnchor.constraint(equalTo: leftScroll.trailingAnchor, constant: 8),
            rightScroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            rightScroll.widthAnchor.constraint(equalTo: leftScroll.widthAnchor),
        ])
        view = container
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    /// Keeps the two panes at the same place (in cells, so pieces with other fonts still line up).
    @objc private func clipMoved(_ note: Notification) {
        guard !syncing, let moved = note.object as? NSClipView else { return }
        let (source, target) = moved === leftScroll.contentView ? (leftCanvas, rightScroll) : (rightCanvas, leftScroll)
        let targetCanvas = target.documentView as! CompareCanvas
        syncing = true
        let origin = moved.bounds.origin
        let point = NSPoint(x: origin.x / max(1, source.frame.width) * targetCanvas.frame.width,
                            y: origin.y / max(1, source.frame.height) * targetCanvas.frame.height)
        target.contentView.scroll(to: point)
        target.reflectScrolledClipView(target.contentView)
        syncing = false
    }

    func showNextDifference() { step(forward: true) }
    func showPreviousDifference() { step(forward: false) }

    private func step(forward: Bool) {
        guard let row = diff.nextRow(after: currentRow, forward: forward) else { NSSound.beep(); return }
        currentRow = row
        let rect = leftCanvas.rowRect(row)
        let clip = leftScroll.contentView
        let y = max(0, min(leftCanvas.frame.height - clip.bounds.height, rect.midY - clip.bounds.height / 2))
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
        leftScroll.reflectScrolledClipView(clip)
        leftCanvas.markRow(row)
        rightCanvas.markRow(row)
    }

    @objc private func highlightToggled(_ sender: NSButton) { highlightsOn = sender.state == .on }
    @objc private func nextPressed(_ sender: Any?) { showNextDifference() }
    @objc private func previousPressed(_ sender: Any?) { showPreviousDifference() }

    // Edit > Find > Find Next / Previous step through differences here.
    @objc func artFindNext(_ sender: Any?) { showNextDifference() }
    @objc func artFindPrevious(_ sender: Any?) { showPreviousDifference() }
    @objc func showArtFind(_ sender: Any?) { showNextDifference() }
}

/// One piece's finished art at one point per font pixel, with a red tint over differing cells.
final class CompareCanvas: NSView {
    private let columns: Int
    private let rows: Int
    private let cellSize: CGSize
    private let overlay = CALayer()
    private let rowMark = NSView()
    /// Differing cells this canvas tints (for checks).
    let overlayCellCount: Int

    init(screen: AnsiScreen, file: ArtFile, diff: CellDiff) {
        columns = diff.columns
        rows = diff.rows
        var padded = screen
        padded.columns = diff.columns
        padded.rows = (0..<diff.rows).map { y in
            var row = y < screen.rows.count ? screen.rows[y] : []
            if row.count < diff.columns { row += Array(repeating: AnsiCell(), count: diff.columns - row.count) }
            return row
        }
        var options = RenderOptions(for: padded, scale: 1)
        options.ninePixel = file.ninePixel
        let image = AnsiRenderer.render(padded, options: options)
        let cellWidth = CGFloat(screen.font.width + (file.ninePixel ? 1 : 0))
        cellSize = CGSize(width: cellWidth, height: CGFloat(screen.font.height))
        // Only cells this piece has can be tinted on it; the rest show as tinted empty space.
        var count = 0
        let width = Int(cellSize.width) * max(1, columns), height = Int(cellSize.height) * max(1, rows)
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.setFillColor(NSColor.systemRed.withAlphaComponent(0.45).cgColor)
        for y in 0..<diff.rows {
            for x in 0..<diff.columns where diff.differs(x: x, y: y) {
                count += 1
                context?.fill(CGRect(x: CGFloat(x) * cellSize.width, y: CGFloat(height) - CGFloat(y + 1) * cellSize.height,
                                     width: cellSize.width, height: cellSize.height))
            }
        }
        overlayCellCount = count
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.contents = image?.image
        layer?.contentsGravity = .resize
        layer?.magnificationFilter = .nearest
        overlay.contents = context?.makeImage()
        overlay.contentsGravity = .resize
        overlay.magnificationFilter = .nearest
        overlay.actions = ["hidden": NSNull(), "bounds": NSNull(), "position": NSNull()]
        rowMark.wantsLayer = true
        rowMark.layer?.borderColor = NSColor.systemYellow.cgColor
        rowMark.layer?.borderWidth = 1.5
        rowMark.isHidden = true
        layer?.addSublayer(overlay)
        addSubview(rowMark)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("\(count) differing cells tinted red")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    var overlayHidden: Bool {
        get { overlay.isHidden }
        set { overlay.isHidden = newValue }
    }

    /// The outlined row's frame (for checks).
    var markedRowFrame: CGRect? { rowMark.isHidden ? nil : rowMark.frame }

    /// Row `row` in this view's top down points.
    func rowRect(_ row: Int) -> CGRect {
        CGRect(x: 0, y: CGFloat(row) * cellSize.height, width: bounds.width, height: cellSize.height)
    }

    /// Outlines the row the difference stepping is on.
    func markRow(_ row: Int) {
        // A subview in this flipped view's points: no layer flipping to get wrong.
        rowMark.frame = rowRect(row).insetBy(dx: 0, dy: -1)
        rowMark.isHidden = false
    }

    override func layout() {
        super.layout()
        overlay.frame = layer?.bounds ?? bounds
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        overlay.frame = CGRect(origin: .zero, size: newSize)
    }
}

final class CompareWindowController: NSWindowController, NSWindowDelegate {
    private static var open: Set<CompareWindowController> = []

    @discardableResult
    static func open(left: ComparePiece, right: ComparePiece) -> CompareWindowController {
        let controller = CompareWindowController(left: left, right: right)
        open.insert(controller)
        controller.showWindow(nil)
        return controller
    }

    /// Asks for a file to compare with `piece`.
    static func chooseAndCompare(with piece: ComparePiece) {
        let panel = NSOpenPanel()
        panel.message = "Choose a piece to compare with \(piece.name)."
        panel.prompt = "Compare"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let file = ArtFile(data: try Data(contentsOf: url), fileExtension: url.pathExtension)
            open(left: piece, right: ComparePiece(name: url.lastPathComponent, file: file))
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private init(left: ComparePiece, right: ComparePiece) {
        let controller = CompareViewController(left: left, right: right)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1340, height: 560),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Compare \(left.name) and \(right.name)"
        window.subtitle = controller.summary
        window.minSize = NSSize(width: 500, height: 300)
        super.init(window: window)
        window.delegate = self
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 1340, height: 560))
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func windowWillClose(_ notification: Notification) { Self.open.remove(self) }
}

extension AnsiCanvasView {
    /// File > Compare With...: the piece in this window against a file the user picks.
    @objc func compareWithFile(_ sender: Any?) {
        guard let player else { NSSound.beep(); return }
        let name = player.fileURL?.lastPathComponent ?? player.artName ?? "This piece"
        CompareWindowController.chooseAndCompare(with: ComparePiece(name: name, file: player.source))
    }
}
