import AnsiCore
import AppKit
import ObjectiveC
import UniformTypeIdentifiers

// Viewer tools for the app's art windows (plan 9 items 38, 40, 41, 42): find in art, smooth auto
// scroll, the minimap and live palettes. App only: Quick Look compiles `Shared/` but not this file,
// so its previews never get any of these.

// MARK: Palettes (ruling 6)

/// Built in and loaded palettes, and the one new windows use. Loaded palettes are copied into the
/// app's container, so the original file can move or go away.
final class PaletteLibrary: ObservableObject {
    static let shared = PaletteLibrary(folder: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Palettes"))
    /// The chosen palette's name in the app's own defaults (not shared with Quick Look); none means the art's own colours.
    static let choiceKey = "viewerPalette"

    let folder: URL
    @Published private(set) var loaded: [NamedPalette] = []
    @Published private(set) var currentName: String?

    init(folder: URL) {
        self.folder = folder
        loaded = LibraryFiles.load([NamedPalette].self, from: file) ?? []
        currentName = UserDefaults.standard.string(forKey: Self.choiceKey)
        if let name = currentName, palette(named: name) == nil { currentName = nil }
    }

    private var file: URL { folder.appendingPathComponent("palettes.json") }

    var all: [NamedPalette] { PaletteFile.builtIn + loaded }

    func palette(named name: String) -> NamedPalette? { all.first { $0.name == name } }

    /// The colours new windows (and the focused one, after a choice) use; nil for the art's own.
    var currentColors: [RGB]? { currentName.flatMap(palette(named:))?.colors }

    func choose(_ name: String?) {
        currentName = name.flatMap { palette(named: $0) == nil ? nil : $0 }
        if let currentName { UserDefaults.standard.set(currentName, forKey: Self.choiceKey) }
        else { UserDefaults.standard.removeObject(forKey: Self.choiceKey) }
    }

    /// Art's own colours, then every palette in menu order, then round again.
    func chooseNext() {
        let names: [String?] = [nil] + all.map(\.name)
        let index = names.firstIndex(of: currentName) ?? 0
        choose(names[(index + 1) % names.count])
    }

    /// Reads a palette file and keeps a copy; a name already used gets a number.
    @discardableResult
    func load(_ url: URL) throws -> NamedPalette {
        let data = try Data(contentsOf: url)
        var palette = try PaletteFile.load(data, fileExtension: url.pathExtension,
                                           name: url.deletingPathExtension().lastPathComponent)
        let base = palette.name
        var number = 2
        while self.palette(named: palette.name) != nil {
            palette.name = "\(base) \(number)"
            number += 1
        }
        loaded.append(palette)
        try LibraryFiles.save(loaded, to: file)
        return palette
    }

    func removeLoaded() {
        loaded = []
        try? LibraryFiles.save(loaded, to: file)
        if let name = currentName, palette(named: name) == nil { choose(nil) }
    }

    /// View > Palette > Load Palette File...
    func chooseAndLoad() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = PaletteFile.extensions.compactMap { UTType(filenameExtension: $0) }
        panel.allowsOtherFileTypes = true
        panel.message = "Choose palette files: JASC .pal, GIMP .gpl, Adobe .act, or XBin / ADF / IDF art that carries its own palette."
        panel.prompt = "Load"
        guard panel.runModal() == .OK else { return }
        var last: NamedPalette?
        for url in panel.urls {
            do { last = try load(url) } catch { NSAlert(error: error).runModal() }
        }
        if let last {
            choose(last.name)
            NSApp.sendAction(#selector(AnsiCanvasView.applyChosenPalette(_:)), to: nil, from: nil)
        }
    }
}

// MARK: Per window tools

/// The find bar, auto scroll and minimap of one player.
final class ViewerTools: NSObject, NSSearchFieldDelegate {
    static let minimapKey = "showMinimap"
    static let speedKey = "autoScrollSpeed"
    static let minimapWidth: CGFloat = 64
    private static var key: UInt8 = 0

    static var showsMinimap: Bool { UserDefaults.standard.object(forKey: minimapKey) as? Bool ?? true }

    /// Gives an app window's player the tools and the chosen palette. Call before the view loads.
    static func enable(_ player: AnsiPlayerViewController) {
        guard tools(for: player) == nil else { return }
        let tools = ViewerTools(player: player)
        objc_setAssociatedObject(player, &key, tools, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        player.paletteOverride = PaletteLibrary.shared.currentColors
        let previousLoad = player.onViewLoaded
        player.onViewLoaded = { [weak tools] p in
            previousLoad?(p)
            tools?.install()
        }
        if player.isViewLoaded { tools.install() }
    }

    static func tools(for player: AnsiPlayerViewController) -> ViewerTools? {
        objc_getAssociatedObject(player, &key) as? ViewerTools
    }

    private weak var player: AnsiPlayerViewController?
    private var installed = false
    private var observers: [NSObjectProtocol] = []

    private init(player: AnsiPlayerViewController) {
        self.player = player
        super.init()
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        scrollTimer?.invalidate()
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    private func install() {
        guard !installed, let player else { return }
        installed = true
        installFindBar(in: player.view)
        installAutoScrollBar(in: player.view)
        installMinimap(in: player.view)
        let clip = player.scrollView.contentView
        clip.postsBoundsChangedNotifications = true
        clip.postsFrameChangedNotifications = true
        for name in [NSView.boundsDidChangeNotification, NSView.frameDidChangeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: clip, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateMinimap() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil,
                                                                queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateMinimap() }
        })
        let previousRedraw = player.onRedraw
        player.onRedraw = { [weak self] in
            previousRedraw?()
            self?.screenChanged()
        }
        updateMinimap()
    }

    private var canvasHeight: CGFloat { player?.canvasView.frame.height ?? 0 }
    private var visibleHeight: CGFloat { player?.scrollView.contentView.bounds.height ?? 0 }

    private func screenChanged() {
        guard let player else { return }
        // A playback restarting shows other rows under the same cells: drop the highlights.
        if !player.screenIsFinal, !matches.isEmpty {
            matches = []
            currentMatch = nil
            player.highlight([], current: nil)
            updateFindStatus()
        }
        // The finished art only changes with the palette, which the picture's key already covers,
        // so a blink or a playback frame never draws the minimap again.
        updateMinimap()
    }

    // MARK: Find (ruling 2)

    private let findBar = NSView()
    private let findField = NSSearchField()
    private let findLabel = NSTextField(labelWithString: "")
    private(set) var matches: [CellRect] = []
    private(set) var currentMatch: Int?
    var findBarShown: Bool { !findBar.isHidden }
    private(set) var findStatus = ""

    private func installFindBar(in container: NSView) {
        findBar.wantsLayer = true
        findBar.layer?.backgroundColor = NSColor(white: 0.12, alpha: 0.94).cgColor
        findBar.layer?.cornerRadius = 7
        findBar.appearance = NSAppearance(named: .darkAqua)
        findBar.isHidden = true
        findBar.translatesAutoresizingMaskIntoConstraints = false
        findField.placeholderString = "Find in art"
        findField.toolTip = "Finds text in the finished art (case and accents ignored). Return: next match, Shift-Return: previous, Escape: close."
        findField.delegate = self
        findField.sendsSearchStringImmediately = true
        findField.target = self
        findField.action = #selector(findFieldChanged(_:))
        findLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        findLabel.textColor = NSColor(white: 0.8, alpha: 1)
        func button(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
            let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!, target: self, action: action)
            b.bezelStyle = .texturedRounded
            b.toolTip = tip
            return b
        }
        let previous = button("chevron.up", "Previous match (Cmd-Shift-G)", #selector(previousPressed(_:)))
        let next = button("chevron.down", "Next match (Cmd-G)", #selector(nextPressed(_:)))
        let done = NSButton(title: "Done", target: self, action: #selector(donePressed(_:)))
        done.bezelStyle = .texturedRounded
        done.toolTip = "Close the find bar (Escape)"
        let stack = NSStackView(views: [findField, findLabel, previous, next, done])
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        findBar.addSubview(stack)
        container.addSubview(findBar)
        NSLayoutConstraint.activate([
            findField.widthAnchor.constraint(equalToConstant: 200),
            findLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 60),
            stack.leadingAnchor.constraint(equalTo: findBar.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: findBar.trailingAnchor),
            stack.topAnchor.constraint(equalTo: findBar.topAnchor),
            stack.bottomAnchor.constraint(equalTo: findBar.bottomAnchor),
            findBar.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            findBar.trailingAnchor.constraint(equalTo: player!.scrollView.trailingAnchor, constant: -10),
        ])
    }

    func showFind() {
        guard let player else { return }
        if !player.screenIsFinal || player.isPlaying || player.isHolding { player.skipToEnd() }
        findBar.isHidden = false
        player.view.window?.makeFirstResponder(findField)
        if !findField.stringValue.isEmpty { find(findField.stringValue) }
    }

    func closeFind() {
        findBar.isHidden = true
        matches = []
        currentMatch = nil
        player?.highlight([], current: nil)
        if let player { player.view.window?.makeFirstResponder(player.canvasView) }
    }

    /// Finds `query` in the finished art and shows the first match.
    func find(_ query: String) {
        guard let player else { return }
        if findField.stringValue != query { findField.stringValue = query }
        if !player.screenIsFinal || player.isPlaying { player.skipToEnd() }
        matches = ArtSearch.matches(in: player.displayedScreen, query: query)
        let top = player.scrollView.contentView.bounds.minY
        currentMatch = matches.isEmpty ? nil : (matches.firstIndex { player.canvasRect(for: $0).minY >= top - 1 } ?? 0)
        showCurrent()
    }

    func findNext() { step(1) }
    func findPrevious() { step(-1) }

    private func step(_ delta: Int) {
        if findBar.isHidden { showFind() }
        guard !matches.isEmpty else { NSSound.beep(); return }
        currentMatch = ((currentMatch ?? -delta) + delta + matches.count) % matches.count
        showCurrent()
    }

    private func showCurrent() {
        guard let player else { return }
        player.highlight(matches, current: currentMatch)
        if let index = currentMatch {
            let rect = player.canvasRect(for: matches[index])
            player.canvasView.scrollToVisible(rect.insetBy(dx: -40, dy: -60))
        }
        updateFindStatus()
    }

    private func updateFindStatus() {
        let query = findField.stringValue.trimmingCharacters(in: .whitespaces)
        if query.isEmpty { findStatus = "" }
        else if let index = currentMatch { findStatus = "\(index + 1) of \(matches.count)" }
        else { findStatus = "Not found" }
        findLabel.stringValue = findStatus
        findLabel.textColor = findStatus == "Not found" ? .systemOrange : NSColor(white: 0.8, alpha: 1)
    }

    @objc private func findFieldChanged(_ sender: NSSearchField) { find(sender.stringValue) }
    @objc private func nextPressed(_ sender: Any?) { findNext() }
    @objc private func previousPressed(_ sender: Any?) { findPrevious() }
    @objc private func donePressed(_ sender: Any?) { closeFind() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { findPrevious() } else { findNext() }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            closeFind()
            return true
        default:
            return false
        }
    }

    // MARK: Auto scroll (ruling 4)

    private let scrollBar = NSView()
    private let speedLabel = NSTextField(labelWithString: "")
    private let pauseButton = NSButton()
    private var scrollTimer: Timer?
    private var lastTick: TimeInterval = 0
    private var monitor: Any?
    private(set) var isAutoScrolling = false
    private(set) var isAutoScrollPaused = false
    var autoScrollSpeed: Int = {
        let saved = UserDefaults.standard.integer(forKey: ViewerTools.speedKey)
        return AutoScroll.speeds.contains(saved) ? saved : AutoScroll.defaultSpeed
    }() {
        didSet { updateSpeedLabel() }
    }

    var autoScrollAvailable: Bool {
        guard let player, player.screenIsFinal else { return false }
        return AutoScroll.isUseful(documentHeight: canvasHeight, visibleHeight: visibleHeight)
    }

    private func installAutoScrollBar(in container: NSView) {
        scrollBar.wantsLayer = true
        scrollBar.layer?.backgroundColor = NSColor(white: 0.12, alpha: 0.94).cgColor
        scrollBar.layer?.cornerRadius = 7
        scrollBar.appearance = NSAppearance(named: .darkAqua)
        scrollBar.isHidden = true
        scrollBar.translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(labelWithString: "Auto scroll")
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = .white
        speedLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        speedLabel.textColor = NSColor(white: 0.85, alpha: 1)
        func button(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
            let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!, target: self, action: action)
            b.bezelStyle = .texturedRounded
            b.toolTip = tip
            return b
        }
        let slower = button("minus", "Slower (- or Down arrow)", #selector(slowerPressed(_:)))
        let faster = button("plus", "Faster (+ or Up arrow)", #selector(fasterPressed(_:)))
        pauseButton.image = NSImage(systemSymbolName: "pause.fill", accessibilityDescription: "Pause")
        pauseButton.bezelStyle = .texturedRounded
        pauseButton.target = self
        pauseButton.action = #selector(pausePressed(_:))
        pauseButton.toolTip = "Pause or continue (Space)"
        let stop = button("stop.fill", "Stop auto scroll (Escape, a click, or View > Auto Scroll)", #selector(stopPressed(_:)))
        let help = Hint.button(.autoScroll)
        let stack = NSStackView(views: [title, slower, speedLabel, faster, pauseButton, stop, help])
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 10, bottom: 5, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollBar.addSubview(stack)
        container.addSubview(scrollBar)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: scrollBar.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollBar.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scrollBar.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollBar.bottomAnchor),
            speedLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),
            scrollBar.centerXAnchor.constraint(equalTo: player!.scrollView.centerXAnchor),
            scrollBar.bottomAnchor.constraint(equalTo: player!.scrollView.bottomAnchor, constant: -12),
        ])
        updateSpeedLabel()
    }

    private func updateSpeedLabel() {
        speedLabel.stringValue = isAutoScrollPaused ? "Paused" : "\(autoScrollSpeed) lines/s"
    }

    func toggleAutoScroll() {
        if isAutoScrolling { stopAutoScroll() } else { startAutoScroll() }
    }

    func startAutoScroll() {
        guard let player else { return }
        if !player.screenIsFinal || player.isPlaying { player.skipToEnd() }
        player.view.layoutSubtreeIfNeeded()
        guard autoScrollAvailable else { NSSound.beep(); return }
        let clip = player.scrollView.contentView
        if clip.bounds.maxY >= canvasHeight - 1 { scroll(to: 0) }
        isAutoScrolling = true
        isAutoScrollPaused = false
        scrollBar.isHidden = false
        updateSpeedLabel()
        lastTick = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = ProcessInfo.processInfo.systemUptime
                let elapsed = now - self.lastTick
                self.lastTick = now
                self.tick(elapsed: elapsed)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        scrollTimer = timer
        installMonitor()
    }

    func stopAutoScroll() {
        isAutoScrolling = false
        isAutoScrollPaused = false
        scrollTimer?.invalidate()
        scrollTimer = nil
        scrollBar.isHidden = true
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        UserDefaults.standard.set(autoScrollSpeed, forKey: Self.speedKey)
    }

    func togglePauseAutoScroll() {
        guard isAutoScrolling else { return }
        isAutoScrollPaused.toggle()
        lastTick = ProcessInfo.processInfo.systemUptime
        pauseButton.image = NSImage(systemSymbolName: isAutoScrollPaused ? "play.fill" : "pause.fill",
                                    accessibilityDescription: isAutoScrollPaused ? "Continue" : "Pause")
        updateSpeedLabel()
    }

    func speedUp() { autoScrollSpeed = AutoScroll.step(autoScrollSpeed, by: 1); UserDefaults.standard.set(autoScrollSpeed, forKey: Self.speedKey) }
    func slowDown() { autoScrollSpeed = AutoScroll.step(autoScrollSpeed, by: -1); UserDefaults.standard.set(autoScrollSpeed, forKey: Self.speedKey) }

    /// Moves the view on by `elapsed` seconds of auto scroll (the timer calls it; checks call it directly).
    func tick(elapsed: TimeInterval) {
        guard isAutoScrolling, !isAutoScrollPaused, let player else { return }
        let clip = player.scrollView.contentView
        let rows = max(1, player.displayedRows)
        let step = AutoScroll.offset(from: clip.bounds.origin.y, elapsed: elapsed, linesPerSecond: autoScrollSpeed,
                                     pointsPerLine: canvasHeight / CGFloat(rows),
                                     maxOffset: max(0, canvasHeight - clip.bounds.height))
        scroll(to: step.offset)
        if step.atEnd { stopAutoScroll() }
    }

    private func scroll(to y: CGFloat) {
        guard let player else { return }
        let clip = player.scrollView.contentView
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
        player.scrollView.reflectScrolledClipView(clip)
    }

    @objc private func slowerPressed(_ sender: Any?) { slowDown() }
    @objc private func fasterPressed(_ sender: Any?) { speedUp() }
    @objc private func pausePressed(_ sender: Any?) { togglePauseAutoScroll() }
    @objc private func stopPressed(_ sender: Any?) { stopAutoScroll() }

    /// While auto scroll runs, its keys go to it (before the menus, so Space pauses it instead of
    /// replaying), and a click on the art stops it instead of replaying an animation.
    private func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, self.isAutoScrolling, let player = self.player, event.window === player.view.window,
                      event.window?.firstResponder === player.canvasView else { return event }
                if event.type == .leftMouseDown {
                    let point = player.canvasView.convert(event.locationInWindow, from: nil)
                    guard player.canvasView.bounds.contains(point) else { return event }
                    self.stopAutoScroll()
                    return nil
                }
                guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return event }
                switch (event.keyCode, event.charactersIgnoringModifiers ?? "") {
                case (126, _), (_, "+"), (_, "="): self.speedUp()
                case (125, _), (_, "-"), (_, "_"): self.slowDown()
                case (49, _): self.togglePauseAutoScroll()
                case (53, _): self.stopAutoScroll()
                default: return event
                }
                return nil
            }
        }
    }

    // MARK: Minimap (ruling 5)

    let minimap = MinimapView()
    /// Minimap pictures drawn so far (for checks).
    private(set) var minimapRenders = 0
    private var minimapImageKey: String?

    var minimapShown: Bool { !minimap.isHidden }

    private func installMinimap(in container: NSView) {
        minimap.isHidden = true
        minimap.translatesAutoresizingMaskIntoConstraints = false
        minimap.toolTip = "Minimap: the whole piece, squeezed to fit. Click or drag to jump there. View > Show Minimap turns it off."
        minimap.onJump = { [weak self] fraction in self?.minimapJump(toStripFraction: fraction) }
        container.addSubview(minimap)
        NSLayoutConstraint.activate([
            minimap.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            minimap.topAnchor.constraint(equalTo: player!.scrollView.topAnchor),
            minimap.bottomAnchor.constraint(equalTo: player!.scrollView.bottomAnchor),
            minimap.widthAnchor.constraint(equalToConstant: Self.minimapWidth),
        ])
    }

    /// Centres the view on the part of the art at `fraction` (0 top, 1 bottom) of the strip.
    func minimapJump(toStripFraction fraction: CGFloat) {
        let geometry = MinimapGeometry(documentHeight: canvasHeight, visibleHeight: visibleHeight, stripHeight: 1)
        scroll(to: geometry.offset(forStripY: min(1, max(0, fraction))))
        updateMinimap()
    }

    private func updateMinimap() {
        guard installed, let player else { return }
        // Judge the height the art would have with the strip showing (the width it takes changes Fit).
        let show = Self.showsMinimap && player.screenIsFinal && !player.isTerminalMode
            && MinimapGeometry.isShown(documentHeight: canvasHeight, visibleHeight: visibleHeight)
        if minimap.isHidden == show {
            minimap.isHidden = !show
            player.trailingInset = show ? Self.minimapWidth : 0
            player.view.layoutSubtreeIfNeeded()
        }
        guard show else { return }
        let key = "\(player.paletteOverride.map { $0.map { "\($0.r).\($0.g).\($0.b)" }.joined() } ?? "own")"
        if minimapImageKey != key {
            minimapImageKey = key
            minimapRenders += 1
            let screen = player.finalScreenAsShown
            let font = screen.font
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let image = MinimapView.render(screen, font: font)
                DispatchQueue.main.async { self?.minimap.image = image }
            }
        }
        let geometry = MinimapGeometry(documentHeight: canvasHeight, visibleHeight: visibleHeight,
                                       stripHeight: minimap.bounds.height)
        let box = geometry.indicator(offset: player.scrollView.contentView.bounds.minY)
        minimap.indicator = CGRect(x: 0, y: box.y, width: minimap.bounds.width, height: box.height)
    }
}

/// The minimap strip: the whole finished art squeezed to the strip, a box over the visible part.
final class MinimapView: NSView {
    var onJump: ((CGFloat) -> Void)?
    private let box = CALayer()

    var image: CGImage? {
        didSet { layer?.contents = image }
    }
    /// The box over the visible part, in the view's top down points.
    var indicator: CGRect = .zero {
        didSet { layoutBox() }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.06, alpha: 1).cgColor
        layer?.contentsGravity = .resize
        layer?.minificationFilter = .trilinear
        box.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
        box.borderWidth = 1.5
        box.backgroundColor = NSColor.white.withAlphaComponent(0.15).cgColor
        box.actions = ["position": NSNull(), "bounds": NSNull(), "frame": NSNull()]
        layer?.addSublayer(box)
        setAccessibilityElement(true)
        setAccessibilityRole(.scrollBar)
        setAccessibilityLabel("Minimap")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    private func layoutBox() {
        var frame = indicator
        if !(layer?.isGeometryFlipped ?? false) { frame.origin.y = bounds.height - frame.maxY }
        box.frame = frame
    }

    override func layout() {
        super.layout()
        layoutBox()
    }

    override func mouseDown(with event: NSEvent) { jump(event) }
    override func mouseDragged(with event: NSEvent) { jump(event) }

    private func jump(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.height > 0 else { return }
        onJump?(point.y / bounds.height)
    }

    /// The art at 1 font pixel per point, then shrunk to at most 128 x 4096 pixels.
    static func render(_ screen: AnsiScreen, font: BitmapFont) -> CGImage? {
        var options = RenderOptions(for: screen, scale: 1)
        options.font = font
        guard let full = AnsiRenderer.render(screen, options: options)?.image else { return nil }
        let width = min(128, full.width), height = min(4096, full.height)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return full }
        context.interpolationQuality = .high
        context.draw(full, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}

// MARK: Menu actions (sent through the responder chain from the app's menus)

extension AnsiCanvasView {
    private var tools: ViewerTools? { player.flatMap(ViewerTools.tools(for:)) }

    @objc func showArtFind(_ sender: Any?) { tools?.showFind() ?? NSSound.beep() }
    @objc func artFindNext(_ sender: Any?) { tools?.findNext() ?? NSSound.beep() }
    @objc func artFindPrevious(_ sender: Any?) { tools?.findPrevious() ?? NSSound.beep() }
    @objc func toggleAutoScroll(_ sender: Any?) { tools?.toggleAutoScroll() ?? NSSound.beep() }
    @objc func applyChosenPalette(_ sender: Any?) { player?.paletteOverride = PaletteLibrary.shared.currentColors }
}

/// Edit > Find commands: the focused art view (or compare, gallery, library window) answers; a
/// text field gets the standard text finder instead.
enum FindCommands {
    static func send(_ action: Selector, textFinderTag: NSTextFinder.Action) {
        if NSApp.sendAction(action, to: nil, from: nil) { return }
        let item = NSMenuItem()
        item.tag = textFinderTag.rawValue
        if !NSApp.sendAction(#selector(NSResponder.performTextFinderAction(_:)), to: nil, from: item) { NSSound.beep() }
    }
}
