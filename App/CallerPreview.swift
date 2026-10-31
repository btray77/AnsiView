import AnsiCore
import AppKit

/// Screen > Preview as Caller...: the screen as the chosen BBS sends it (codes replaced by the
/// sample values), played through AnsiView's terminal emulator at the chosen baud and size, with
/// warnings for what a caller may see differently (screen designer ruling 9).
final class CallerPreviewWindowController: NSWindowController, NSWindowDelegate {
    private static var open: Set<CallerPreviewWindowController> = []
    let viewController: CallerPreviewViewController

    static func showForFocusedEditor() {
        guard let editor = ScreenDesigner.requireEditor("preview") else { return }
        show(project: editor.editor.project, name: editor.window?.title ?? "Screen")
    }

    @discardableResult
    static func show(project: ArtProject, name: String, profile: ExportProfile? = nil, platform: RetroPlatform? = nil) -> CallerPreviewWindowController {
        let controller = CallerPreviewWindowController(project: project, name: name, profile: profile, platform: platform)
        open.insert(controller)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.viewController.replay()
        return controller
    }

    init(project: ArtProject, name: String, profile: ExportProfile?, platform: RetroPlatform? = nil) {
        viewController = CallerPreviewViewController(project: project, profile: profile, platform: platform)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Preview as Caller: \(name)"
        window.contentMinSize = NSSize(width: 800, height: 520)
        super.init(window: window)
        window.contentViewController = viewController
        window.setContentSize(NSSize(width: 1100, height: 760))
        window.center()
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func windowWillClose(_ notification: Notification) {
        viewController.stop()
        Self.open.remove(self)
    }
}

final class CallerPreviewViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    let project: ArtProject
    var profile: ExportProfile
    lazy var packagePopup = ScreenDesigner.packagePopup(selected: profile.package, tooltip: "The BBS that sends the screen: whose codes are read")
    let nativeBox = NSButton(checkboxWithTitle: "Package colour codes", target: nil, action: nil)
    let baudPopup = NSPopUpButton()
    let sizePopup = NSPopUpButton()
    let encodingPopup = NSPopUpButton()
    let iceBox = NSButton(checkboxWithTitle: "iCE colours", target: nil, action: nil)
    /// PC (the BBS package's ANSI) or a retro platform the screen is redrawn for (final gaps ruling 8).
    let terminalPopup = NSPopUpButton()
    let screenView = NSImageView()
    let sizeLabel = ScreenDesigner.label("", size: 12)
    let warningsTable = NSTableView()
    static let bauds = [300, 1200, 2400, 9600, 14400, 19200, 28800, 33600, 57600, 115200, 0]

    private(set) var engine: any TerminalEngine = TerminalEmulator()
    private var initialPlatform: RetroPlatform?
    private var pacer = LinePacer(baud: 2400)
    private var timer: Timer?
    private var lastTick = ProcessInfo.processInfo.systemUptime
    private(set) var warnings: [PreviewWarning] = []
    private(set) var sentBytes: [UInt8] = []

    init(project: ArtProject, profile: ExportProfile?, platform: RetroPlatform? = nil) {
        self.project = project
        self.profile = profile ?? ExportProfile(package: ScreenDesignerSettings.shared.package)
        initialPlatform = platform
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        for baud in Self.bauds { baudPopup.addItem(withTitle: baud == 0 ? "Unlimited" : "\(baud) baud") }
        baudPopup.selectItem(at: 2)
        baudPopup.toolTip = "The caller's modem speed: the screen draws as fast as that line carries it (10 bits a character)"
        for size in CallerTerminalSize.presets { sizePopup.addItem(withTitle: size.label) }
        sizePopup.selectItem(at: project.frames[0].composite.columns > 80 ? 2 : 0)
        sizePopup.toolTip = "The caller's terminal size"
        encodingPopup.addItems(withTitles: ["CP437 (DOS)", "UTF-8"])
        encodingPopup.selectItem(at: profile.encoding == .utf8 ? 1 : 0)
        encodingPopup.toolTip = "CP437 for DOS style terminals (SyncTERM, NetRunner); UTF-8 for modern terminals that do not speak CP437"
        nativeBox.state = profile.colourCodes == .native ? .on : .off
        nativeBox.toolTip = "Send the colours as the package's own codes instead of ANSI escapes (the BBS turns them into ANSI for the caller)"
        iceBox.state = project.frames[0].composite.iceColors ? .on : .off
        iceBox.toolTip = "Whether the caller's terminal shows the blink bit as bright backgrounds (iCE) or as blinking"
        terminalPopup.addItem(withTitle: String(localized: "PC (ANSI-BBS)"))
        for p in RetroPlatform.allCases { terminalPopup.addItem(withTitle: p.label) }
        terminalPopup.selectItem(at: initialPlatform.flatMap { RetroPlatform.allCases.firstIndex(of: $0) }.map { $0 + 1 } ?? 0)
        terminalPopup.toolTip = String(localized: "The caller's computer: a PC terminal gets the BBS package's ANSI; a Commodore, Atari or Viewdata caller gets the screen redrawn for that platform")
        for control in [terminalPopup, packagePopup, baudPopup, sizePopup, encodingPopup, nativeBox, iceBox] as [NSControl] {
            control.target = self
            control.action = #selector(replay)
        }
        let replayButton = NSButton(title: "Replay", target: self, action: #selector(replay))
        replayButton.toolTip = "Clears the caller's screen and sends the screen again"
        let samples = NSButton(title: "Sample Values...", target: self, action: #selector(showSamples))
        samples.toolTip = String(localized: "The made up caller name, dates and numbers the preview puts in place of display codes")
        let help = TextArtImages.helpButton(
            "This is what a caller sees: the screen goes through the BBS package (its codes become the sample values), then over a line at the chosen speed into AnsiView's terminal emulator. The warnings come from following the cursor as a terminal that wraps at once (ANSI.SYS) would; AnsiView's own terminal waits at the edge, so a column 80 problem may not show above but would on such a caller.",
            tooltip: "About the caller preview")
        let top = ScreenDesigner.row([terminalPopup, Hint.button(.retroExport), packagePopup, nativeBox, baudPopup, sizePopup, encodingPopup, iceBox, Hint.button(.iceColours), NSView(), samples, replayButton, help])
        screenView.imageScaling = .scaleProportionallyUpOrDown
        screenView.wantsLayer = true
        screenView.layer?.backgroundColor = NSColor.black.cgColor
        screenView.setContentCompressionResistancePriority(.fittingSizeCompression, for: .horizontal)
        screenView.setContentCompressionResistancePriority(.fittingSizeCompression, for: .vertical)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("warning"))
        column.title = "Warnings"
        column.width = 900
        warningsTable.addTableColumn(column)
        warningsTable.dataSource = self
        warningsTable.delegate = self
        warningsTable.rowHeight = 22
        let scroll = NSScrollView()
        scroll.documentView = warningsTable
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.heightAnchor.constraint(equalToConstant: 130).isActive = true
        let stack = ScreenDesigner.column([top, screenView, sizeLabel, scroll], spacing: 8)
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        for view in [top, screenView, scroll] { view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true }
        screenView.setContentHuggingPriority(.defaultLow, for: .vertical)
        view = ScreenDesigner.container(stack)
    }

    var size: CallerTerminalSize { CallerTerminalSize.presets[max(0, sizePopup.indexOfSelectedItem)] }
    var baud: Int { Self.bauds[max(0, baudPopup.indexOfSelectedItem)] }

    var platform: RetroPlatform? {
        let i = terminalPopup.indexOfSelectedItem - 1
        return RetroPlatform.allCases.indices.contains(i) ? RetroPlatform.allCases[i] : nil
    }

    /// Builds what the BBS sends with the current choices and starts sending it.
    @objc func replay() {
        for control in [packagePopup, nativeBox, sizePopup, encodingPopup, iceBox] as [NSControl] { control.isEnabled = platform == nil }
        if let platform {
            replayRetro(platform)
            return
        }
        profile.package = ScreenDesigner.package(of: packagePopup)
        profile.colourCodes = nativeBox.state == .on ? .native : .ansi
        profile.encoding = encodingPopup.indexOfSelectedItem == 1 ? .utf8 : .cp437
        let samples = ScreenDesignerSettings.shared.samples
        // Codes are read from the CP437 file; a UTF-8 caller gets the result converted.
        var cp437 = profile
        cp437.encoding = .cp437
        let exported = ScreenExporter.export(project, profile: cp437, slot: .custom)
        var sent = BBSDisplay.render(exported.body, package: profile.package, samples: samples)
        warnings = ScreenExporter.export(project, profile: profile, slot: .custom).warnings
            .filter { $0.kind != .needsIce || iceBox.state == .off }
            + CallerPreviewAnalysis.layoutWarnings(sent, size: size)
        if profile.encoding == .utf8 { sent = ScreenEncoding.utf8(fromCP437: sent) }
        sentBytes = sent
        sizeLabel.stringValue = "File \(exported.data.count) bytes; the caller receives " + CallerPreviewAnalysis.sizeLine(bytes: sent.count, baud: baud)
            + (warnings.isEmpty ? ". No warnings." : ".")
        warningsTable.reloadData()
        var emulator = TerminalEmulator(columns: size.columns, rows: size.rows, encoding: profile.encoding)
        emulator.iceColors = iceBox.state == .on
        engine = emulator
        start(sent)
    }

    /// The screen redrawn for a retro platform and played through that platform's terminal.
    private func replayRetro(_ platform: RetroPlatform) {
        let canvas = project.frames[project.frames.count > 1 ? 0 : project.currentFrame].composite
        let result = RetroScreenEncoder.encode(canvas, for: platform)
        warnings = result.warnings
        sentBytes = result.bytes
        sizeLabel.stringValue = "\(platform.label), \(platform.columns) x \(platform.rows): the caller receives "
            + CallerPreviewAnalysis.sizeLine(bytes: result.bytes.count, baud: baud) + (warnings.isEmpty ? ". No warnings." : ".")
        warningsTable.reloadData()
        engine = TerminalEngines.make(platform.emulation, columns: platform.columns, rows: platform.rows, encoding: .cp437, iceColors: false)
        start(result.bytes)
    }

    private func start(_ sent: [UInt8]) {
        pacer = LinePacer(baud: baud)
        pacer.push(sent)
        lastTick = ProcessInfo.processInfo.systemUptime
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }
        tick()
    }

    func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let bytes = pacer.release(elapsed: now - lastTick)
        lastTick = now
        if !bytes.isEmpty { engine.feed(bytes) }
        draw()
        if pacer.pending == 0 { timer?.invalidate(); timer = nil }
    }

    /// Sends the rest at once (the harness, and Unlimited).
    func finishNow() {
        engine.feed(pacer.release(elapsed: 1e9))
        draw()
    }

    private func draw() {
        let screen = engine.screen(scrollOffset: 0)
        if let rendered = AnsiRenderer.render(screen, options: RenderOptions(font: engine.font ?? .vga, scale: 1)) {
            screenView.image = NSImage(cgImage: rendered.image, size: NSSize(width: rendered.image.width, height: rendered.image.height))
        }
    }

    func stop() { timer?.invalidate(); timer = nil }

    @objc func showSamples() { SampleValuesWindowController.show() }

    func numberOfRows(in tableView: NSTableView) -> Int { max(1, warnings.count) }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard !warnings.isEmpty else {
            return ScreenDesigner.label("No warnings: the screen fits a \(platform.map { "\($0.label) \($0.columns) x \($0.rows)" } ?? size.label) caller.", secondary: true)
        }
        let warning = warnings[row]
        let text = ScreenDesigner.label("\u{26A0} " + warning.message)
        text.lineBreakMode = .byTruncatingTail
        text.toolTip = warning.help
        let help = TextArtImages.helpButton(warning.help, tooltip: "Why this matters")
        return ScreenDesigner.row([help, text], spacing: 6)
    }
}
