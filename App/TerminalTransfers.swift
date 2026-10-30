import AnsiCore
import AppKit

/// File transfers for one terminal window: the pure `TransferCoordinator` decides what each
/// received chunk is for; this class runs the `FileTransferSession` in pull mode over the
/// terminal's `BBSClient`, shows the ask bar and the transfer panel, writes the transfer log and
/// keeps the download folder's sandbox permission.
final class TerminalTransfers: NSObject {
    weak var terminal: TerminalViewController?
    private(set) var coordinator: TransferCoordinator
    private(set) var session: FileTransferSession?
    private(set) var model: TransferPanelModel?
    private(set) var summary: TransferSummary?
    /// Lines of the last session's log (shown in the summary).
    private(set) var lastLog: [String] = []
    private var flow = TransferFlow()
    private var timer: Timer?
    private var request: TransferRequest?
    private var pendingFiles: [URL] = []
    private var pendingName = "download.bin"
    private var accessedFolder: URL?

    let panel = TransferPanelView()
    let bar = TransferOfferBar()

    // Seams for the harness (the app leaves them nil).
    /// Chooses files for an upload the BBS asked for, instead of the open panel.
    var chooseFilesOverride: ((TransferProtocolKind, @escaping ([URL]?) -> Void) -> Void)?
    /// The download folder to use, instead of the entry's or the default bookmark.
    var downloadFolderOverride: URL?
    var logStore = TransferLogStore(directory: TerminalTransfers.defaultLogDirectory)
    /// Every coordinator action performed (for the harness).
    private(set) var performed: [String] = []

    static var defaultLogDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return support.appendingPathComponent("AnsiView/Transfer Logs", isDirectory: true)
    }

    static let defaultFolderKey = "transferDownloadFolder"

    init(terminal: TerminalViewController) {
        self.terminal = terminal
        coordinator = TransferCoordinator(autoAcceptZmodem: terminal.entry.zmodemAutoAccept,
                                          usesTelnet: TransportSettings(entry: terminal.entry).usesTelnet)
        super.init()
        panel.onCancel = { [weak self] in self?.cancel() }
        panel.onClose = { [weak self] in self?.closePanel() }
        panel.onReveal = { [weak self] in self?.revealDownloads() }
        panel.onShowLog = { [weak self] in
            guard let self, let entry = self.terminal?.entry else { return }
            TransferLogWindowController.show(entry: entry, store: self.logStore)
        }
        bar.onAccept = { [weak self] in self?.acceptOffer() }
        bar.onIgnore = { [weak self] in self?.ignoreOffer() }
    }

    deinit {
        timer?.invalidate()
        accessedFolder?.stopAccessingSecurityScopedResource()
    }

    /// Puts the bar and the panel over the bottom of the terminal view.
    func install(over terminalView: NSView, in container: NSView) {
        for view in [bar, panel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.isHidden = true
            container.addSubview(view)
        }
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: terminalView.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: terminalView.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: terminalView.bottomAnchor),
            panel.centerXAnchor.constraint(equalTo: terminalView.centerXAnchor),
            panel.bottomAnchor.constraint(equalTo: terminalView.bottomAnchor, constant: -8),
            panel.widthAnchor.constraint(equalToConstant: 600),
        ])
    }

    /// Keys are blocked and the screen paused.
    var isActive: Bool { coordinator.isTransferActive }

    /// A short status line part while something is going on.
    var statusText: String? {
        switch coordinator.state {
        case .idle: return nil
        case .offering: return "File transfer offered"
        case .choosingFiles: return "Choosing files to upload"
        case .negotiating: return "Asking the BBS for binary mode"
        case .running: return model.map { "\($0.title): \($0.bytesLine)" } ?? "File transfer"
        }
    }

    private var now: Double { ProcessInfo.processInfo.systemUptime }
    private var byteClean: Bool { terminal?.client?.isByteClean ?? true }

    // MARK: Driving

    func received(_ bytes: [UInt8]) {
        perform(coordinator.received(bytes, at: now, byteClean: byteClean))
    }

    /// Terminal > Download...: asks for the protocol (and the name for XMODEM), then starts.
    func chooseDownload() {
        guard let terminal, terminal.client?.state == .connected, !isActive else { NSSound.beep(); return }
        TransferChooser.download(entry: terminal.entry, window: terminal.view.window, transfers: self) { [weak self] choice in
            guard let self, let choice else { return }
            self.startDownload(kind: choice.kind, xmodemName: choice.name)
        }
    }

    /// Terminal > Upload File(s)...: the open panel with a protocol choice.
    func chooseUpload() {
        guard let terminal, terminal.client?.state == .connected, !isActive else { NSSound.beep(); return }
        TransferChooser.upload(entry: terminal.entry, fixed: nil, window: terminal.view.window) { [weak self] choice in
            guard let self, let choice else { return }
            self.startUpload(files: choice.files, kind: choice.kind)
        }
    }

    /// Starts receiving (the BBS must be sending, or about to).
    func startDownload(kind: TransferProtocolKind, xmodemName: String = "download.bin") {
        remember(kind)
        guard ensureFolder() else { return }
        pendingName = xmodemName.isEmpty ? "download.bin" : xmodemName
        perform(coordinator.begin(kind: kind, direction: .receive, at: now, byteClean: byteClean))
    }

    func startUpload(files: [URL], kind: TransferProtocolKind) {
        remember(kind)
        pendingFiles = kind.isBatch ? files : Array(files.prefix(1))
        perform(coordinator.begin(kind: kind, direction: .send, at: now, byteClean: byteClean))
    }

    /// Escape, the panel's Cancel or Terminal > Cancel Transfer.
    func cancel() {
        if let session, !session.isFinished {
            session.cancel(reason: "cancelled by user")
            pump()
        } else {
            perform(coordinator.cancelPending(at: now))
        }
    }

    func acceptOffer() {
        guard case .offering(let offer) = coordinator.state else { return }
        if offer.detected.direction == .receive {
            remember(offer.detected.kind)
            guard ensureFolder() else { return }
            pendingName = "download.bin"
        }
        perform(coordinator.accept(at: now, byteClean: byteClean))
    }

    func ignoreOffer() { perform(coordinator.ignore(at: now)) }

    func connectionClosed() { perform(coordinator.connectionClosed(at: now)) }

    /// A new connection or a closed window: everything stops without a trace on the line.
    func reset() {
        if let session, !session.isFinished { session.cancel(reason: "the session ended") }
        session = nil
        timer?.invalidate()
        timer = nil
        _ = coordinator.connectionClosed(at: now)
        if let terminal {
            coordinator = TransferCoordinator(autoAcceptZmodem: terminal.entry.zmodemAutoAccept,
                                              usesTelnet: TransportSettings(entry: terminal.entry).usesTelnet)
        }
        bar.isHidden = true
        panel.isHidden = true
    }

    private func perform(_ actions: [TransferCoordinatorAction]) {
        for action in actions {
            performed.append(String(describing: action).prefix(80).description)
            if performed.count > 500 { performed.removeFirst(100) }
            switch action {
            case .showOnScreen(let bytes): terminal?.showIncoming(bytes)
            case .feedSession(let bytes):
                session?.feed(bytes)
                pump()
            case .showOffer(let offer):
                bar.show(offer)
                startTimer()
            case .hideOffer: bar.isHidden = true
            case .requestBinary:
                terminal?.pauseForTransfer()
                terminal?.client?.requestBinary()
                showWaiting()
                startTimer()
            case .chooseUploadFiles(let kind): chooseFilesForBBS(kind)
            case .startSession(let request): start(request)
            case .sendToRemote(let bytes):
                terminal?.client?.sendTransfer(bytes) {}
                finishWithoutSession()
            case .failSession(let reason):
                if let session, !session.isFinished {
                    session.cancel(reason: reason)
                }
            }
        }
        terminal.map { _ in updateStatus() }
    }

    private func updateStatus() {
        // The terminal's status line reads `statusText`.
        terminal?.refreshStatus()
    }

    private func chooseFilesForBBS(_ kind: TransferProtocolKind) {
        let done: ([URL]?) -> Void = { [weak self] urls in
            guard let self else { return }
            if let urls, !urls.isEmpty {
                self.remember(kind)
                self.pendingFiles = urls
                self.perform(self.coordinator.filesChosen(true, at: self.now, byteClean: self.byteClean))
            } else {
                self.perform(self.coordinator.filesChosen(false, at: self.now, byteClean: self.byteClean))
            }
        }
        if let chooseFilesOverride { chooseFilesOverride(kind, done); return }
        guard let terminal else { done(nil); return }
        TransferChooser.upload(entry: terminal.entry, fixed: kind, window: terminal.view.window) { choice in done(choice?.files) }
    }

    private func showWaiting() {
        guard case .negotiating(let kind, let direction, _) = coordinator.state else { return }
        var waiting = TransferPanelModel(kind: kind, direction: direction, fileCount: nil, totalBytes: nil)
        waiting.warning = nil
        model = waiting
        summary = nil
        panel.showRunning(waiting, note: "Asking the BBS for telnet binary mode...")
    }

    // MARK: Session

    private func start(_ request: TransferRequest) {
        guard let terminal else { return }
        self.request = request
        terminal.pauseForTransfer()
        var options = request.options()
        options.zmodemBlockSize = 1024
        let made: FileTransferSession
        var total: Int?
        var count: Int?
        if request.direction == .receive {
            guard let folder = accessedFolder ?? downloadFolderOverride else {
                fail(request, "no download folder is chosen")
                return
            }
            var sinkOptions = DownloadsDirectorySink.Options()
            sinkOptions.keepPartialForResume = request.kind == .zmodem
            let sink = DownloadsDirectorySink(directory: folder, options: sinkOptions)
            made = FileTransferSession(receivingInto: sink, kind: request.kind, options: options, xmodemFileName: pendingName)
        } else {
            var files: [OutgoingFile] = []
            for url in pendingFiles {
                do { files.append(try OutgoingFile(url: url)) } catch {
                    fail(request, "\(url.lastPathComponent) cannot be read (\(error))")
                    return
                }
            }
            guard !files.isEmpty else {
                fail(request, "no file was chosen")
                return
            }
            count = files.count
            total = files.reduce(0) { $0 + $1.size }
            made = FileTransferSession(sending: files, kind: request.kind, options: options)
        }
        var panelModel = TransferPanelModel(kind: request.kind, direction: request.direction, fileCount: count, totalBytes: total,
                                            zmodemBlockSize: options.zmodemBlockSize)
        panelModel.warning = request.warning
        model = panelModel
        summary = nil
        made.onEvent = { [weak self] event in
            self?.model?.apply(event)
            self?.refreshPanel()
        }
        made.onProgress = { [weak self] progress in
            self?.model?.apply(progress)
            self?.refreshPanel()
        }
        made.onFinish = { [weak self] outcome in self?.finished(outcome) }
        session = made
        flow = TransferFlow()
        refreshPanel()
        startTimer()
        made.start()
        if !request.initialBytes.isEmpty { made.feed(request.initialBytes) }
        pump()
    }

    private func fail(_ request: TransferRequest, _ reason: String) {
        // Nothing started on our side; tell the BBS (its sender or receiver may be waiting).
        terminal?.client?.sendTransfer(TransferCoordinator.cancelSequence) {}
        summary = TransferSummary(outcome: .failed(reason), kind: request.kind, direction: request.direction, elapsed: 0, bytes: 0)
        lastLog = ["transfer failed: \(reason)"]
        writeLog(kind: request.kind, direction: request.direction, lines: lastLog)
        coordinator.sessionFinished(at: now)
        terminal?.resumeAfterTransfer()
        panel.showSummary(summary!, log: lastLog)
    }

    /// Pull mode: takes engine output only while the connection has room (ruling 4).
    func pump() {
        guard let session, let client = terminal?.client else { return }
        while true {
            let room = flow.nextChunkSize()
            guard room > 0 else { break }
            let bytes = session.takeOutput(max: room)
            if bytes.isEmpty { break }
            let count = bytes.count
            flow.sent(count)
            client.sendTransfer(bytes) { [weak self] in
                guard let self else { return }
                self.flow.completed(count)
                self.pump()
            }
        }
    }

    private func startTimer() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        if case .negotiating = coordinator.state {
            perform(coordinator.tick(at: now, byteClean: byteClean))
        }
        if let session, !session.isFinished {
            session.tick()
            pump()
        }
        if session == nil, coordinator.state == .idle, timer != nil {
            timer?.invalidate()
            timer = nil
        }
    }

    private func finished(_ outcome: FileTransferSession.Outcome) {
        guard let session, let request else { return }
        let progress = session.progress
        // The cancel sequence (if any) is still queued: send it.
        pump()
        let result = TransferSummary(outcome: outcome, kind: request.kind, direction: request.direction,
                                     elapsed: progress.elapsed, bytes: progress.sessionBytes)
        summary = result
        lastLog = session.logLines()
        writeLog(kind: request.kind, direction: request.direction, lines: lastLog + ["result: \(result.headline)"] + result.lines)
        self.session = nil
        coordinator.sessionFinished(at: now)
        terminal?.resumeAfterTransfer()
        panel.showSummary(result, log: lastLog)
        updateStatus()
    }

    private func finishWithoutSession() {
        panel.isHidden = true
        terminal?.resumeAfterTransfer()
    }

    private func refreshPanel() {
        guard let model, session != nil else { return }
        panel.showRunning(model, note: nil)
        updateStatus()
    }

    private func closePanel() {
        panel.isHidden = true
        summary = nil
        terminal?.view.window?.makeFirstResponder(terminal?.terminalView)
    }

    private func revealDownloads() {
        if let files = summary?.files.compactMap(\.url), !files.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(files)
        } else if let folder = summary?.folder ?? accessedFolder {
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        }
    }

    private func writeLog(kind: TransferProtocolKind, direction: TransferDirection, lines: [String]) {
        guard let entry = terminal?.entry else { return }
        let header = TransferLogStore.header(entryName: entry.name, kind: kind, direction: direction, date: Date())
        try? logStore.append(entryID: entry.id, text: ([header] + lines).joined(separator: "\n") + "\n\n")
    }

    // MARK: Protocol memory and folders

    private func remember(_ kind: TransferProtocolKind) {
        guard let terminal, terminal.entry.transferProtocol != kind else { return }
        terminal.updateEntry { $0.transferProtocol = kind }
    }

    /// Makes sure a writable download folder is open for this session (ruling 6). False when
    /// none could be had (the user cancelled the panel, or the folder cannot be written).
    @discardableResult
    func ensureFolder() -> Bool {
        if downloadFolderOverride != nil { return true }
        guard let terminal else { return false }
        if let url = TransferFolders.resolve(terminal.entry.downloadFolderBookmark) ?? TransferFolders.resolve(
            UserDefaults.standard.data(forKey: Self.defaultFolderKey)) {
            return open(url)
        }
        guard let url = TransferFolders.ask(message: "Choose the folder where downloads are saved. AnsiView remembers it.") else {
            return false
        }
        if let bookmark = TransferFolders.bookmark(url) {
            UserDefaults.standard.set(bookmark, forKey: Self.defaultFolderKey)
        }
        return open(url)
    }

    /// A folder chosen in the download chooser for this BBS only.
    func setEntryFolder(_ url: URL) {
        guard let bookmark = TransferFolders.bookmark(url) else { return }
        terminal?.updateEntry {
            $0.downloadFolderBookmark = bookmark
            $0.downloadFolderName = (url.path as NSString).abbreviatingWithTildeInPath
        }
        accessedFolder?.stopAccessingSecurityScopedResource()
        accessedFolder = nil
    }

    /// The folder downloads go to now, for showing (nil until one is known).
    var currentFolderName: String {
        if let downloadFolderOverride { return (downloadFolderOverride.path as NSString).abbreviatingWithTildeInPath }
        if let name = terminal?.entry.downloadFolderName { return name }
        if let url = TransferFolders.resolve(UserDefaults.standard.data(forKey: Self.defaultFolderKey)) {
            return (url.path as NSString).abbreviatingWithTildeInPath + " (default)"
        }
        return "not chosen yet (you will be asked)"
    }

    private func open(_ url: URL) -> Bool {
        if accessedFolder?.standardizedFileURL == url.standardizedFileURL { return true }
        accessedFolder?.stopAccessingSecurityScopedResource()
        accessedFolder = nil
        let accessing = url.startAccessingSecurityScopedResource()
        if let problem = TransferFolders.writeCheck(url) {
            if accessing { url.stopAccessingSecurityScopedResource() }
            if terminal?.showsAlerts == true {
                let alert = NSAlert()
                alert.messageText = "AnsiView cannot save downloads in \(url.lastPathComponent)"
                alert.informativeText = problem + " Choose another folder with Terminal > Download... > Change."
                alert.runModal()
            }
            return false
        }
        accessedFolder = url
        return true
    }
}

/// Download folder bookmarks and the sandbox write check.
enum TransferFolders {
    static func resolve(_ bookmark: Data?) -> URL? {
        guard let bookmark else { return nil }
        var stale = false
        return try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
    }

    static func bookmark(_ url: URL) -> Data? {
        try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// The user's real Downloads folder (the sandbox's own home is the app container).
    static var realDownloads: URL {
        if let pw = getpwuid(getuid()), let home = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: home)).appendingPathComponent("Downloads", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    }

    static func ask(message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = realDownloads
        panel.prompt = "Choose"
        panel.message = message
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Creates and removes a small file: nil when the folder can be written, else the reason.
    static func writeCheck(_ folder: URL) -> String? {
        let probe = folder.appendingPathComponent(".ansiview-write-check-\(getpid())")
        let fd = Darwin.open(probe.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return String(cString: strerror(errno)) + "." }
        close(fd)
        unlink(probe.path)
        return nil
    }
}

// MARK: - Choosers

enum TransferChooser {
    struct Download { var kind: TransferProtocolKind; var name: String }
    struct Upload { var kind: TransferProtocolKind; var files: [URL] }

    static func protocolPopup(selected: TransferProtocolKind) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        for kind in TransferProtocolKind.allCases {
            popup.addItem(withTitle: kind.displayName)
            popup.lastItem?.toolTip = TransferHelp.hint(kind)
        }
        popup.selectItem(at: TransferProtocolKind.allCases.firstIndex(of: selected) ?? 5)
        popup.toolTip = TransferHelp.chooser
        return popup
    }

    /// The protocol row with its (?) button, and the popup.
    static func protocolRow(selected: TransferProtocolKind) -> (NSView, NSPopUpButton) {
        let label = NSTextField(labelWithString: "Protocol:")
        let popup = protocolPopup(selected: selected)
        let help = TransferHelpButton(text: TransferHelp.chooser + "\n\n" + TransferHelp.allProtocols)
        let row = NSStackView(views: [label, popup, help])
        row.orientation = .horizontal
        row.spacing = 8
        return (row, popup)
    }

    static func download(entry: BBSEntry, window: NSWindow?, transfers: TerminalTransfers, done: @escaping (Download?) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Download from \(entry.name)"
        alert.informativeText = "Start the download on the BBS first (or right after this), then press Download. ZMODEM and Kermit downloads usually start by themselves."
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Cancel")
        let (row, popup) = protocolRow(selected: entry.transferProtocol)
        let nameLabel = NSTextField(labelWithString: "XMODEM file name:")
        let name = NSTextField(string: "download.bin")
        name.toolTip = TransferHelp.xmodemName
        name.widthAnchor.constraint(equalToConstant: 220).isActive = true
        let nameRow = NSStackView(views: [nameLabel, name])
        nameRow.spacing = 8
        let folder = NSTextField(labelWithString: "Saving to: \(transfers.currentFolderName)")
        folder.toolTip = TransferHelp.folder
        folder.lineBreakMode = .byTruncatingMiddle
        let change = NSButton(title: "Change...", target: nil, action: nil)
        change.toolTip = "Choose the download folder for this BBS."
        let changer = ClosureTarget {
            guard let url = TransferFolders.ask(message: "Choose the download folder for \(entry.name).") else { return }
            transfers.setEntryFolder(url)
            folder.stringValue = "Saving to: \(transfers.currentFolderName)"
        }
        change.target = changer
        change.action = #selector(ClosureTarget.run)
        let folderRow = NSStackView(views: [folder, change])
        folderRow.spacing = 8
        let updateName = ClosureTarget {
            let kind = TransferProtocolKind.allCases[popup.indexOfSelectedItem]
            nameRow.isHidden = kind.isBatch
        }
        popup.target = updateName
        popup.action = #selector(ClosureTarget.run)
        updateName.run()
        let stack = NSStackView(views: [row, nameRow, folderRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 420, height: 96)
        alert.accessoryView = stack
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            _ = (changer, updateName)  // kept alive while the alert is up
            guard response == .alertFirstButtonReturn else { done(nil); return }
            let kind = TransferProtocolKind.allCases[popup.indexOfSelectedItem]
            done(Download(kind: kind, name: name.stringValue.trimmingCharacters(in: .whitespaces)))
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: finish) } else { finish(alert.runModal()) }
    }

    /// The open panel with the protocol choice; `fixed` when the BBS already chose (auto start).
    static func upload(entry: BBSEntry, fixed: TransferProtocolKind?, window: NSWindow?, done: @escaping (Upload?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Upload"
        panel.message = fixed.map { "The BBS is waiting for files with \($0.displayName). Choose the files to upload." }
            ?? "Choose the files to upload to \(entry.name). Start the upload on the BBS first."
        let (row, popup) = protocolRow(selected: fixed ?? entry.transferProtocol)
        popup.isEnabled = fixed == nil
        row.frame = NSRect(x: 0, y: 0, width: 420, height: 32)
        panel.accessoryView = row
        panel.isAccessoryViewDisclosed = true
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, !panel.urls.isEmpty else { done(nil); return }
            let kind = fixed ?? TransferProtocolKind.allCases[popup.indexOfSelectedItem]
            if !kind.isBatch, panel.urls.count > 1 {
                let alert = NSAlert()
                alert.messageText = "\(kind.displayName) sends one file at a time"
                alert.informativeText = "Only \(panel.urls[0].lastPathComponent) will be sent. Choose YMODEM, ZMODEM or Kermit to send several files at once."
                alert.runModal()
            }
            done(Upload(kind: kind, files: panel.urls))
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: finish) } else { finish(panel.runModal()) }
    }
}

/// Runs a closure as an AppKit target.
final class ClosureTarget: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func run() { action() }
}

/// A (?) button that shows its text in a popover.
final class TransferHelpButton: NSButton {
    let text: String

    init(text: String) {
        self.text = text
        super.init(frame: .zero)
        bezelStyle = .helpButton
        title = ""
        toolTip = "Explain"
        target = self
        action = #selector(showHelp)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc func showHelp() {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = TransferHelpPopover(text: text)
        popover.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
    }
}

final class TransferHelpPopover: NSViewController {
    let text: String
    init(text: String) {
        self.text = text
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        let label = NSTextField(wrappingLabelWithString: text)
        label.preferredMaxLayoutWidth = 380
        label.frame = NSRect(x: 12, y: 12, width: 380, height: 10)
        let size = label.fittingSize
        label.frame.size = NSSize(width: 380, height: size.height)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 404, height: size.height + 24))
        container.addSubview(label)
        view = container
    }
}

// MARK: - Ask bar

/// The non-modal bar that asks about a detected transfer start (ruling 1).
final class TransferOfferBar: NSView {
    var onAccept: (() -> Void)?
    var onIgnore: (() -> Void)?
    let message = NSTextField(labelWithString: "")
    let acceptButton = NSButton(title: "Receive", target: nil, action: nil)
    let ignoreButton = NSButton(title: "Ignore", target: nil, action: nil)
    let help = TransferHelpButton(text: TransferHelp.autoStart + "\n\n" + TransferHelp.hint(.zmodem) + "\n\nIgnore draws what arrived as text and lets the BBS give up by itself; typing Ctrl-X five times stops it sooner.")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedRed: 0.10, green: 0.16, blue: 0.32, alpha: 0.96).cgColor
        message.textColor = .white
        message.font = .systemFont(ofSize: 13, weight: .semibold)
        message.lineBreakMode = .byTruncatingTail
        message.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        acceptButton.bezelStyle = .rounded
        acceptButton.keyEquivalent = ""
        acceptButton.target = self
        acceptButton.action = #selector(accept)
        acceptButton.toolTip = "Start the transfer the BBS offered."
        ignoreButton.bezelStyle = .rounded
        ignoreButton.target = self
        ignoreButton.action = #selector(ignore)
        ignoreButton.toolTip = "Not a transfer, or not now: show it as text. The same offer is not asked again for a minute."
        let stack = NSStackView(views: [message, help, acceptButton, ignoreButton])
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ offer: TransferOffer) {
        message.stringValue = offer.message
        message.toolTip = TransferHelp.autoStart
        acceptButton.title = offer.acceptTitle
        ignoreButton.title = offer.ignoreTitle
        isHidden = false
    }

    @objc func accept() { onAccept?() }
    @objc func ignore() { onIgnore?() }
}

// MARK: - Panel

/// The transfer panel: progress while running, then the summary (with SHA-256, the folder,
/// Reveal in Finder and the log).
final class TransferPanelView: NSView {
    var onCancel: (() -> Void)?
    var onClose: (() -> Void)?
    var onReveal: (() -> Void)?
    var onShowLog: (() -> Void)?

    let title = NSTextField(labelWithString: "")
    let fileName = NSTextField(labelWithString: "")
    let bar = NSProgressIndicator()
    let warning = NSTextField(wrappingLabelWithString: "")
    let note = NSTextField(labelWithString: "")
    private var values: [String: NSTextField] = [:]
    let grid = NSGridView()
    let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    let revealButton = NSButton(title: "Reveal in Finder", target: nil, action: nil)
    let logButton = NSButton(title: "Transfer Log", target: nil, action: nil)
    let closeButton = NSButton(title: "Close", target: nil, action: nil)
    let summaryText = NSTextView()
    let summaryScroll = NSScrollView()
    let help = TransferHelpButton(text: TransferHelp.allProtocols + "\n\n" + TransferHelp.resume)
    private let stack = NSStackView()

    static let rows: [(id: String, label: String, tip: String)] = [
        ("file", "File", "Which file of the batch is going across now."),
        ("bytes", "Bytes", "Bytes of the current file so far, and its size when the protocol tells it."),
        ("total", "Total", "Bytes of every file in this transfer so far."),
        ("speed", "Speed", "Average over the last few seconds."),
        ("eta", "Time left", "For the current file, at the current speed."),
        ("protocol", "Protocol", "The file transfer protocol in use."),
        ("block", "Block size", "How much data goes in each block or packet."),
        ("errors", "Errors and retries", "Blocks that had to be sent again after a line error. A few are normal on a noisy line."),
        ("resume", "Resumed", TransferHelp.resume),
    ]

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.13, alpha: 0.97).cgColor
        layer?.cornerRadius = 10
        layer?.borderColor = NSColor(calibratedWhite: 0.4, alpha: 1).cgColor
        layer?.borderWidth = 1
        appearance = NSAppearance(named: .darkAqua)
        title.font = .systemFont(ofSize: 15, weight: .bold)
        fileName.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        fileName.lineBreakMode = .byTruncatingMiddle
        fileName.toolTip = "The file going across now."
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        bar.style = .bar
        bar.toolTip = "How much of the current file has gone across."
        warning.textColor = .systemOrange
        warning.font = .systemFont(ofSize: 12, weight: .semibold)
        warning.preferredMaxLayoutWidth = 560
        note.textColor = .secondaryLabelColor
        for row in Self.rows {
            let label = NSTextField(labelWithString: row.label + ":")
            label.textColor = .secondaryLabelColor
            label.alignment = .right
            label.toolTip = row.tip
            let value = NSTextField(labelWithString: "")
            value.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            value.toolTip = row.tip
            value.lineBreakMode = .byTruncatingTail
            values[row.id] = value
            grid.addRow(with: [label, value])
        }
        grid.columnSpacing = 10
        grid.rowSpacing = 3
        grid.column(at: 0).xPlacement = .trailing
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        cancelButton.toolTip = TransferHelp.cancel
        revealButton.bezelStyle = .rounded
        revealButton.target = self
        revealButton.action = #selector(reveal)
        revealButton.toolTip = "Shows the received files in the Finder."
        logButton.bezelStyle = .rounded
        logButton.target = self
        logButton.action = #selector(showLog)
        logButton.toolTip = "Opens this BBS's transfer log: every transfer with its protocol details and results."
        closeButton.bezelStyle = .rounded
        closeButton.keyEquivalent = "\r"
        closeButton.target = self
        closeButton.action = #selector(close)
        closeButton.toolTip = "Closes this panel and returns to the terminal."
        summaryText.isEditable = false
        summaryText.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        summaryText.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 1)
        summaryText.textColor = .white
        summaryScroll.documentView = summaryText
        summaryScroll.hasVerticalScroller = true
        summaryScroll.toolTip = "The files with their SHA-256 checksums, then the protocol log."
        summaryScroll.heightAnchor.constraint(equalToConstant: 170).isActive = true
        summaryText.autoresizingMask = [.width]
        summaryText.isVerticallyResizable = true
        summaryText.textContainer?.widthTracksTextView = true
        let header = NSStackView(views: [title, help])
        header.spacing = 8
        let buttons = NSStackView(views: [revealButton, logButton, closeButton, cancelButton])
        buttons.spacing = 8
        stack.setViews([header, fileName, bar, grid, warning, note, summaryScroll, buttons], in: .leading)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            bar.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            fileName.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, constant: -32),
            warning.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, constant: -32),
            summaryScroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            buttons.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -16),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func value(_ id: String) -> String { values[id]?.stringValue ?? "" }

    func showRunning(_ m: TransferPanelModel, note text: String?) {
        title.stringValue = m.title
        fileName.stringValue = m.fileName
        fileName.isHidden = false
        if let fraction = m.fraction {
            bar.isIndeterminate = false
            bar.doubleValue = fraction
        } else {
            bar.isIndeterminate = true
            bar.startAnimation(nil)
        }
        bar.isHidden = false
        values["file"]?.stringValue = m.fileLine
        values["bytes"]?.stringValue = m.bytesLine
        values["total"]?.stringValue = m.totalLine
        values["speed"]?.stringValue = m.speedLine
        values["eta"]?.stringValue = m.etaLine
        values["protocol"]?.stringValue = m.kind.displayName + (m.direction == .send ? ", sending" : ", receiving")
        values["protocol"]?.toolTip = TransferHelp.hint(m.kind)
        values["block"]?.stringValue = m.blockLine
        values["errors"]?.stringValue = m.errorsLine
        values["resume"]?.stringValue = m.resumeLine ?? ""
        grid.row(at: Self.rows.firstIndex { $0.id == "resume" }!).isHidden = m.resumeLine == nil
        grid.isHidden = false
        warning.stringValue = m.warning ?? ""
        warning.isHidden = m.warning == nil
        note.stringValue = text ?? "Escape or Cancel stops the transfer. The terminal continues when it ends."
        note.isHidden = false
        summaryScroll.isHidden = true
        cancelButton.isHidden = false
        revealButton.isHidden = true
        logButton.isHidden = true
        closeButton.isHidden = true
        isHidden = false
    }

    func showSummary(_ s: TransferSummary, log: [String]) {
        title.stringValue = s.headline
        title.toolTip = s.headline
        title.lineBreakMode = .byTruncatingTail
        bar.stopAnimation(nil)
        bar.isHidden = true
        grid.isHidden = true
        fileName.isHidden = s.folder == nil
        fileName.stringValue = s.folder.map { "Saved in " + ($0.path as NSString).abbreviatingWithTildeInPath } ?? ""
        warning.isHidden = true
        note.isHidden = true
        var text = s.lines.joined(separator: "\n")
        if !text.isEmpty { text += "\n\n" }
        text += log.joined(separator: "\n")
        summaryText.string = text
        summaryScroll.isHidden = false
        cancelButton.isHidden = true
        revealButton.isHidden = s.folder == nil
        logButton.isHidden = false
        closeButton.isHidden = false
        isHidden = false
    }

    @objc func cancel() { onCancel?() }
    @objc func close() { onClose?() }
    @objc func reveal() { onReveal?() }
    @objc func showLog() { onShowLog?() }
}

// MARK: - Transfer log window

/// Terminal > Transfer Log: the focused BBS's log file.
final class TransferLogWindowController: NSWindowController {
    private static var open: [UUID: TransferLogWindowController] = [:]
    let textView = NSTextView()
    let entry: BBSEntry
    let store: TransferLogStore

    static func show(entry: BBSEntry, store: TransferLogStore = TransferLogStore(directory: TerminalTransfers.defaultLogDirectory)) {
        let controller = open[entry.id] ?? TransferLogWindowController(entry: entry, store: store)
        open[entry.id] = controller
        controller.reload()
        controller.showWindow(nil)
    }

    init(entry: BBSEntry, store: TransferLogStore) {
        self.entry = entry
        self.store = store
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 460),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Transfer Log: \(entry.name)"
        super.init(window: window)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 44, width: 720, height: 416))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        textView.frame = scroll.bounds
        textView.autoresizingMask = [.width]
        textView.isEditable = false
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        scroll.documentView = textView
        scroll.toolTip = "Every file transfer with this BBS: protocol, negotiation, retries, results and SHA-256 checksums."
        let reveal = NSButton(title: "Reveal in Finder", target: self, action: #selector(revealLog))
        reveal.frame = NSRect(x: 12, y: 8, width: 150, height: 28)
        reveal.toolTip = "Shows the log file in the Finder (in AnsiView's container)."
        let refresh = NSButton(title: "Refresh", target: self, action: #selector(reloadNow))
        refresh.frame = NSRect(x: 170, y: 8, width: 100, height: 28)
        refresh.toolTip = "Reads the log file again."
        window.contentView?.addSubview(scroll)
        window.contentView?.addSubview(reveal)
        window.contentView?.addSubview(refresh)
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func reload() {
        let text = store.read(entryID: entry.id)
        textView.string = text.isEmpty ? "No file transfers with \(entry.name) yet." : text
        textView.scrollToEndOfDocument(nil)
    }

    @objc func reloadNow() { reload() }

    @objc func revealLog() {
        let url = store.url(for: entry.id)
        if FileManager.default.fileExists(atPath: url.path) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }
}
