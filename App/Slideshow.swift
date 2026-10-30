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

/// The art files of a folder or a ZIP art pack, in slideshow order. Holds the folder's security
/// scoped access (when it was granted through an open panel) for as long as it lives.
final class ArtCollection {
    struct Item {
        let name: String
        /// The file on disk; nil for entries inside an art pack.
        let fileURL: URL?
        let load: () throws -> Data
    }

    let title: String
    let items: [Item]
    /// Art entries in a pack that use a compression method AnsiView cannot read.
    let skipped: Int
    private let scopedURL: URL?

    private init(title: String, items: [Item], skipped: Int, scopedURL: URL?) {
        self.title = title
        self.items = items
        self.skipped = skipped
        self.scopedURL = scopedURL
    }

    deinit { scopedURL?.stopAccessingSecurityScopedResource() }

    /// A folder or a `.zip` art pack. `scoped` starts security scoped access to a URL that came
    /// from an open panel; it is stopped when the collection goes away.
    static func open(_ url: URL, scoped: Bool) throws -> ArtCollection {
        let started = scoped && url.startAccessingSecurityScopedResource()
        let scope = started ? url : nil
        do {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                return try folder(url, scope: scope)
            }
            return try pack(url, scope: scope)
        } catch {
            if started { url.stopAccessingSecurityScopedResource() }
            throw error
        }
    }

    /// The art files directly inside `url` (subfolders are not searched).
    private static func folder(_ url: URL, scope: URL?) throws -> ArtCollection {
        let contents = try FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        let byName = Dictionary(contents.map { ($0.lastPathComponent, $0) }, uniquingKeysWith: { a, _ in a })
        let items = ArtFiles.ordered(Array(byName.keys)).compactMap { name -> Item? in
            guard let file = byName[name] else { return nil }
            return Item(name: name, fileURL: file, load: { try Data(contentsOf: file) })
        }
        return ArtCollection(title: url.lastPathComponent, items: items, skipped: 0, scopedURL: scope)
    }

    private static func pack(_ url: URL, scope: URL?) throws -> ArtCollection {
        let archive = try ZipArchive(data: try Data(contentsOf: url, options: .mappedIfSafe))
        let items = archive.artEntries.map { entry in
            Item(name: entry.name, fileURL: nil, load: { try archive.data(for: entry) })
        }
        return ArtCollection(title: url.lastPathComponent, items: items, skipped: archive.skippedCount, scopedURL: scope)
    }

    func artFile(at index: Int) -> ArtFile {
        guard items.indices.contains(index) else { return ArtFile(data: Data()) }
        let item = items[index]
        let data = (try? item.load()) ?? Data()
        return ArtFile(data: data, fileExtension: (item.name as NSString).pathExtension)
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
        didSet { player?.zoom = zoom }
    }
    /// Called after each move, with the new index (the window title follows it).
    var onMove: ((Int) -> Void)?
    private var dwellTimer: Timer?
    private var defaultsObserver: NSObjectProtocol?

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
        next.sound = makeSound?()
        next.handlesArrowKeys = false
        next.zoom = zoom
        next.onFinished = { [weak self] in self?.scheduleAdvance() }
        addChild(next)
        next.view.frame = view.bounds
        next.view.autoresizingMask = [.width, .height]
        view.addSubview(next.view)
        player = next
        view.window?.makeFirstResponder(next.canvasView)
        if !next.analysis.isAnimated { scheduleAdvance() }
        onMove?(newIndex)
    }

    /// Supplies line sounds for each new player (the app passes its modem sound player).
    var makeSound: (() -> PlaybackSound?)?

    /// Starts the dwell before auto advance (static art, or an animation that just finished).
    private func scheduleAdvance() {
        dwellTimer?.invalidate()
        dwellTimer = nil
        guard SlideshowSettings.autoAdvance, collection.items.count > 1 else { return }
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
        guard let player else { return }
        if !SlideshowSettings.autoAdvance {
            dwellTimer?.invalidate()
            dwellTimer = nil
        } else if dwellTimer == nil, !player.isPlaying, !player.isPaused, !player.isHolding {
            scheduleAdvance()
        }
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
        window.setFrameAutosaveName("Slideshow")
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
        if let slideshow = parent as? SlideshowViewController {
            slideshow.move(by: 0)
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
