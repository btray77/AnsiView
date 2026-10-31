import AnsiCore
import AppKit

/// One entry in the library's sidebar.
final class SidebarNode: NSObject {
    let title: String
    let source: LibrarySource?
    let symbol: String?
    let children: [SidebarNode]
    let tip: String?

    init(_ title: String, source: LibrarySource? = nil, symbol: String? = nil, tip: String? = nil, children: [SidebarNode] = []) {
        self.title = title
        self.source = source
        self.symbol = symbol
        self.tip = tip
        self.children = children
    }

    var isHeader: Bool { source == nil }
}

/// The library window's content (plan 9 items 38, 43, 44): sources on the left; search, the
/// artist or group page, the pieces and the selected piece's notes on the right.
final class LibraryViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate,
                                   NSCollectionViewDataSource, NSCollectionViewDelegate, NSTokenFieldDelegate,
                                   NSTableViewDataSource, NSTableViewDelegate {
    let store: LibraryStore
    private let outline = NSOutlineView()
    private var nodes: [SidebarNode] = []
    private let grid = LibraryGridView()
    private let searchField = NSSearchField()
    private let statusLabel = NSTextField(labelWithString: "")
    private let compareButton = NSButton(title: "Compare", target: nil, action: nil)
    // Artist / group page.
    private let pageBox = NSStackView()
    private let pageTitleLabel = NSTextField(labelWithString: "")
    private let pageDetailLabel = NSTextField(labelWithString: "")
    private let remoteButton = NSButton(title: "Show on 16colo.rs", target: nil, action: nil)
    private let remoteStatus = NSTextField(labelWithString: "")
    private let remoteTable = NSTableView()
    private let remoteScroll = NSScrollView()
    private var remotePacks: [SixteenColors.RemotePack] = []
    private var remoteTask: Task<Void, Never>?
    // Inspector.
    private let nameLabel = NSTextField(labelWithString: "")
    private let sauceLabel = NSTextField(labelWithString: "")
    private let rating = NSLevelIndicator()
    private let favouriteButton = NSButton()
    private let tagsField = NSTokenField()
    private var observer: NSObjectProtocol?

    private(set) var source: LibrarySource = .all
    private(set) var shownIndexes: [Int] = []
    private var query = ""
    private(set) var pageTitle = ""
    private(set) var pageDetail = ""

    init(store: LibraryStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        remoteTask?.cancel()
    }

    // MARK: Layout

    override func loadView() {
        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(makeSidebar())
        split.addArrangedSubview(makeMain())
        split.setHoldingPriority(.defaultLow + 10, forSubviewAt: 0)
        view = split
        observer = NotificationCenter.default.addObserver(forName: LibraryStore.changed, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.storeChanged() }
        }
        reloadSidebar()
        refresh()
        DispatchQueue.main.async { [weak self] in split.setPosition(220, ofDividerAt: 0); _ = self }
    }

    private func makeSidebar() -> NSView {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.dataSource = self
        outline.delegate = self
        outline.floatsGroupRows = false
        outline.rowSizeStyle = .default
        outline.target = self
        outline.doubleAction = #selector(sidebarDoubleClicked(_:))
        outline.setAccessibilityLabel("Library sources")
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let add = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "New Smart Folder")!,
                           target: self, action: #selector(newSmartFolder(_:)))
        add.bezelStyle = .texturedRounded
        add.toolTip = "New smart folder: a saved search, by tags, rating, favourite, SAUCE fields, text, format or year."
        let remove = NSButton(image: NSImage(systemSymbolName: "minus", accessibilityDescription: "Remove")!,
                              target: self, action: #selector(removeSelectedSource(_:)))
        remove.bezelStyle = .texturedRounded
        remove.toolTip = "Remove the selected smart folder, or take the selected folder out of the library (its files stay where they are)."
        let help = Hint.button(.smartFolder, detail: String(localized: "The built in smart folders cannot be removed."))
        let buttons = NSStackView(views: [add, remove, NSView(), help])
        buttons.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 6, right: 8)
        let box = NSStackView(views: [scroll, buttons])
        box.orientation = .vertical
        box.spacing = 0
        box.setHuggingPriority(.defaultLow, for: .horizontal)
        box.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        return box
    }

    private func makeMain() -> NSView {
        searchField.placeholderString = "Search the library"
        searchField.toolTip = "Finds pieces whose words, file name or SAUCE (title, author, group, comments) contain every word you type. Cmd-F comes here."
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        func button(_ title: String, _ tip: String, _ action: Selector) -> NSButton {
            let b = NSButton(title: title, target: self, action: action)
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.toolTip = tip
            return b
        }
        let addFolder = button("Add Folder...", "Adds a folder of art to the library. Subfolders and ZIP art packs inside it are included; nothing is copied or moved.", #selector(addFolderPressed(_:)))
        let rescan = button("Rescan", "Looks for new, changed and removed files in the library's folders. Unchanged files are not read again.", #selector(rescanPressed(_:)))
        let duplicates = button("Duplicates...", "Finds copies of the same art across the library's folders and packs.", #selector(duplicatesPressed(_:)))
        compareButton.target = self
        compareButton.action = #selector(compareSelected(_:))
        compareButton.bezelStyle = .rounded
        compareButton.controlSize = .small
        compareButton.toolTip = "Select two pieces, then Compare shows them side by side with the cells that differ tinted red."
        let help = Hint.button(.library)
        let bar = NSStackView(views: [searchField, statusLabel, NSView(), addFolder, rescan, duplicates, compareButton, help])
        bar.spacing = 8
        bar.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        searchField.widthAnchor.constraint(equalToConstant: 240).isActive = true

        // Artist or group page header.
        pageTitleLabel.font = .systemFont(ofSize: 20, weight: .bold)
        pageDetailLabel.textColor = .secondaryLabelColor
        pageDetailLabel.lineBreakMode = .byWordWrapping
        pageDetailLabel.maximumNumberOfLines = 2
        remoteButton.target = self
        remoteButton.action = #selector(remotePressed(_:))
        remoteButton.bezelStyle = .rounded
        remoteButton.controlSize = .small
        remoteButton.toolTip = String(localized: "Asks 16colo.rs, the online ANSI art archive, for packs under this name. Double click a pack to open it.")
        remoteStatus.textColor = .secondaryLabelColor
        remoteStatus.font = .systemFont(ofSize: 11)
        let pageHelp = Hint.button(.artScene, detail: String(localized: "Artist and group pages come from the author and group in your files' SAUCE records, merged when only case or spacing differ. 16colo.rs may spell a name differently, in which case it shows nothing."))
        let remoteRow = NSStackView(views: [remoteButton, remoteStatus, NSView(), pageHelp])
        for (id, title, width) in [("year", "Year", 60.0), ("pack", "Pack", 200.0), ("group", "Group", 160.0), ("files", "Files", 300.0)] {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            col.title = title
            col.width = width
            remoteTable.addTableColumn(col)
        }
        remoteTable.dataSource = self
        remoteTable.delegate = self
        remoteTable.target = self
        remoteTable.doubleAction = #selector(remoteDoubleClicked(_:))
        remoteTable.toolTip = "Double click a pack to download it from 16colo.rs and open it."
        remoteScroll.documentView = remoteTable
        remoteScroll.hasVerticalScroller = true
        remoteScroll.isHidden = true
        remoteScroll.heightAnchor.constraint(equalToConstant: 150).isActive = true
        pageBox.orientation = .vertical
        pageBox.alignment = .leading
        pageBox.spacing = 4
        pageBox.edgeInsets = NSEdgeInsets(top: 4, left: 14, bottom: 8, right: 14)
        for v in [pageTitleLabel, pageDetailLabel, remoteRow, remoteScroll] as [NSView] { pageBox.addArrangedSubview(v) }
        remoteRow.widthAnchor.constraint(equalTo: pageBox.widthAnchor, constant: -28).isActive = true
        remoteScroll.widthAnchor.constraint(equalTo: pageBox.widthAnchor, constant: -28).isActive = true
        pageBox.isHidden = true

        // Pieces.
        let flow = NSCollectionViewFlowLayout()
        flow.itemSize = NSSize(width: 200, height: 190)
        flow.minimumInteritemSpacing = 12
        flow.minimumLineSpacing = 12
        flow.sectionInset = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        grid.collectionViewLayout = flow
        grid.dataSource = self
        grid.delegate = self
        grid.isSelectable = true
        grid.allowsMultipleSelection = true
        grid.backgroundColors = [NSColor(white: 0.08, alpha: 1)]
        grid.register(LibraryItem.self, forItemWithIdentifier: LibraryItem.identifier)
        grid.onOpen = { [weak self] index in self?.openShown(index) }
        grid.onKey = { [weak self] chars in self?.handleKey(chars) ?? false }
        grid.setAccessibilityLabel("Pieces")
        let gridScroll = NSScrollView()
        gridScroll.documentView = grid
        gridScroll.hasVerticalScroller = true

        // Inspector.
        nameLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        sauceLabel.textColor = .secondaryLabelColor
        sauceLabel.font = .systemFont(ofSize: 11)
        sauceLabel.lineBreakMode = .byTruncatingTail
        rating.levelIndicatorStyle = .rating
        rating.maxValue = 5
        rating.isEditable = true
        rating.target = self
        rating.action = #selector(ratingChanged(_:))
        rating.toolTip = "Star rating (keys 0 to 5)"
        rating.setAccessibilityLabel("Rating")
        favouriteButton.setButtonType(.toggle)
        favouriteButton.bezelStyle = .texturedRounded
        favouriteButton.image = NSImage(systemSymbolName: "heart", accessibilityDescription: "Favourite")
        favouriteButton.alternateImage = NSImage(systemSymbolName: "heart.fill", accessibilityDescription: "Favourite")
        favouriteButton.target = self
        favouriteButton.action = #selector(favouritePressed(_:))
        favouriteButton.toolTip = "Favourite (key F)"
        tagsField.placeholderString = "Add tags (key T), separated by commas"
        tagsField.delegate = self
        tagsField.target = self
        tagsField.action = #selector(tagsChanged(_:))
        tagsField.toolTip = "Tags are your own labels, such as logos or favourites from a BBS. Type a tag and press Return or a comma."
        let sauceHelp = Hint.button(.sauce, detail: String(localized: "The library reads it to build artist and group pages."))
        let info = NSStackView(views: [nameLabel, sauceLabel])
        info.orientation = .vertical
        info.alignment = .leading
        info.spacing = 2
        let inspector = NSStackView(views: [info, NSView(), sauceHelp, rating, favouriteButton, tagsField])
        inspector.spacing = 10
        inspector.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        tagsField.widthAnchor.constraint(equalToConstant: 260).isActive = true
        info.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let main = NSStackView(views: [bar, pageBox, gridScroll, inspector])
        main.orientation = .vertical
        main.spacing = 0
        main.alignment = .leading
        for v in [bar, pageBox, gridScroll, inspector] as [NSView] {
            v.widthAnchor.constraint(equalTo: main.widthAnchor).isActive = true
        }
        gridScroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        main.widthAnchor.constraint(greaterThanOrEqualToConstant: 520).isActive = true
        return main
    }

    // MARK: Sidebar

    private func reloadSidebar() {
        func count(_ n: Int) -> String { "\(n)" }
        let builtIn = SmartFolder.builtIn.map { SidebarNode($0.name, source: .smart($0), symbol: "gearshape", tip: "Built in smart folder") }
        let custom = store.data.smartFolders.map { SidebarNode($0.name, source: .smart($0), symbol: "gearshape.fill",
                                                               tip: "Your smart folder. Double click to edit it.") }
        let tags = store.data.allTags.map { SidebarNode($0, source: .tag($0), symbol: "tag") }
        let artists = store.artists.map { SidebarNode("\($0.name) (\($0.pieces.count))", source: .artist($0.key), symbol: "person",
                                                      tip: "Pieces whose SAUCE author is \($0.name)") }
        let groups = store.groups.map { SidebarNode("\($0.name) (\($0.pieces.count))", source: .group($0.key), symbol: "person.3",
                                                    tip: "Pieces whose SAUCE group is \($0.name)") }
        let folders = store.data.folders.map { folder -> SidebarNode in
            let missing = store.missingFolders.contains(folder.id)
            return SidebarNode((folder.path as NSString).lastPathComponent + (missing ? " (not found)" : ""), source: .folder(folder.id),
                               symbol: missing ? "exclamationmark.triangle" : "folder", tip: folder.path)
        }
        nodes = [SidebarNode("Library", children: [SidebarNode("All Art (\(store.records.count))", source: .all, symbol: "square.grid.2x2")]),
                 SidebarNode("Smart Folders", children: builtIn + custom)]
        if !tags.isEmpty { nodes.append(SidebarNode("Tags", children: tags)) }
        if !artists.isEmpty { nodes.append(SidebarNode("Artists", children: artists)) }
        if !groups.isEmpty { nodes.append(SidebarNode("Groups", children: groups)) }
        nodes.append(SidebarNode("Folders", children: folders))
        outline.reloadData()
        for node in nodes { outline.expandItem(node) }
        selectSidebarRow(for: source)
    }

    /// Every sidebar title (for checks).
    var sidebarTitles: [String] { nodes.flatMap { [$0.title] + $0.children.map(\.title) } }

    private func selectSidebarRow(for source: LibrarySource) {
        for row in 0..<outline.numberOfRows {
            if let node = outline.item(atRow: row) as? SidebarNode, node.source == source {
                if outline.selectedRow != row { outline.selectRowIndexes([row], byExtendingSelection: false) }
                return
            }
        }
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? SidebarNode)?.children.count ?? nodes.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? SidebarNode)?.children[index] ?? nodes[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? SidebarNode)?.isHeader ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        (item as? SidebarNode)?.isHeader ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        !((item as? SidebarNode)?.isHeader ?? true)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? SidebarNode else { return nil }
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: node.isHeader ? node.title.uppercased() : node.title)
        label.lineBreakMode = .byTruncatingTail
        label.font = node.isHeader ? .systemFont(ofSize: 11, weight: .semibold) : .systemFont(ofSize: 13)
        label.textColor = node.isHeader ? .secondaryLabelColor : .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        cell.textField = label
        var leading = label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2)
        if let symbol = node.symbol, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            let icon = NSImageView(image: image)
            icon.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(icon)
            cell.imageView = icon
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 16),
            ])
            leading = label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6)
        }
        NSLayoutConstraint.activate([leading, label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                                     label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor)])
        cell.toolTip = node.tip
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard let node = outline.item(atRow: outline.selectedRow) as? SidebarNode, let source = node.source,
              source != self.source else { return }
        select(source: source)
    }

    /// Shows a source's pieces (and its page for an artist or group).
    func select(source: LibrarySource) {
        self.source = source
        remoteTask?.cancel()
        remotePacks = []
        remoteTable.reloadData()
        remoteScroll.isHidden = true
        remoteStatus.stringValue = ""
        selectSidebarRow(for: source)
        refresh()
    }

    // MARK: Contents

    private func storeChanged() {
        let selected = selectedRecords.map(\.key)
        reloadSidebar()
        refresh()
        let keys = Set(selected)
        select(shownIndexes.indices.filter { keys.contains(store.records[shownIndexes[$0]].key) })
    }

    private func refresh() {
        shownIndexes = store.matching(source, query: query)
        grid.reloadData()
        updatePage()
        updateStatus()
        updateInspector()
    }

    private func updateStatus() {
        var text = "\(shownIndexes.count) of \(store.records.count) pieces"
        if store.isIndexing {
            text += store.progress.total > 0 ? "  \u{00B7}  Indexing \(store.progress.done) of \(store.progress.total) files"
                : "  \u{00B7}  Looking for files..."
        } else if store.data.folders.isEmpty {
            text = "Add a folder of art to start the library."
        }
        statusLabel.stringValue = text
    }

    private func updatePage() {
        let entry: ArtistEntry?
        let kind: String
        switch source {
        case .artist(let key): entry = store.artists.first { $0.key == key }; kind = "artist"
        case .group(let key): entry = store.groups.first { $0.key == key }; kind = "group"
        default: entry = nil; kind = ""
        }
        guard let entry else {
            pageBox.isHidden = true
            pageTitle = ""
            pageDetail = ""
            return
        }
        pageBox.isHidden = false
        pageTitle = entry.name
        var parts = ["\(entry.pieces.count) piece\(entry.pieces.count == 1 ? "" : "s")"]
        if let first = entry.years.first, let last = entry.years.last {
            parts.append(first == last ? "\(first)" : "\(first) to \(last)")
        }
        if !entry.related.isEmpty {
            parts.append((kind == "artist" ? "with " : "artists: ") + entry.related.joined(separator: ", "))
        }
        pageDetail = parts.joined(separator: "  \u{00B7}  ")
        pageTitleLabel.stringValue = pageTitle
        pageDetailLabel.stringValue = pageDetail
        remoteButton.title = "Show on 16colo.rs"
    }

    @objc private func searchChanged(_ sender: NSSearchField) { search(sender.stringValue) }

    func search(_ text: String) {
        query = text
        if searchField.stringValue != text { searchField.stringValue = text }
        refresh()
    }

    @objc func showArtFind(_ sender: Any?) { view.window?.makeFirstResponder(searchField) }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { shownIndexes.count }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: LibraryItem.identifier, for: indexPath) as! LibraryItem
        let record = store.records[shownIndexes[indexPath.item]]
        item.name = record.name
        item.notes = store.data.notes(for: record.identity)
        item.thumbnail = store.thumbnail(for: record)
        item.view.toolTip = [record.title, record.author, record.group, record.packName.map { "in \($0)" }]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) { updateInspector() }
    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) { updateInspector() }

    var selectedRecords: [IndexRecord] {
        grid.selectionIndexPaths.map(\.item).sorted().compactMap {
            shownIndexes.indices.contains($0) ? store.records[shownIndexes[$0]] : nil
        }
    }

    /// Selects pieces by their place in the grid.
    func selectPieces(_ indexes: [Int]) { select(indexes) }

    private func select(_ indexes: [Int]) {
        grid.selectionIndexPaths = Set(indexes.map { IndexPath(item: $0, section: 0) })
        updateInspector()
    }

    private func updateInspector() {
        let chosen = selectedRecords
        compareButton.isEnabled = chosen.count == 2
        let enabled = !chosen.isEmpty
        rating.isEnabled = enabled
        favouriteButton.isEnabled = enabled
        tagsField.isEnabled = enabled
        guard let first = chosen.first else {
            nameLabel.stringValue = "No piece selected"
            sauceLabel.stringValue = "Select pieces to rate, tag or mark them as favourites."
            rating.integerValue = 0
            favouriteButton.state = .off
            tagsField.objectValue = []
            return
        }
        let notes = store.data.notes(for: first.identity)
        nameLabel.stringValue = chosen.count == 1 ? first.name : "\(chosen.count) pieces selected"
        let sauce = [first.title.isEmpty ? nil : "\u{201C}\(first.title)\u{201D}", first.author.isEmpty ? nil : "by \(first.author)",
                     first.group.isEmpty ? nil : first.group, first.year.map(String.init), first.packName.map { "in \($0)" }]
        sauceLabel.stringValue = chosen.count == 1 ? (sauce.compactMap { $0 }.joined(separator: ", ").nilIfEmpty ?? "No SAUCE record") : ""
        rating.integerValue = notes.rating
        favouriteButton.state = notes.favourite ? .on : .off
        tagsField.objectValue = notes.tags
    }

    // MARK: Notes

    /// Keys on the grid (ruling 9): 0 to 5 rate, F favourite, T tags, Space opens. True when handled.
    @discardableResult
    func handleKey(_ chars: String) -> Bool {
        let ids = selectedRecords.map(\.identity)
        switch chars.lowercased() {
        case "0", "1", "2", "3", "4", "5":
            guard !ids.isEmpty else { return false }
            store.setRating(Int(chars)!, for: ids)
        case "f":
            guard !ids.isEmpty else { return false }
            store.toggleFavourite(ids)
        case "t":
            guard !ids.isEmpty else { return false }
            view.window?.makeFirstResponder(tagsField)
        case " ":
            guard let first = selectedRecords.first else { return false }
            store.open(first)
        default:
            return false
        }
        return true
    }

    @objc private func ratingChanged(_ sender: NSLevelIndicator) {
        store.setRating(sender.integerValue, for: selectedRecords.map(\.identity))
    }

    @objc private func favouritePressed(_ sender: NSButton) { store.toggleFavourite(selectedRecords.map(\.identity)) }

    @objc private func tagsChanged(_ sender: NSTokenField) {
        let tags = (sender.objectValue as? [String]) ?? []
        store.setTags(tags, for: selectedRecords.map(\.identity))
    }

    func tokenField(_ tokenField: NSTokenField, completionsForSubstring substring: String, indexOfToken tokenIndex: Int,
                    indexOfSelectedItem selectedIndex: UnsafeMutablePointer<Int>?) -> [Any]? {
        store.data.allTags.filter { $0.lowercased().hasPrefix(substring.lowercased()) }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        if (obj.object as? NSTokenField) === tagsField { tagsChanged(tagsField) }
    }

    // MARK: Actions

    private func openShown(_ index: Int) {
        guard shownIndexes.indices.contains(index) else { return }
        store.open(store.records[shownIndexes[index]])
    }

    @objc private func addFolderPressed(_ sender: Any?) { store.chooseAndAddFolder(window: view.window) }
    @objc private func rescanPressed(_ sender: Any?) { store.rescan() }
    @objc private func duplicatesPressed(_ sender: Any?) { DuplicatesWindowController.show(store: store) }

    @objc func compareSelected(_ sender: Any?) {
        let chosen = selectedRecords
        guard chosen.count == 2, let a = store.artFile(chosen[0]), let b = store.artFile(chosen[1]) else { NSSound.beep(); return }
        CompareWindowController.open(left: ComparePiece(name: chosen[0].name, file: a), right: ComparePiece(name: chosen[1].name, file: b))
    }

    @objc private func newSmartFolder(_ sender: Any?) { editSmartFolder(nil) }

    @objc private func sidebarDoubleClicked(_ sender: Any?) {
        guard let node = outline.item(atRow: outline.clickedRow) as? SidebarNode, case .smart(let folder)? = node.source,
              store.data.smartFolders.contains(where: { $0.id == folder.id }) else { return }
        editSmartFolder(folder)
    }

    private func editSmartFolder(_ folder: SmartFolder?) {
        let editor = SmartFolderEditor(folder: folder, tags: store.data.allTags)
        editor.onSave = { [weak self] made in
            self?.store.addSmartFolder(made)
            self?.select(source: .smart(made))
        }
        presentAsSheet(editor)
    }

    @objc private func removeSelectedSource(_ sender: Any?) {
        switch source {
        case .smart(let folder) where store.data.smartFolders.contains(where: { $0.id == folder.id }):
            store.removeSmartFolder(folder.id)
            select(source: .all)
        case .folder(let id):
            let alert = NSAlert()
            alert.messageText = "Take this folder out of the library?"
            alert.informativeText = "Its files stay where they are; only the library's index and its thumbnails forget them. Tags and ratings are kept."
            alert.addButton(withTitle: "Remove from Library")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            store.removeFolder(id)
            select(source: .all)
        default:
            NSSound.beep()
        }
    }

    // MARK: 16colo.rs (item 44)

    @objc private func remotePressed(_ sender: Any?) {
        let name = pageTitle
        guard !name.isEmpty else { return }
        let isGroup: Bool
        if case .group = source { isGroup = true } else { isGroup = false }
        remoteTask?.cancel()
        remoteStatus.stringValue = "Asking 16colo.rs..."
        remoteTask = Task { [weak self] in
            do {
                let packs: [SixteenColors.RemotePack]
                var note = ""
                if isGroup {
                    let found = try await SixteenColorsClient.shared.groupPacks(name)
                    packs = found?.packs ?? []
                    if let group = found?.group { note = " (filed as \u{201C}\(group.longName ?? group.tag)\u{201D})" }
                } else {
                    packs = try await SixteenColorsClient.shared.artistPacks(name)
                }
                guard let self, !Task.isCancelled else { return }
                self.remotePacks = packs
                self.remoteTable.reloadData()
                self.remoteScroll.isHidden = packs.isEmpty
                self.remoteStatus.stringValue = packs.isEmpty ? "16colo.rs has nothing listed under this name."
                    : "\(packs.count) pack\(packs.count == 1 ? "" : "s") on 16colo.rs\(note). Double click one to open it."
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.remoteStatus.stringValue = SixteenColorsClient.describe(error).message
            }
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { remotePacks.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let pack = remotePacks[row]
        let text: String
        switch tableColumn?.identifier.rawValue {
        case "year": text = pack.year.map(String.init) ?? ""
        case "pack": text = pack.name
        case "group": text = pack.group ?? ""
        default: text = pack.files.joined(separator: ", ")
        }
        let label = NSTextField(labelWithString: text)
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    @objc private func remoteDoubleClicked(_ sender: Any?) {
        let row = remoteTable.clickedRow
        guard remotePacks.indices.contains(row) else { return }
        let name = remotePacks[row].name
        remoteStatus.stringValue = "Downloading \(name)..."
        Task { [weak self] in
            do {
                let url = try await SixteenColorsClient.shared.openPack(named: name)
                GalleryWindowController.open(collection: try ArtCollection.open(url, scoped: false))
                self?.remoteStatus.stringValue = "Opened \(name)."
            } catch {
                self?.remoteStatus.stringValue = SixteenColorsClient.describe(error).message
            }
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// The library's grid: Return and double click open; other keys go to `onKey` first.
final class LibraryGridView: NSCollectionView {
    var onOpen: ((Int) -> Void)?
    var onKey: ((String) -> Bool)?

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        guard event.clickCount == 2 else { return }
        if let path = indexPathForItem(at: convert(event.locationInWindow, from: nil)) { onOpen?(path.item) }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76, let item = selectionIndexPaths.map(\.item).min() {
            onOpen?(item)
            return
        }
        if event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           let chars = event.charactersIgnoringModifiers, onKey?(chars) == true { return }
        super.keyDown(with: event)
    }
}

/// A piece in the library grid: thumbnail, name, stars and a heart.
final class LibraryItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("LibraryItem")
    private let picture = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let badge = NSTextField(labelWithString: "")

    var name = "" { didSet { label.stringValue = name; updateAccessibility() } }
    var thumbnail: NSImage? { didSet { picture.image = thumbnail } }
    var notes = PieceNotes() {
        didSet {
            let stars = notes.rating > 0 ? String(repeating: "\u{2605}", count: notes.rating) + String(repeating: "\u{2606}", count: 5 - notes.rating) : ""
            badge.stringValue = [stars, notes.favourite ? "\u{2665}" : "", notes.tags.isEmpty ? "" : notes.tags.joined(separator: ", ")]
                .filter { !$0.isEmpty }.joined(separator: "  ")
            updateAccessibility()
        }
    }

    private func updateAccessibility() {
        var parts = [name]
        if notes.rating > 0 { parts.append("\(notes.rating) stars") }
        if notes.favourite { parts.append("favourite") }
        if !notes.tags.isEmpty { parts.append("tags " + notes.tags.joined(separator: ", ")) }
        view.setAccessibilityLabel(parts.joined(separator: ", "))
    }

    override var isSelected: Bool {
        didSet { view.layer?.backgroundColor = isSelected ? NSColor.selectedContentBackgroundColor.cgColor : nil }
    }

    override func loadView() {
        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = 6
        picture.imageScaling = .scaleProportionallyDown
        label.textColor = .white
        label.alignment = .center
        label.lineBreakMode = .byTruncatingMiddle
        label.font = .systemFont(ofSize: 11)
        badge.textColor = .systemYellow
        badge.alignment = .center
        badge.font = .systemFont(ofSize: 10)
        badge.lineBreakMode = .byTruncatingTail
        for v in [picture, label, badge] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            box.addSubview(v)
        }
        NSLayoutConstraint.activate([
            picture.topAnchor.constraint(equalTo: box.topAnchor, constant: 6),
            picture.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 4),
            picture.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -4),
            picture.heightAnchor.constraint(equalToConstant: 144),
            label.topAnchor.constraint(equalTo: picture.bottomAnchor, constant: 3),
            label.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -4),
            badge.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 1),
            badge.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 4),
            badge.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -4),
        ])
        view = box
    }
}

// MARK: Smart folder editor (ruling 8)

/// The fields a smart folder rule can test.
enum SmartField: Int, CaseIterable {
    case tag, notTag, untagged, rating, favourite, text, title, author, group, format, yearFrom, yearTo, addedDays

    var label: String {
        switch self {
        case .tag: return "Tag is"
        case .notTag: return "Tag is not"
        case .untagged: return "Has no tags"
        case .rating: return "Rating at least"
        case .favourite: return "Is a favourite"
        case .text: return "Text contains"
        case .title: return "SAUCE title contains"
        case .author: return "SAUCE author contains"
        case .group: return "SAUCE group contains"
        case .format: return "Format is"
        case .yearFrom: return "Year from"
        case .yearTo: return "Year up to"
        case .addedDays: return "Added in the last (days)"
        }
    }

    var needsValue: Bool { self != .untagged && self != .favourite }

    func rule(_ value: String) -> SmartRule? {
        let text = value.trimmingCharacters(in: .whitespaces)
        switch self {
        case .tag: return text.isEmpty ? nil : .tagIs(text)
        case .notTag: return text.isEmpty ? nil : .tagIsNot(text)
        case .untagged: return .untagged
        case .rating: return Int(text).map { .ratingAtLeast(min(5, max(0, $0))) }
        case .favourite: return .favourite
        case .text: return text.isEmpty ? nil : .textContains(text)
        case .title: return text.isEmpty ? nil : .titleContains(text)
        case .author: return text.isEmpty ? nil : .authorContains(text)
        case .group: return text.isEmpty ? nil : .groupContains(text)
        case .format: return text.isEmpty ? nil : .formatIs(text)
        case .yearFrom: return Int(text).map { .yearFrom($0) }
        case .yearTo: return Int(text).map { .yearTo($0) }
        case .addedDays: return Int(text).map { .addedWithinDays($0) }
        }
    }

    static func from(_ rule: SmartRule) -> (SmartField, String) {
        switch rule {
        case .tagIs(let v): return (.tag, v)
        case .tagIsNot(let v): return (.notTag, v)
        case .untagged: return (.untagged, "")
        case .ratingAtLeast(let v): return (.rating, "\(v)")
        case .favourite: return (.favourite, "")
        case .textContains(let v): return (.text, v)
        case .titleContains(let v): return (.title, v)
        case .authorContains(let v): return (.author, v)
        case .groupContains(let v): return (.group, v)
        case .formatIs(let v): return (.format, v)
        case .yearFrom(let v): return (.yearFrom, "\(v)")
        case .yearTo(let v): return (.yearTo, "\(v)")
        case .folderIs(let v): return (.text, v)
        case .addedWithinDays(let v): return (.addedDays, "\(v)")
        }
    }
}

/// A sheet to make or change a smart folder: a name, all or any, and rule rows.
final class SmartFolderEditor: NSViewController {
    let folder: SmartFolder?
    let tags: [String]
    let nameField = NSTextField()
    private let matchPopup = NSPopUpButton()
    private let rowsStack = NSStackView()
    private var rows: [(field: NSPopUpButton, value: NSComboBox, row: NSStackView)] = []
    var onSave: ((SmartFolder) -> Void)?

    init(folder: SmartFolder?, tags: [String]) {
        self.folder = folder
        self.tags = tags
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        nameField.placeholderString = "Smart folder name"
        nameField.stringValue = folder?.name ?? ""
        matchPopup.addItems(withTitles: ["all of these rules", "any of these rules"])
        matchPopup.selectItem(at: folder?.matchAll == false ? 1 : 0)
        matchPopup.toolTip = String(localized: "All: a piece must match every rule. Any: one matching rule is enough.")
        let matchRow = NSStackView(views: [NSTextField(labelWithString: "Pieces matching"), matchPopup])
        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 6
        let add = NSButton(title: "Add Rule", target: self, action: #selector(addPressed(_:)))
        add.toolTip = String(localized: "Adds another rule: a tag, rating, SAUCE field, year or format to match")
        let help = Hint.button(.smartFolder, detail: String(localized: "Format is a name such as ANSI, XBin or BinaryText."))
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelPressed(_:)))
        cancel.keyEquivalent = "\u{1B}"
        let save = NSButton(title: folder == nil ? "Create" : "Save", target: self, action: #selector(savePressed(_:)))
        save.keyEquivalent = "\r"
        let buttons = NSStackView(views: [add, help, NSView(), cancel, save])
        let stack = NSStackView(views: [nameField, matchRow, rowsStack, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        nameField.widthAnchor.constraint(equalToConstant: 420).isActive = true
        buttons.widthAnchor.constraint(equalTo: nameField.widthAnchor).isActive = true
        view = stack
        let start = folder?.rules.map(SmartField.from) ?? [(.tag, "")]
        setRows(start, matchAll: folder?.matchAll ?? true)
    }

    /// Replaces the rule rows (also used by checks).
    func setRows(_ values: [(SmartField, String)], matchAll: Bool) {
        _ = view
        rows.forEach { $0.row.removeFromSuperview() }
        rows = []
        for (field, value) in values { addRow(field, value) }
        matchPopup.selectItem(at: matchAll ? 0 : 1)
    }

    private func addRow(_ field: SmartField, _ value: String) {
        let popup = NSPopUpButton()
        popup.addItems(withTitles: SmartField.allCases.map(\.label))
        popup.selectItem(at: field.rawValue)
        popup.target = self
        popup.action = #selector(fieldChanged(_:))
        popup.toolTip = String(localized: "What this rule looks at: your tags, rating or favourites, or the file's SAUCE, year or format")
        let box = NSComboBox()
        box.stringValue = value
        box.completes = true
        box.addItems(withObjectValues: tags)
        box.widthAnchor.constraint(equalToConstant: 180).isActive = true
        box.isHidden = !field.needsValue
        let remove = NSButton(image: NSImage(systemSymbolName: "minus.circle", accessibilityDescription: "Remove rule")!,
                              target: self, action: #selector(removePressed(_:)))
        remove.isBordered = false
        remove.toolTip = String(localized: "Removes this rule")
        let row = NSStackView(views: [popup, box, remove])
        rowsStack.addArrangedSubview(row)
        rows.append((popup, box, row))
    }

    /// The smart folder the form describes; nil when it has no name or no usable rule.
    var result: SmartFolder? {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        let rules = rows.compactMap { SmartField(rawValue: $0.field.indexOfSelectedItem)?.rule($0.value.stringValue) }
        guard !name.isEmpty, !rules.isEmpty else { return nil }
        return SmartFolder(id: folder?.id ?? UUID(), name: name, matchAll: matchPopup.indexOfSelectedItem == 0, rules: rules)
    }

    @objc private func fieldChanged(_ sender: NSPopUpButton) {
        guard let row = rows.first(where: { $0.field === sender }), let field = SmartField(rawValue: sender.indexOfSelectedItem) else { return }
        row.value.isHidden = !field.needsValue
    }

    @objc private func addPressed(_ sender: Any?) { addRow(.tag, "") }

    @objc private func removePressed(_ sender: NSButton) {
        guard let index = rows.firstIndex(where: { $0.row.arrangedSubviews.contains(sender) }) else { return }
        rows[index].row.removeFromSuperview()
        rows.remove(at: index)
    }

    @objc private func cancelPressed(_ sender: Any?) { dismiss(self) }

    @objc private func savePressed(_ sender: Any?) {
        guard let made = result else {
            NSSound.beep()
            nameField.placeholderString = "A name and at least one complete rule are needed"
            return
        }
        onSave?(made)
        dismiss(self)
    }
}

// MARK: Window

final class LibraryWindowController: NSWindowController, NSWindowDelegate {
    private static var current: LibraryWindowController?

    /// Window > Library: shows the library and looks for new or changed files.
    static func show() {
        if let current { current.showWindow(nil); return }
        let controller = LibraryWindowController()
        current = controller
        controller.showWindow(nil)
        LibraryStore.shared.rescan()
    }

    private init() {
        let content = LibraryViewController(store: .shared)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 780),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Library"
        window.minSize = NSSize(width: 760, height: 480)
        window.setFrameAutosaveName("AnsiViewLibrary")
        super.init(window: window)
        window.delegate = self
        window.contentViewController = content
        window.setContentSize(NSSize(width: 1240, height: 780))
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func windowWillClose(_ notification: Notification) { Self.current = nil }
}
