import AnsiCore
import AppKit
import UniformTypeIdentifiers

/// A grid of thumbnails for a folder or art pack. Thumbnails render on background threads, the
/// pieces on screen first (plan 9 ruling 11), and come from the disk cache when it has them.
/// A search field filters the pieces by the text inside them. Double click (or Return) opens a piece.
final class GalleryViewController: NSViewController, NSCollectionViewDataSource, NSCollectionViewDelegate, NSSearchFieldDelegate {
    static let itemSize = NSSize(width: 200, height: 172)
    /// Thumbnails are rendered at twice the point size for Retina screens.
    static let thumbnailPixels = ThumbnailStore.pixels
    /// For checks: new galleries wait for `resumeRendering()` before drawing thumbnails.
    static var startsPaused = false

    let collection: ArtCollection
    private let store: ThumbnailStore
    private var thumbnails: [Int: NSImage] = [:]
    /// Each piece's searchable text, once read.
    private var haystacks: [Int: SearchHaystack] = [:]
    private let grid = GalleryCollectionView()
    private let searchField = NSSearchField()
    private let statusLabel = NSTextField(labelWithString: "")
    private let compareButton = NSButton(title: "Compare", target: nil, action: nil)
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        return queue
    }()
    private var order: WorkOrder
    private var inFlight = 0
    private let workers = max(2, ProcessInfo.processInfo.activeProcessorCount)
    private var paused: Bool
    private var observers: [NSObjectProtocol] = []
    /// For checks: each render reports whether it ran on the main thread; the last one finishing
    /// calls `onAllRendered`.
    var onRendered: ((_ index: Int, _ onMainThread: Bool) -> Void)?
    var onAllRendered: (() -> Void)?
    /// Thumbnails finished, and how many came from the disk cache or from reading the art.
    private(set) var renderedCount = 0
    private(set) var renderedFromCache = 0
    private(set) var renderedFromFile = 0
    /// The first pieces whose thumbnails were started, in order (for checks).
    private(set) var startedOrder: [Int] = []

    /// Collection indexes on show, in order (all of them unless a search is filtering).
    private(set) var shownIndexes: [Int]
    private var query: [String] = []
    private(set) var isSearching = false
    private(set) var searchStatus = ""
    private var searchGeneration = 0

    init(collection: ArtCollection, thumbnails: ThumbnailStore = .shared) {
        self.collection = collection
        self.store = thumbnails
        order = WorkOrder(count: collection.items.count)
        shownIndexes = Array(collection.items.indices)
        paused = Self.startsPaused
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit {
        queue.cancelAllOperations()
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    /// Where the grid / list choice is remembered for gallery windows.
    static let layoutKey = "galleryLayout"
    private(set) var layout = BrowseLayout.stored(key: GalleryViewController.layoutKey)

    /// The view of the pieces (for checks).
    var collectionView: NSCollectionView { grid }

    private static func makeLayout(_ layout: BrowseLayout) -> NSCollectionViewLayout {
        switch layout {
        case .grid:
            let flow = NSCollectionViewFlowLayout()
            flow.itemSize = itemSize
            flow.minimumInteritemSpacing = 12
            flow.minimumLineSpacing = 12
            flow.sectionInset = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
            return flow
        case .list:
            // One column of rows as wide as the window.
            let rows = NSCollectionViewGridLayout()
            rows.maximumNumberOfColumns = 1
            rows.minimumItemSize = NSSize(width: 200, height: GalleryListItem.height)
            rows.maximumItemSize = NSSize(width: 0, height: GalleryListItem.height)
            rows.minimumLineSpacing = 2
            rows.margins = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
            return rows
        }
    }

    /// Shows the pieces as a grid or a list, and remembers the choice for gallery windows.
    func setLayout(_ new: BrowseLayout) {
        let selected = grid.selectionIndexPaths
        layout = new
        new.store(key: Self.layoutKey)
        grid.collectionViewLayout = Self.makeLayout(new)
        grid.reloadData()
        grid.selectionIndexPaths = selected
        onLayoutChange?(new)
    }

    /// Told when the layout changes (the window's toggle follows).
    var onLayoutChange: ((BrowseLayout) -> Void)?

    @objc func layoutToggled(_ sender: NSSegmentedControl) {
        setLayout(BrowseLayout(segment: sender.selectedSegment))
    }

    override func loadView() {
        grid.collectionViewLayout = Self.makeLayout(layout)
        grid.dataSource = self
        grid.delegate = self
        grid.isSelectable = true
        grid.allowsMultipleSelection = true
        grid.backgroundColors = [NSColor(white: 0.08, alpha: 1)]
        grid.register(GalleryItem.self, forItemWithIdentifier: GalleryItem.identifier)
        grid.register(GalleryListItem.self, forItemWithIdentifier: GalleryListItem.identifier)
        grid.toolTip = "Double click a piece (or press Return) to open it."
        grid.onOpen = { [weak self] index in self?.openShown(index) }
        let scroll = NSScrollView()
        scroll.documentView = grid
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        searchField.placeholderString = "Search text in these pieces"
        searchField.toolTip = "Finds pieces whose words, file name or SAUCE (title, author, group, comments) contain every word you type. Cmd-F comes here."
        searchField.sendsSearchStringImmediately = false
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        searchField.delegate = self
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.lineBreakMode = .byTruncatingTail
        compareButton.bezelStyle = .rounded
        compareButton.controlSize = .small
        compareButton.target = self
        compareButton.action = #selector(compareSelected(_:))
        compareButton.toolTip = "Select two pieces, then Compare shows them side by side with the cells that differ tinted red."
        compareButton.isEnabled = false
        let bar = NSStackView(views: [searchField, statusLabel, NSView(), compareButton])
        bar.spacing = 10
        bar.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        bar.translatesAutoresizingMaskIntoConstraints = false
        searchField.widthAnchor.constraint(equalToConstant: 260).isActive = true

        let container = NSView()
        container.addSubview(bar)
        container.addSubview(scroll)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: container.topAnchor),
            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: bar.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container
        scroll.contentView.postsBoundsChangedNotifications = true
        observers.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                                                                object: scroll.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.visibleChanged() }
        })
        if collection.items.isEmpty { onAllRendered?() }
        DispatchQueue.main.async { [weak self] in self?.visibleChanged() }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(grid)
    }

    // MARK: Thumbnails (visible first, disk cache)

    /// For checks: starts rendering in a gallery made while `startsPaused` was on.
    func resumeRendering() {
        paused = false
        visibleChanged()
    }

    /// The pieces on screen go to the front of the work.
    private func visibleChanged() {
        let visible = grid.indexPathsForVisibleItems().map(\.item).sorted()
            .compactMap { shownIndexes.indices.contains($0) ? shownIndexes[$0] : nil }
        order.prioritize(visible)
        pumpThumbnails()
    }

    private func pumpThumbnails() {
        guard !paused else { return }
        while inFlight < workers, let index = order.next() {
            inFlight += 1
            if startedOrder.count < 64 { startedOrder.append(index) }
            let wantsText = !query.isEmpty
            queue.addOperation { [collection, store, weak self] in
                let result = Self.thumbnail(for: index, in: collection, store: store, wantsText: wantsText)
                let onMain = Thread.isMainThread
                DispatchQueue.main.async { self?.finished(index, result, onMain: onMain) }
            }
        }
    }

    private struct Rendered {
        let image: CGImage?
        let fromCache: Bool
        let haystack: SearchHaystack?
    }

    /// The cached thumbnail, or the art read, drawn and cached (with its text kept for searching).
    private static func thumbnail(for index: Int, in collection: ArtCollection, store: ThumbnailStore,
                                  wantsText: Bool) -> Rendered {
        let key = collection.thumbnailKey(at: index)
        if !wantsText, let key, let image = store.image(for: key) {
            return Rendered(image: image, fromCache: true, haystack: nil)
        }
        let file = collection.artFile(at: index)
        let screen = AnsiAnalysis(file).finalScreen
        let cached = key.flatMap { store.image(for: $0) }
        let image = cached ?? Thumbnail.render(file, screen: screen, maximum: thumbnailPixels)
        if cached == nil, let image, let key { store.store(image, for: key) }
        return Rendered(image: image, fromCache: cached != nil, haystack: haystack(collection.items[index].name, file, screen))
    }

    static func haystack(_ name: String, _ file: ArtFile, _ screen: AnsiScreen) -> SearchHaystack {
        let sauce = file.sauce
        return SearchHaystack(name: name, title: sauce?.title ?? "", author: sauce?.author ?? "", group: sauce?.group ?? "",
                              comments: sauce?.comments.joined(separator: "\n") ?? "", text: ArtText.plainText(screen))
    }

    private func finished(_ index: Int, _ result: Rendered, onMain: Bool) {
        inFlight -= 1
        if let image = result.image, thumbnails[index] == nil {
            thumbnails[index] = NSImage(cgImage: image, size: NSSize(width: image.width / 2, height: image.height / 2))
            renderedCount += 1
            if result.fromCache { renderedFromCache += 1 } else { renderedFromFile += 1 }
            onRendered?(index, onMain)
            if let shown = shownIndexes.firstIndex(of: index) {
                let path = IndexPath(item: shown, section: 0)
                if let item = grid.item(at: path) as? GalleryItem { item.thumbnail = thumbnails[index] }
                if let item = grid.item(at: path) as? GalleryListItem { item.thumbnail = thumbnails[index] }
            }
            if renderedCount == collection.items.count { onAllRendered?() }
        }
        if let haystack = result.haystack { haystacks[index] = haystack }
        pumpThumbnails()
    }

    // MARK: Search (plan 9 item 38: a folder or pack)

    @objc private func searchChanged(_ sender: NSSearchField) { search(sender.stringValue) }

    func focusSearch() { view.window?.makeFirstResponder(searchField) }

    /// Shows only the pieces whose name, SAUCE or art text contains every word of `text`. Pieces
    /// not read yet are read in the background; the grid fills in as they are.
    func search(_ text: String) {
        if searchField.stringValue != text { searchField.stringValue = text }
        query = ArtSearch.words(text)
        searchGeneration += 1
        guard !query.isEmpty else {
            isSearching = false
            searchStatus = ""
            statusLabel.stringValue = ""
            applyFilter()
            return
        }
        let missing = collection.items.indices.filter { haystacks[$0] == nil }
        guard !missing.isEmpty else { finishSearch(); return }
        isSearching = true
        let generation = searchGeneration
        var remaining = missing.count
        statusLabel.stringValue = "Reading \(missing.count) pieces..."
        for index in missing {
            queue.addOperation { [collection, weak self] in
                let file = collection.artFile(at: index)
                let hay = Self.haystack(collection.items[index].name, file, AnsiAnalysis(file).finalScreen)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.haystacks[index] = hay
                    remaining -= 1
                    guard generation == self.searchGeneration else { return }
                    if remaining == 0 { self.finishSearch() }
                    else if remaining % 200 == 0 { self.statusLabel.stringValue = "Reading \(remaining) more pieces..." }
                }
            }
        }
    }

    private func finishSearch() {
        isSearching = false
        applyFilter()
        let total = collection.items.count
        searchStatus = shownIndexes.isEmpty ? "No piece matches" : "\(shownIndexes.count) of \(total) pieces match"
        statusLabel.stringValue = searchStatus
    }

    private func applyFilter() {
        let selected = selectedIndexes
        shownIndexes = query.isEmpty ? Array(collection.items.indices)
            : collection.items.indices.filter { haystacks[$0]?.matches(words: query) == true }
        grid.reloadData()
        select(selected.compactMap { shownIndexes.firstIndex(of: $0) })
        updateCompareButton()
        visibleChanged()
    }

    func controlTextDidChange(_ note: Notification) {
        // Clearing the field (the x button or deleting everything) shows every piece at once.
        if searchField.stringValue.isEmpty, !query.isEmpty { search("") }
    }

    // MARK: Selection

    /// The first selected piece's collection index.
    var selectedIndex: Int? { selectedIndexes.first }

    /// The selected pieces' collection indexes in gallery order (for File > Batch Export).
    var selectedIndexes: [Int] {
        grid.selectionIndexPaths.map(\.item).sorted().compactMap { shownIndexes.indices.contains($0) ? shownIndexes[$0] : nil }
    }

    /// Selects pieces by their place on screen (for checks).
    func select(_ indexes: [Int]) {
        grid.selectionIndexPaths = Set(indexes.map { IndexPath(item: $0, section: 0) })
        updateCompareButton()
    }

    /// The two selected pieces, ready to compare; nil unless exactly two are selected.
    var piecesToCompare: [ComparePiece]? {
        let chosen = selectedIndexes
        guard chosen.count == 2 else { return nil }
        return chosen.map { ComparePiece(name: collection.items[$0].name, file: collection.artFile(at: $0)) }
    }

    @objc func compareSelected(_ sender: Any?) {
        guard let pieces = piecesToCompare else { NSSound.beep(); return }
        CompareWindowController.open(left: pieces[0], right: pieces[1])
    }

    private func updateCompareButton() { compareButton.isEnabled = selectedIndexes.count == 2 }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) { updateCompareButton() }
    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) { updateCompareButton() }

    private func openShown(_ shown: Int) {
        guard shownIndexes.indices.contains(shown) else { return }
        open(shownIndexes[shown])
    }

    /// Opens a piece: files as documents, art pack entries in a slideshow at that piece.
    func open(_ index: Int) {
        guard collection.items.indices.contains(index) else { return }
        if let url = collection.items[index].fileURL {
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
                if let error { NSAlert(error: error).runModal() }
            }
        } else {
            SlideshowWindowController.open(collection: collection, index: index)
        }
    }

    /// Slideshow > Start Slideshow: from the selected piece, or the first.
    @objc func startSlideshow(_ sender: Any?) {
        guard !collection.items.isEmpty else { NSSound.beep(); return }
        SlideshowWindowController.open(collection: collection, index: selectedIndex ?? 0)
    }

    // Edit > Find in a gallery: the search field.
    @objc func showArtFind(_ sender: Any?) { focusSearch() }

    // MARK: Data source

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        shownIndexes.count
    }

    func collectionView(_ collectionView: NSCollectionView,
                        itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let id = layout == .grid ? GalleryItem.identifier : GalleryListItem.identifier
        let item = collectionView.makeItem(withIdentifier: id, for: indexPath)
        let index = shownIndexes[indexPath.item]
        let name = collection.items[index].name
        if let item = item as? GalleryItem {
            item.name = name
            item.thumbnail = thumbnails[index]
        }
        if let item = item as? GalleryListItem {
            item.name = name
            item.detail = Self.kind(of: name)
            item.thumbnail = thumbnails[index]
        }
        return item
    }
}

extension GalleryViewController {
    /// What a list row says under the name: the kind of file, from its extension.
    static func kind(of name: String) -> String {
        let ext = (name as NSString).pathExtension
        return ext.isEmpty ? "Art" : ext.uppercased() + " art"
    }
}

/// One row of a gallery in list layout: a small thumbnail, the name and the kind of file.
final class GalleryListItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("GalleryListItem")
    static let height: CGFloat = 56
    private let picture = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")

    var name = "" {
        didSet { label.stringValue = name; view.setAccessibilityLabel(name) }
    }
    var detail = "" {
        didSet { detailLabel.stringValue = detail }
    }
    var thumbnail: NSImage? {
        didSet { picture.image = thumbnail }
    }

    override var isSelected: Bool {
        didSet { view.layer?.backgroundColor = isSelected ? NSColor.selectedContentBackgroundColor.cgColor : nil }
    }

    override func loadView() {
        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = 4
        picture.imageScaling = .scaleProportionallyDown
        label.textColor = .white
        label.font = .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingMiddle
        detailLabel.textColor = NSColor(white: 0.65, alpha: 1)
        detailLabel.font = .systemFont(ofSize: 11)
        let text = NSStackView(views: [label, detailLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        for view in [picture, text] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            box.addSubview(view)
        }
        NSLayoutConstraint.activate([
            picture.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 6),
            picture.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            picture.widthAnchor.constraint(equalToConstant: 64),
            picture.heightAnchor.constraint(equalToConstant: 48),
            text.leadingAnchor.constraint(equalTo: picture.trailingAnchor, constant: 12),
            text.trailingAnchor.constraint(lessThanOrEqualTo: box.trailingAnchor, constant: -8),
            text.centerYAnchor.constraint(equalTo: box.centerYAnchor),
        ])
        view = box
    }
}

/// Opens items on double click and Return.
final class GalleryCollectionView: NSCollectionView {
    var onOpen: ((Int) -> Void)?

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        guard event.clickCount == 2 else { return }
        let point = convert(event.locationInWindow, from: nil)
        if let path = indexPathForItem(at: point) { onOpen?(path.item) }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76, let item = selectionIndexPaths.map(\.item).min() {
            onOpen?(item)
        } else {
            super.keyDown(with: event)
        }
    }
}

/// Grid (thumbnails) or list (rows) for a window of art, remembered per kind of window.
enum BrowseLayout: String {
    case grid, list

    static func stored(key: String) -> BrowseLayout {
        UserDefaults.standard.string(forKey: key).flatMap(BrowseLayout.init(rawValue:)) ?? .grid
    }

    func store(key: String) { UserDefaults.standard.set(rawValue, forKey: key) }

    /// The two segment toggle (list, grid) that switches it.
    static func makeToggle(selected: BrowseLayout, target: AnyObject, action: Selector) -> NSSegmentedControl {
        let images = [NSImage(systemSymbolName: "list.bullet", accessibilityDescription: "List")!,
                      NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "Grid")!]
        let toggle = NSSegmentedControl(images: images, trackingMode: .selectOne, target: target, action: action)
        toggle.setToolTip("Show as a list", forSegment: 0)
        toggle.setToolTip("Show as a grid of pictures", forSegment: 1)
        toggle.toolTip = "List or grid of pictures"
        toggle.selectedSegment = selected == .list ? 0 : 1
        return toggle
    }

    init(segment: Int) { self = segment == 0 ? .list : .grid }
}

/// One thumbnail and its file name.
final class GalleryItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("GalleryItem")
    private let picture = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let note = NSTextField(labelWithString: "")

    var name = "" {
        didSet { label.stringValue = name; view.setAccessibilityLabel(name) }
    }
    var thumbnail: NSImage? {
        didSet { picture.image = thumbnail; note.isHidden = thumbnail != nil || placeholder.isEmpty }
    }
    /// Shown in place of the picture until it arrives ("Loading...", "No preview").
    var placeholder = "" {
        didSet { note.stringValue = placeholder; note.isHidden = thumbnail != nil || placeholder.isEmpty }
    }

    override var isSelected: Bool {
        didSet { view.layer?.backgroundColor = isSelected ? NSColor.selectedContentBackgroundColor.cgColor : nil }
    }

    override func loadView() {
        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = 6
        picture.imageScaling = .scaleProportionallyDown
        picture.translatesAutoresizingMaskIntoConstraints = false
        label.textColor = .white
        label.alignment = .center
        label.lineBreakMode = .byTruncatingMiddle
        label.font = .systemFont(ofSize: 11)
        label.translatesAutoresizingMaskIntoConstraints = false
        note.textColor = NSColor(white: 0.6, alpha: 1)
        note.font = .systemFont(ofSize: 11)
        note.alignment = .center
        note.isHidden = true
        note.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(picture)
        box.addSubview(label)
        box.addSubview(note)
        NSLayoutConstraint.activate([
            note.centerXAnchor.constraint(equalTo: picture.centerXAnchor),
            note.centerYAnchor.constraint(equalTo: picture.centerYAnchor),
            picture.topAnchor.constraint(equalTo: box.topAnchor, constant: 6),
            picture.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 4),
            picture.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -4),
            picture.heightAnchor.constraint(equalToConstant: 144),
            label.topAnchor.constraint(equalTo: picture.bottomAnchor, constant: 4),
            label.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -4),
        ])
        view = box
    }
}

final class GalleryWindowController: NSWindowController, NSWindowDelegate {
    private static var open: Set<GalleryWindowController> = []
    let content: GalleryContainerViewController
    let gallery: GalleryViewController

    @discardableResult
    static func open(collection: ArtCollection) -> GalleryWindowController {
        let controller = GalleryWindowController(collection: collection)
        open.insert(controller)
        controller.showWindow(nil)
        return controller
    }

    /// File > Open Folder or Art Pack: asks for a folder or a `.zip`, then shows its gallery.
    static func chooseAndOpen() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.folder, .zip]
        panel.prompt = "Open"
        panel.message = "Choose a folder of art or a ZIP art pack."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            open(collection: try ArtCollection.open(url, scoped: true))
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private init(collection: ArtCollection) {
        content = GalleryContainerViewController(collection: collection)
        gallery = content.gallery
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.minSize = NSSize(width: 260, height: 240)
        window.title = collection.title
        let count = collection.items.count
        var subtitle = count == 1 ? "1 piece" : "\(count) pieces"
        if collection.skipped > 0 { subtitle += ", \(collection.skipped) skipped (unsupported ZIP compression)" }
        window.subtitle = subtitle
        super.init(window: window)
        window.delegate = self
        window.contentViewController = content
        window.setContentSize(NSSize(width: content.packInfo == nil ? 900 : 1180, height: 620))
        window.center()
        // Grid / list toggle at the right of the title bar.
        let toggle = BrowseLayout.makeToggle(selected: gallery.layout, target: gallery,
                                             action: #selector(GalleryViewController.layoutToggled(_:)))
        toggle.controlSize = .small
        toggle.sizeToFit()
        let holder = NSView(frame: NSRect(x: 0, y: 0, width: toggle.frame.width + 12, height: toggle.frame.height + 4))
        toggle.frame.origin = NSPoint(x: 0, y: 2)
        holder.addSubview(toggle)
        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = holder
        accessory.layoutAttribute = .trailing
        window.addTitlebarAccessoryViewController(accessory)
        gallery.onLayoutChange = { [weak toggle] layout in toggle?.selectedSegment = layout == .list ? 0 : 1 }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func windowWillClose(_ notification: Notification) {
        Self.open.remove(self)
    }
}
