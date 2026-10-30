import AnsiCore
import AppKit
import UniformTypeIdentifiers

/// Draws a BBS terminal screen with the bitmap font renderer. Each row is rendered once and kept
/// until its cells change, so streamed text re-renders only the rows it touches.
final class TerminalView: NSView {
    weak var controller: TerminalViewController?
    var pasteboard = NSPasteboard.general
    var font: BitmapFont = .vga { didSet { rowCache.removeAll(); needsDisplay = true } }
    /// Rows rendered since the view was made (for measuring).
    private(set) var rowRenderCount = 0
    private var rowCache: [Int: (cells: [AnsiCell], blinkOn: Bool, image: CGImage)] = [:]

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The art's rectangle in the view: scaled to fit, aspect kept, centered.
    private var artRect: NSRect {
        guard let controller else { return .zero }
        let width = CGFloat(controller.emulator.columns * font.width)
        let height = CGFloat(controller.emulator.rows * font.height)
        let scale = max(0.1, min(bounds.width / width, bounds.height / height))
        let size = NSSize(width: (width * scale).rounded(), height: (height * scale).rounded())
        return NSRect(x: ((bounds.width - size.width) / 2).rounded(), y: ((bounds.height - size.height) / 2).rounded(),
                      width: size.width, height: size.height)
    }

    /// Renders every visible row whose cells changed; returns the rows to draw.
    @discardableResult
    func prepareRows() -> [CGImage?] {
        guard let controller else { return [] }
        let screen = controller.visibleScreen()
        let blinkOn = controller.blinkOn
        var images: [CGImage?] = []
        images.reserveCapacity(screen.rows.count)
        for (index, cells) in screen.rows.enumerated() {
            let hasBlink = cells.contains { $0.blink }
            let phase = hasBlink ? blinkOn : true
            if let cached = rowCache[index], cached.blinkOn == phase, cached.cells == cells {
                images.append(cached.image)
                continue
            }
            var row = AnsiScreen(columns: screen.columns, rows: [cells])
            row.font = font
            let image = AnsiRenderer.render(row, options: RenderOptions(font: font, scale: 1, blinkVisible: phase))?.image
            rowRenderCount += 1
            if let image { rowCache[index] = (cells, phase, image) } else { rowCache[index] = nil }
            images.append(image)
        }
        if rowCache.count > screen.rows.count {
            for key in rowCache.keys where key >= screen.rows.count { rowCache[key] = nil }
        }
        return images
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()
        guard let controller else { return }
        let images = prepareRows()
        let art = artRect
        guard !images.isEmpty, art.width > 0 else { return }
        let rowHeight = art.height / CGFloat(images.count)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.interpolationQuality = .none
        for (index, image) in images.enumerated() {
            guard let image else { continue }
            let rect = NSRect(x: art.minX, y: art.minY + CGFloat(index) * rowHeight, width: art.width, height: rowHeight)
            // The context is flipped; draw the image upright.
            context.saveGState()
            context.translateBy(x: rect.minX, y: rect.maxY)
            context.scaleBy(x: 1, y: -1)
            context.draw(image, in: CGRect(origin: .zero, size: rect.size))
            context.restoreGState()
        }
        // A VGA style underline cursor, in the colour of the text under it.
        let emulator = controller.emulator
        if controller.cursorOn, emulator.cursorVisible, controller.scrollOffset == 0 {
            let cellWidth = art.width / CGFloat(emulator.columns)
            let cursor = emulator.cursor
            let cell = emulator.grid[cursor.row][cursor.column]
            let thickness = max(2, (rowHeight / 8).rounded())
            NSColor(red: CGFloat(cell.fg.r) / 255, green: CGFloat(cell.fg.g) / 255, blue: CGFloat(cell.fg.b) / 255, alpha: 1).setFill()
            NSRect(x: art.minX + CGFloat(cursor.column) * cellWidth,
                   y: art.minY + CGFloat(cursor.row + 1) * rowHeight - thickness,
                   width: cellWidth, height: thickness).fill()
        }
    }

    // MARK: Keyboard and mouse

    /// Plain keys (Space, letters with no Command) go to the BBS, not to menu shortcuts.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, window?.firstResponder === self,
              !event.modifierFlags.contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }
        keyDown(with: event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) { super.keyDown(with: event); return }
        controller?.handleKey(event)
    }

    override func scrollWheel(with event: NSEvent) {
        let lines = Int((event.scrollingDeltaY / (event.hasPreciseScrollingDeltas ? 16 : 1)).rounded())
        guard lines != 0 else { return }
        controller?.scrollBack(by: lines)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    // MARK: Menu actions

    @objc func copy(_ sender: Any?) {
        guard let controller else { return }
        pasteboard.clearContents()
        pasteboard.setString(TextConvert.utf8Text(controller.visibleScreen()), forType: .string)
    }

    @objc func paste(_ sender: Any?) {
        guard let text = pasteboard.string(forType: .string) else { return }
        controller?.sendText(text)
    }
}

/// One BBS session: the connection, the emulator, pacing, capture and the status line.
final class TerminalViewController: NSViewController {
    static let sizes: [(columns: Int, rows: Int)] = [(80, 25), (80, 43), (80, 50), (132, 25), (132, 50)]

    let entry: BBSEntry
    private(set) var emulator: TerminalEmulator
    private(set) var client: BBSClient?
    let terminalView = TerminalView()
    var sound: PlaybackSound?
    /// Alerts on connection errors (off in tests).
    var showsAlerts = true
    var onTitleChange: ((String) -> Void)?

    private(set) var scrollOffset = 0
    private(set) var cursorOn = true
    private(set) var blinkOn = true
    private(set) var baud: Int
    private(set) var statusText = ""
    private var pacer: LinePacer
    private var capture: FileHandle?
    private var captureName: String?
    private var shownChanges = -1
    private var shownBells = 0
    private var lastTick = ProcessInfo.processInfo.systemUptime
    private var displayTimer: Timer?
    private var blinkTimer: Timer?
    private var stateText = "Not connected"
    private let statusLabel = NSTextField(labelWithString: "")

    init(entry: BBSEntry) {
        self.entry = entry
        emulator = TerminalEmulator(columns: entry.columns, rows: entry.rows, encoding: entry.encoding)
        baud = entry.baud
        pacer = LinePacer(baud: entry.baud)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit {
        displayTimer?.invalidate()
        blinkTimer?.invalidate()
        client?.disconnect()
        try? capture?.close()
    }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 960, height: 622))
        terminalView.controller = self
        terminalView.font = BitmapFont.named(entry.fontName)
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        container.addSubview(terminalView)
        container.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            terminalView.topAnchor.constraint(equalTo: container.topAnchor),
            terminalView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            terminalView.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -4),
            statusLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            statusLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            statusLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4),
        ])
        view = container
        updateStatus()
        startTimers()
    }

    // MARK: Connection

    func connect() {
        _ = view
        client?.disconnect()
        let client = BBSClient(host: entry.host, port: entry.port, mode: entry.mode,
                               columns: emulator.columns, rows: emulator.rows)
        client.onData = { [weak self] bytes in self?.receive(bytes) }
        client.onState = { [weak self] state in self?.clientChanged(state) }
        self.client = client
        if PlaybackSpeed.modemSounds { sound?.playbackStateChanged(.connecting) }
        client.connect()
    }

    func disconnect() {
        client?.disconnect()
    }

    func reconnect() {
        connect()
    }

    private func clientChanged(_ state: BBSClientState) {
        switch state {
        case .idle: stateText = "Not connected"
        case .connecting: stateText = "Connecting..."
        case .connected: stateText = "Connected"
        case .closed(let error):
            sound?.playbackStateChanged(.quiet)
            if let error {
                stateText = error.message
                if showsAlerts { showError(error) }
            } else {
                stateText = "Disconnected"
            }
        }
        updateStatus()
    }

    private func showError(_ error: BBSConnectionError) {
        let alert = NSAlert()
        alert.messageText = error == .closedByRemote ? "Disconnected" : "Could not connect to \(entry.name)"
        alert.informativeText = error.message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Reconnect")
        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            if response == .alertSecondButtonReturn { self?.reconnect() }
        }
        if let window = view.window, window.isVisible {
            alert.beginSheetModal(for: window, completionHandler: handler)
        } else {
            handler(alert.runModal())
        }
    }

    /// Bytes from the BBS (telnet already removed): captured as they arrive, shown at the line speed.
    func receive(_ bytes: [UInt8]) {
        if let capture { try? capture.write(contentsOf: Data(bytes)) }
        pacer.push(bytes)
        if baud == 0 { tick(elapsed: 0) }
    }

    /// One display step: releases paced bytes into the emulator, answers status requests and redraws.
    func tick(elapsed: TimeInterval) {
        let due = pacer.release(elapsed: elapsed)
        if !due.isEmpty {
            emulator.feed(due)
            let replies = emulator.takeReplies()
            if !replies.isEmpty { client?.send(replies) }
        }
        if emulator.bells != shownBells {
            shownBells = emulator.bells
            NSSound.beep()
        }
        if emulator.changeCount != shownChanges {
            shownChanges = emulator.changeCount
            terminalView.needsDisplay = true
        }
    }

    private func startTimers() {
        let display = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = ProcessInfo.processInfo.systemUptime
                self.tick(elapsed: now - self.lastTick)
                self.lastTick = now
            }
        }
        RunLoop.main.add(display, forMode: .common)
        displayTimer = display
        let blink = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.cursorOn.toggle()
                self.blinkOn.toggle()
                self.terminalView.needsDisplay = true
            }
        }
        RunLoop.main.add(blink, forMode: .common)
        blinkTimer = blink
    }

    func blinkPhaseForTesting(cursorOn: Bool) {
        self.cursorOn = cursorOn
        blinkOn = true
        terminalView.needsDisplay = true
    }

    // MARK: Screen

    func visibleScreen() -> AnsiScreen {
        emulator.screen(scrollOffset: scrollOffset)
    }

    func scrollBack(by lines: Int) {
        let offset = min(max(0, scrollOffset + lines), emulator.scrollback.count)
        guard offset != scrollOffset else { return }
        scrollOffset = offset
        terminalView.needsDisplay = true
        updateStatus()
    }

    func setSize(columns: Int, rows: Int) {
        emulator.resize(columns: columns, rows: rows)
        client?.resize(columns: emulator.columns, rows: emulator.rows)
        scrollOffset = 0
        terminalView.needsDisplay = true
        updateStatus()
    }

    func setBaud(_ value: Int) {
        baud = value
        pacer.baud = value
        updateStatus()
    }

    func clearScrollback() {
        emulator.clearScrollback()
        scrollOffset = 0
        updateStatus()
    }

    // MARK: Input

    func handleKey(_ event: NSEvent) {
        let flags = event.modifierFlags
        let ignoring = event.charactersIgnoringModifiers ?? ""
        let scalar = ignoring.unicodeScalars.first.map { Int($0.value) } ?? 0
        if flags.contains(.shift), scalar == NSPageUpFunctionKey { scrollBack(by: emulator.rows - 1); return }
        if flags.contains(.shift), scalar == NSPageDownFunctionKey { scrollBack(by: -(emulator.rows - 1)); return }
        let key: TerminalKey?
        switch event.keyCode {
        case 36, 76: key = .returnKey
        case 51: key = .backspace
        case 48: key = .tab
        case 53: key = .escape
        case 126: key = .up
        case 125: key = .down
        case 124: key = .right
        case 123: key = .left
        case 115: key = .home
        case 119: key = .end
        case 116: key = .pageUp
        case 121: key = .pageDown
        case 117: key = .forwardDelete
        case 114: key = .insert
        default:
            if (NSF1FunctionKey...NSF12FunctionKey).contains(scalar) {
                key = .function(scalar - NSF1FunctionKey + 1)
            } else {
                key = nil
            }
        }
        if let key {
            send(TerminalInput.bytes(for: key, backspaceSendsDelete: entry.backspaceSendsDelete))
            return
        }
        if flags.contains(.control), let letter = ignoring.first, let bytes = TerminalInput.control(letter) {
            send(bytes)
            return
        }
        guard let characters = event.characters, !characters.isEmpty,
              !characters.unicodeScalars.contains(where: { (0xF700...0xF8FF).contains($0.value) }) else { return }
        sendText(characters)
    }

    func sendText(_ text: String) {
        send(TerminalInput.text(text, encoding: entry.encoding))
    }

    func sendUsername() {
        guard let name = entry.username, !name.isEmpty else { return }
        send(TerminalInput.text(name, encoding: entry.encoding) + [13])
    }

    private func send(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        if scrollOffset != 0 {
            scrollOffset = 0
            terminalView.needsDisplay = true
            updateStatus()
        }
        client?.send(bytes)
    }

    // MARK: Capture

    func startCapture() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "ans") ?? .data]
        panel.nameFieldStringValue = "\(entry.name) capture.ans"
        let begin: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.startCapture(to: url)
        }
        if let window = view.window { panel.beginSheetModal(for: window, completionHandler: begin) } else { begin(panel.runModal()) }
    }

    func startCapture(to url: URL) {
        stopCapture()
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: url) else {
            let alert = NSAlert()
            alert.messageText = "Could not start the capture"
            alert.informativeText = "\(url.lastPathComponent) could not be written."
            alert.runModal()
            return
        }
        capture = handle
        captureName = url.lastPathComponent
        updateStatus()
    }

    func stopCapture() {
        try? capture?.close()
        capture = nil
        captureName = nil
        updateStatus()
    }

    var isCapturing: Bool { capture != nil }

    // MARK: Status

    private func updateStatus() {
        var parts = [entry.address, stateText, baud == 0 ? "Unlimited" : "\(baud) baud",
                     "\(emulator.columns)x\(emulator.rows)", entry.encoding.label]
        if entry.mode == .raw { parts.append("Raw TCP") }
        if let captureName { parts.append("Capturing to \(captureName)") }
        if scrollOffset > 0 { parts.append("Scrollback -\(scrollOffset)") }
        statusText = parts.joined(separator: "  |  ")
        statusLabel.stringValue = statusText
        statusLabel.toolTip = statusText
    }
}

/// A terminal window. Closing it ends the session.
final class TerminalWindowController: NSWindowController, NSWindowDelegate {
    private static var open: Set<TerminalWindowController> = []
    let terminal: TerminalViewController

    @discardableResult
    static func open(entry: BBSEntry) -> TerminalWindowController {
        let controller = TerminalWindowController(entry: entry)
        open.insert(controller)
        controller.showWindow(nil)
        controller.window?.makeFirstResponder(controller.terminal.terminalView)
        controller.terminal.connect()
        return controller
    }

    /// The terminal in the key (or main) window, for the Terminal menu.
    static var focused: TerminalViewController? {
        for window in [NSApp.keyWindow, NSApp.mainWindow].compactMap({ $0 }) {
            if let controller = window.windowController as? TerminalWindowController { return controller.terminal }
        }
        return nil
    }

    private init(entry: BBSEntry) {
        terminal = TerminalViewController(entry: entry)
        terminal.sound = ModemSoundPlayer()
        let font = BitmapFont.named(entry.fontName)
        let art = NSSize(width: entry.columns * font.width, height: entry.rows * font.height)
        let visible = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        let scale = max(0.5, min(1.5, (visible.width - 40) / art.width, (visible.height - 80) / art.height))
        let size = NSSize(width: (art.width * scale).rounded(), height: (art.height * scale).rounded() + 22)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = entry.name
        window.backgroundColor = .black
        window.minSize = NSSize(width: 320, height: 220)
        super.init(window: window)
        window.delegate = self
        terminal.view.frame = window.contentView?.bounds ?? .zero
        terminal.view.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(terminal.view)
        window.center()
        window.setFrameAutosaveName("BBS Terminal")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func windowWillClose(_ notification: Notification) {
        terminal.stopCapture()
        terminal.disconnect()
        Self.open.remove(self)
    }
}
