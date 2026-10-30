import AppKit
import os

/// Playback speeds in bits per second. 0 means draw instantly.
enum PlaybackSpeed {
    static let defaultsKey = "playbackBaud"
    /// 2400 baud was the common modem speed when most BBS animations were timed.
    static let defaultBaud = 2400
    static let choices = [300, 1200, 2400, 4800, 9600, 14400, 19200, 28800, 57600, 115200, 0]
    /// Shared between the app and the Quick Look extension.
    static let suiteName = "47HEHK53W5.com.traynham.ansiview"

    static var defaults: UserDefaults { UserDefaults(suiteName: suiteName) ?? .standard }

    static var current: Int {
        get { (defaults.object(forKey: defaultsKey) as? Int) ?? defaultBaud }
        set { defaults.set(newValue, forKey: defaultsKey) }
    }

    static func label(_ baud: Int) -> String {
        baud == 0 ? "Instant" : "\(baud) baud"
    }

    /// The next speed up (+1) or down (-1) the list. Instant is treated as the fastest.
    static func step(_ baud: Int, by direction: Int) -> Int {
        let index = choices.firstIndex(of: baud) ?? choices.firstIndex(of: defaultBaud)!
        return choices[min(choices.count - 1, max(0, index + direction))]
    }
}

/// Shows an ANSI file in a scroll view. Animated files replay at modem speed and blinking text blinks.
/// Clicking skips an animation to its end, or replays it once it has finished.
final class AnsiPlayerViewController: NSViewController {
    static let blinkInterval: TimeInterval = 0.46
    static let frameInterval: TimeInterval = 1.0 / 30.0

    let analysis: AnsiAnalysis
    let source: AnsiSource
    /// The frame currently on screen.
    private(set) var screen: AnsiScreen
    private let atlas: GlyphAtlas
    private let canvas = AnsiCanvasView()
    private let hud = NSTextField(labelWithString: "")
    private var terminal: AnsiTerminal
    private var blinkVisible = true
    private var frameTimer: Timer?
    private var blinkTimer: Timer?
    private var hudTimer: Timer?
    private var lastFrameTime: TimeInterval = 0
    private var byteCredit: Double = 0
    private var shownBaud = PlaybackSpeed.current
    private var defaultsObserver: NSObjectProtocol?

    init(source: AnsiSource) {
        self.source = source
        self.analysis = AnsiAnalysis(source)
        self.atlas = GlyphAtlas(scale: AnsiRenderer.preferredScale(rows: analysis.canvasRows))
        self.terminal = AnsiTerminal(source)
        self.screen = analysis.finalScreen
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit {
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
    }

    /// Size of the art in points, one point per VGA pixel.
    var contentSize: CGSize {
        CGSize(width: source.columns * AnsiRenderer.cellWidth,
               height: analysis.canvasRows * AnsiRenderer.cellHeight)
    }

    var isPlaying: Bool { frameTimer != nil }
    var isPaused: Bool { !isPlaying && terminal.position > 0 && !terminal.isFinished }

    override func loadView() {
        let container = NSView()
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.backgroundColor = .black
        scroll.drawsBackground = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        canvas.frame = CGRect(origin: .zero, size: contentSize)
        canvas.onClick = { [weak self] in self?.skipOrReplay() }
        canvas.player = self
        scroll.documentView = canvas
        container.addSubview(scroll)

        hud.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
        hud.textColor = .white
        hud.drawsBackground = true
        hud.backgroundColor = NSColor.black.withAlphaComponent(0.7)
        hud.alphaValue = 0
        hud.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hud)

        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            hud.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            hud.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
        ])
        view = container
        preferredContentSize = contentSize
        redraw()

        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.speedMayHaveChanged() }
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(canvas)
        if analysis.isAnimated && !isPlaying && terminal.position == 0 {
            replay()
        }
        updateBlinkTimer()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        stopPlayback()
        blinkTimer?.invalidate()
        blinkTimer = nil
    }

    // MARK: Playback

    func replay() {
        stopPlayback()
        terminal = AnsiTerminal(source)
        if PlaybackSpeed.current == 0 {
            skipToEnd()
            return
        }
        screen = terminal.screen(minimumRows: analysis.canvasRows)
        redraw()
        Logger(subsystem: "com.traynham.ansiview", category: "playback")
            .info("Playback started at \(PlaybackSpeed.current, privacy: .public) baud")
        showHUD("\(PlaybackSpeed.label(PlaybackSpeed.current))  \u{00B7}  click to skip")
        startTimer()
    }

    func skipToEnd() {
        stopPlayback()
        terminal.runToEnd()
        screen = analysis.finalScreen
        redraw()
        updateBlinkTimer()
    }

    /// Pauses a running animation, resumes a paused one, or replays a finished one.
    func togglePause() {
        if isPlaying {
            stopPlayback()
            showHUD("Paused")
        } else if isPaused {
            showHUD(PlaybackSpeed.label(PlaybackSpeed.current))
            startTimer()
        } else {
            replay()
        }
    }

    private func skipOrReplay() {
        guard analysis.isAnimated else { return }
        if isPlaying { skipToEnd() } else { replay() }
    }

    private func startTimer() {
        lastFrameTime = ProcessInfo.processInfo.systemUptime
        byteCredit = 0
        let timer = Timer(timeInterval: Self.frameInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.advanceFrame() }
        }
        RunLoop.main.add(timer, forMode: .common)
        frameTimer = timer
    }

    private func stopPlayback() {
        frameTimer?.invalidate()
        frameTimer = nil
    }

    private func advanceFrame() {
        let now = ProcessInfo.processInfo.systemUptime
        let baud = PlaybackSpeed.current
        guard baud > 0 else { skipToEnd(); return }
        // 8N1 serial framing: 10 bits on the wire per byte.
        byteCredit += (now - lastFrameTime) * Double(baud) / 10
        lastFrameTime = now
        let count = Int(byteCredit)
        guard count > 0 else { return }
        byteCredit -= Double(count)
        terminal.advance(byteCount: count)
        if terminal.isFinished {
            skipToEnd()
        } else {
            screen = terminal.screen(minimumRows: analysis.canvasRows)
            redraw()
            updateBlinkTimer()
        }
    }

    private func speedMayHaveChanged() {
        let baud = PlaybackSpeed.current
        guard baud != shownBaud else { return }
        shownBaud = baud
        showHUD(PlaybackSpeed.label(baud))
    }

    // MARK: Heads up display

    private func showHUD(_ text: String) {
        hud.stringValue = " \(text) "
        hud.alphaValue = 1
        hudTimer?.invalidate()
        let timer = Timer(timeInterval: 1.8, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.4
                    self?.hud.animator().alphaValue = 0
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        hudTimer = timer
    }

    // MARK: Blink

    private func updateBlinkTimer() {
        let needsBlink = screen.hasBlink && view.window != nil
        if needsBlink, blinkTimer == nil {
            let timer = Timer(timeInterval: Self.blinkInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.blinkVisible.toggle()
                    self.redraw()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            blinkTimer = timer
        } else if !needsBlink, let timer = blinkTimer {
            timer.invalidate()
            blinkTimer = nil
            blinkVisible = true
        }
    }

    private func redraw() {
        var padded = screen
        while padded.rows.count < analysis.canvasRows {
            padded.rows.append(Array(repeating: AnsiCell(), count: source.columns))
        }
        canvas.image = AnsiRenderer.render(padded, blinkVisible: blinkVisible, atlas: atlas)?.image
    }
}

/// Displays one rendered frame with crisp, unsmoothed pixels.
final class AnsiCanvasView: NSView {
    var onClick: (() -> Void)?
    weak var player: AnsiPlayerViewController?

    var image: CGImage? {
        didSet { layer?.contents = image }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.magnificationFilter = .nearest
        layer?.minificationFilter = .nearest
        layer?.contentsGravity = .resize
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    // Menu actions sent through the responder chain from the app's Playback menu.
    @objc func replayAnimation(_ sender: Any?) { player?.replay() }
    @objc func skipAnimation(_ sender: Any?) { player?.skipToEnd() }
    @objc func togglePausePlayback(_ sender: Any?) { player?.togglePause() }
}
