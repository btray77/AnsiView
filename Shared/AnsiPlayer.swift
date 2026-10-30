import AnsiCore
import AppKit
import Combine
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

    /// Optional CRT look (scanlines, glow, curvature), shared with Quick Look.
    static let crtEffectKey = "crtEffect"
    static var crtEffect: Bool { defaults.bool(forKey: crtEffectKey) }

    /// Synthesized modem sounds during playback (app only; Quick Look stays silent).
    static let modemSoundsKey = "modemSounds"
    static var modemSounds: Bool { defaults.bool(forKey: modemSoundsKey) }

    /// Hold the last frame of a playback until clicked, instead of going straight to the finished art.
    static let holdFinalFrameKey = "holdFinalFrame"
    static var holdFinalFrame: Bool { defaults.bool(forKey: holdFinalFrameKey) }

    /// Speeds remembered per file (by `ArtFile.identity`), shared with Quick Look.
    static let fileSpeedsKey = "fileSpeeds"
    static var fileSpeeds: SpeedMemory { SpeedMemory(serialized: defaults.object(forKey: fileSpeedsKey)) }

    /// The file's remembered speed, or the global speed when it has none (or a value not in `choices`).
    static func speed(forFile key: String) -> Int {
        if let baud = fileSpeeds.speed(for: key), choices.contains(baud) { return baud }
        return current
    }

    /// Remembers the speed for this file and makes it the global speed for files without one.
    static func remember(_ baud: Int, forFile key: String) {
        var memory = fileSpeeds
        memory.set(baud, for: key)
        defaults.set(memory.serialized, forKey: fileSpeedsKey)
        current = baud
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

/// What the line sounds like: the handshake before the art, noise while bytes flow, or nothing.
enum PlaybackSoundState { case connecting, streaming, quiet }

/// Plays the line sounds for a player. The app supplies one; Quick Look does not.
protocol PlaybackSound: AnyObject {
    func playbackStateChanged(_ state: PlaybackSoundState)
}

/// The playback speed of one file's window. The app's speed commands act on the focused one.
final class PlayerSpeed: ObservableObject {
    let fileKey: String
    @Published private(set) var baud: Int

    init(fileKey: String) {
        self.fileKey = fileKey
        baud = PlaybackSpeed.speed(forFile: fileKey)
    }

    func set(_ baud: Int) {
        PlaybackSpeed.remember(baud, forFile: fileKey)
        if self.baud != baud { self.baud = baud }
    }

    /// Picks up a change made elsewhere (the global speed, or the same file in another window).
    func refresh() {
        let latest = PlaybackSpeed.speed(forFile: fileKey)
        if latest != baud { baud = latest }
    }
}

/// Shows an ANSI file in a scroll view. Animated files replay at modem speed and blinking text blinks.
/// Clicking skips an animation to its end, or replays it once it has finished.
final class AnsiPlayerViewController: NSViewController {
    static let blinkInterval: TimeInterval = 0.46
    static let frameInterval: TimeInterval = 1.0 / 30.0

    let analysis: AnsiAnalysis
    let source: ArtFile
    let speed: PlayerSpeed
    /// Frame positions for the scrub bar and stepping; nil for static art, which has no bar.
    let timeline: PlaybackTimeline?
    /// The frame currently on screen.
    private(set) var screen: AnsiScreen
    private let renderOptions: RenderOptions
    private let canvas = AnsiCanvasView()
    private let hud = NSTextField(labelWithString: "")
    private var terminal: AnsiTerminal
    private var blinkVisible = true
    private var frameTimer: Timer?
    private var blinkTimer: Timer?
    private var hudTimer: Timer?
    private var lastFrameTime: TimeInterval = 0
    private var byteCredit: Double = 0
    /// True while the finished art is on screen (before playback starts, or after it ends).
    private var screenIsFinal = true
    private lazy var shownBaud = speed.baud
    private var shownCRT = PlaybackSpeed.crtEffect
    private var defaultsObserver: NSObjectProtocol?

    init(source: ArtFile, speed: PlayerSpeed? = nil) {
        self.source = source
        self.speed = speed ?? PlayerSpeed(fileKey: source.identity)
        self.analysis = AnsiAnalysis(source)
        self.timeline = analysis.isAnimated ? PlaybackTimeline(source) : nil
        var options = RenderOptions(for: analysis.finalScreen)
        options.scale = AnsiRenderer.preferredScale(rows: analysis.canvasRows)
        self.renderOptions = options
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
    var contentSize: CGSize { artSize(rows: analysis.canvasRows) }

    private func artSize(rows: Int) -> CGSize {
        let cellWidth = renderOptions.font.width + (renderOptions.ninePixel ? 1 : 0)
        let aspect = AnsiRenderer.pixelAspect(for: analysis.finalScreen, ninePixel: renderOptions.ninePixel)
        return CGSize(width: CGFloat(source.columns * cellWidth),
                      height: (CGFloat(rows * renderOptions.font.height) * aspect).rounded())
    }

    /// True while tall art is mid playback: the view shows a 25 line terminal window that follows
    /// the cursor instead of the whole canvas.
    var isTerminalMode: Bool { analysis.canvasRows > TerminalViewport.rows && !screenIsFinal }
    /// Rows on screen now: the terminal window during playback of tall art, else the whole canvas.
    var displayedRows: Int { isTerminalMode ? TerminalViewport.rows : analysis.canvasRows }
    /// Line sounds; used only while `PlaybackSpeed.modemSounds` is on.
    var sound: PlaybackSound?
    private var soundState = PlaybackSoundState.quiet
    /// Waits for the handshake to finish before the art starts drawing.
    private var connectTimer: Timer?
    var isConnecting: Bool { connectTimer != nil }
    private var soundsOn: Bool { sound != nil && PlaybackSpeed.modemSounds }

    /// True when playback reached the end and is holding its last frame until clicked.
    private(set) var isHolding = false
    /// Called each time a playback in progress reaches the finished art (end of stream without a
    /// hold, a click or Skip to End during playback, or the release of a hold).
    var onFinished: (() -> Void)?

    /// Top row of the terminal window; nil until playback places it.
    private(set) var viewportTop: Int?

    /// The art plus the scrub bar, for hosts that size a window to fit.
    var idealViewSize: CGSize {
        CGSize(width: contentSize.width, height: contentSize.height + (timeline == nil ? 0 : Self.timelineBarHeight))
    }

    var isPlaying: Bool { frameTimer != nil || connectTimer != nil }
    /// Bytes of the stream played so far.
    var playbackPosition: Int { terminal.position }
    var isPaused: Bool { !isPlaying && terminal.position > 0 && !terminal.isFinished }

    /// Art taller than this many lines is a "scroller": it fits the window width and scrolls.
    static let scrollerRows = 50

    private let scroll = NSScrollView()
    private let timelineBar = NSView()
    private let slider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let frameLabel = NSTextField(labelWithString: "")
    static let timelineBarHeight: CGFloat = 26

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        let clip = CenteringClipView()
        clip.drawsBackground = true
        clip.backgroundColor = .black
        scroll.contentView = clip
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
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
            hud.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            hud.bottomAnchor.constraint(equalTo: scroll.bottomAnchor, constant: -10),
        ])
        if timeline != nil {
            installTimelineBar(in: container)
        } else {
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor).isActive = true
        }
        // No preferredContentSize here: AppKit turns it into priority 501 size constraints that
        // would stop the window from resizing. Hosts use contentSize as a sizing hint instead.
        view = container
        redraw()

        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.speedMayHaveChanged() }
        }
    }

    /// The scrub bar under the art: a slider over the byte stream and a frame counter.
    private func installTimelineBar(in container: NSView) {
        timelineBar.appearance = NSAppearance(named: .darkAqua)
        timelineBar.wantsLayer = true
        timelineBar.layer?.backgroundColor = NSColor(white: 0.1, alpha: 1).cgColor
        timelineBar.translatesAutoresizingMaskIntoConstraints = false
        slider.isContinuous = true
        slider.controlSize = .small
        slider.refusesFirstResponder = true
        slider.target = self
        slider.action = #selector(sliderMoved(_:))
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.setAccessibilityLabel("Playback position")
        frameLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        frameLabel.textColor = NSColor(white: 0.75, alpha: 1)
        frameLabel.alignment = .right
        frameLabel.translatesAutoresizingMaskIntoConstraints = false
        frameLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        timelineBar.addSubview(slider)
        timelineBar.addSubview(frameLabel)
        container.addSubview(timelineBar)
        NSLayoutConstraint.activate([
            timelineBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            timelineBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            timelineBar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            timelineBar.topAnchor.constraint(equalTo: scroll.bottomAnchor),
            timelineBar.heightAnchor.constraint(equalToConstant: Self.timelineBarHeight),
            slider.leadingAnchor.constraint(equalTo: timelineBar.leadingAnchor, constant: 10),
            slider.centerYAnchor.constraint(equalTo: timelineBar.centerYAnchor),
            frameLabel.leadingAnchor.constraint(equalTo: slider.trailingAnchor, constant: 10),
            frameLabel.trailingAnchor.constraint(equalTo: timelineBar.trailingAnchor, constant: -10),
            frameLabel.centerYAnchor.constraint(equalTo: timelineBar.centerYAnchor),
        ])
        updateTimeline()
    }

    @objc private func sliderMoved(_ sender: NSSlider) {
        guard let timeline else { return }
        seek(to: timeline.position(atFraction: sender.doubleValue))
    }

    /// Moves the slider and frame counter to the terminal's position.
    private func updateTimeline() {
        guard let timeline else { return }
        let position = screenIsFinal ? timeline.length : terminal.position
        slider.doubleValue = timeline.fraction(at: position)
        frameLabel.stringValue = "frame \(timeline.frameIndex(at: position)) / \(timeline.frameEnds.count)"
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        fitToWindow()
    }

    /// Scales the art to the window, keeping its proportions. Normal screens fit entirely and are
    /// centered; scrollers fit the width and scroll vertically.
    private func fitToWindow() {
        let art = artSize(rows: displayedRows)
        let available = scroll.contentSize
        guard art.width > 0, art.height > 0, available.width > 0, available.height > 0 else { return }
        let widthScale = available.width / art.width
        let isScroller = displayedRows > Self.scrollerRows && art.height * widthScale > available.height
        let scale = isScroller ? widthScale : min(widthScale, available.height / art.height)
        let size = CGSize(width: (art.width * scale).rounded(), height: (art.height * scale).rounded())
        if canvas.frame.size != size {
            canvas.setFrameSize(size)
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
        isHolding = false
        terminal = AnsiTerminal(source)
        if speed.baud == 0 {
            showFinal()
            onFinished?()
            return
        }
        viewportTop = nil
        showTerminal()
        Logger(subsystem: "com.traynham.ansiview", category: "playback")
            .info("Playback started at \(self.speed.baud, privacy: .public) baud")
        guard soundsOn else {
            showHUD("\(PlaybackSpeed.label(speed.baud))  \u{00B7}  click to skip")
            startTimer()
            return
        }
        // Dial and handshake first; the art arrives after CONNECT.
        showHUD("Dialing...  \u{00B7}  click to skip")
        setSound(.connecting)
        let timer = Timer(timeInterval: ModemSound.handshakeSeconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.connected() }
        }
        RunLoop.main.add(timer, forMode: .common)
        connectTimer = timer
    }

    private func connected() {
        connectTimer = nil
        showHUD("CONNECT \(speed.baud)")
        startTimer()
    }

    private func setSound(_ state: PlaybackSoundState) {
        guard state != soundState else { return }
        soundState = state
        sound?.playbackStateChanged(state)
    }

    /// Finishes playback and shows the finished art.
    func skipToEnd() {
        let wasInProgress = isPlaying || isHolding || isPaused
        showFinal()
        if wasInProgress { onFinished?() }
    }

    /// Releases a held final frame and shows the finished art.
    func finishHold() {
        guard isHolding else { return }
        skipToEnd()
    }

    private func showFinal() {
        stopPlayback()
        isHolding = false
        terminal.runToEnd()
        screen = analysis.finalScreen
        screenIsFinal = true
        redraw()
        updateTimeline()
        updateBlinkTimer()
    }

    /// Pauses and shows the screen as it was after `position` bytes.
    func seek(to position: Int) {
        stopPlayback()
        isHolding = false
        terminal.seek(to: position)
        if terminal.isFinished {
            showFinal()
            return
        }
        viewportTop = nil
        showTerminal()
    }

    /// Pauses and moves one frame forward (+1) or back (-1).
    func stepFrame(_ delta: Int) {
        guard let timeline else { return }
        let from = screenIsFinal ? timeline.length : terminal.position
        seek(to: timeline.step(from: from, by: delta))
    }

    /// Draws the terminal's current screen mid playback.
    private func showTerminal() {
        screen = terminal.screen(minimumRows: analysis.canvasRows)
        screenIsFinal = false
        viewportTop = TerminalViewport.follow(cursorRow: terminal.cursorRow, previousTop: viewportTop,
                                              canvasRows: analysis.canvasRows)
        redraw()
        updateTimeline()
        updateBlinkTimer()
    }

    /// Pauses a running animation, resumes a paused one, or replays a finished one.
    func togglePause() {
        if isPlaying {
            stopPlayback()
            showHUD("Paused")
        } else if isPaused {
            showHUD(PlaybackSpeed.label(speed.baud))
            startTimer()
        } else {
            replay()
        }
    }

    private func skipOrReplay() {
        if isHolding {
            finishHold()
        } else if isPlaying {
            skipToEnd()
        } else if analysis.isAnimated {
            replay()
        }
    }

    private func startTimer() {
        lastFrameTime = ProcessInfo.processInfo.systemUptime
        byteCredit = 0
        let timer = Timer(timeInterval: Self.frameInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.advanceFrame() }
        }
        RunLoop.main.add(timer, forMode: .common)
        frameTimer = timer
        if soundsOn { setSound(.streaming) }
    }

    private func stopPlayback() {
        frameTimer?.invalidate()
        frameTimer = nil
        connectTimer?.invalidate()
        connectTimer = nil
        setSound(.quiet)
    }

    private func advanceFrame() {
        let now = ProcessInfo.processInfo.systemUptime
        let baud = speed.baud
        guard baud > 0 else { skipToEnd(); return }
        // 8N1 serial framing: 10 bits on the wire per byte.
        byteCredit += (now - lastFrameTime) * Double(baud) / 10
        lastFrameTime = now
        let count = Int(byteCredit)
        guard count > 0 else { return }
        byteCredit -= Double(count)
        terminal.advance(byteCount: count)
        if terminal.isFinished, PlaybackSpeed.holdFinalFrame {
            stopPlayback()
            isHolding = true
            showTerminal()
            showHUD("Click to continue")
        } else if terminal.isFinished {
            skipToEnd()
        } else {
            showTerminal()
        }
    }

    private func speedMayHaveChanged() {
        if PlaybackSpeed.crtEffect != shownCRT {
            shownCRT = PlaybackSpeed.crtEffect
            redraw()
        }
        if !soundsOn {
            setSound(.quiet)
            if isConnecting {
                connectTimer?.invalidate()
                connected()
            }
        } else if frameTimer != nil {
            setSound(.streaming)
        }
        speed.refresh()
        let baud = speed.baud
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
        var options = renderOptions
        var padded = screen
        if isTerminalMode {
            padded = screen.window(top: viewportTop ?? 0, rows: TerminalViewport.rows)
            options.scale = AnsiRenderer.preferredScale(rows: TerminalViewport.rows)
        } else {
            while padded.rows.count < analysis.canvasRows {
                padded.rows.append(Array(repeating: AnsiCell(), count: source.columns))
            }
        }
        options.blinkVisible = blinkVisible
        let image = AnsiRenderer.render(padded, options: options)?.image
        canvas.image = PlaybackSpeed.crtEffect ? image.flatMap { CRTFilter().apply($0) } ?? image : image
        if isViewLoaded { fitToWindow() }
    }
}

/// A top-down clip view that centers its document when the document is smaller than the window.
final class CenteringClipView: NSClipView {
    override var isFlipped: Bool { true }

    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView else { return rect }
        if document.frame.width < proposedBounds.width {
            rect.origin.x = (document.frame.width - proposedBounds.width) / 2
        }
        if document.frame.height < proposedBounds.height {
            rect.origin.y = (document.frame.height - proposedBounds.height) / 2
        }
        return rect
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

    /// Left and Right arrows step frames (Quick Look has no menus to carry the shortcuts).
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: player?.stepFrame(-1)
        case 124: player?.stepFrame(1)
        default: super.keyDown(with: event)
        }
    }

    // Menu actions sent through the responder chain from the app's Playback menu.
    @objc func replayAnimation(_ sender: Any?) { player?.replay() }
    @objc func skipAnimation(_ sender: Any?) { player?.skipToEnd() }
    @objc func togglePausePlayback(_ sender: Any?) { player?.togglePause() }
    @objc func previousFrame(_ sender: Any?) { player?.stepFrame(-1) }
    @objc func nextFrame(_ sender: Any?) { player?.stepFrame(1) }
}
