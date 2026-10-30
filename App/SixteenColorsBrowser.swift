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
    /// Listings (`api/`, read back only when offline), pictures (`images/`) and files (`files/`),
    /// under a 200 MB cap. Pack ZIPs (`packs/`) stay outside it: a gallery may still be reading one.
    let cache: DiskCache
    private var spacing = RequestSpacing(interval: 1)
    private var lane = RequestLane()
    private var waiters: [Int: CheckedContinuation<Void, Error>] = [:]
    private var pump: Task<Void, Never>?
    private var memory: [URL: Data] = [:]
    /// Pictures 16colo.rs does not have (HTTP 404), remembered for the session.
    private(set) var missing: Set<URL> = []
    /// True while answers come from the disk because 16colo.rs cannot be reached.
    private(set) var isOffline = false
    /// When each network request started (uptime seconds), for checks.
    private(set) var requestStarts: [TimeInterval] = []
    /// Every finished request: what, when it started, how many bytes came back (for checks).
    private(set) var requests: [(url: URL, start: TimeInterval, bytes: Int)] = []
    private let log = Logger(subsystem: "com.traynham.ansiview", category: "16colors")

    init(session: URLSession? = nil, cacheFolder: URL, capacity: Int = DiskCache.defaultCapacity) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 30
            self.session = URLSession(configuration: configuration)
        }
        self.cacheFolder = cacheFolder
        self.cache = DiskCache(folder: cacheFolder, capacity: capacity, excluded: ["packs"])
    }

    /// One request with AnsiView's User-Agent.
    private func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    /// Waits in the lane until this request may start (by priority, at least a second after the
    /// last one), then records it. A cancelled waiter (the user moved on, the row scrolled away)
    /// leaves the lane, throws CancellationError and never reaches the network.
    private func waitForTurn(_ priority: RequestLane.Priority) async throws -> TimeInterval {
        try Task.checkCancellation()
        let ticket = lane.enqueue(priority)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    lane.cancel(ticket)
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waiters[ticket] = continuation
                startPump()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.leaveLane(ticket) }
        }
        return requestStarts.last ?? ProcessInfo.processInfo.systemUptime
    }

    private func leaveLane(_ ticket: Int) {
        lane.cancel(ticket)
        waiters.removeValue(forKey: ticket)?.resume(throwing: CancellationError())
    }

    /// Lets waiters go one at a time, a second apart, best priority first.
    private func startPump() {
        guard pump == nil else { return }
        pump = Task { @MainActor [weak self] in
            while let self {
                let delay = self.spacing.delay(now: ProcessInfo.processInfo.systemUptime)
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                }
                guard let ticket = self.lane.next() else {
                    self.pump = nil
                    return
                }
                guard let waiter = self.waiters.removeValue(forKey: ticket) else { continue }
                let now = ProcessInfo.processInfo.systemUptime
                self.spacing.started(at: now)
                self.requestStarts.append(now)
                waiter.resume()
            }
        }
    }

    private func check(_ response: URLResponse) throws {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw HTTPError(status: http.statusCode)
        }
    }

    /// Notes whether this failure means 16colo.rs cannot be reached.
    private func noteFailure(_ error: Error) {
        if Self.describe(error).offline { isOffline = true }
    }

    private func json(_ url: URL) async throws -> Data {
        if let cached = memory[url] { return cached }
        let key = SixteenColors.apiCacheName(for: url)
        do {
            let start = try await waitForTurn(.user)
            log.info("GET \(url.absoluteString, privacy: .public)")
            let (data, response) = try await session.data(for: request(url))
            requests.append((url, start, data.count))
            try check(response)
            memory[url] = data
            isOffline = false
            try? cache.store(data, for: key)
            return data
        } catch {
            // Offline: the copy saved last time, if there is one.
            if Self.describe(error).offline, let saved = cache.data(for: key) {
                isOffline = true
                memory[url] = saved
                return saved
            }
            noteFailure(error)
            throw error
        }
    }

    /// A `tn` or `x1` picture: from the disk cache, else downloaded (when its turn comes) and kept.
    /// Only PNG data is kept; a 404 is remembered for the session.
    func image(_ url: URL, priority: RequestLane.Priority) async throws -> NSImage {
        guard let key = SixteenColors.imageCacheName(for: url) else { throw SixteenColors.DecodeError.unreadable }
        if let saved = cache.data(for: key), let image = NSImage(data: saved) { return image }
        if missing.contains(url) { throw HTTPError(status: 404) }
        let start = try await waitForTurn(priority)
        log.info("GET \(url.absoluteString, privacy: .public)")
        let data: Data
        do {
            let (body, response) = try await session.data(for: request(url))
            requests.append((url, start, body.count))
            if (response as? HTTPURLResponse)?.statusCode == 404 { missing.insert(url) }
            try check(response)
            data = body
        } catch {
            noteFailure(error)
            throw error
        }
        isOffline = false
        guard SixteenColors.isPNG(data), let image = NSImage(data: data) else { throw SixteenColors.DecodeError.unreadable }
        try? cache.store(data, for: key)
        return image
    }

    /// A picture already on disk (no network): for showing at once, and when offline.
    func cachedImage(_ url: URL) -> NSImage? {
        guard let key = SixteenColors.imageCacheName(for: url), let data = cache.data(for: key) else { return nil }
        return NSImage(data: data)
    }

    /// A pack's file list already known (this session, or saved on disk), without the network.
    func cachedPack(named name: String) -> SixteenColors.PackDetail? {
        let url = SixteenColors.packURL(name: name)
        let data = memory[url] ?? cache.data(for: SixteenColors.apiCacheName(for: url))
        return data.flatMap { try? SixteenColors.decodePack($0, name: name) }
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
        let start = try await waitForTurn(.user)
        log.info("Download \(url.absoluteString, privacy: .public)")
        let (temporary, response) = try await session.download(for: request(url))
        requests.append((url, start, (try? temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0))
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

    /// One file of a pack, in Caches/16colors/files/<pack> (counted in the disk cache's cap).
    func downloadFile(_ file: SixteenColors.PackFile, in pack: String,
                      priority: RequestLane.Priority = .user) async throws -> URL {
        guard let url = SixteenColors.rawFileURL(pack: pack, file: file.name),
              let key = SixteenColors.fileCacheName(pack: pack, file: file.name) else {
            throw SixteenColors.DecodeError.unreadable
        }
        if cache.contains(key) {
            cache.touch(key)
            return cache.url(for: key)
        }
        let start = try await waitForTurn(priority)
        log.info("Download \(url.absoluteString, privacy: .public)")
        do {
            let (temporary, response) = try await session.download(for: request(url))
            requests.append((url, start, (try? temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0))
            try check(response)
            isOffline = false
            return try cache.adopt(temporary, for: key)
        } catch {
            noteFailure(error)
            throw error
        }
    }

    /// A file already downloaded, without the network.
    func cachedFile(_ file: SixteenColors.PackFile, in pack: String) -> URL? {
        guard let key = SixteenColors.fileCacheName(pack: pack, file: file.name), cache.contains(key) else { return nil }
        return cache.url(for: key)
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

/// File > Browse 16colo.rs: years, then a year's packs, then a pack's files, and a preview of the
/// selected file. Open Pack downloads the ZIP and shows it in a gallery; Open downloads one file
/// and opens it.
@MainActor
final class SixteenColorsBrowser: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    static let hint = "Choose a year, then a pack. Selecting a file previews it on the right; double click or Open opens it in its own window."

    let client: SixteenColorsClient
    /// The app opens downloads: a pack's ZIP in a gallery (with the pack's name), a file as a document.
    var onOpenPack: ((URL, String) -> Void)?
    var onOpenFile: ((URL) -> Void)?
    /// The app opens a downloaded file in the editor.
    var onEditFile: ((URL) -> Void)?

    private(set) var years: [SixteenColors.Year] = []
    private(set) var packs: [SixteenColors.Pack] = []
    private(set) var detail: SixteenColors.PackDetail?
    var files: [SixteenColors.PackFile] { detail?.files ?? [] }

    private let yearTable = NSTableView()
    private let packTable = NSTableView()
    private let fileTable = NSTableView()
    let preview = SixteenColorsPreview()
    private let status = NSTextField(labelWithString: "")
    private let retryButton = NSButton(title: "Retry", target: nil, action: nil)
    private let openPackButton = NSButton(title: "Open Pack", target: nil, action: nil)
    private let spinner = NSProgressIndicator()
    /// What Retry does: the last thing that failed.
    private var retry: (() async -> Void)?
    /// Bumped on each selection so a slow answer for an old selection is dropped.
    private var generation = 0
    /// Bumped on each file selection (the preview's own guard).
    private var previewGeneration = 0
    /// True while the code (not the user) changes a table's selection.
    private var selectingInCode = false
    /// The listing for the current selection; a new selection cancels it, so stale requests never go out.
    private var listing: Task<Void, Never>?
    /// The preview for the selected file; a new selection cancels it the same way.
    private var previewTask: Task<Void, Never>?
    /// The file the preview shows (or is loading).
    private(set) var selectedFileIndex: Int?

    var statusText: String { status.stringValue }
    var retryVisible: Bool { !retryButton.isHidden }

    init(client: SixteenColorsClient) {
        self.client = client
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        func column(_ table: NSTableView, _ id: String, _ title: String, width: CGFloat, tip: String) -> NSScrollView {
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
            table.toolTip = tip
            let scroll = NSScrollView()
            scroll.documentView = table
            scroll.hasVerticalScroller = true
            scroll.borderType = .bezelBorder
            return scroll
        }
        let yearScroll = column(yearTable, "year", "Year", width: 120,
                                tip: "Years of the 16colo.rs archive, with how many packs each has.")
        let packScroll = column(packTable, "pack", "Pack", width: 260,
                                tip: "The year's art packs. Double click (or Open Pack) to download one and see it in a gallery.")
        let fileScroll = column(fileTable, "file", "File", width: 320,
                                tip: "The pack's files. Select one to preview it; double click to open it.")
        addChild(preview)
        preview.onOpen = { [weak self] in self?.openSelectedFile() }
        preview.onEdit = { [weak self] in self?.editSelectedFile() }
        preview.onSave = { [weak self] in self?.chooseSaveLocation() }
        preview.onShowArt = { [weak self] in self?.keepKeyboardInList() }
        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(yearScroll)
        split.addArrangedSubview(packScroll)
        split.addArrangedSubview(fileScroll)
        split.addArrangedSubview(preview.view)
        split.setHoldingPriority(.defaultLow + 1, forSubviewAt: 0)
        split.setHoldingPriority(.defaultLow + 2, forSubviewAt: 1)
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
        openPackButton.toolTip = "Download the whole pack (its ZIP) and show it in a gallery."
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        let hint = NSTextField(labelWithString: Self.hint)
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.textColor = .secondaryLabelColor
        hint.lineBreakMode = .byTruncatingTail
        hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let credit = NSTextField(labelWithString: "Art from 16colo.rs. Each piece remains the property of its artist.")
        credit.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        credit.textColor = .tertiaryLabelColor
        credit.setContentHuggingPriority(.required, for: .horizontal)
        let bar = NSStackView(views: [spinner, status, retryButton, NSView(), openPackButton])
        bar.orientation = .horizontal
        bar.spacing = 8
        bar.translatesAutoresizingMaskIntoConstraints = false
        let footer = NSStackView(views: [hint, NSView(), credit])
        footer.orientation = .horizontal
        footer.spacing = 8
        footer.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(split)
        container.addSubview(bar)
        container.addSubview(footer)
        NSLayoutConstraint.activate([
            split.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            split.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            split.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            bar.topAnchor.constraint(equalTo: split.bottomAnchor, constant: 10),
            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            bar.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            footer.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 6),
            footer.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            footer.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            footer.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
            yearScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 100),
            packScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
            fileScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),
            split.heightAnchor.constraint(greaterThanOrEqualToConstant: 260),
        ])
        view = container
        // Starting widths: years narrow, then packs, files, and the preview takes the rest.
        DispatchQueue.main.async { [split] in
            split.setPosition(130, ofDividerAt: 0)
            split.setPosition(430, ofDividerAt: 1)
            split.setPosition(820, ofDividerAt: 2)
        }
    }

    // MARK: Loading

    private func begin(_ text: String) {
        status.stringValue = text
        retryButton.isHidden = true
        spinner.startAnimation(nil)
    }

    private func finish(_ text: String) {
        status.stringValue = client.isOffline ? "Offline: showing what was saved earlier. " + text : text
        spinner.stopAnimation(nil)
    }

    private func failed(_ error: Error, retry: @escaping () async -> Void) {
        if Self.isCancellation(error) { return }
        spinner.stopAnimation(nil)
        status.stringValue = SixteenColorsClient.describe(error).message
        self.retry = retry
        retryButton.isHidden = false
    }

    static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
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
        showPack(nil)
        packTable.reloadData()
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
        showPack(nil)
        begin("Loading \(pack.name)...")
        do {
            let loaded = try await client.pack(named: pack.name)
            guard mine == generation else { return }
            showPack(loaded)
            let groups = pack.groups.isEmpty ? "" : " by \(pack.groups.joined(separator: ", "))"
            finish("\(pack.name)\(groups): \(loaded.files.count) files.")
        } catch {
            guard mine == generation else { return }
            failed(error) { [weak self] in await self?.selectPack(index) }
        }
    }

    /// Shows a pack's files (nil: none), and clears the preview.
    private func showPack(_ loaded: SixteenColors.PackDetail?) {
        detail = loaded
        previewTask?.cancel()
        previewGeneration += 1
        selectedFileIndex = nil
        fileTable.reloadData()
        preview.show(.empty(loaded == nil ? SixteenColorsPreview.emptyHint : "Select a file of \(loaded!.name) to preview it here."))
        updateButtons()
    }

    private func select(_ row: Int, in table: NSTableView) {
        guard table.selectedRow != row else { return }
        selectingInCode = true
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
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
    }

    // MARK: Preview

    /// The user picked a file (also for checks): previews it, replacing any preview still loading.
    @discardableResult
    func chooseFile(_ row: Int) -> Task<Void, Never>? {
        guard files.indices.contains(row) else { return nil }
        select(row, in: fileTable)
        previewTask?.cancel()
        previewTask = Task { [weak self] in await self?.previewFile(row) }
        return previewTask
    }

    /// Shows the file in the preview pane: its thumbnail at once when it is on disk, then the art
    /// itself (downloaded once, then cached), or 16colo.rs's full size picture for files AnsiView
    /// does not render.
    func previewFile(_ index: Int) async {
        guard files.indices.contains(index), let detail else { return }
        previewGeneration += 1
        let mine = previewGeneration
        selectedFileIndex = index
        let file = files[index]
        let thumbnail = file.thumbnail.flatMap(client.cachedImage)
        if let thumbnail {
            preview.show(.picture(thumbnail, note: "Loading \(file.name)..."))
        } else {
            preview.show(.empty("Loading \(file.name)..."))
        }
        preview.setButtons(open: false, save: false)
        var problem: Error?
        if file.isViewable {
            do {
                let url = try await client.downloadFile(file, in: detail.name)
                guard mine == previewGeneration else { return }
                let art = ArtFile(data: try Data(contentsOf: url), fileExtension: url.pathExtension)
                preview.show(.art(art, name: file.name, url: url))
                return
            } catch {
                if Self.isCancellation(error) || mine != previewGeneration { return }
                problem = error
            }
        }
        // Not art AnsiView renders (or it could not be fetched): 16colo.rs's own picture of it.
        if let full = file.fullImage ?? SixteenColors.fullImageURL(pack: detail.name, file: file.name) {
            do {
                let image = try await client.image(full, priority: .user)
                guard mine == previewGeneration else { return }
                preview.show(.picture(image, note: "\(file.name)  \u{00B7}  picture rendered by 16colo.rs"))
                preview.setButtons(open: false, save: problem == nil)
                return
            } catch {
                if Self.isCancellation(error) || mine != previewGeneration { return }
                problem = problem ?? error
            }
        }
        let text = problem.map { SixteenColorsClient.describe($0).message } ?? "No preview for \(file.name)."
        if let thumbnail {
            preview.show(.picture(thumbnail, note: "Saved thumbnail. " + text))
        } else {
            preview.show(.empty(text))
        }
    }

    private func openSelectedFile() {
        guard let index = selectedFileIndex else { return }
        Task { await openFile(index) }
    }

    private func editSelectedFile() {
        guard let index = selectedFileIndex, canOpenFile(index), let detail else { return }
        let file = files[index]
        Task {
            do {
                let url = try await client.downloadFile(file, in: detail.name)
                onEditFile?(url)
            } catch {
                failed(error) { [weak self] in self?.editSelectedFile() }
            }
        }
    }

    /// Copies a file of the pack (downloading it first when needed) to `destination`.
    func saveFile(_ index: Int, to destination: URL) async throws {
        guard files.indices.contains(index), let detail else { return }
        let source = try await client.downloadFile(files[index], in: detail.name)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: source, to: destination)
    }

    /// Save to...: a save panel starting in Downloads, with the file's own name.
    private func chooseSaveLocation() {
        guard let index = selectedFileIndex, files.indices.contains(index), let window = view.window else { return }
        let name = (files[index].name as NSString).lastPathComponent
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.message = "Save \(name) from 16colo.rs."
        if let home = getpwuid(getuid())?.pointee.pw_dir {
            panel.directoryURL = URL(fileURLWithPath: String(cString: home)).appendingPathComponent("Downloads")
        }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            Task {
                do {
                    try await self.saveFile(index, to: url)
                    self.finish("Saved \(url.lastPathComponent).")
                } catch {
                    self.failed(error) { [weak self] in self?.chooseSaveLocation() }
                }
            }
        }
    }

    /// The art view takes the keyboard when it appears; arrows belong to the file list.
    private func keepKeyboardInList() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.view.window else { return }
            window.makeFirstResponder(self.fileTable)
        }
    }

    // MARK: Actions

    @objc private func retryPressed(_ sender: Any?) {
        guard let retry else { return }
        Task { await retry() }
    }

    @objc private func openPackPressed(_ sender: Any?) { Task { await openPack() } }

    /// The user picked a year (also for checks): replaces any listing still waiting or loading.
    @discardableResult
    func chooseYear(_ row: Int) -> Task<Void, Never>? {
        startListing { await $0.selectYear(row) }
        return listing
    }

    /// The user picked a pack (also for checks).
    @discardableResult
    func choosePack(_ row: Int) -> Task<Void, Never>? {
        startListing { await $0.selectPack(row) }
        return listing
    }

    /// Stops a listing or preview in progress (the window is closing).
    func cancelListing() {
        listing?.cancel()
        previewTask?.cancel()
        preview.show(.empty(SixteenColorsPreview.emptyHint))
    }

    /// Cancels the listing for the previous selection and starts this one.
    private func startListing(_ work: @escaping (SixteenColorsBrowser) async -> Void) {
        listing?.cancel()
        listing = Task { [weak self] in
            guard let self else { return }
            await work(self)
        }
    }

    @objc private func doubleClicked(_ sender: NSTableView) {
        let row = sender.clickedRow
        guard row >= 0 else { return }
        if sender === fileTable { Task { await openFile(row) } }
        if sender === packTable {
            // The first click started loading this pack; open it once its file list is here.
            let pending = listing
            Task {
                await pending?.value
                await openPack()
            }
        }
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
            if years.indices.contains(row) { chooseYear(row) }
        case packTable:
            if packs.indices.contains(row) { choosePack(row) }
        default:
            if files.indices.contains(row) { chooseFile(row) }
        }
    }
}

/// The browser's window (one, reused).
@MainActor
final class SixteenColorsWindowController: NSWindowController, NSWindowDelegate {
    private static var current: SixteenColorsWindowController?

    static func show(openPack: @escaping (URL, String) -> Void, openFile: @escaping (URL) -> Void,
                     editFile: @escaping (URL) -> Void) {
        if let current {
            current.showWindow(nil)
            return
        }
        let browser = SixteenColorsBrowser(client: .shared)
        browser.onOpenPack = openPack
        browser.onOpenFile = openFile
        browser.onEditFile = editFile
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1320, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "16colo.rs"
        window.minSize = NSSize(width: 900, height: 440)
        let controller = SixteenColorsWindowController(window: window)
        window.delegate = controller
        window.contentViewController = browser
        window.setContentSize(NSSize(width: 1320, height: 760))
        window.center()
        current = controller
        controller.showWindow(nil)
        Task { await browser.loadYears() }
    }

    func windowWillClose(_ notification: Notification) {
        (contentViewController as? SixteenColorsBrowser)?.cancelListing()
        Self.current = nil
    }
}
