import AnsiCore
import AppKit

/// Slideshow settings, kept with the other playback settings.
enum SlideshowSettings {
    static let autoAdvanceKey = "slideshowAutoAdvance"
    static let dwellKey = "slideshowDwell"
    static let dwellChoices = [5, 10, 20, 30]
    static let defaultDwell = 10

    static var autoAdvance: Bool { PlaybackSpeed.defaults.bool(forKey: autoAdvanceKey) }
    /// Seconds a static piece (or a finished animation) stays up before auto advance moves on.
    static var dwellSeconds: TimeInterval {
        let value = PlaybackSpeed.defaults.object(forKey: dwellKey) as? Double ?? Double(defaultDwell)
        return value > 0 ? value : Double(defaultDwell)
    }
}

/// Shows one piece of a collection at a time. Left and Right (and the Slideshow menu) move between
/// pieces, wrapping at the ends; with Auto Advance on it moves on by itself.
final class SlideshowViewController: NSViewController {
    let collection: ArtCollection
    /// True inside the presentation window: no scrub bar.
    let isPresentation: Bool
    private(set) var index: Int
    private(set) var player: AnsiPlayerViewController?
    /// Kept across pieces, so a zoom chosen on one applies to the next.
    var zoom: ZoomMode = .fit {
        didSet { if player?.zoom != zoom { player?.zoom = zoom } }
    }
    /// Called after each move, with the new index (the window title follows it).
    var onMove: ((Int) -> Void)?
    private var dwellTimer: Timer?
    private var defaultsObserver: NSObjectProtocol?
    /// True while presentation mode has taken over: no dwell, no auto advance.
    private var isSuspended = false

    init(collection: ArtCollection, index: Int, presenting: Bool = false) {
        self.collection = collection
        self.isPresentation = presenting
        self.index = collection.items.indices.contains(index) ? index : 0
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit {
        dwellTimer?.invalidate()
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
    }

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        view = container
        show(index)
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.settingsChanged() }
        }
    }

    var currentName: String { collection.items.indices.contains(index) ? collection.items[index].name : "" }

    /// Moves `delta` pieces forward (positive) or back, wrapping.
    func move(by delta: Int) {
        show(SlideOrder.step(index, by: delta, count: collection.items.count))
    }

    func show(_ newIndex: Int) {
        isSuspended = false
        dwellTimer?.invalidate()
        dwellTimer = nil
        if let old = player {
            old.onFinished = nil
            old.view.removeFromSuperview()
            old.removeFromParent()
        }
        index = newIndex
        let source = collection.artFile(at: newIndex)
        let next = AnsiPlayerViewController(source: source, showsTimeline: !isPresentation)
        next.fileURL = collection.items.indices.contains(newIndex) ? collection.items[newIndex].fileURL : nil
        next.artName = collection.items.indices.contains(newIndex) ? collection.items[newIndex].name : nil
        next.sound = makeSound?()
        next.music = makeSound == nil ? nil : AudioMusicOutput()
        next.handlesArrowKeys = false
        ViewerCopy.enable(next)
        next.zoom = zoom
        next.onZoomChange = { [weak self] zoom in self?.zoom = zoom }
        next.onFinished = { [weak self] in self?.scheduleAdvance() }
        addChild(next)
        next.view.frame = view.bounds
        next.view.autoresizingMask = [.width, .height]
        view.addSubview(next.view)
        player = next
        view.window?.makeFirstResponder(next.canvasView)
        if !next.isPlayable { scheduleAdvance() }
        onMove?(newIndex)
    }

    /// Supplies line sounds for each new player (the app passes its modem sound player).
    var makeSound: (() -> PlaybackSound?)?

    /// Starts the dwell before auto advance (static art, or an animation that just finished).
    private func scheduleAdvance() {
        dwellTimer?.invalidate()
        dwellTimer = nil
        guard !isSuspended, SlideshowSettings.autoAdvance, collection.items.count > 1 else { return }
        let timer = Timer(timeInterval: SlideshowSettings.dwellSeconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.dwellEnded() }
        }
        RunLoop.main.add(timer, forMode: .common)
        dwellTimer = timer
    }

    private func dwellEnded() {
        dwellTimer = nil
        guard SlideshowSettings.autoAdvance, let player else { return }
        // Someone replayed or scrubbed meanwhile: wait for that playback to finish.
        if player.isPlaying || player.isPaused || player.isHolding { return }
        move(by: 1)
    }

    /// Turning Auto Advance on while a piece is resting starts its dwell; turning it off stops it.
    private func settingsChanged() {
        guard !isSuspended, let player else { return }
        if !SlideshowSettings.autoAdvance {
            dwellTimer?.invalidate()
            dwellTimer = nil
        } else if dwellTimer == nil, isResting {
            scheduleAdvance()
        }
    }

    /// The piece is on screen and nothing is playing, paused, held or dialing.
    private var isResting: Bool {
        guard let player else { return false }
        return !player.isPlaying && !player.isPaused && !player.isHolding && !player.isConnecting
    }

    /// Continues `other`'s playback in this slideshow's player (presentation hand-off), then starts
    /// the dwell if the piece is resting, as `onFinished` would have.
    func resume(from other: AnsiPlayerViewController?) {
        isSuspended = false
        if let other { player?.takeOver(from: other) }
        if isResting { scheduleAdvance() }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: move(by: -1)
        case 124: move(by: 1)
        default: super.keyDown(with: event)
        }
    }

    /// Stops the dwell and the current playback (presentation mode took over).
    func suspend() {
        isSuspended = true
        dwellTimer?.invalidate()
        dwellTimer = nil
        player?.halt()
    }

    @objc func nextSlide(_ sender: Any?) { move(by: 1) }
    @objc func previousSlide(_ sender: Any?) { move(by: -1) }
}

/// A slideshow in an ordinary window, titled with the piece's name and position.
final class SlideshowWindowController: NSWindowController, NSWindowDelegate {
    private static var open: Set<SlideshowWindowController> = []

    let slideshow: SlideshowViewController

    @discardableResult
    static func open(collection: ArtCollection, index: Int) -> SlideshowWindowController {
        let controller = SlideshowWindowController(collection: collection, index: index)
        open.insert(controller)
        controller.showWindow(nil)
        return controller
    }

    private init(collection: ArtCollection, index: Int) {
        slideshow = SlideshowViewController(collection: collection, index: index)
        slideshow.makeSound = { ModemSoundPlayer() }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 600),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.backgroundColor = .black
        window.minSize = NSSize(width: 320, height: 200)
        super.init(window: window)
        window.delegate = self
        slideshow.view.frame = window.contentLayoutRect
        slideshow.view.autoresizingMask = [.width, .height]
        window.contentView = NSView(frame: window.contentLayoutRect)
        window.contentView?.addSubview(slideshow.view)
        slideshow.onMove = { [weak self] _ in self?.updateTitle() }
        updateTitle()
        window.center()
        // Each slideshow window steps down from the frontmost window instead of covering it.
        if let key = NSApp.keyWindow {
            window.setFrameTopLeftPoint(window.cascadeTopLeft(from: NSPoint(x: key.frame.minX, y: key.frame.maxY)))
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func updateTitle() {
        let count = slideshow.collection.items.count
        window?.title = count == 0
            ? "\(slideshow.collection.title) (no art)"
            : "\(slideshow.currentName)  (\(slideshow.index + 1) of \(count), \(slideshow.collection.title))"
        if let canvas = slideshow.player?.canvasView { window?.makeFirstResponder(canvas) }
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        if let canvas = slideshow.player?.canvasView { window?.makeFirstResponder(canvas) }
    }

    func windowWillClose(_ notification: Notification) {
        Self.open.remove(self)
    }
}

extension AnsiPlayerViewController {
    /// Slideshow > Start Slideshow from a document window: the file's folder, starting at this file.
    /// The sandbox normally hides the folder, so AnsiView asks for it with an open panel.
    @objc func startSlideshow(_ sender: Any?) {
        if parent is SlideshowViewController {
            NSSound.beep()
            return
        }
        guard let fileURL else { NSSound.beep(); return }
        let folder = fileURL.deletingLastPathComponent()
        if let collection = try? ArtCollection.open(folder, scoped: false), !collection.items.isEmpty {
            SlideshowWindowController.open(collection: collection, index: Self.index(of: fileURL, in: collection))
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = folder
        panel.prompt = "Start Slideshow"
        panel.message = "Choose the folder to show. AnsiView can read only folders you choose."
        let begin: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let collection = try ArtCollection.open(url, scoped: true)
                SlideshowWindowController.open(collection: collection, index: Self.index(of: fileURL, in: collection))
            } catch {
                NSAlert(error: error).runModal()
            }
        }
        if let window = view.window { panel.beginSheetModal(for: window, completionHandler: begin) } else { begin(panel.runModal()) }
    }

    static func index(of fileURL: URL, in collection: ArtCollection) -> Int {
        let target = fileURL.standardizedFileURL.resolvingSymlinksInPath()
        return collection.items.firstIndex { $0.fileURL?.standardizedFileURL.resolvingSymlinksInPath() == target } ?? 0
    }
}
