import AnsiCore
import AppKit
import Combine
import QuartzCore
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

    /// ANSI music in the app's windows (Quick Look never plays it). On unless turned off.
    static let ansiMusicKey = "ansiMusic"
    static var ansiMusic: Bool { defaults.object(forKey: ansiMusicKey) as? Bool ?? true }

    /// At Instant speed (and when replaying there), play the file's music once from the start.
    static let musicAtInstantKey = "ansiMusicAtInstant"
    static var musicAtInstant: Bool { defaults.object(forKey: musicAtInstantKey) as? Bool ?? true }

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

/// Plays ANSI music for a player: queued tunes play one after another on one speaker. The app
/// supplies one; Quick Look does not, so its previews stay silent.
protocol MusicOutput: AnyObject {
    /// Queues `notes` (times relative to their first note) after anything already queued.
    func enqueue(_ notes: [TimedNote])
    func pause()
    func resume()
    /// Silences everything queued.
    func stop()
}

/// What the music indicator and its tooltip say.
enum MusicIndicator {
    static let foreground = "\u{266A} ANSI music"
    static let background = "\u{266A} ANSI music (background)"
    static let paused = "\u{266A} ANSI music (paused)"
    static let tip = "This art is playing ANSI music: a BASIC PLAY tune sent inside the file, as BBS terminals played it. "
        + "Foreground music (MF) pauses the drawing until it ends; background music (MB) plays while it draws. "
        + "Click to mute this window. Playback > Play ANSI Music turns it off everywhere."
}

/// Shows an ANSI file in a scroll view. Animated files replay at modem speed and blinking text blinks.
/// Clicking skips an animation to its end, or replays it once it has finished.
final class AnsiPlayerViewController: NSViewController {
    static let blinkInterval: TimeInterval = 0.46
    static let frameInterval: TimeInterval = 1.0 / 30.0

    let analysis: AnsiAnalysis
    let source: ArtFile
    /// Where the file lives, when the host knows (document windows and folder slideshows).
    var fileURL: URL? {
        didSet { if isViewLoaded { updateAccessibility() } }
    }
    /// The piece's name when it has no file of its own (an entry in a ZIP art pack).
    var artName: String? {
        didSet { if isViewLoaded { updateAccessibility() } }
    }
    let speed: PlayerSpeed
    /// Frame positions for the scrub bar and stepping; nil for static art, which has no bar.
    private(set) var timeline: PlaybackTimeline?
    /// The frame currently on screen.
    private(set) var screen: AnsiScreen
    private let renderOptions: RenderOptions
    private let canvas = AnsiCanvasView()
    /// The art view, which takes the keyboard.
    var canvasView: NSView { canvas }
    private let hud = NSTextField(labelWithString: "")
    private var terminal: AnsiTerminal
    private var blinkVisible = true
    private var frameTimer: Timer?
    private var blinkTimer: Timer?
    private var hudTimer: Timer?
    private var lastFrameTime: TimeInterval = 0
    private var byteCredit: Double = 0
    /// True while the finished art is on screen (before playback starts, or after it ends).
    private(set) var screenIsFinal = true
    private lazy var shownBaud = speed.baud
    private var shownCRT = PlaybackSpeed.crtEffect
    private var defaultsObserver: NSObjectProtocol?

    /// False in presentation mode: animations get no scrub bar.
    let showsTimeline: Bool

    init(source: ArtFile, speed: PlayerSpeed? = nil, showsTimeline: Bool = true) {
        self.source = source
        self.showsTimeline = showsTimeline
        self.speed = speed ?? PlayerSpeed(fileKey: source.identity)
        self.analysis = AnsiAnalysis(source)
        self.timeline = analysis.isAnimated ? PlaybackTimeline(source) : nil
        var options = RenderOptions(for: analysis.finalScreen)
        options.scale = AnsiRenderer.preferredScale(rows: analysis.canvasRows)
        self.renderOptions = options
        self.terminal = AnsiTerminal(source)
        self.screen = analysis.finalScreen
        self.musicScheduler = MusicPlaybackScheduler(file: source)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit {
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
        musicTimer?.invalidate()
        music?.stop()
    }

    // MARK: ANSI music

    /// Plays the file's ANSI music. Set it before the view loads (as hosts set `sound`): a file whose
    /// only movement is music then plays back like an animation. Nil (Quick Look) means silence,
    /// no holds, and the file behaves exactly as it would without music.
    var music: MusicOutput? {
        didSet {
            guard !isViewLoaded else { return }
            hasMusicPlayback = music != nil && musicScheduler.hasMusic && PlaybackSpeed.ansiMusic
            timeline = isPlayable ? PlaybackTimeline(source) : nil
        }
    }
    /// True when this window plays the file's music (decided when the output is set).
    private(set) var hasMusicPlayback = false
    /// The file replays: it is animated, or it has music this window plays.
    var isPlayable: Bool { analysis.isAnimated || hasMusicPlayback }
    /// Silences this window only (not remembered).
    var musicMuted = false {
        didSet {
            guard musicMuted != oldValue else { return }
            musicSettingsChanged()
            if isViewLoaded, hasMusicPlayback { showHUD(musicMuted ? String(localized: "Music muted in this window") : String(localized: "Music on")) }
        }
    }
    /// The clock music is timed by (a harness may replace it).
    var clock: () -> Double = { ProcessInfo.processInfo.systemUptime }
    private var musicScheduler: MusicPlaybackScheduler
    private var musicTimer: Timer?
    private let musicBadge = NSButton(title: "", target: nil, action: nil)
    /// Music sounds and holds only with an output, the setting on and the window not muted.
    private var musicOn: Bool { music != nil && hasMusicPlayback && !musicMuted && PlaybackSpeed.ansiMusic }
    /// The display is waiting for foreground music.
    var isHoldingForMusic: Bool { musicOn && musicScheduler.isHolding(at: clock()) }
    /// The music sounding now, if any.
    var musicPlayingNow: ScheduledMusic? { musicScheduler.queue.playing(at: clock()) }
    /// True while the music indicator is on screen.
    var musicIndicatorShown: Bool { !musicBadge.isHidden }

    private func perform(_ events: [MusicEvent]) {
        guard !events.isEmpty else { return }
        for event in events {
            switch event {
            case .play(let scheduled): music?.enqueue(scheduled.notes)
            case .pause: music?.pause()
            case .resume: music?.resume()
            case .stop: music?.stop()
            }
        }
        updateMusicIndicator()
    }

    /// Music was turned off or muted: silence it and stop holding the drawing.
    private func musicSettingsChanged() {
        // Defaults change often (any setting); only a window with music has anything to stop.
        guard hasMusicPlayback, !musicOn else { return }
        perform(musicScheduler.stop())
        musicScheduler.skip(to: terminal.position)
    }

    private func updateMusicIndicator() {
        guard isViewLoaded else { return }
        let now = clock()
        let queue = musicScheduler.queue
        let active = musicOn && queue.isActive(at: now)
        musicBadge.isHidden = !active
        if active {
            let title = queue.pausedAt != nil ? MusicIndicator.paused
                : queue.isHolding(at: now) ? MusicIndicator.foreground
                : queue.playing(at: now)?.holds == false ? MusicIndicator.background : MusicIndicator.foreground
            if musicBadge.title != title { musicBadge.title = title }
            if musicTimer == nil {
                let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.updateMusicIndicator() }
                }
                RunLoop.main.add(timer, forMode: .common)
                musicTimer = timer
            }
        } else if let timer = musicTimer {
            timer.invalidate()
            musicTimer = nil
        }
    }

    @objc private func musicBadgeClicked(_ sender: Any?) {
        musicMuted = true
    }

    private func installMusicBadge(in container: NSView) {
        musicBadge.isBordered = false
        musicBadge.wantsLayer = true
        musicBadge.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.7).cgColor
        musicBadge.layer?.cornerRadius = 4
        musicBadge.appearance = NSAppearance(named: .darkAqua)
        musicBadge.contentTintColor = .white
        musicBadge.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
        musicBadge.title = MusicIndicator.foreground
        musicBadge.toolTip = MusicIndicator.tip
        musicBadge.setAccessibilityLabel("ANSI music playing. Press to mute this window.")
        musicBadge.refusesFirstResponder = true
        musicBadge.target = self
        musicBadge.action = #selector(musicBadgeClicked(_:))
        musicBadge.isHidden = true
        musicBadge.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(musicBadge)
        NSLayoutConstraint.activate([
            musicBadge.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            musicBadge.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            musicBadge.heightAnchor.constraint(equalToConstant: 22),
        ])
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
    /// Left and Right arrows step frames. Quick Look turns this off so the arrows keep moving
    /// between the selected files.
    var handlesArrowKeys = true

    /// Dragging selects cells for copying. The app's windows turn this on; Quick Look leaves it
    /// off, so a click there still skips or replays on mouse down.
    var allowsSelection = false

    /// The selected cells of the screen on display (`displayedScreen`), or nil.
    private(set) var selection: CellRect?
    private var selectionWasInTerminalMode = false

    /// Selects cells of the displayed screen (clipped to it), or clears with nil.
    func select(_ rect: CellRect?) {
        let grid = CellRect(x: 0, y: 0, width: source.columns, height: displayedRows)
        selection = rect.flatMap { Self.intersect($0, grid) }
        canvas.showSelection(selection, columns: source.columns, rows: displayedRows)
    }

    func selectAll() { select(CellRect(x: 0, y: 0, width: source.columns, height: displayedRows)) }

    private static func intersect(_ a: CellRect, _ b: CellRect) -> CellRect? {
        let x0 = max(a.x, b.x), y0 = max(a.y, b.y)
        let x1 = min(a.x + a.width, b.x + b.width), y1 = min(a.y + a.height, b.y + b.height)
        return x1 > x0 && y1 > y0 ? CellRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0) : nil
    }

    /// The selected cells of the frame on screen, ready for the pasteboard, drawn with the art's font.
    var selectionClipboard: CellClipboard? {
        guard let selection else { return nil }
        let region = displayedScreen.region(selection)
        guard region.height > 0 else { return nil }
        return CellClipboard(region: region, font: renderOptions.font, ninePixel: renderOptions.ninePixel)
    }

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

    // MARK: Hooks for the app's viewer tools (plan 9). Quick Look sets none of them, so its
    // previews draw exactly as before.

    /// Colours to show the art in (16, VGA order): the piece's own colours map to these by index.
    /// Nil (the default, and always in Quick Look) shows the art's own colours.
    var paletteOverride: [RGB]? {
        didSet {
            colorMap = paletteOverride.map { PaletteRemap.map(from: PaletteRemap.sourcePalette(for: source), to: $0) } ?? [:]
            if isViewLoaded { redraw() }
        }
    }
    private var colorMap: [RGB: RGB] = [:]

    /// Called once the view has loaded (the app installs its find bar, minimap and auto scroll).
    var onViewLoaded: ((AnsiPlayerViewController) -> Void)?
    /// Called after each redraw (a new frame, a blink, a palette change).
    var onRedraw: (() -> Void)?
    /// The scroll view holding the art.
    var scrollView: NSScrollView { scroll }
    /// Room kept free at the right of the art (for the app's minimap strip); 0 by default.
    var trailingInset: CGFloat = 0 {
        didSet { scrollTrailing?.constant = -trailingInset }
    }
    private var scrollTrailing: NSLayoutConstraint?

    /// The finished screen as it is drawn now (palette applied).
    var finalScreenAsShown: AnsiScreen {
        colorMap.isEmpty ? analysis.finalScreen : PaletteRemap.apply(colorMap, to: analysis.finalScreen)
    }

    /// Outlines cells of the displayed screen (search matches); `current` is filled. Empty by default.
    func highlight(_ rects: [CellRect], current: Int?) {
        canvas.showHighlights(rects, current: current, columns: source.columns, rows: displayedRows)
    }

    /// Where cells of the displayed screen are, in the art view's coordinates.
    func canvasRect(for cells: CellRect) -> CGRect {
        CellGrid.rect(for: cells, in: canvas.bounds.size, columns: source.columns, rows: displayedRows)
    }

    /// The art plus the scrub bar, for hosts that size a window to fit.
    var idealViewSize: CGSize {
        CGSize(width: contentSize.width,
               height: contentSize.height + (timeline != nil && showsTimeline ? Self.timelineBarHeight : 0))
    }

    var isPlaying: Bool { frameTimer != nil || connectTimer != nil }
    /// Bytes of the stream played so far.
    var playbackPosition: Int { terminal.position }
    var isPaused: Bool {
        !isPlaying && ((terminal.position > 0 && !terminal.isFinished) || pausedAtEnd)
    }
    /// Paused while the last screen waited for music sent at the very end (the stream is finished,
    /// so the position alone cannot say "paused"). Kept by the player, not the music queue, so
    /// muting or stopping the music leaves the pause intact.
    private var pausedAtEnd = false

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
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.backgroundColor = .black
        scroll.drawsBackground = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        canvas.frame = CGRect(origin: .zero, size: contentSize)
        canvas.onClick = { [weak self] in self?.skipOrReplay() }
        canvas.player = self
        updateAccessibility()
        scroll.documentView = canvas
        container.addSubview(scroll)

        hud.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
        hud.textColor = .white
        hud.drawsBackground = true
        hud.backgroundColor = NSColor.black.withAlphaComponent(0.7)
        hud.alphaValue = 0
        hud.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hud)
        installMusicBadge(in: container)

        let trailing = scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -trailingInset)
        scrollTrailing = trailing
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            trailing,
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            hud.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            hud.bottomAnchor.constraint(equalTo: scroll.bottomAnchor, constant: -10),
        ])
        if timeline != nil, showsTimeline {
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
        onViewLoaded?(self)
    }

    /// VoiceOver reads the art as static text: the finished art's words (not the frame on screen,
    /// so it does not change during playback), described by its SAUCE title, author and group.
    /// Set through the setters: AppKit's attribute bridge ignores overridden getters on a plain NSView.
    private func updateAccessibility() {
        canvas.setAccessibilityElement(true)
        canvas.setAccessibilityRole(.staticText)
        canvas.setAccessibilityRoleDescription("ANSI art")
        canvas.setAccessibilityValue(ArtText.accessibilityValue(analysis.finalScreen))
        canvas.setAccessibilityLabel(ArtText.accessibilityLabel(source, fileName: fileURL?.lastPathComponent ?? artName))
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

    /// Sizes the art for the zoom mode. Fit (the default) scales it to the window keeping its
    /// proportions: normal screens fit entirely and are centered; scrollers fit the width and scroll.
    private func fitToWindow() {
        let cellWidth = renderOptions.font.width + (renderOptions.ninePixel ? 1 : 0)
        let pixels = CGSize(width: source.columns * cellWidth, height: displayedRows * renderOptions.font.height)
        let aspect = AnsiRenderer.pixelAspect(for: analysis.finalScreen, ninePixel: renderOptions.ninePixel)
        let backing = view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        let size = Zoom.canvasSize(artPixels: pixels, aspect: aspect, available: scroll.contentSize, mode: zoom,
                                   scroller: displayedRows > Self.scrollerRows, backingScale: backing)
        if size.width > 0, size.height > 0, canvas.frame.size != size {
            canvas.setFrameSize(size)
        }
    }

    /// Told when the zoom changes (a slideshow keeps it for the next piece).
    var onZoomChange: ((ZoomMode) -> Void)?

    /// How this window sizes its art. Not saved: each window starts at Fit.
    var zoom: ZoomMode = .fit {
        didSet {
            guard zoom != oldValue else { return }
            onZoomChange?(zoom)
            guard isViewLoaded else { return }
            fitToWindow()
            showHUD(String(localized: "Zoom: \(zoom.label)"))
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(canvas)
        if isPlayable && !isPlaying && terminal.position == 0 {
            replay()
        }
        updateBlinkTimer()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        stopPlayback()
        perform(musicScheduler.stop())
        blinkTimer?.invalidate()
        blinkTimer = nil
    }

    // MARK: Playback

    func replay() {
        stopPlayback()
        isHolding = false
        terminal = AnsiTerminal(source)
        pausedAtEnd = false
        perform(musicScheduler.seek(to: 0))
        if speed.baud == 0 {
            showFinal()
            onFinished?()
            if musicOn, PlaybackSpeed.musicAtInstant { perform(musicScheduler.playAll(at: clock())) }
            return
        }
        viewportTop = nil
        showTerminal()
        Logger(subsystem: "com.traynham.ansiview", category: "playback")
            .info("Playback started at \(self.speed.baud, privacy: .public) baud")
        guard soundsOn else {
            showHUD(String(localized: "\(PlaybackSpeed.label(speed.baud))  \u{00B7}  click to skip"))
            startTimer()
            return
        }
        // Dial and handshake first; the art arrives after CONNECT.
        showHUD(String(localized: "Dialing...  \u{00B7}  click to skip"))
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

    /// Finishes playback and shows the finished art. A skip stops the music; reaching the end
    /// on its own lets music still sounding play out.
    func skipToEnd() {
        skipToEnd(stoppingMusic: true)
    }

    private func skipToEnd(stoppingMusic: Bool) {
        let wasInProgress = isPlaying || isHolding || isPaused
        if stoppingMusic { perform(musicScheduler.stop()) }
        showFinal()
        if wasInProgress { onFinished?() }
    }

    /// Releases a held final frame and shows the finished art.
    func finishHold() {
        guard isHolding else { return }
        skipToEnd(stoppingMusic: false)
    }

    private func showFinal() {
        stopPlayback()
        pausedAtEnd = false
        isHolding = false
        terminal.runToEnd()
        screen = analysis.finalScreen
        screenIsFinal = true
        redraw()
        updateTimeline()
        updateBlinkTimer()
    }

    /// Pauses and shows the screen as it was after `position` bytes.
    /// Reaching the end of a playback in progress this way finishes it (`onFinished` fires).
    func seek(to position: Int) {
        let wasInProgress = isPlaying || isHolding || isPaused
        stopPlayback()
        isHolding = false
        pausedAtEnd = false
        terminal.seek(to: position)
        perform(musicScheduler.seek(to: terminal.position))
        if terminal.isFinished {
            showFinal()
            if wasInProgress { onFinished?() }
            return
        }
        viewportTop = nil
        showTerminal()
    }

    /// True when the scrub bar is on screen.
    var timelineBarShown: Bool { timelineBar.superview != nil }

    /// Stops timers and sound without changing what is on screen (another player is taking over).
    func halt() {
        stopPlayback()
        perform(musicScheduler.stop())
    }

    /// Continues where `other` was: the same position, playing, paused, held or finished. `other`
    /// stops. Used when presentation mode starts and ends.
    func takeOver(from other: AnsiPlayerViewController) {
        let position = other.playbackPosition
        let wasPlaying = other.isPlaying
        let wasHolding = other.isHolding
        let wasFinal = other.screenIsFinal && !wasPlaying
        other.halt()
        // Music the other player already reached is not replayed here.
        musicScheduler.skip(to: wasFinal ? source.stream.count : position)
        if wasFinal {
            showFinal()
        } else if wasHolding {
            stopPlayback()
            terminal.seek(to: position)
            isHolding = true
            viewportTop = nil
            showTerminal()
        } else {
            stopPlayback()
            isHolding = false
            terminal.seek(to: position)
            viewportTop = nil
            showTerminal()
            if wasPlaying { startTimer() }
        }
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

    /// Pauses a running animation, resumes a paused one, releases a held final frame, or replays a
    /// finished one.
    func togglePause() {
        if isHolding {
            finishHold()
        } else if isPlaying {
            stopPlayback()
            pausedAtEnd = terminal.isFinished && !screenIsFinal
            perform(musicScheduler.pause(at: clock()))
            showHUD(String(localized: "Paused"))
        } else if isPaused {
            showHUD(PlaybackSpeed.label(speed.baud))
            perform(musicScheduler.resume(at: clock()))
            startTimer()
        } else {
            replay()
        }
    }

    private func skipOrReplay() {
        if isHolding {
            finishHold()
        } else if isPlaying || isPaused {
            skipToEnd()
        } else if isPlayable {
            replay()
        }
    }

    private func startTimer() {
        pausedAtEnd = false
        lastFrameTime = clock()
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
        let now = clock()
        let baud = speed.baud
        guard baud > 0 else { skipToEnd(); return }
        // Foreground music holds the drawing; line time is not saved up meanwhile.
        if musicOn, musicScheduler.isHolding(at: now) {
            lastFrameTime = now
            byteCredit = 0
            return
        }
        // 8N1 serial framing: 10 bits on the wire per byte.
        byteCredit += (now - lastFrameTime) * Double(baud) / 10
        lastFrameTime = now
        let count = Int(byteCredit)
        guard count > 0 || terminal.isFinished else { return }
        byteCredit -= Double(count)
        if musicOn {
            // Stops at each music sequence so its tune starts as the cursor passes it.
            perform(musicScheduler.advance(&terminal, by: count, at: now))
            if musicScheduler.isHolding(at: now) { byteCredit = 0 }
        } else {
            terminal.advance(byteCount: count)
            musicScheduler.skip(to: terminal.position)
        }
        if terminal.isFinished, musicOn, musicScheduler.isHolding(at: now) {
            // Music sent at the very end: the last screen stays until it has played.
            showTerminal()
        } else if terminal.isFinished, PlaybackSpeed.holdFinalFrame {
            stopPlayback()
            isHolding = true
            showTerminal()
            showHUD(String(localized: "Click to continue"))
        } else if terminal.isFinished {
            skipToEnd(stoppingMusic: false)
        } else {
            showTerminal()
        }
    }

    private func speedMayHaveChanged() {
        if PlaybackSpeed.crtEffect != shownCRT {
            shownCRT = PlaybackSpeed.crtEffect
            redraw()
        }
        musicSettingsChanged()
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

    /// The screen as drawn: the 25 line terminal window during playback of tall art, otherwise
    /// the whole canvas padded to its full height.
    var displayedScreen: AnsiScreen {
        if isTerminalMode { return screen.window(top: viewportTop ?? 0, rows: TerminalViewport.rows) }
        var padded = screen
        while padded.rows.count < analysis.canvasRows {
            padded.rows.append(Array(repeating: AnsiCell(), count: source.columns))
        }
        return padded
    }

    private func redraw() {
        var options = renderOptions
        let padded = colorMap.isEmpty ? displayedScreen : PaletteRemap.apply(colorMap, to: displayedScreen)
        if isTerminalMode { options.scale = AnsiRenderer.preferredScale(rows: TerminalViewport.rows) }
        options.blinkVisible = blinkVisible
        // A tall piece entering or leaving its 25 row playback window shows other rows under the
        // same cells: the selection no longer means the same art, so it is dropped.
        if isTerminalMode != selectionWasInTerminalMode {
            selectionWasInTerminalMode = isTerminalMode
            if selection != nil { select(nil) }
        }
        let image = AnsiRenderer.render(padded, options: options)?.image
        canvas.image = PlaybackSpeed.crtEffect ? image.flatMap { CRTFilter().apply($0) } ?? image : image
        if isViewLoaded { fitToWindow() }
        onRedraw?()
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
        // Keep the art on the device pixel grid so integer zoom pixels stay even.
        let backing = window?.backingScaleFactor ?? 1
        rect.origin.x = (rect.origin.x * backing).rounded() / backing
        rect.origin.y = (rect.origin.y * backing).rounded() / backing
        return rect
    }
}

/// Outlines of search matches over the art (app windows only). Lets every click through.
final class CellHighlightView: NSView {
    var cells: (rects: [CellRect], current: Int?, columns: Int, rows: Int)? {
        didSet { needsDisplay = true; isHidden = cells == nil }
    }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Where a cell rect is drawn, in this view's top down points.
    func area(_ rect: CellRect) -> CGRect {
        guard let cells else { return .zero }
        return CellGrid.rect(for: rect, in: bounds.size, columns: cells.columns, rows: cells.rows).insetBy(dx: -1, dy: -1)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let cells else { return }
        for (index, rect) in cells.rects.enumerated() {
            let box = area(rect)
            guard box.intersects(dirtyRect) else { continue }
            let path = NSBezierPath(rect: box.insetBy(dx: 0.75, dy: 0.75))
            if index == cells.current {
                NSColor.systemOrange.withAlphaComponent(0.5).setFill()
                NSColor.white.setStroke()
                path.lineWidth = 2
            } else {
                NSColor.systemYellow.withAlphaComponent(0.22).setFill()
                NSColor.systemYellow.setStroke()
                path.lineWidth = 1.5
            }
            path.fill()
            path.stroke()
        }
    }
}

/// Displays one rendered frame with crisp, unsmoothed pixels.
final class AnsiCanvasView: NSView {
    var onClick: (() -> Void)?
    weak var player: AnsiPlayerViewController?
    /// Called with an image file dropped on art. Set by the app (opens the image import
    /// window); the Quick Look preview leaves it nil and accepts no drops.
    static var imageDropHandler: ((URL) -> Void)?

    var image: CGImage? {
        didSet { layer?.contents = image }
    }

    /// The selection marquee: a translucent fill with a dashed outline, over the art.
    private let marquee = CAShapeLayer()
    private var marqueeCells: (rect: CellRect, columns: Int, rows: Int)?
    /// Where a mouse press went down, while it may still become a selection drag.
    private var pressPoint: NSPoint?
    private var dragAnchor: (x: Int, y: Int)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.magnificationFilter = .nearest
        layer?.minificationFilter = .nearest
        layer?.contentsGravity = .resize
        marquee.fillColor = NSColor.systemBlue.withAlphaComponent(0.25).cgColor
        marquee.strokeColor = NSColor.white.cgColor
        marquee.lineWidth = 1
        marquee.lineDashPattern = [5, 3]
        marquee.shadowColor = NSColor.black.cgColor
        marquee.shadowOpacity = 1
        marquee.shadowRadius = 0
        marquee.shadowOffset = CGSize(width: 1, height: -1)
        marquee.isHidden = true
        marquee.actions = ["path": NSNull(), "hidden": NSNull(), "position": NSNull(), "bounds": NSNull()]
        layer?.addSublayer(marquee)
        if Self.imageDropHandler != nil { registerForDraggedTypes([.fileURL]) }
    }

    /// Shows the marquee over `rect` of a `columns` x `rows` grid stretched over the view, or hides it.
    func showSelection(_ rect: CellRect?, columns: Int, rows: Int) {
        marqueeCells = rect.map { ($0, columns, rows) }
        layoutMarquee()
    }

    private func layoutMarquee() {
        guard let cells = marqueeCells else { marquee.isHidden = true; return }
        marquee.frame = bounds
        marquee.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        var area = CellGrid.rect(for: cells.rect, in: bounds.size, columns: cells.columns, rows: cells.rows)
        // The layer's origin is at the bottom unless AppKit flipped its geometry for this flipped view.
        if !(layer?.isGeometryFlipped ?? false) { area.origin.y = bounds.height - area.maxY }
        marquee.path = CGPath(rect: area.insetBy(dx: 0.5, dy: 0.5), transform: nil)
        marquee.isHidden = false
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutMarquee()
        layoutHighlights()
    }

    /// Search match outlines, created only when the app first shows some (never in Quick Look).
    /// A flipped subview that draws in view points, so it lines up with the cells however the
    /// layer tree is flipped.
    private var highlightView: CellHighlightView?

    func showHighlights(_ rects: [CellRect], current: Int?, columns: Int, rows: Int) {
        if highlightView == nil, !rects.isEmpty {
            let overlay = CellHighlightView(frame: bounds)
            overlay.autoresizingMask = [.width, .height]
            addSubview(overlay)
            highlightView = overlay
        }
        highlightView?.cells = rects.isEmpty ? nil : (rects, current, columns, rows)
    }

    private func layoutHighlights() {
        highlightView?.frame = bounds
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    private func droppedImage(_ info: NSDraggingInfo) -> URL? {
        guard Self.imageDropHandler != nil else { return nil }
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        return urls?.first(where: ImageBatch.isImage)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedImage(sender) == nil ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = droppedImage(sender) else { return false }
        Self.imageDropHandler?(url)
        return true
    }

    /// Without selection (Quick Look) a press is a click at once. With it, a drag selects cells and
    /// a click without a drag clears the selection, or is a click when nothing is selected.
    override func mouseDown(with event: NSEvent) {
        guard let player, player.allowsSelection else { onClick?(); return }
        window?.makeFirstResponder(self)
        pressPoint = convert(event.locationInWindow, from: nil)
        dragAnchor = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let player, player.allowsSelection, let start = pressPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        if dragAnchor == nil {
            guard hypot(point.x - start.x, point.y - start.y) > 3 else { return }
            dragAnchor = cell(at: start)
        }
        if let anchor = dragAnchor {
            let here = cell(at: point)
            player.select(CellRect.spanning(anchor, here))
        }
        autoscroll(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        guard let player, player.allowsSelection, pressPoint != nil else { return }
        let dragged = dragAnchor != nil
        pressPoint = nil
        dragAnchor = nil
        guard !dragged else { return }
        if player.selection != nil { player.select(nil) } else { onClick?() }
    }

    private func cell(at point: NSPoint) -> (Int, Int) {
        guard let player else { return (0, 0) }
        let cell = CellGrid.cell(at: point, in: bounds.size, columns: player.source.columns, rows: player.displayedRows)
        return (cell.x, cell.y)
    }

    @objc override func selectAll(_ sender: Any?) {
        guard let player, player.allowsSelection else {
            // Quick Look: not ours to answer; pass it on as if this view did not implement it.
            nextResponder?.tryToPerform(#selector(selectAll(_:)), with: sender)
            return
        }
        player.selectAll()
    }

    /// Escape or Command-period clears a selection. NSView does not implement this action, so
    /// it is passed on rather than sent to super (which would raise).
    @objc override func cancelOperation(_ sender: Any?) {
        if let player, player.selection != nil {
            player.select(nil)
        } else {
            nextResponder?.tryToPerform(#selector(cancelOperation(_:)), with: sender)
        }
    }

    /// The app's context menu for a viewer with selection (Copy, Copy As, Select All); none in Quick Look.
    static var selectionMenu: ((AnsiCanvasView) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let player, player.allowsSelection, let make = Self.selectionMenu else { return super.menu(for: event) }
        return make(self)
    }

    /// Left and Right arrows step frames (Quick Look has no menus to carry the shortcuts).
    /// Only animated art in a host that wants them takes the arrows; otherwise they pass on.
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, let player, player.selection != nil {
            player.select(nil)
            return
        }
        guard let player, player.timeline != nil, player.handlesArrowKeys else {
            super.keyDown(with: event)
            return
        }
        switch event.keyCode {
        case 123: player.stepFrame(-1)
        case 124: player.stepFrame(1)
        default: super.keyDown(with: event)
        }
    }

    // Menu actions sent through the responder chain from the app's Playback menu.
    @objc func replayAnimation(_ sender: Any?) { player?.replay() }
    @objc func skipAnimation(_ sender: Any?) { player?.skipToEnd() }
    @objc func togglePausePlayback(_ sender: Any?) { player?.togglePause() }
    @objc func previousFrame(_ sender: Any?) { player?.stepFrame(-1) }
    @objc func nextFrame(_ sender: Any?) { player?.stepFrame(1) }
    @objc func toggleMusicMute(_ sender: Any?) { player?.musicMuted.toggle() }
    // View menu zoom presets.
    @objc func zoomToFit(_ sender: Any?) { player?.zoom = .fit }
    @objc func zoomIntegerFit(_ sender: Any?) { player?.zoom = .integerFit }
    @objc func zoomActualSize(_ sender: Any?) { player?.zoom = .scale(1) }
    @objc func zoom2x(_ sender: Any?) { player?.zoom = .scale(2) }
    @objc func zoom3x(_ sender: Any?) { player?.zoom = .scale(3) }
}
