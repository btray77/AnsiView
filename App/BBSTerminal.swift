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
    /// Pictures already turned into images, by position and size.
    private var imageCache: [String: CGImage] = [:]

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
        let width = CGFloat(controller.emulator.columns * font.width) * CGFloat(controller.emulator.horizontalStretch)
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
        // RIPscrip: the graphics screen lies under the text, whose black background is see-through.
        let overlay = controller.scrollOffset == 0 ? controller.emulator.overlay() : nil
        if let overlay {
            context.saveGState()
            context.translateBy(x: art.minX, y: art.maxY)
            context.scaleBy(x: 1, y: -1)
            context.draw(overlay, in: CGRect(origin: .zero, size: art.size))
            context.restoreGState()
        }
        for (index, row) in images.enumerated() {
            guard let row else { continue }
            let image = overlay == nil ? row : (row.copy(maskingColorComponents: [0, 0, 0, 0, 0, 0]) ?? row)
            let rect = NSRect(x: art.minX, y: art.minY + CGFloat(index) * rowHeight, width: art.width, height: rowHeight)
            // The context is flipped; draw the image upright.
            context.saveGState()
            context.translateBy(x: rect.minX, y: rect.maxY)
            context.scaleBy(x: 1, y: -1)
            context.draw(image, in: CGRect(origin: .zero, size: rect.size))
            context.restoreGState()
        }
        // Sixel and iTerm2 pictures, over the cells they cover.
        let placed = controller.emulator.images(scrollOffset: controller.scrollOffset)
        if !placed.isEmpty {
            let cellWidth = art.width / CGFloat(controller.emulator.columns)
            context.saveGState()
            context.clip(to: art)
            var kept: [String: CGImage] = [:]
            for picture in placed {
                let key = "\(picture.id)"
                guard let image = imageCache[key] ?? picture.image.cgImage else { continue }
                kept[key] = image
                let rect = CGRect(x: art.minX + CGFloat(picture.column) * cellWidth, y: art.minY + CGFloat(picture.line) * rowHeight,
                                  width: CGFloat(picture.columns) * cellWidth, height: CGFloat(picture.rows) * rowHeight)
                context.saveGState()
                context.translateBy(x: rect.minX, y: rect.maxY)
                context.scaleBy(x: 1, y: -1)
                context.draw(image, in: CGRect(origin: .zero, size: rect.size))
                context.restoreGState()
            }
            imageCache = kept
            context.restoreGState()
        }
        // A VGA style underline cursor, in the colour of the text under it.
        let emulator = controller.emulator
        if controller.cursorOn, emulator.cursorVisible, controller.scrollOffset == 0 {
            let cellWidth = art.width / CGFloat(emulator.columns)
            let cursor = emulator.cursor
            let shown = controller.visibleScreen().rows
            guard cursor.row < shown.count, cursor.column < shown[cursor.row].count else { return }
            let cell = shown[cursor.row][cursor.column]
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

    /// The cell under a mouse event (zero based), when it is on the art.
    private func cell(at event: NSEvent) -> (column: Int, row: Int)? {
        guard let controller else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let art = artRect
        guard art.contains(point), art.width > 0, art.height > 0 else { return nil }
        return (Int((point.x - art.minX) / art.width * CGFloat(controller.emulator.columns)),
                Int((point.y - art.minY) / art.height * CGFloat(controller.emulator.rows)))
    }

    override func mouseUp(with event: NSEvent) {
        if let controller, !(controller.emulator is RIPTerminal), let cell = cell(at: event) {
            controller.mouseReport(column: cell.column, row: cell.row, button: 0, pressed: false)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        if let controller, let cell = cell(at: event) {
            controller.mouseReport(column: cell.column, row: cell.row, button: 2, pressed: true)
        }
    }

    override func rightMouseUp(with event: NSEvent) {
        if let controller, let cell = cell(at: event) {
            controller.mouseReport(column: cell.column, row: cell.row, button: 2, pressed: false)
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        // A BBS that asked for mouse reports (CSI ? 1000 h) hears the click on its cell.
        if let controller, !(controller.emulator is RIPTerminal), let cell = cell(at: event) {
            controller.mouseReport(column: cell.column, row: cell.row, button: 0, pressed: true)
            return
        }
        // RIPscrip mouse fields and buttons: the click in the graphics screen's own pixels.
        // Not while scrolled back: the picture (and its buttons) is hidden then.
        guard let controller, controller.scrollOffset == 0, controller.emulator is RIPTerminal else { return }
        let point = convert(event.locationInWindow, from: nil)
        let art = artRect
        guard art.contains(point), art.width > 0, art.height > 0 else { return }
        let canvas = RIPCanvas()
        let x = Int((point.x - art.minX) / art.width * CGFloat(canvas.width))
        let y = Int((point.y - art.minY) / art.height * CGFloat(canvas.height))
        controller.click(x: x, y: y)
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

    /// The BBS; transfer choices made in the terminal update it (see `updateEntry`).
    private(set) var entry: BBSEntry
    /// Called when the terminal changed the entry's transfer protocol or download folder.
    var onEntryChange: ((BBSEntry, Set<TransferSetting>) -> Void)?
    /// The entry as saved in the directory now (nil for an unsaved entry).
    var savedEntry: (() -> BBSEntry?)?
    /// File transfers (App/TerminalTransfers.swift).
    private(set) lazy var transfers = TerminalTransfers(terminal: self)
    private(set) var emulator: any TerminalEngine
    /// Watches the start of the session for another terminal type (only suggests).
    private var detector = TerminalDetector()
    /// What the BBS sent since connecting (up to `replayLimit`), replayed when the type is switched.
    private var sessionStart: [UInt8] = []
    static let replayLimit = 256 * 1024
    /// The suggestion bar shown when the detector thinks the BBS expects another terminal type.
    let suggestionBar = NSStackView()
    private let suggestionLabel = NSTextField(labelWithString: "")
    private(set) var suggestedEmulation: TerminalEmulation?
    /// Called when the terminal type was switched here, to save it in the directory.
    var onEmulationChange: ((BBSEntry) -> Void)?
    /// The IEMSI handshake, when the entry turns it on and has a username and saved password.
    private var iemsi: IEMSIClient?
    /// Asks about TLS certificates macOS does not trust (the harness swaps in one that answers by itself).
    lazy var certificates = CertificatePrompt(window: { [weak self] in self?.view.window })
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
    /// Bytes released to the screen so far (after pacing).
    private(set) var shownBytes = 0
    private var pacer: LinePacer
    /// ANSI music in the received stream (App/TerminalMusic.swift).
    private(set) lazy var music = TerminalMusic(mode: entry.musicMode)
    private var capture: FileHandle?
    private var captureName: String?
    private var shownChanges = -1
    private var shownBells = 0
    private var lastTick = ProcessInfo.processInfo.systemUptime
    private var displayTimer: Timer?
    private var blinkTimer: Timer?
    private var stateText = "Not connected"
    private let statusLabel = NSTextField(labelWithString: "")

    /// Option-1 ... Option-0 for every BBS (the entry's own macros win).
    var globalMacros: [String]
    /// Where Send Password and the login script read the password; nil sends none.
    var passwords: PasswordStore?
    /// Every connection state, for the dialer.
    var onStateChange: ((BBSClientState) -> Void)?
    /// The BBS showed its busy text soon after answering.
    var onBusy: (() -> Void)?
    /// Called on every successful connect (the directory counts the call).
    var callRecorder: ((UUID) -> Void)?
    /// Seconds after connecting during which the busy text counts.
    static let busyWindow: TimeInterval = 30
    private(set) var loginRunner: LoginScriptRunner?
    private(set) var loginText: String?
    /// Why capture on connect did not start (kept apart from the login status).
    private(set) var captureProblem: String?
    private var busyMatcher: PromptMatcher?
    private var connectedAt: TimeInterval = 0
    private var captureFolder: URL?

    init(entry: BBSEntry, globalMacros: [String] = [], passwords: PasswordStore? = nil) {
        self.entry = entry
        self.globalMacros = globalMacros
        self.passwords = passwords
        emulator = Self.configured(TerminalEngines.make(entry.emulation, columns: entry.columns, rows: entry.rows,
                                                        encoding: entry.encoding, iceColors: entry.iceColors), entry: entry)
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
        captureFolder?.stopAccessingSecurityScopedResource()
    }

    /// The entry's modem sound choice, or Playback > Modem Sounds.
    var playsModemSound: Bool {
        switch entry.modemSound {
        case .on: return true
        case .off: return false
        case .playbackSetting: return PlaybackSpeed.modemSounds
        }
    }

    private func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 960, height: 622))
        terminalView.controller = self
        terminalView.font = emulator.font ?? BitmapFont.named(entry.fontName)
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        buildSuggestionBar()
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        container.addSubview(terminalView)
        container.addSubview(statusLabel)
        container.addSubview(suggestionBar)
        transfers.install(over: terminalView, in: container)
        NSLayoutConstraint.activate([
            suggestionBar.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            suggestionBar.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            suggestionBar.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 8),
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

    /// Starts a fresh session: the previous client is silenced and closed, and its unshown
    /// backlog, parser state and screen are dropped so nothing leaks into the new session.
    func connect() {
        _ = view
        if let old = client {
            old.onState = nil
            old.onData = nil
            old.disconnect()
        }
        transfers.reset()
        pacer = LinePacer(baud: baud)
        music.reset(mode: entry.musicMode)
        emulator = Self.configured(TerminalEngines.make(entry.emulation, columns: emulator.columns, rows: emulator.rows,
                                                        encoding: entry.encoding, iceColors: entry.iceColors), entry: entry)
        terminalView.font = emulator.font ?? BitmapFont.named(entry.fontName)
        detector = TerminalDetector(encoding: entry.encoding)
        sessionStart = []
        iemsi = nil
        if entry.iemsi, let name = entry.username, !name.isEmpty,
           let password = entry.credentialKey.flatMap({ passwords?.password(for: $0) }), !password.isEmpty {
            iemsi = IEMSIClient(login: IEMSI.Login(name: name, password: password, rows: emulator.rows,
                                                   columns: emulator.columns, emulation: IEMSI.crtName(entry.emulation)))
        }
        hideSuggestion()
        scrollOffset = 0
        shownBells = 0
        loginRunner = nil
        loginText = nil
        captureProblem = nil
        busyMatcher = nil
        terminalView.needsDisplay = true
        var settings = TransportSettings(entry: entry)
        if entry.mode == .rlogin, entry.rloginClientIsPassword {
            settings.password = entry.credentialKey.flatMap { passwords?.password(for: $0) }
        }
        let client = BBSClient(host: entry.host, port: entry.port, settings: settings,
                               columns: emulator.columns, rows: emulator.rows, terminalTypes: entry.terminalTypes,
                               transport: makeTransport())
        client.certificateVerifier = certificates
        // A client certificate from the Keychain, for TLS boards that ask for one.
        client.clientIdentity = entry.tlsClientIdentity.flatMap(TLSClientIdentities.identity(reference:))
        client.onData = { [weak self] bytes in self?.receive(bytes) }
        client.onState = { [weak self] state in self?.clientChanged(state) }
        self.client = client
        if playsModemSound { sound?.playbackStateChanged(.connecting) }
        client.connect()
    }

    /// Asks about SSH host keys (the harness swaps in one that answers by itself).
    lazy var hostKeys = HostKeyPrompt(window: { [weak self] in self?.view.window })
    /// Why the SSH key file was not used for this connection.
    private(set) var transportProblem: String?
    /// Asks keyboard-interactive SSH questions (the harness swaps in one that answers by itself).
    lazy var sshPrompts = SSHPromptSheet(window: { [weak self] in self?.view.window })
    /// The weak SSH algorithms this connection uses (shown as a status note).
    private(set) var sshWeakAlgorithms: [String] = []

    /// The app's SSH transport (AnsiCore makes the others).
    private func makeTransport() -> BBSTransport? {
        transportProblem = nil
        sshWeakAlgorithms = []
        guard entry.mode == .ssh else { return nil }
        let entry = self.entry, passwords = self.passwords
        let ssh = SSHTransport(host: entry.host, port: entry.port, settings: TransportSettings(entry: entry),
                               login: SSHLogin(username: SSHLogin.username(for: entry)),
                               loadLogin: { SSHLogin.load(entry: entry, passwords: passwords) },
                               columns: emulator.columns, rows: emulator.rows, queue: .main, verifier: hostKeys)
        ssh.onLoginProblem = { [weak self] problem in
            self?.transportProblem = problem
            self?.updateStatus()
        }
        ssh.onNegotiated = { [weak self] algorithms in
            self?.sshWeakAlgorithms = algorithms.weakAlgorithms
            self?.updateStatus()
        }
        ssh.askPrompts = { [weak self] question, done in
            guard let self else { return done(nil) }
            self.sshPrompts.ask(question, done: done)
        }
        return ssh
    }

    // MARK: Login, busy text and capture on connect

    /// The BBS answered: count the call, watch for the busy text, start the capture and the login script.
    private func answered() {
        connectedAt = now()
        callRecorder?(entry.id)
        // Busy text matters only to the dialer, which hangs up and dials the next BBS.
        let busy = LoginStep.patterns(in: entry.busyText)
        busyMatcher = busy.isEmpty || onBusy == nil ? nil : PromptMatcher(patterns: busy, encoding: entry.encoding)
        if entry.captureOnConnect { startCaptureOnConnect() }
        // SSH and RLogin already sent the name (and SSH the password), so the script waits for Terminal > Log In.
        let protocolLogin = entry.mode == .ssh || entry.mode == .rlogin
        if entry.autoLogin, !protocolLogin, let name = entry.username, !name.isEmpty { runLogin() }
    }

    /// Terminal > Log In: runs the entry's login script from its first step.
    func runLogin() {
        guard client?.state == .connected, !transfers.isActive else { return }
        let password = entry.credentialKey.flatMap { passwords?.password(for: $0) }
        var runner = LoginScriptRunner(steps: entry.loginScript, username: entry.username, password: password,
                                       encoding: entry.encoding)
        loginText = "Logging in"
        let actions = runner.start(now: now())
        loginRunner = runner
        perform(actions)
        updateStatus()
    }

    private func perform(_ actions: [LoginAction]) {
        for action in actions {
            switch action {
            case .send(let bytes): if !transfers.isActive { client?.send(bytes) }
            case .finished: loginText = "Login script done"
            case .failed(let message): loginText = message
            }
        }
        if !actions.isEmpty { updateStatus() }
    }

    private func watch(_ bytes: [UInt8]) {
        // Busy first, so a full BBS is not sent the username.
        if busyMatcher != nil {
            if now() - connectedAt > Self.busyWindow {
                busyMatcher = nil
            } else if busyMatcher?.feed(bytes) == true {
                busyMatcher = nil
                loginRunner = nil
                loginText = "The BBS is busy"
                updateStatus()
                onBusy?()
                return
            }
        }
        if var runner = loginRunner, runner.isRunning {
            let actions = runner.feed(bytes, now: now())
            loginRunner = runner
            perform(actions)
        }
    }

    private func startCaptureOnConnect() {
        guard let bookmark = entry.captureFolderBookmark else {
            captureProblem = "Capture on connect is on, but no capture folder is chosen"
            return
        }
        var stale = false
        guard let folder = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil,
                                    bookmarkDataIsStale: &stale) else {
            captureProblem = "The capture folder could not be found. Choose it again in the dialing directory"
            return
        }
        if captureFolder != folder {
            captureFolder?.stopAccessingSecurityScopedResource()
            captureFolder = folder.startAccessingSecurityScopedResource() ? folder : nil
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HHmmss"
        let safeName = entry.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let url = folder.appendingPathComponent("\(safeName) \(formatter.string(from: Date())).ans")
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: url) else {
            captureProblem = "The capture folder \(folder.lastPathComponent) cannot be written, so this session is not captured"
            return
        }
        startCapture(handle: handle, name: url.lastPathComponent)
    }

    /// Terminal > Send Password: the Keychain password and Return.
    func sendPassword() {
        guard let key = entry.credentialKey, let password = passwords?.password(for: key), !password.isEmpty else {
            loginText = "No password is saved for this BBS. Add one in the dialing directory."
            updateStatus()
            NSSound.beep()
            return
        }
        send(emulator.text(password, encoding: entry.encoding) + returnBytes)
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
        case .connected:
            stateText = "Connected"
            answered()
        case .closed(let error):
            transfers.connectionClosed()
            sound?.playbackStateChanged(.quiet)
            loginRunner = nil
            busyMatcher = nil
            if let error {
                stateText = error.message
                // A BBS hanging up after logoff is normal: the status line says so, no alert.
                if showsAlerts, error != .closedByRemote, !error.isHostKeyAnswer { showError(error) }
            } else {
                stateText = "Disconnected"
            }
        }
        updateStatus()
        onStateChange?(state)
    }

    private func showError(_ error: BBSConnectionError) {
        let alert = NSAlert()
        alert.messageText = "Could not connect to \(entry.name)"
        alert.informativeText = error.message
        alert.addButton(withTitle: "Reconnect")
        alert.addButton(withTitle: "Close")
        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            if response == .alertFirstButtonReturn { self?.reconnect() } else { self?.view.window?.performClose(nil) }
        }
        if let window = view.window, window.isVisible {
            alert.beginSheetModal(for: window, completionHandler: handler)
        } else {
            handler(alert.runModal())
        }
    }

    /// Bytes from the BBS (telnet already removed): to a running file transfer, held while the
    /// transfer bar asks, or to the screen.
    func receive(_ bytes: [UInt8]) {
        transfers.received(bytes)
    }

    /// Terminal output: captured as it arrives, shown at the line speed.
    func showIncoming(_ bytes: [UInt8]) {
        if let capture {
            do { try capture.write(contentsOf: Data(bytes)) } catch { captureFailed(error) }
        }
        // Prompts are matched as they arrive, not as the speed emulation shows them.
        watch(bytes)
        if !detector.isFinished, let suggestion = detector.feed(bytes),
           TerminalDetector.shouldSuggest(suggestion, current: entry.emulation) {
            suggest(suggestion)
        }
        if iemsi != nil, var client = iemsi {
            let reply = client.feed(bytes)
            iemsi = client
            if !reply.isEmpty {
                client.isFinished ? (loginText = "IEMSI login sent") : ()
                send(reply)
            }
        }
        pacer.push(bytes)
        if baud == 0 { tick(elapsed: 0) }
    }

    /// One display step: releases paced bytes into the emulator, answers status requests and redraws.
    func tick(elapsed: TimeInterval) {
        // A file transfer has the line: the screen, music and login script wait.
        if transfers.isActive { return }
        // Foreground ANSI music holds the line: nothing more is released until it ends.
        let due = music.screenBytes(music.isHolding ? [] : pacer.release(elapsed: elapsed))
        if !due.isEmpty {
            shownBytes += due.count
            emulator.feed(due)
            remember(due)
            let replies = emulator.takeReplies()
            if !replies.isEmpty { client?.send(replies) }
            applySpeedRequest()
        }
        pumpRIP()
        // A CTerm loadable font the BBS selected (or went back from).
        let font = emulator.font ?? BitmapFont.named(entry.fontName)
        if font.name != terminalView.font.name || font.height != terminalView.font.height {
            terminalView.font = font
            if var ansi = emulator as? TerminalEmulator {
                ansi.imageCellSize = (font.width, font.height)
                emulator = ansi
            }
        }
        if emulator.bells != shownBells {
            shownBells = emulator.bells
            NSSound.beep()
        }
        if emulator.changeCount != shownChanges {
            shownChanges = emulator.changeCount
            terminalView.needsDisplay = true
        }
        if var runner = loginRunner, runner.isRunning {
            let actions = runner.tick(now: now())
            loginRunner = runner
            perform(actions)
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

    // MARK: File transfers

    /// A transfer takes the line: what waited for the screen is drawn now (music bytes removed,
    /// not played), and nothing more is drawn until `resumeAfterTransfer`.
    func pauseForTransfer() {
        let saved = pacer.baud
        pacer.baud = 0
        let backlog = pacer.release(elapsed: 0)
        pacer.baud = saved
        let due = music.suspend(drawing: backlog)
        if !due.isEmpty {
            shownBytes += due.count
            emulator.feed(due)
            remember(due)
            let replies = emulator.takeReplies()
            if !replies.isEmpty { client?.send(replies) }
        }
        terminalView.needsDisplay = true
        updateStatus()
    }

    func resumeAfterTransfer() {
        music.resumeAfterTransfer()
        lastTick = now()
        updateStatus()
        view.window?.makeFirstResponder(terminalView)
    }

    /// Changes the entry (from the transfer choosers) and tells the directory which settings changed.
    func updateEntry(_ settings: Set<TransferSetting>, _ change: (inout BBSEntry) -> Void) {
        change(&entry)
        onEntryChange?(entry, settings)
    }

    /// Picks up transfer settings edited in the dialing directory while this window was open.
    func syncTransferSettings() {
        guard let saved = savedEntry?() else { return }
        entry = entry.merging(transferSettings: [.protocolChoice, .downloadFolder], from: saved)
        entry.zmodemAutoAccept = saved.zmodemAutoAccept
    }

    // MARK: Screen

    func visibleScreen() -> AnsiScreen {
        emulator.screen(scrollOffset: scrollOffset)
    }

    func scrollBack(by lines: Int) {
        let offset = min(max(0, scrollOffset + lines), emulator.scrollbackCount)
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
        // During a file transfer only Escape (Cancel) does anything.
        if transfers.isActive {
            if event.keyCode == 53 { transfers.cancel() } else { NSSound.beep() }
            return
        }
        let flags = event.modifierFlags
        let ignoring = event.charactersIgnoringModifiers ?? ""
        let scalar = ignoring.unicodeScalars.first.map { Int($0.value) } ?? 0
        if flags.contains(.shift), scalar == NSPageUpFunctionKey { scrollBack(by: emulator.rows - 1); return }
        if flags.contains(.shift), scalar == NSPageDownFunctionKey { scrollBack(by: -(emulator.rows - 1)); return }
        if flags.contains(.option), !flags.contains(.control), let digit = ignoring.first,
           let slot = MacroSet.slot(forDigit: digit), sendMacro(slot: slot) {
            return
        }
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
        if key == .returnKey, let command = ripHotkey(0x0D) {
            send(command)
            return
        }
        if let key {
            send(emulator.bytes(for: key, backspaceSendsDelete: entry.backspaceSendsDelete))
            return
        }
        if flags.contains(.control), let letter = ignoring.first, let bytes = emulator.control(letter) {
            send(bytes)
            return
        }
        guard let characters = event.characters, !characters.isEmpty,
              !characters.unicodeScalars.contains(where: { (0xF700...0xF8FF).contains($0.value) }) else { return }
        // A RIPscrip button's hotkey sends the button's command instead of the key.
        if characters.utf8.count == 1, let byte = characters.utf8.first, let command = ripHotkey(byte) {
            send(command)
            return
        }
        sendText(characters)
    }

    /// The host command of the RIPscrip button a key belongs to; nil when none (or not RIP).
    private func ripHotkey(_ byte: UInt8) -> [UInt8]? {
        guard scrollOffset == 0, var rip = emulator as? RIPTerminal else { return nil }
        emulator = TerminalEmulator(columns: 1, rows: 1)
        let command = rip.hotkey(byte)
        emulator = rip
        terminalView.needsDisplay = true
        return command
    }

    func sendText(_ text: String) {
        send(emulator.text(text, encoding: entry.encoding))
    }

    /// The entry's extras for a new engine: the RIP icon folder; the picture cell size.
    static func configured(_ engine: any TerminalEngine, entry: BBSEntry) -> any TerminalEngine {
        if var rip = engine as? RIPTerminal {
            rip.files = RIPIconFolder.provider()
            return rip
        }
        if var ansi = engine as? TerminalEmulator {
            let font = ansi.font ?? BitmapFont.named(entry.fontName)
            ansi.imageCellSize = (font.width, font.height)
            return ansi
        }
        return engine
    }

    /// RIPscrip: continues drawing that waited for the next frame, and reports block transfers.
    private func pumpRIP() {
        guard let peek = emulator as? RIPTerminal, peek.hasPendingWork || peek.hasBlockTransfer else { return }
        var rip = peek
        // The engine is taken out first so the canvas is not copied when it changes.
        emulator = TerminalEmulator(columns: 1, rows: 1)
        if rip.hasPendingWork { rip.feed([]) }
        let request = rip.takeBlockTransfer()
        emulator = rip
        if let request {
            let what = request.upload ? "send \(request.fileName ?? "a file")" : "send you \(request.fileName ?? "files")"
            ripNotice = request.protocolCode == 7
                ? "RIP: the BBS will \(what) with Zmodem; it starts by itself"
                : "RIP: the BBS wants to \(what) with \(request.protocolName); use Transfer to start it"
            updateStatus()
        }
    }

    /// The last RIPscrip block transfer request, shown in the status line.
    private(set) var ripNotice: String?

    /// A mouse button on a cell, reported when the BBS asked for mouse reports.
    func mouseReport(column: Int, row: Int, button: Int, pressed: Bool) {
        guard scrollOffset == 0, !transfers.isActive else { return }
        let bytes = emulator.mouse(column: column, row: row, button: button, pressed: pressed)
        if !bytes.isEmpty { send(bytes) }
    }

    /// Atari: the inverse video key, for typing in inverse characters.
    func toggleAtariInverse() {
        guard var atari = emulator as? ATASCIITerminal else { NSSound.beep(); return }
        atari.inverseTyping.toggle()
        emulator = atari
        updateStatus()
    }

    /// Asks for the RIPscrip icon folder and gives it to a running RIP session.
    func chooseRIPIconFolder() {
        guard RIPIconFolder.choose(), var rip = emulator as? RIPTerminal else { return }
        rip.files = RIPIconFolder.provider()
        emulator = rip
    }

    /// A click on the RIPscrip screen: a mouse field or button sends its host command.
    func click(x: Int, y: Int) {
        let bytes = emulator.click(x: x, y: y)
        if !bytes.isEmpty { send(bytes) }
        terminalView.needsDisplay = true
    }

    /// Return as this terminal type sends it (CR, ATASCII EOL, the Prestel # key).
    private var returnBytes: [UInt8] { emulator.bytes(for: .returnKey, backspaceSendsDelete: false) }

    // MARK: Terminal type

    /// Keeps the most recent bytes already drawn, for replay when the terminal type is switched.
    private func remember(_ bytes: [UInt8]) {
        sessionStart += bytes
        if sessionStart.count > Self.replayLimit { sessionStart.removeFirst(sessionStart.count - Self.replayLimit) }
    }

    /// A SyncTERM speed request (CSI Ps1 ; Ps2 * r) sets the simulated line speed.
    private func applySpeedRequest() {
        guard var ansi = emulator as? TerminalEmulator, let speed = ansi.takeSpeedRequest() else { return }
        emulator = ansi
        setBaud(speed)
    }

    /// Switches this session to another terminal type, replays what the BBS sent so far, and saves it.
    func switchEmulation(to emulation: TerminalEmulation) {
        hideSuggestion()
        guard emulation != entry.emulation else { return }
        let old = entry.emulation
        // A size picked from Terminal > Size during this call is kept; the entry's defaults follow the type.
        let sessionSize = (emulator.columns, emulator.rows)
        let sizeChangedHere = sessionSize != (entry.columns, entry.rows)
        if entry.columns == old.defaultColumns { entry.columns = emulation.defaultColumns }
        if entry.rows == old.defaultRows { entry.rows = emulation.defaultRows }
        if entry.terminalType.caseInsensitiveCompare(old.terminalNames[0]) == .orderedSame {
            entry.terminalType = emulation.terminalNames[0]
        }
        entry.emulation = emulation
        emulator = Self.configured(TerminalEngines.make(emulation, columns: sizeChangedHere ? sessionSize.0 : entry.columns,
                                                        rows: sizeChangedHere ? sessionSize.1 : entry.rows, encoding: entry.encoding,
                                                        iceColors: entry.iceColors), entry: entry)
        terminalView.font = emulator.font ?? BitmapFont.named(entry.fontName)
        emulator.feed(sessionStart)
        _ = emulator.takeReplies()
        client?.resize(columns: emulator.columns, rows: emulator.rows)
        scrollOffset = 0
        terminalView.needsDisplay = true
        onEmulationChange?(entry)
        updateStatus()
    }

    /// Teletext Reveal: shows concealed text (quiz answers and the like).
    func toggleReveal() {
        guard var teletext = emulator as? TeletextTerminal else { NSSound.beep(); return }
        teletext.reveal.toggle()
        emulator = teletext
        terminalView.needsDisplay = true
    }

    private func buildSuggestionBar() {
        suggestionBar.orientation = .horizontal
        suggestionBar.spacing = 8
        suggestionBar.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
        suggestionBar.wantsLayer = true
        suggestionBar.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.95).cgColor
        suggestionBar.layer?.cornerRadius = 6
        suggestionBar.translatesAutoresizingMaskIntoConstraints = false
        suggestionLabel.font = .systemFont(ofSize: 12)
        let switchButton = NSButton(title: "Switch", target: self, action: #selector(acceptSuggestion))
        let ignore = NSButton(title: "Not Now", target: self, action: #selector(dismissSuggestion))
        suggestionBar.addArrangedSubview(suggestionLabel)
        suggestionBar.addArrangedSubview(switchButton)
        suggestionBar.addArrangedSubview(ignore)
        suggestionBar.isHidden = true
    }

    /// Shows the bar; the terminal type only changes if the user presses Switch.
    func suggest(_ emulation: TerminalEmulation) {
        suggestedEmulation = emulation
        suggestionLabel.stringValue = "This BBS looks like it expects \(emulation.label). Switch the terminal type?"
        suggestionBar.isHidden = false
    }

    private func hideSuggestion() {
        suggestedEmulation = nil
        suggestionBar.isHidden = true
    }

    @objc func acceptSuggestion() {
        if let suggestion = suggestedEmulation { switchEmulation(to: suggestion) }
        view.window?.makeFirstResponder(terminalView)
    }

    @objc func dismissSuggestion() {
        hideSuggestion()
        view.window?.makeFirstResponder(terminalView)
    }

    /// Types macro `slot` (Option-1 is 0); false when neither the entry nor the globals define it.
    @discardableResult
    func sendMacro(slot: Int) -> Bool {
        guard let text = MacroSet.text(slot: slot, entry: entry, global: globalMacros) else { return false }
        send(MacroText.bytes(text, encoding: entry.encoding))
        return true
    }

    func sendUsername() {
        guard let name = entry.username, !name.isEmpty else { return }
        send(emulator.text(name, encoding: entry.encoding) + returnBytes)
    }

    private func send(_ bytes: [UInt8]) {
        // Typing, macros, paste and the Send menu items never reach a running file transfer.
        guard !bytes.isEmpty, !transfers.isActive else { return }
        transfers.userTyped()
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

    func startCapture(handle: FileHandle, name: String) {
        stopCapture()
        capture = handle
        captureName = name
        updateStatus()
    }

    private func captureFailed(_ error: Error) {
        let name = captureName ?? "the capture file"
        stopCapture()
        stateText += ". Capture stopped: \(name) could not be written (\(error.localizedDescription))"
        updateStatus()
        if showsAlerts {
            let alert = NSAlert()
            alert.messageText = "Capture stopped"
            alert.informativeText = "\(name) could not be written: \(error.localizedDescription)"
            if let window = view.window, window.isVisible { alert.beginSheetModal(for: window) } else { alert.runModal() }
        }
    }

    var pendingBytes: Int { pacer.pending }

    func stopCapture() {
        try? capture?.close()
        capture = nil
        captureName = nil
        updateStatus()
    }

    var isCapturing: Bool { capture != nil }

    // MARK: Status

    func refreshStatus() { updateStatus() }

    private func updateStatus() {
        var parts = [entry.address, stateText, baud == 0 ? "Unlimited" : "\(baud) baud",
                     "\(emulator.columns)x\(emulator.rows)", entry.emulation.label]
        // Platform types have their own character set; the setting applies to the ANSI and VT types.
        if emulator.font == nil { parts.append(entry.encoding.label) }
        if entry.mode == .telnet, entry.telnetSecure { parts.append("Telnet over TLS") }
        if entry.mode != .telnet { parts.append(entry.mode == .webSocket && entry.webSocketSecure ? "WebSocket (wss)" : entry.mode.label) }
        if let transportProblem { parts.append(transportProblem) }
        let legacyNote = SSHCompatibility.legacyNote(weakAlgorithms: sshWeakAlgorithms)
        if let legacyNote { parts.append(legacyNote) }
        if let captureName { parts.append("Capturing to \(captureName)") }
        if scrollOffset > 0 { parts.append("Scrollback -\(scrollOffset)") }
        if let captureProblem { parts.append(captureProblem) }
        if let loginText { parts.append(loginText) }
        if let transferText = transfers.statusText { parts.append(transferText) }
        if let ripNotice { parts.append(ripNotice) }
        if (emulator as? ATASCIITerminal)?.inverseTyping == true { parts.append("Inverse typing") }
        statusText = parts.joined(separator: "  |  ")
        statusLabel.stringValue = statusText
        statusLabel.toolTip = legacyNote == nil ? statusText
            : statusText + "\n\n" + SSHCompatibility.legacyExplanation(weakAlgorithms: sshWeakAlgorithms)
    }
}

/// A terminal window. Closing it ends the session.
final class TerminalWindowController: NSWindowController, NSWindowDelegate {
    private static var open: Set<TerminalWindowController> = []
    let terminal: TerminalViewController

    /// Opens a window and connects. Saved entries (in `store`) get their call counted.
    @discardableResult
    static func open(entry: BBSEntry, store: DialingDirectoryStore = .shared) -> TerminalWindowController {
        let controller = make(entry: entry, store: store)
        controller.present()
        controller.terminal.connect()
        return controller
    }

    /// A window for `entry`, not shown and not connected (the dialer shows it when the BBS answers).
    static func make(entry: BBSEntry, store: DialingDirectoryStore = .shared) -> TerminalWindowController {
        let controller = TerminalWindowController(entry: entry)
        controller.terminal.globalMacros = store.directory.globalMacros
        controller.terminal.passwords = store.passwords
        if store.directory.entries.contains(where: { $0.id == entry.id }) {
            controller.terminal.callRecorder = { [weak store] id in store?.recordCall(id) }
            // Only the transfer choices are written back, so edits made in the directory meanwhile stay.
            controller.terminal.onEntryChange = { [weak store] changed, settings in
                store?.update { d in
                    guard let i = d.entries.firstIndex(where: { $0.id == changed.id }) else { return }
                    d.entries[i] = d.entries[i].merging(transferSettings: settings, from: changed)
                }
            }
            controller.terminal.savedEntry = { [weak store] in store?.entry(entry.id) }
            controller.terminal.onEmulationChange = { [weak store] changed in
                store?.update { d in
                    guard let i = d.entries.firstIndex(where: { $0.id == changed.id }) else { return }
                    d.entries[i].emulation = changed.emulation
                    d.entries[i].columns = changed.columns
                    d.entries[i].rows = changed.rows
                    d.entries[i].terminalType = changed.terminalType
                }
            }
        }
        open.insert(controller)
        return controller
    }

    /// The open terminal window of a dialing directory entry (screen designer upload).
    static func existing(for entryID: UUID) -> TerminalWindowController? {
        open.first { $0.terminal.entry.id == entryID }
    }

    func present() {
        showWindow(nil)
        window?.makeFirstResponder(terminal.terminalView)
    }

    /// Ends the session and closes the window (shown or not).
    func dismiss() {
        terminal.onStateChange = nil
        terminal.onBusy = nil
        terminal.stopCapture()
        terminal.disconnect()
        window?.orderOut(nil)
        Self.open.remove(self)
        window?.close()
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
        let engine = TerminalEngines.make(entry.emulation, columns: entry.columns, rows: entry.rows, encoding: entry.encoding,
                                          iceColors: false)
        let font = engine.font ?? BitmapFont.named(entry.fontName)
        let art = NSSize(width: CGFloat(entry.columns * font.width) * CGFloat(engine.horizontalStretch),
                         height: CGFloat(entry.rows * font.height))
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
        terminal.transfers.reset()
        terminal.stopCapture()
        terminal.disconnect()
        Self.open.remove(self)
    }
}

private extension BBSConnectionError {
    /// The host key alert already told the user (or the user said no), so no second alert.
    var isHostKeyAnswer: Bool {
        switch self {
        case .hostKeyChanged, .hostKeyNotTrusted: return true
        default: return false
        }
    }
}
