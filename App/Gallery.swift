import AnsiCore
import AppKit
import UniformTypeIdentifiers

/// A grid of thumbnails for a folder or art pack. Thumbnails render on background threads and
/// fill in as they finish. Double click (or Return) opens a piece.
final class GalleryViewController: NSViewController, NSCollectionViewDataSource {
    static let itemSize = NSSize(width: 200, height: 172)
    /// Thumbnails are rendered at twice the point size for Retina screens.
    static let thumbnailPixels = CGSize(width: 384, height: 288)

    let collection: ArtCollection
    private var thumbnails: [Int: NSImage] = [:]
    private let grid = GalleryCollectionView()
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = ProcessInfo.processInfo.activeProcessorCount
        queue.qualityOfService = .userInitiated
        return queue
    }()
    /// For checks: each render reports whether it ran on the main thread; the last one finishing
    /// calls `onAllRendered`.
    var onRendered: ((_ index: Int, _ onMainThread: Bool) -> Void)?
    var onAllRendered: (() -> Void)?

    init(collection: ArtCollection) {
        self.collection = collection
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit { queue.cancelAllOperations() }

    override func loadView() {
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = Self.itemSize
        layout.minimumInteritemSpacing = 12
        layout.minimumLineSpacing = 12
        layout.sectionInset = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        grid.collectionViewLayout = layout
        grid.dataSource = self
        grid.isSelectable = true
        grid.allowsMultipleSelection = true
        grid.backgroundColors = [NSColor(white: 0.08, alpha: 1)]
        grid.register(GalleryItem.self, forItemWithIdentifier: GalleryItem.identifier)
        grid.onOpen = { [weak self] index in self?.open(index) }
        let scroll = NSScrollView()
        scroll.documentView = grid
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        view = scroll
        renderThumbnails()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(grid)
    }

    private func renderThumbnails() {
        var remaining = collection.items.count
        if remaining == 0 { onAllRendered?() }
        for index in collection.items.indices {
            queue.addOperation { [collection, weak self] in
                let image = Thumbnail.render(collection.artFile(at: index), maximum: Self.thumbnailPixels)
                let onMain = Thread.isMainThread
                DispatchQueue.main.async {
                    guard let self else { return }
                    if let image {
                        self.thumbnails[index] = NSImage(cgImage: image, size: NSSize(width: image.width / 2,
                                                                                      height: image.height / 2))
                    }
                    self.onRendered?(index, onMain)
                    let path = IndexPath(item: index, section: 0)
                    if let item = self.grid.item(at: path) as? GalleryItem { item.thumbnail = self.thumbnails[index] }
                    remaining -= 1
                    if remaining == 0 { self.onAllRendered?() }
                }
            }
        }
    }

    var selectedIndex: Int? { grid.selectionIndexPaths.map(\.item).min() }

    /// The selected pieces in gallery order (for File > Batch Export).
    var selectedIndexes: [Int] { grid.selectionIndexPaths.map(\.item).sorted() }

    /// Selects pieces (for checks).
    func select(_ indexes: [Int]) {
        grid.selectionIndexPaths = Set(indexes.map { IndexPath(item: $0, section: 0) })
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

    // MARK: Data source

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        collection.items.count
    }

    func collectionView(_ collectionView: NSCollectionView,
                        itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: GalleryItem.identifier, for: indexPath)
        if let item = item as? GalleryItem {
            item.name = collection.items[indexPath.item].name
            item.thumbnail = thumbnails[indexPath.item]
        }
        return item
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

/// One thumbnail and its file name.
final class GalleryItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("GalleryItem")
    private let picture = NSImageView()
    private let label = NSTextField(labelWithString: "")

    var name = "" {
        didSet { label.stringValue = name; view.setAccessibilityLabel(name) }
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
        box.layer?.cornerRadius = 6
        picture.imageScaling = .scaleProportionallyDown
        picture.translatesAutoresizingMaskIntoConstraints = false
        label.textColor = .white
        label.alignment = .center
        label.lineBreakMode = .byTruncatingMiddle
        label.font = .systemFont(ofSize: 11)
        label.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(picture)
        box.addSubview(label)
        NSLayoutConstraint.activate([
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
        gallery = GalleryViewController(collection: collection)
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
        window.contentViewController = gallery
        window.setContentSize(NSSize(width: 900, height: 620))
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func windowWillClose(_ notification: Notification) {
        Self.open.remove(self)
    }
}
