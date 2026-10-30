import AnsiCore
import AppKit

/// Dials a queue of BBSes with redial (ruling 7), showing the retro dialing panel (ruling 8).
/// Each attempt connects a hidden terminal window, which comes forward when the BBS answers.
final class DialSession: NSObject, NSWindowDelegate {
    private static var active: Set<DialSession> = []

    let store: DialingDirectoryStore
    private(set) var queue: RedialQueue
    private let entries: [UUID: BBSEntry]
    let panelView = RetroScreenView()
    private(set) var panel: NSPanel?
    /// The attempt in progress, or the session that answered (watched for busy text).
    private(set) var terminal: TerminalWindowController?
    private(set) var stateText = "Starting"
    /// Every state shown, for the harness.
    private(set) var history: [String] = []
    private var phaseStart = ProcessInfo.processInfo.systemUptime
    private var waitUntil: TimeInterval?
    private var waitTotal: TimeInterval = 0
    private var timer: Timer?
    private var stopButton: NSButton?
    private var dialNowButton: NSButton?
    private var skipButton: NSButton?
    /// Shows the panel window (off in the harness, which draws `panelView` itself).
    var showsWindow = true
    /// Called when the session ends: connected, exhausted or stopped.
    var onFinish: ((RedialQueue.State) -> Void)?

    @discardableResult
    static func start(entries: [BBSEntry], store: DialingDirectoryStore, showsWindow: Bool = true) -> DialSession {
        let session = DialSession(entries: entries, store: store)
        session.showsWindow = showsWindow
        active.insert(session)
        session.begin()
        return session
    }

    private init(entries list: [BBSEntry], store: DialingDirectoryStore) {
        self.store = store
        entries = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        queue = RedialQueue(ids: list.map(\.id), passes: store.directory.redialAttempts, delay: store.directory.redialDelay)
        super.init()
    }

    private func begin() {
        if showsWindow { makePanel() }
        let tick = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(tick, forMode: .common)
        timer = tick
        handle(queue.start())
    }

    // MARK: Queue

    private func handle(_ step: RedialQueue.Step) {
        switch step {
        case .dial(let id): dial(id)
        case .wait(let seconds, _):
            waitTotal = seconds
            waitUntil = ProcessInfo.processInfo.systemUptime + seconds
            let outcome = queue.lastOutcome?.label ?? "Failed"
            setState("\(outcome): \(lastDialed). Next")
        case .exhausted:
            let outcome = queue.lastOutcome.map { " (\($0.label))" } ?? ""
            setState("No answer after \(queue.passes) \(queue.passes == 1 ? "pass" : "passes")\(outcome)")
            finish()
        case .none: break
        }
    }

    private func dial(_ id: UUID) {
        waitUntil = nil
        phaseStart = ProcessInfo.processInfo.systemUptime
        // Take the saved copy: the directory may have changed since Dial was pressed.
        guard let entry = store.entry(id) ?? entries[id] else {
            handle(queue.failed(.failed("The BBS was deleted from the directory.")))
            return
        }
        let controller = TerminalWindowController.make(entry: entry, store: store)
        controller.terminal.showsAlerts = false
        controller.terminal.onStateChange = { [weak self, weak controller] state in
            guard let self, let controller, controller === self.terminal else { return }
            self.attemptChanged(state)
        }
        controller.terminal.onBusy = { [weak self, weak controller] in
            guard let self, let controller, controller === self.terminal else { return }
            self.busyAfterAnswer()
        }
        terminal = controller
        lastDialed = entry.name
        setState("Connecting")
        controller.terminal.connect()
    }

    /// The name of the BBS dialed last, for the status after it fails.
    private var lastDialed = ""

    private func attemptChanged(_ state: BBSClientState) {
        switch state {
        case .connecting: break
        case .connected:
            queue.connected()
            setState("Connected")
            terminal?.terminal.showsAlerts = true
            terminal?.present()
            // The panel goes; the session stays a while in case the BBS says it is busy.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                guard let self, case .connected = self.queue.state else { return }
                self.panel?.orderOut(nil)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + TerminalViewController.busyWindow + 1) { [weak self] in
                guard let self, case .connected = self.queue.state else { return }
                self.finish()
            }
        case .closed(let error):
            guard case .dialing = queue.state else { return }
            let outcome = error.map(DialOutcome.init) ?? .failed("The connection was closed.")
            terminal?.dismiss()
            terminal = nil
            handle(queue.failed(outcome))
        case .idle: break
        }
    }

    private func busyAfterAnswer() {
        terminal?.dismiss()
        terminal = nil
        panel?.orderFront(nil)
        handle(queue.busyAfterConnect())
    }

    // MARK: Buttons

    @objc func stop(_ sender: Any?) {
        guard !finished else { panel?.close(); return }
        if case .dialing = queue.state {
            terminal?.dismiss()
            terminal = nil
        }
        queue.stop()
        setState("Stopped")
        finish()
        panel?.close()
    }

    @objc func dialNow(_ sender: Any?) {
        handle(queue.delayElapsed())
    }

    @objc func skip(_ sender: Any?) {
        if case .dialing = queue.state {
            terminal?.dismiss()
            terminal = nil
        }
        handle(queue.skip())
    }

    // MARK: Panel

    private func tick() {
        if let waitUntil, ProcessInfo.processInfo.systemUptime >= waitUntil {
            self.waitUntil = nil
            handle(queue.delayElapsed())
        }
        redraw()
    }

    private func setState(_ text: String) {
        stateText = text
        history.append(text)
        redraw()
    }

    var status: DialPanelStatus {
        let id = queue.current
        let entry = id.flatMap { store.entry($0) ?? entries[$0] }
        let now = ProcessInfo.processInfo.systemUptime
        var seconds = Int(now - phaseStart)
        var fraction: Double?
        if let waitUntil {
            seconds = Int((waitUntil - now).rounded(.up))
            fraction = waitTotal > 0 ? min(1, max(0, 1 - (waitUntil - now) / waitTotal)) : 1
        }
        return DialPanelStatus(name: entry?.name ?? "", address: entry?.address ?? "", attempt: queue.pass,
                               passes: queue.passes, position: queue.position, queueCount: queue.ids.count,
                               state: stateText, seconds: max(0, seconds), waitFraction: fraction)
    }

    func redraw() {
        panelView.show(DialPanelScreen.make(status))
        let waiting: Bool
        if case .waiting = queue.state { waiting = true } else { waiting = false }
        dialNowButton?.isEnabled = waiting
        let running: Bool
        switch queue.state {
        case .dialing, .waiting: running = true
        default: running = false
        }
        skipButton?.isEnabled = running && queue.ids.count > 1
        stopButton?.title = running ? "Stop" : "Close"
    }

    private func makePanel() {
        let font = BitmapFont.vga
        let art = NSSize(width: DialPanelScreen.columns * font.width, height: DialPanelScreen.rows * font.height)
        let size = NSSize(width: art.width * 1.25, height: art.height * 1.25 + 44)
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .utilityWindow],
                            backing: .buffered, defer: false)
        panel.title = "Dialing"
        panel.backgroundColor = .black
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        let content = panel.contentView!
        panelView.frame = NSRect(x: 0, y: 44, width: size.width, height: size.height - 44)
        panelView.autoresizingMask = [.width, .height]
        content.addSubview(panelView)
        let stop = NSButton(title: "Stop", target: self, action: #selector(stop(_:)))
        stop.toolTip = "Stop dialing. A call in progress is hung up."
        stop.keyEquivalent = "\u{1b}"
        let now = NSButton(title: "Dial Now", target: self, action: #selector(dialNow(_:)))
        now.toolTip = "Skip the redial wait and dial the next BBS at once."
        let skip = NSButton(title: "Skip", target: self, action: #selector(skip(_:)))
        skip.toolTip = "Give up on this BBS for this pass and dial the next one in the queue."
        let row = NSStackView(views: [skip, now, stop])
        row.frame = NSRect(x: 0, y: 8, width: size.width - 12, height: 28)
        row.alignment = .centerY
        row.spacing = 8
        row.setHuggingPriority(.defaultLow, for: .horizontal)
        row.edgeInsets = NSEdgeInsets(top: 0, left: size.width - 300, bottom: 0, right: 0)
        content.addSubview(row)
        stopButton = stop
        dialNowButton = now
        skipButton = skip
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    func windowWillClose(_ notification: Notification) {
        panelClosed = true
        if case .dialing = queue.state { stop(nil) } else if case .waiting = queue.state { stop(nil) }
        // A finished session stayed alive only for its panel (for example "No answer").
        if finished { Self.active.remove(self) }
    }

    /// True while the session is kept alive (dialing, watching for busy text, or showing its panel).
    var isActive: Bool { Self.active.contains(self) }

    private var finished = false
    private var panelClosed = false

    private func finish() {
        guard !finished else { return }
        finished = true
        timer?.invalidate()
        timer = nil
        if case .connected = queue.state {
            terminal?.terminal.onBusy = nil
            terminal?.terminal.onStateChange = nil
            panel?.close()
        }
        redraw()
        onFinish?(queue.state)
        // The panel's buttons and delegate are weak: keep the session until the panel closes.
        if panel == nil || panelClosed { Self.active.remove(self) }
    }
}
