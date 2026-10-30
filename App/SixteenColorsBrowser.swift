import AnsiCore
import AppKit
import os

/// Talks to the 16colo.rs API: listings (kept in memory for the session) and downloads (kept in
/// the Caches folder and reused). API requests start at least a second apart; there are no
/// published rate limits, so AnsiView keeps its own.
@MainActor
final class SixteenColorsClient {
    struct HTTPError: LocalizedError {
        let status: Int
        var errorDescription: String? { "16colo.rs answered with HTTP \(status). Try again later." }
    }

    static let shared = SixteenColorsClient(cacheFolder: defaultCacheFolder)

    /// Caches/16colors inside the app's container.
    static var defaultCacheFolder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("16colors")
    }

    static var userAgent: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return SixteenColors.userAgent(version: info["CFBundleShortVersionString"] as? String ?? "2",
                                       build: info["CFBundleVersion"] as? String ?? "0")
    }

    let session: URLSession
    let cacheFolder: URL
    private var spacing = RequestSpacing(interval: 1)
    private var memory: [URL: Data] = [:]
    /// When each network request started (uptime seconds), for checks.
    private(set) var requestStarts: [TimeInterval] = []
    private let log = Logger(subsystem: "com.traynham.ansiview", category: "16colors")

    init(session: URLSession? = nil, cacheFolder: URL) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 30
            self.session = URLSession(configuration: configuration)
        }
        self.cacheFolder = cacheFolder
    }

    /// Waits for its turn, then makes one request with AnsiView's User-Agent.
    private func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    private func waitForTurn() async throws {
        let now = ProcessInfo.processInfo.systemUptime
        let delay = spacing.delay(now: now)
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        requestStarts.append(ProcessInfo.processInfo.systemUptime)
    }

    private func check(_ response: URLResponse) throws {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw HTTPError(status: http.statusCode)
        }
    }

    private func json(_ url: URL) async throws -> Data {
        if let cached = memory[url] { return cached }
        try await waitForTurn()
        log.info("GET \(url.absoluteString, privacy: .public)")
        let (data, response) = try await session.data(for: request(url))
        try check(response)
        memory[url] = data
        return data
    }

    func years() async throws -> [SixteenColors.Year] {
        try SixteenColors.decodeYears(try await json(SixteenColors.yearsURL()))
    }

    /// Every pack of a year (all pages).
    func packs(year: Int) async throws -> [SixteenColors.Pack] {
        var packs: [SixteenColors.Pack] = []
        var page = 1
        while true {
            let result = try SixteenColors.decodePackPage(try await json(SixteenColors.packsURL(year: year, page: page)))
            packs += result.packs
            guard page < result.pages, page < 20 else { return packs }
            page += 1
        }
    }

    func pack(named name: String) async throws -> SixteenColors.PackDetail {
        try SixteenColors.decodePack(try await json(SixteenColors.packURL(name: name)), name: name)
    }

    /// Downloads `url` to `destination` unless it is already there.
    private func download(_ url: URL, to destination: URL) async throws -> URL {
        if FileManager.default.fileExists(atPath: destination.path) { return destination }
        try await waitForTurn()
        log.info("Download \(url.absoluteString, privacy: .public)")
        let (temporary, response) = try await session.download(for: request(url))
        try check(response)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        // Another download of the same file may have finished first.
        if FileManager.default.fileExists(atPath: destination.path) {
            try? FileManager.default.removeItem(at: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
        return destination
    }

    /// The pack's ZIP, in Caches/16colors/packs.
    func downloadPack(_ pack: SixteenColors.PackDetail) async throws -> URL {
        guard let url = pack.download, let name = SixteenColors.packCacheName(pack.name) else {
            throw SixteenColors.DecodeError.unreadable
        }
        return try await download(url, to: cacheFolder.appendingPathComponent("packs").appendingPathComponent(name))
    }

    /// One file of a pack, in Caches/16colors/files/<pack>.
    func downloadFile(_ file: SixteenColors.PackFile, in pack: String) async throws -> URL {
        guard let url = SixteenColors.rawFileURL(pack: pack, file: file.name),
              let folder = SixteenColors.packCacheName(pack).map({ ($0 as NSString).deletingPathExtension }),
              let name = SixteenColors.cacheName(for: file.name) else {
            throw SixteenColors.DecodeError.unreadable
        }
        return try await download(url, to: cacheFolder.appendingPathComponent("files")
            .appendingPathComponent(folder).appendingPathComponent(name))
    }

    /// What to tell the user, and whether it looks like no network at all.
    static func describe(_ error: Error) -> (message: String, offline: Bool) {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .dnsLookupFailed,
                 .timedOut, .cannotConnectToHost, .internationalRoamingOff, .dataNotAllowed:
                return ("You appear to be offline, or 16colo.rs cannot be reached. Check your connection and try again.", true)
            default:
                return ("Could not reach 16colo.rs: \(urlError.localizedDescription)", false)
            }
        }
        // Lower level connection failures (a proxy that refuses, say) arrive as CFNetwork errors.
        if (error as NSError).domain == kCFErrorDomainCFNetwork as String {
            return ("You appear to be offline, or 16colo.rs cannot be reached. Check your connection and try again.", true)
        }
        return (error.localizedDescription, false)
    }
}

/// File > Browse 16colo.rs: years, then a year's packs, then a pack's files. Open Pack downloads
/// the ZIP and shows it in a gallery; Open File downloads one file and opens it.
@MainActor
final class SixteenColorsBrowser: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    let client: SixteenColorsClient
    /// The app opens downloads: a pack's ZIP in a gallery (with the pack's name), a file as a document.
    var onOpenPack: ((URL, String) -> Void)?
    var onOpenFile: ((URL) -> Void)?

    private(set) var years: [SixteenColors.Year] = []
    private(set) var packs: [SixteenColors.Pack] = []
    private(set) var detail: SixteenColors.PackDetail?
    var files: [SixteenColors.PackFile] { detail?.files ?? [] }

    private let yearTable = NSTableView()
    private let packTable = NSTableView()
    private let fileTable = NSTableView()
    private let status = NSTextField(labelWithString: "")
    private let retryButton = NSButton(title: "Retry", target: nil, action: nil)
    private let openPackButton = NSButton(title: "Open Pack", target: nil, action: nil)
    private let openFileButton = NSButton(title: "Open File", target: nil, action: nil)
    private let spinner = NSProgressIndicator()
    /// What Retry does: the last thing that failed.
    private var retry: (() async -> Void)?
    /// Bumped on each selection so a slow answer for an old selection is dropped.
    private var generation = 0
    /// True while the code (not the user) changes a table's selection.
    private var selectingInCode = false

    var statusText: String { status.stringValue }
    var retryVisible: Bool { !retryButton.isHidden }

    init(client: SixteenColorsClient) {
        self.client = client
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        func column(_ table: NSTableView, _ id: String, _ title: String, width: CGFloat) -> NSScrollView {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            column.resizingMask = .autoresizingMask
            table.addTableColumn(column)
            table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
            table.headerView = NSTableHeaderView()
            table.usesAlternatingRowBackgroundColors = true
            table.dataSource = self
            table.delegate = self
            table.target = self
            table.doubleAction = #selector(doubleClicked(_:))
            table.setAccessibilityLabel(title)
            let scroll = NSScrollView()
            scroll.documentView = table
            scroll.hasVerticalScroller = true
            scroll.borderType = .bezelBorder
            return scroll
        }
        let yearScroll = column(yearTable, "year", "Year", width: 150)
        let packScroll = column(packTable, "pack", "Pack", width: 300)
        let fileScroll = column(fileTable, "file", "File", width: 420)
        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(yearScroll)
        split.addArrangedSubview(packScroll)
        split.addArrangedSubview(fileScroll)
        split.setHoldingPriority(.defaultLow + 1, forSubviewAt: 0)
        split.translatesAutoresizingMaskIntoConstraints = false

        status.lineBreakMode = .byTruncatingTail
        status.textColor = .secondaryLabelColor
        status.translatesAutoresizingMaskIntoConstraints = false
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        retryButton.target = self
        retryButton.action = #selector(retryPressed(_:))
        retryButton.isHidden = true
        openPackButton.target = self
        openPackButton.action = #selector(openPackPressed(_:))
        openPackButton.isEnabled = false
        openFileButton.target = self
        openFileButton.action = #selector(openFilePressed(_:))
        openFileButton.isEnabled = false
        openFileButton.keyEquivalent = "\r"
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        let credit = NSTextField(labelWithString: "Art from 16colo.rs. Each piece remains the property of its artist.")
        credit.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        credit.textColor = .tertiaryLabelColor
        let bar = NSStackView(views: [spinner, status, retryButton, NSView(), openPackButton, openFileButton])
        bar.orientation = .horizontal
        bar.spacing = 8
        bar.translatesAutoresizingMaskIntoConstraints = false
        credit.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(split)
        container.addSubview(bar)
        container.addSubview(credit)
        NSLayoutConstraint.activate([
            split.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            split.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            split.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            bar.topAnchor.constraint(equalTo: split.bottomAnchor, constant: 10),
            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            bar.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            credit.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 6),
            credit.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            credit.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
            yearScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
            packScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),
            fileScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
            split.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),
        ])
        view = container
        // Starting widths: years narrow, files widest.
        DispatchQueue.main.async { [split] in
            split.setPosition(170, ofDividerAt: 0)
            split.setPosition(500, ofDividerAt: 1)
        }
    }

    // MARK: Loading

    private func begin(_ text: String) {
        status.stringValue = text
        retryButton.isHidden = true
        spinner.startAnimation(nil)
    }

    private func finish(_ text: String) {
        status.stringValue = text
        spinner.stopAnimation(nil)
    }

    private func failed(_ error: Error, retry: @escaping () async -> Void) {
        spinner.stopAnimation(nil)
        status.stringValue = SixteenColorsClient.describe(error).message
        self.retry = retry
        retryButton.isHidden = false
    }

    func loadYears() async {
        begin("Loading years from 16colo.rs...")
        do {
            years = try await client.years().reversed()
            yearTable.reloadData()
            let packs = years.reduce(0) { $0 + $1.packs }
            finish("\(packs) packs from \(years.count) years. Choose a year.")
        } catch {
            failed(error) { [weak self] in await self?.loadYears() }
        }
    }

    func selectYear(_ index: Int) async {
        guard years.indices.contains(index) else { return }
        generation += 1
        let mine = generation
        select(index, in: yearTable)
        let year = years[index].year
        packs = []
        detail = nil
        packTable.reloadData()
        fileTable.reloadData()
        updateButtons()
        begin("Loading packs from \(year)...")
        do {
            let loaded = try await client.packs(year: year)
            guard mine == generation else { return }
            packs = loaded
            packTable.reloadData()
            finish("\(loaded.count) packs from \(year).")
        } catch {
            guard mine == generation else { return }
            failed(error) { [weak self] in await self?.selectYear(index) }
        }
    }

    func selectPack(_ index: Int) async {
        guard packs.indices.contains(index) else { return }
        generation += 1
        let mine = generation
        select(index, in: packTable)
        let pack = packs[index]
        detail = nil
        fileTable.reloadData()
        updateButtons()
        begin("Loading \(pack.name)...")
        do {
            let loaded = try await client.pack(named: pack.name)
            guard mine == generation else { return }
            detail = loaded
            fileTable.reloadData()
            updateButtons()
            let groups = pack.groups.isEmpty ? "" : " by \(pack.groups.joined(separator: ", "))"
            finish("\(pack.name)\(groups): \(loaded.files.count) files.")
        } catch {
            guard mine == generation else { return }
            failed(error) { [weak self] in await self?.selectPack(index) }
        }
    }

    private func select(_ row: Int, in table: NSTableView) {
        guard table.selectedRow != row else { return }
        selectingInCode = true
        table.selectRowIndexes([row], byExtendingSelection: false)
        selectingInCode = false
    }

    func canOpenFile(_ index: Int) -> Bool { files.indices.contains(index) && files[index].isViewable }

    func openFile(_ index: Int) async {
        guard canOpenFile(index), let detail else { return }
        let file = files[index]
        begin("Downloading \(file.name)...")
        do {
            let url = try await client.downloadFile(file, in: detail.name)
            finish("Opened \(file.name).")
            onOpenFile?(url)
        } catch {
            failed(error) { [weak self] in await self?.openFile(index) }
        }
    }

    func openPack() async {
        guard let detail else { return }
        begin("Downloading \(detail.archive ?? detail.name)...")
        do {
            let url = try await client.downloadPack(detail)
            finish("Opened \(detail.name).")
            onOpenPack?(url, detail.name)
        } catch {
            failed(error) { [weak self] in await self?.openPack() }
        }
    }

    private func updateButtons() {
        openPackButton.isEnabled = detail?.download != nil
        openFileButton.isEnabled = canOpenFile(fileTable.selectedRow)
    }

    // MARK: Actions

    @objc private func retryPressed(_ sender: Any?) {
        guard let retry else { return }
        Task { await retry() }
    }

    @objc private func openPackPressed(_ sender: Any?) { Task { await openPack() } }

    @objc private func openFilePressed(_ sender: Any?) {
        let row = fileTable.selectedRow
        Task { await openFile(row) }
    }

    @objc private func doubleClicked(_ sender: NSTableView) {
        let row = sender.clickedRow
        if sender === fileTable { Task { await openFile(row) } }
        if sender === packTable { Task { await openPack() } }
    }

    // MARK: Tables

    func numberOfRows(in tableView: NSTableView) -> Int {
        switch tableView {
        case yearTable: return years.count
        case packTable: return packs.count
        default: return files.count
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? NSTextField ?? {
            let field = NSTextField(labelWithString: "")
            field.identifier = id
            field.lineBreakMode = .byTruncatingTail
            return field
        }()
        cell.textColor = .labelColor
        switch tableView {
        case yearTable:
            let year = years[row]
            cell.stringValue = "\(year.year)  (\(year.packs))"
        case packTable:
            let pack = packs[row]
            cell.stringValue = pack.groups.isEmpty ? pack.name : "\(pack.name)  \u{00B7}  \(pack.groups.joined(separator: ", "))"
        default:
            let file = files[row]
            let artists = file.artists.isEmpty ? "" : "  \u{00B7}  \(file.artists.joined(separator: ", "))"
            cell.stringValue = file.name + artists
            if !file.isViewable { cell.textColor = .tertiaryLabelColor }
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let table = notification.object as? NSTableView, !selectingInCode else { return }
        let row = table.selectedRow
        switch table {
        case yearTable:
            if years.indices.contains(row) { Task { await selectYear(row) } }
        case packTable:
            if packs.indices.contains(row) { Task { await selectPack(row) } }
        default:
            updateButtons()
        }
    }
}

/// The browser's window (one, reused).
@MainActor
final class SixteenColorsWindowController: NSWindowController, NSWindowDelegate {
    private static var current: SixteenColorsWindowController?

    static func show(openPack: @escaping (URL, String) -> Void, openFile: @escaping (URL) -> Void) {
        if let current {
            current.showWindow(nil)
            return
        }
        let browser = SixteenColorsBrowser(client: .shared)
        browser.onOpenPack = openPack
        browser.onOpenFile = openFile
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 620),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "16colo.rs"
        window.minSize = NSSize(width: 640, height: 360)
        let controller = SixteenColorsWindowController(window: window)
        window.delegate = controller
        window.contentViewController = browser
        window.setContentSize(NSSize(width: 980, height: 620))
        window.center()
        current = controller
        controller.showWindow(nil)
        Task { await browser.loadYears() }
    }

    func windowWillClose(_ notification: Notification) {
        Self.current = nil
    }
}
