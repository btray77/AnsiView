import AnsiCore
import AppKit
import UniformTypeIdentifiers

/// The baud rate and export order last used for animations (animation plan, ruling 10).
enum AnimationSettings {
    static let bauds = [300, 1200, 2400, 4800, 9600, 14400, 19200, 28800, 57600, 115200]
    static var defaults = UserDefaults.standard

    static var baud: Int {
        get { let value = defaults.integer(forKey: "AnimationBaud"); return bauds.contains(value) ? value : 2400 }
        set { defaults.set(newValue, forKey: "AnimationBaud") }
    }

    static var order: AnimationOrder {
        get { defaults.string(forKey: "AnimationOrder").flatMap(AnimationOrder.init(rawValue:)) ?? .asDrawn }
        set { defaults.set(newValue.rawValue, forKey: "AnimationOrder") }
    }

    static func baudPopup(target: AnyObject?, action: Selector?) -> NSPopUpButton {
        let popup = NSPopUpButton()
        popup.addItems(withTitles: bauds.map { "\($0) baud" })
        popup.selectItem(at: bauds.firstIndex(of: baud) ?? 2)
        popup.target = target
        popup.action = action
        return popup
    }
}

/// Shows one of `AnimationHelp.explanations` in a popover next to a (?) button.
enum AnimationHelpPopover {
    static func button(_ topic: String, target: AnyObject, action: Selector) -> NSButton {
        let button = NSButton(title: "", target: target, action: action)
        button.bezelStyle = .helpButton
        button.identifier = NSUserInterfaceItemIdentifier("help." + topic)
        button.toolTip = "Explain: " + (AnimationHelp.explanations[topic]?.title ?? topic)
        button.setAccessibilityLabel("Explain " + (AnimationHelp.explanations[topic]?.title ?? topic))
        return button
    }

    static func show(from sender: NSButton) {
        guard let id = sender.identifier?.rawValue, id.hasPrefix("help."),
              let entry = AnimationHelp.explanations[String(id.dropFirst(5))] else { return }
        let title = NSTextField(labelWithString: entry.title)
        title.font = .boldSystemFont(ofSize: 13)
        let text = NSTextField(wrappingLabelWithString: entry.text)
        text.preferredMaxLayoutWidth = 360
        let stack = NSStackView(views: [title, text])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        let controller = NSViewController()
        controller.view = stack
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }
}

// MARK: - Frame strip

/// Thumbnails of every frame: click to edit, drag to reorder, right click for duplicate and delete.
final class FrameStripView: NSView {
    unowned let editor: CanvasEditor
    var onSelect: ((Int) -> Void)?
    var onMove: ((Int, Int) -> Void)?
    var onDuplicate: (() -> Void)?
    var onDelete: (() -> Void)?

    static let thumbnailWidth: CGFloat = 128
    static let gap: CGFloat = 10
    static let labelHeight: CGFloat = 18
    private var cache: [Int: (rows: [[AnsiCell]], image: CGImage)] = [:]
    private var pressed: Int?
    private var dropIndex: Int?

    init(editor: CanvasEditor) {
        self.editor = editor
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("strip")
        toolTip = AnimationHelp.tooltips["strip"]
        setAccessibilityLabel("Animation frames")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    private var thumbnailHeight: CGFloat {
        let canvas = editor.canvas
        let font = canvas.font
        let aspect = CGFloat(canvas.height * font.height) / CGFloat(max(1, canvas.columns * font.width))
        return min(96, max(24, (Self.thumbnailWidth * aspect).rounded()))
    }

    var stripHeight: CGFloat { thumbnailHeight + Self.labelHeight + Self.gap }

    func thumbnailRect(_ index: Int) -> NSRect {
        NSRect(x: Self.gap + CGFloat(index) * (Self.thumbnailWidth + Self.gap), y: 6,
               width: Self.thumbnailWidth, height: thumbnailHeight)
    }

    func reload() {
        let count = editor.frames.count
        cache = cache.filter { $0.key < count }
        let width = Self.gap + CGFloat(count) * (Self.thumbnailWidth + Self.gap)
        setFrameSize(NSSize(width: max(width, superview?.bounds.width ?? width), height: stripHeight))
        needsDisplay = true
        scrollToVisible(thumbnailRect(editor.currentFrame).insetBy(dx: -Self.gap, dy: 0))
    }

    /// The frame's picture, re-rendered only when its cells changed.
    private func image(_ index: Int) -> CGImage? {
        let canvas = editor.frameComposite(index)
        if let cached = cache[index], cached.rows == canvas.rows { return cached.image }
        var screen = AnsiScreen(columns: canvas.columns, rows: canvas.rows)
        screen.font = canvas.font
        guard let image = AnsiRenderer.render(screen, options: RenderOptions(font: canvas.font, scale: 1))?.image else { return nil }
        cache[index] = (canvas.rows, image)
        return image
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()
        let frames = editor.frames
        NSGraphicsContext.current?.imageInterpolation = .high
        let label: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
                                                    .foregroundColor: NSColor.secondaryLabelColor]
        for index in frames.indices {
            let rect = thumbnailRect(index)
            guard rect.insetBy(dx: -4, dy: -4).intersects(dirtyRect) || rect.maxY + Self.labelHeight >= dirtyRect.minY else { continue }
            NSColor.black.setFill()
            rect.fill()
            if let image = image(index) {
                NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)).draw(in: rect)
            }
            let current = index == editor.currentFrame
            (current ? NSColor.systemYellow : NSColor.separatorColor).setStroke()
            let path = NSBezierPath(rect: rect.insetBy(dx: -1.5, dy: -1.5))
            path.lineWidth = current ? 3 : 1
            path.stroke()
            let text = String(format: "%d  %.2f s", index + 1, frames[index].delay)
            (text as NSString).draw(at: NSPoint(x: rect.minX + 2, y: rect.maxY + 3), withAttributes: label)
        }
        if let dropIndex {
            NSColor.controlAccentColor.setFill()
            let x = thumbnailRect(dropIndex).minX - Self.gap / 2 - 1.5
            NSRect(x: x, y: 2, width: 3, height: thumbnailHeight + 8).fill()
        }
    }

    /// The frame under `point`, or nil between frames.
    private func index(at point: NSPoint) -> Int? {
        let count = editor.frames.count
        for i in 0..<count where thumbnailRect(i).insetBy(dx: -Self.gap / 2, dy: -4).contains(point) { return i }
        return nil
    }

    private func insertion(at point: NSPoint) -> Int {
        let slot = Int(((point.x - Self.gap / 2) / (Self.thumbnailWidth + Self.gap)).rounded())
        return min(editor.frames.count, max(0, slot))
    }

    override func mouseDown(with event: NSEvent) {
        pressed = index(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseDragged(with event: NSEvent) {
        guard pressed != nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        dropIndex = insertion(at: point)
        autoscroll(with: event)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressed = nil; dropIndex = nil; needsDisplay = true }
        guard let from = pressed else { return }
        if let drop = dropIndex {
            // Dropping before itself or just after itself leaves the order as it is.
            let to = drop > from ? drop - 1 : drop
            if to != from { onMove?(from, to) } else { onSelect?(from) }
        } else {
            onSelect?(from)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let i = index(at: convert(event.locationInWindow, from: nil)) else { return nil }
        onSelect?(i)
        let menu = NSMenu()
        let duplicate = NSMenuItem(title: "Duplicate Frame", action: #selector(duplicateItem(_:)), keyEquivalent: "")
        duplicate.target = self
        duplicate.toolTip = AnimationHelp.tooltips["duplicateFrame"]
        let delete = NSMenuItem(title: "Delete Frame", action: #selector(deleteItem(_:)), keyEquivalent: "")
        delete.target = self
        delete.isEnabled = editor.frames.count > 1
        menu.autoenablesItems = false
        menu.addItem(duplicate)
        menu.addItem(delete)
        return menu
    }

    @objc private func duplicateItem(_ sender: Any?) { onDuplicate?() }
    @objc private func deleteItem(_ sender: Any?) { onDelete?() }
}

// MARK: - Timeline

/// The strip under the editor canvas: frame commands, delay, onion skin, record, play, baud,
/// export and import, and the frame thumbnails (ruling 10).
final class AnimationTimelineView: NSView {
    enum Command { case newFrame, duplicateFrame, deleteFrame, previousFrame, nextFrame }

    weak var controller: EditorViewController?
    let editor: CanvasEditor
    let strip: FrameStripView
    private let scroll = NSScrollView()
    private let delayField = NSTextField()
    private let onionBox = NSButton(checkboxWithTitle: "Onion skin", target: nil, action: nil)
    private let recordButton = NSButton()
    private let frameLabel = NSTextField(labelWithString: "")
    private var baudPopup = NSPopUpButton()
    private var deleteButton = NSButton()
    private var previousButton = NSButton()
    private var nextButton = NSButton()
    /// Ids of the controls shown, for the harness and hints.
    private(set) var controlIDs: [String] = []

    init(editor: CanvasEditor, controller: EditorViewController) {
        self.editor = editor
        self.controller = controller
        strip = FrameStripView(editor: editor)
        super.init(frame: .zero)
        controlIDs.append("strip")

        func button(_ id: String, symbol: String, title: String, action: Selector) -> NSButton {
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            let b = image.map { NSButton(title: title, image: $0, target: self, action: action) } ?? NSButton(title: title, target: self, action: action)
            b.imagePosition = .imageLeading
            b.bezelStyle = .rounded
            b.controlSize = .small
            tag(b, id)
            return b
        }
        let newButton = button("newFrame", symbol: "plus.rectangle.on.rectangle", title: "New Frame", action: #selector(newFrame(_:)))
        let duplicateButton = button("duplicateFrame", symbol: "rectangle.on.rectangle", title: "Duplicate", action: #selector(duplicateFrame(_:)))
        deleteButton = button("deleteFrame", symbol: "trash", title: "Delete", action: #selector(deleteFrame(_:)))
        previousButton = button("previousFrame", symbol: "chevron.left", title: "", action: #selector(previousFrame(_:)))
        nextButton = button("nextFrame", symbol: "chevron.right", title: "", action: #selector(nextFrame(_:)))
        frameLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        frameLabel.textColor = .secondaryLabelColor

        let delayLabel = NSTextField(labelWithString: "Delay:")
        delayLabel.toolTip = AnimationHelp.tooltips["delay"]
        delayField.controlSize = .small
        delayField.alignment = .right
        delayField.target = self
        delayField.action = #selector(delayChanged(_:))
        delayField.widthAnchor.constraint(equalToConstant: 52).isActive = true
        let formatter = NumberFormatter()
        formatter.minimum = 0
        formatter.maximum = 60
        formatter.maximumFractionDigits = 3
        formatter.minimumFractionDigits = 2
        delayField.formatter = formatter
        tag(delayField, "delay")
        let seconds = NSTextField(labelWithString: "s")

        onionBox.target = self
        onionBox.action = #selector(onionChanged(_:))
        onionBox.state = controller.onionSkin ? .on : .off
        tag(onionBox, "onionSkin")
        let onionHelp = AnimationHelpPopover.button("onionSkin", target: self, action: #selector(help(_:)))

        recordButton.title = "Record"
        recordButton.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Record")
        recordButton.imagePosition = .imageLeading
        recordButton.setButtonType(.pushOnPushOff)
        recordButton.bezelStyle = .rounded
        recordButton.controlSize = .small
        recordButton.target = self
        recordButton.action = #selector(recordChanged(_:))
        tag(recordButton, "record")

        let play = button("play", symbol: "play.fill", title: "Play", action: #selector(play(_:)))
        baudPopup = AnimationSettings.baudPopup(target: self, action: #selector(baudChanged(_:)))
        baudPopup.controlSize = .small
        tag(baudPopup, "baud")
        let paddingHelp = AnimationHelpPopover.button("padding", target: self, action: #selector(help(_:)))
        let export = button("export", symbol: "square.and.arrow.up", title: "Export...", action: #selector(export(_:)))
        let importButton = button("import", symbol: "square.and.arrow.down", title: "Import...", action: #selector(importAnimation(_:)))
        let ordersHelp = AnimationHelpPopover.button("orders", target: self, action: #selector(help(_:)))

        let row = NSStackView(views: [newButton, duplicateButton, deleteButton, previousButton, frameLabel, nextButton,
                                      delayLabel, delayField, seconds, onionBox, onionHelp, recordButton, play, baudPopup,
                                      paddingHelp, export, ordersHelp, importButton])
        row.spacing = 6
        row.setCustomSpacing(14, after: deleteButton)
        row.setCustomSpacing(14, after: nextButton)
        row.setCustomSpacing(14, after: seconds)
        row.setCustomSpacing(14, after: onionHelp)
        row.setCustomSpacing(14, after: paddingHelp)

        scroll.documentView = strip
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        strip.onSelect = { [weak self] index in self?.editor.selectFrame(index) }
        strip.onMove = { [weak self] from, to in self?.editor.moveFrame(from: from, to: to) }
        strip.onDuplicate = { [weak self] in self?.perform(.duplicateFrame) }
        strip.onDelete = { [weak self] in self?.perform(.deleteFrame) }

        let separator = NSBox()
        separator.boxType = .separator
        for view in [separator, row, scroll] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 6),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            scroll.topAnchor.constraint(equalTo: row.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.heightAnchor.constraint(equalToConstant: strip.stripHeight + 14),
        ])
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func tag(_ view: NSView, _ id: String) {
        view.identifier = NSUserInterfaceItemIdentifier(id)
        view.toolTip = AnimationHelp.tooltips[id]
        controlIDs.append(id)
    }

    /// Shows the current frame's state; called after every editor change.
    func refresh() {
        let frames = editor.frames
        let current = editor.currentFrame
        frameLabel.stringValue = "\(current + 1) / \(frames.count)"
        if window?.firstResponder != delayField.currentEditor() {
            delayField.doubleValue = frames[current].delay
        }
        deleteButton.isEnabled = frames.count > 1
        previousButton.isEnabled = current > 0
        nextButton.isEnabled = current < frames.count - 1
        recordButton.state = editor.recording ? .on : .off
        recordButton.contentTintColor = editor.recording ? .systemRed : nil
        strip.reload()
    }

    func perform(_ command: Command) {
        guard editor.floating == nil else { NSSound.beep(); return }
        switch command {
        case .newFrame: editor.addFrame()
        case .duplicateFrame: editor.duplicateFrame()
        case .deleteFrame: editor.deleteFrame()
        case .previousFrame: editor.selectFrame(editor.currentFrame - 1)
        case .nextFrame: editor.selectFrame(editor.currentFrame + 1)
        }
        controller?.focusCanvas()
    }

    @objc private func newFrame(_ sender: Any?) { perform(.newFrame) }
    @objc private func duplicateFrame(_ sender: Any?) { perform(.duplicateFrame) }
    @objc private func deleteFrame(_ sender: Any?) { perform(.deleteFrame) }
    @objc private func previousFrame(_ sender: Any?) { perform(.previousFrame) }
    @objc private func nextFrame(_ sender: Any?) { perform(.nextFrame) }

    @objc private func delayChanged(_ sender: NSTextField) {
        editor.setFrameDelay(editor.currentFrame, seconds: sender.doubleValue)
        controller?.focusCanvas()
    }

    @objc private func onionChanged(_ sender: NSButton) {
        controller?.onionSkin = sender.state == .on
        controller?.focusCanvas()
    }

    @objc private func recordChanged(_ sender: NSButton) {
        editor.recording = sender.state == .on
        controller?.transientHint = editor.recording
            ? "Recording: your drawing's timing is kept, so an As drawn export replays your pauses"
            : nil
        refresh()
        controller?.focusCanvas()
    }

    @objc private func baudChanged(_ sender: NSPopUpButton) {
        AnimationSettings.baud = AnimationSettings.bauds[max(0, sender.indexOfSelectedItem)]
    }

    @objc func play(_ sender: Any?) {
        AnimationPreviewController.show(frames: editor.frames, name: controller?.view.window?.title ?? "Animation",
                                        order: AnimationSettings.order, baud: AnimationSettings.baud)
    }

    @objc func export(_ sender: Any?) { controller?.windowController?.exportAnimation() }
    @objc private func importAnimation(_ sender: Any?) { AnimationImportAction.chooseAndOpen() }
    @objc private func help(_ sender: NSButton) { AnimationHelpPopover.show(from: sender) }
}

// MARK: - Preview

/// Plays the exported stream through `AnsiTerminal` (the player's own interpreter) at a baud rate,
/// so the preview is exactly what a caller would see.
final class AnimationPreviewController: NSWindowController {
    private static var open: Set<AnimationPreviewController> = []
    private let frames: [AnimationFrame]
    private(set) var order: AnimationOrder
    private(set) var baud: Int
    private var stream: AnimationStream
    private var terminal: AnsiTerminal
    private var credit = 0.0
    private var elapsed = 0.0
    private var timer: Timer?
    private let screenView = NSImageView()
    private let info = NSTextField(labelWithString: "")
    private let playButton = NSButton()
    private let orderPopup = NSPopUpButton()
    private var baudPopup = NSPopUpButton()
    private let rows: Int

    static func show(frames: [AnimationFrame], name: String, order: AnimationOrder, baud: Int) {
        let controller = AnimationPreviewController(frames: frames, name: name, order: order, baud: baud)
        open.insert(controller)
        controller.showWindow(nil)
        controller.start()
    }

    init(frames: [AnimationFrame], name: String, order: AnimationOrder, baud: Int) {
        self.frames = frames
        self.order = order
        self.baud = baud
        rows = frames.map(\.composite.height).max() ?? 25
        stream = AnimationEncoder.encode(frames, options: AnimationExportOptions(order: order, baud: baud))
        terminal = AnsiTerminal(ArtFile(data: stream.data, fileExtension: "ans"))
        let first = frames.first?.composite ?? EditCanvas()
        let size = NSSize(width: first.columns * first.font.width, height: rows * first.font.height)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: max(560, size.width + 20), height: size.height + 64),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Preview: \(name)"
        window.isReleasedWhenClosed = false
        super.init(window: window)

        screenView.imageScaling = .scaleProportionallyUpOrDown
        screenView.wantsLayer = true
        screenView.layer?.backgroundColor = NSColor.black.cgColor
        screenView.layer?.magnificationFilter = .nearest
        playButton.bezelStyle = .rounded
        playButton.target = self
        playButton.action = #selector(togglePlay(_:))
        playButton.identifier = NSUserInterfaceItemIdentifier("previewPlay")
        playButton.toolTip = AnimationHelp.tooltips["previewPlay"]
        orderPopup.addItems(withTitles: AnimationOrder.allCases.map(\.label))
        orderPopup.selectItem(at: AnimationOrder.allCases.firstIndex(of: order) ?? 0)
        orderPopup.target = self
        orderPopup.action = #selector(settingsChanged(_:))
        orderPopup.toolTip = AnimationHelp.tooltips["previewOrder"]
        baudPopup = AnimationSettings.baudPopup(target: self, action: #selector(settingsChanged(_:)))
        baudPopup.selectItem(at: AnimationSettings.bauds.firstIndex(of: baud) ?? 2)
        baudPopup.toolTip = AnimationHelp.tooltips["baud"]
        info.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        info.textColor = .secondaryLabelColor
        let bar = NSStackView(views: [playButton, orderPopup, baudPopup, info])
        bar.spacing = 8
        let content = NSView()
        for view in [screenView, bar] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            screenView.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            screenView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            screenView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            bar.topAnchor.constraint(equalTo: screenView.bottomAnchor, constant: 8),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            bar.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
        ])
        window.contentView = content
        window.center()
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var isFinished: Bool { terminal.isFinished }

    /// The last frame fully on screen (-1 before the first is complete).
    var frameIndex: Int { (stream.boundaries.lastIndex { $0 <= terminal.position }) ?? -1 }

    func start() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.step(seconds: 1.0 / 30) }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        playButton.title = "Stop"
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        playButton.title = isFinished ? "Replay" : "Play"
    }

    /// Advances playback by `seconds` at the baud rate (10 bits per character).
    func step(seconds: Double) {
        elapsed += seconds
        credit += seconds * Double(baud) / Double(PaddingDelay.bitsPerCharacter)
        let count = Int(credit)
        credit -= Double(count)
        if count > 0 { terminal.advance(byteCount: count) }
        render()
        if isFinished { stop() }
    }

    private func render() {
        let screen = terminal.screen(minimumRows: rows)
        if let image = AnsiRenderer.render(screen.window(top: 0, rows: rows), options: RenderOptions(for: screen, scale: 1))?.image {
            screenView.image = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        }
        let total = Double(stream.body.count) * PaddingDelay.characterTime(baud: baud)
        info.stringValue = String(format: "frame %d of %d   %.1f s of %.1f s   %@ bytes",
                                  max(0, frameIndex) + 1, frames.count, min(elapsed, total), total,
                                  stream.data.count.formatted())
    }

    @objc private func togglePlay(_ sender: Any?) {
        if timer != nil { stop(); return }
        if isFinished { restart() }
        start()
    }

    private func restart() {
        stream = AnimationEncoder.encode(frames, options: AnimationExportOptions(order: order, baud: baud))
        terminal = AnsiTerminal(ArtFile(data: stream.data, fileExtension: "ans"))
        credit = 0
        elapsed = 0
        render()
    }

    @objc private func settingsChanged(_ sender: Any?) {
        order = AnimationOrder.allCases[max(0, orderPopup.indexOfSelectedItem)]
        baud = AnimationSettings.bauds[max(0, baudPopup.indexOfSelectedItem)]
        AnimationSettings.order = order
        AnimationSettings.baud = baud
        restart()
        start()
    }

    override func close() {
        stop()
        super.close()
        Self.open.remove(self)
    }
}

// MARK: - Export

/// The export sheet's settings (ruling 10), with the size of each order and what the file uses.
final class AnimationExportView: NSStackView {
    enum Format: Int, CaseIterable {
        case ansi, gif, mp4
        var label: String { ["ANSI animation (.ans)", "GIF", "MP4 video"][rawValue] }
        var fileExtension: String { ["ans", "gif", "mp4"][rawValue] }
    }

    let editor: CanvasEditor
    private let formatPopup = NSPopUpButton()
    private let orderPopup = NSPopUpButton()
    private var baudPopup = NSPopUpButton()
    private let pausesBox = NSButton(checkboxWithTitle: "Replay recorded pauses", target: nil, action: nil)
    private let markersBox = NSButton(checkboxWithTitle: "AnsiView frame markers (custom extension, not standard ANSI)", target: nil, action: nil)
    private let sizesLabel = NSTextField(wrappingLabelWithString: "")
    private let compatibilityLabel = NSTextField(wrappingLabelWithString: "")
    private let holdsLabel = NSTextField(wrappingLabelWithString: "")

    var sizesText: String { sizesLabel.stringValue }
    var compatibilityText: String { compatibilityLabel.stringValue }
    var format: Format { Format(rawValue: formatPopup.indexOfSelectedItem) ?? .ansi }

    var options: AnimationExportOptions {
        AnimationExportOptions(order: AnimationOrder.allCases[max(0, orderPopup.indexOfSelectedItem)],
                               baud: AnimationSettings.bauds[max(0, baudPopup.indexOfSelectedItem)],
                               replayPauses: pausesBox.state == .on, frameMarkers: markersBox.state == .on)
    }

    init(editor: CanvasEditor) {
        self.editor = editor
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 8
        edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        formatPopup.addItems(withTitles: Format.allCases.map(\.label))
        orderPopup.addItems(withTitles: AnimationOrder.allCases.map(\.label))
        orderPopup.selectItem(at: AnimationOrder.allCases.firstIndex(of: AnimationSettings.order) ?? 0)
        baudPopup = AnimationSettings.baudPopup(target: nil, action: nil)
        pausesBox.state = .on
        markersBox.state = .off
        for (control, id) in [(formatPopup, "format"), (orderPopup, "order"), (baudPopup, "baud"), (pausesBox, "replayPauses"),
                              (markersBox, "frameMarkers")] as [(NSControl, String)] {
            control.target = self
            control.action = #selector(changed(_:))
            control.identifier = NSUserInterfaceItemIdentifier(id)
            control.toolTip = AnimationHelp.tooltips[id]
        }
        for (label, id) in [(sizesLabel, "sizes"), (compatibilityLabel, "compatibility"), (holdsLabel, "compatibility")] {
            label.preferredMaxLayoutWidth = 480
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.toolTip = AnimationHelp.tooltips[id]
        }
        func row(_ title: String, _ views: [NSView]) -> NSStackView {
            let label = NSTextField(labelWithString: title)
            label.alignment = .right
            label.widthAnchor.constraint(equalToConstant: 60).isActive = true
            let stack = NSStackView(views: [label] + views)
            stack.spacing = 6
            return stack
        }
        addArrangedSubview(row("Format:", [formatPopup]))
        addArrangedSubview(row("Order:", [orderPopup, AnimationHelpPopover.button("orders", target: self, action: #selector(help(_:)))]))
        addArrangedSubview(row("Speed:", [baudPopup, AnimationHelpPopover.button("padding", target: self, action: #selector(help(_:)))]))
        addArrangedSubview(pausesBox)
        addArrangedSubview(markersBox)
        addArrangedSubview(sizesLabel)
        addArrangedSubview(compatibilityLabel)
        addArrangedSubview(holdsLabel)
        refresh()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func setFrameMarkers(_ on: Bool) {
        markersBox.state = on ? .on : .off
        refresh()
    }

    @objc private func changed(_ sender: Any?) { refresh() }
    @objc private func help(_ sender: NSButton) { AnimationHelpPopover.show(from: sender) }

    /// Encodes the frames in every order (measured sizes) and reports holds shorter than asked.
    func refresh() {
        let frames = editor.frames
        var chosen = options
        pausesBox.isEnabled = chosen.order == .asDrawn
        markersBox.isEnabled = format == .ansi
        var parts: [String] = []
        var current: AnimationStream?
        for order in AnimationOrder.allCases {
            chosen.order = order
            let stream = AnimationEncoder.encode(frames, options: chosen)
            if order == options.order { current = stream }
            parts.append("\(order.label) \(stream.data.count.formatted()) bytes")
        }
        sizesLabel.stringValue = "File size: " + parts.joined(separator: ", ") + " (\(frames.count) frames at \(options.baud) baud)"
        guard let current else { return }
        compatibilityLabel.stringValue = AnimationStreamCheck.summary(current.body)
        let c = PaddingDelay.characterTime(baud: options.baud)
        let long = frames.indices.filter { Double(current.holds[$0]) * c > frames[$0].delay + c }
        holdsLabel.stringValue = long.isEmpty
            ? "Every frame holds for its delay at \(options.baud) baud."
            : "Frames " + long.map { "\($0 + 1)" }.joined(separator: ", ")
                + " hold longer than their delay: the next frame's cursor and colour codes take longer than that at \(options.baud) baud."
    }
}

extension EditorWindowController {
    /// Tools > Export Animation...: the sheet, then a save panel (ruling 10).
    func exportAnimation() {
        guard let window, editor.floating == nil else { NSSound.beep(); return }
        let view = AnimationExportView(editor: editor)
        view.frame = NSRect(x: 0, y: 0, width: 500, height: 280)
        let alert = NSAlert()
        alert.messageText = "Export Animation"
        alert.informativeText = "Writes \(editor.frames.count) frames. Only the cells that change are sent after the first frame; delays are padding bytes timed for the chosen speed."
        alert.accessoryView = view
        alert.addButton(withTitle: "Export...")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            AnimationSettings.order = view.options.order
            AnimationSettings.baud = view.options.baud
            self.writeAnimation(format: view.format, options: view.options)
        }
    }

    private func writeAnimation(format: AnimationExportView.Format, options: AnimationExportOptions) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: format.fileExtension) ?? .data]
        panel.nameFieldStringValue = "\(window?.title.components(separatedBy: ".").first ?? "Animation").\(format.fileExtension)"
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let stream = AnimationEncoder.encode(editor.frames, options: options)
        do {
            switch format {
            case .ansi:
                try stream.data.write(to: url, options: .atomic)
            case .gif, .mp4:
                var settings = ExportSettings()
                settings.kind = .animation(format == .gif ? .gif : .mp4)
                settings.baud = options.baud
                try AnsiExporter.export(ArtFile(data: stream.data, fileExtension: "ans"), settings: settings, to: url)
            }
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

// MARK: - Import

/// Tools > Import Animation...: an animated ANSI file opened as frames (ruling 7).
enum AnimationImportAction {
    static func chooseAndOpen() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["ans", "asc", "txt", "ice", "diz", "nfo"].compactMap { UTType(filenameExtension: $0) }
        panel.message = "Choose an animated ANSI file. It opens as frames, split where the screen settles."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            open(data: try Data(contentsOf: url), name: url.deletingPathExtension().lastPathComponent, fileExtension: url.pathExtension)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    @discardableResult
    static func open(data: Data, name: String, fileExtension: String) -> EditorWindowController {
        let frames = AnimationImporter.frames(ArtFile(data: data, fileExtension: fileExtension))
        let controller = EditorWindowController.open(editor: CanvasEditor(frames: frames), name: "\(name) (frames)")
        controller.editorController.setTimelineVisible(true)
        controller.editorController.transientHint = "Imported \(frames.count) frames, split where the screen settles"
        return controller
    }
}
