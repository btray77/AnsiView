import AnsiCore
import AppKit

/// The duplicate finder (plan 9 item 45, ruling 12): copies of the same art across the library's
/// folders and packs, as exact copies (same bytes) or the same art saved differently (same rendered
/// cells). Nothing is ticked at first; ticked files go to the Trash only after a confirmation, and
/// pieces inside ZIP packs can never be ticked.
final class DuplicatesViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let store: LibraryStore
    private(set) var groups: [DuplicateGroup] = []
    /// Record keys of the files to move to the Trash.
    private(set) var ticked: Set<String> = []
    /// How long grouping took the last time, in milliseconds (measured).
    private(set) var scanMilliseconds = 0.0
    /// Moves one file to the Trash (a stub in checks).
    var trash: (URL) throws -> Void = { url in try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
    /// Asks before moving (a stub in checks): the count and the paths; true to go ahead.
    var confirm: (Int, [String]) -> Bool = DuplicatesViewController.askToTrash
    private let outline = NSOutlineView()
    private let summaryLabel = NSTextField(labelWithString: "")
    private let trashButton = NSButton(title: "Move Ticked to Trash...", target: nil, action: nil)
    private var observer: NSObjectProtocol?
    private var nodes: [GroupNode] = []

    final class GroupNode: NSObject {
        let group: DuplicateGroup
        let members: [MemberNode]
        init(group: DuplicateGroup, members: [MemberNode]) { self.group = group; self.members = members }
    }

    final class MemberNode: NSObject {
        let record: IndexRecord
        init(record: IndexRecord) { self.record = record }
    }

    init(store: LibraryStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    var summary: String {
        guard !groups.isEmpty else { return "No duplicates among \(store.records.count) pieces (checked in \(Int(scanMilliseconds.rounded())) ms)." }
        let spare = Set(groups.flatMap { $0.members.dropFirst() }).count
        return "\(groups.count) groups, \(spare) extra copies among \(store.records.count) pieces (checked in \(Int(scanMilliseconds.rounded())) ms)."
            + (ticked.isEmpty ? "" : "  \(ticked.count) ticked.")
    }

    override func loadView() {
        for (id, title, width) in [("tick", "Trash", 44.0), ("name", "Copy", 420.0), ("size", "Size", 80.0), ("where", "Note", 300.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            outline.addTableColumn(column)
            if id == "name" { outline.outlineTableColumn = column }
        }
        outline.tableColumns[0].headerToolTip = "Tick the copies to move to the Trash. Copies inside ZIP packs cannot be ticked."
        outline.dataSource = self
        outline.delegate = self
        outline.allowsMultipleSelection = true
        outline.usesAlternatingRowBackgroundColors = true
        outline.target = self
        outline.doubleAction = #selector(openClicked(_:))
        outline.setAccessibilityLabel("Duplicate groups")
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        summaryLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.textColor = .secondaryLabelColor
        func button(_ title: String, _ tip: String, _ action: Selector) -> NSButton {
            let b = NSButton(title: title, target: self, action: action)
            b.bezelStyle = .rounded
            b.toolTip = tip
            return b
        }
        let tickAll = button("Tick All but One", "In every group, ticks every copy except one to keep: the one with the shortest path, then the oldest. Copies in packs are never ticked.", #selector(tickAllPressed(_:)))
        let untick = button("Untick All", "Clears every tick.", #selector(untickPressed(_:)))
        let compare = button("Compare", "Select two copies to see them side by side with the differing cells tinted.", #selector(comparePressed(_:)))
        let reveal = button("Show in Finder", "Shows the selected copies (or their packs) in the Finder.", #selector(revealPressed(_:)))
        trashButton.target = self
        trashButton.action = #selector(trashPressed(_:))
        trashButton.bezelStyle = .rounded
        trashButton.toolTip = "Moves the ticked files to the Trash after asking. Nothing is deleted: you can put them back from the Trash."
        let help = Hint.button(.duplicates)
        let bar = NSStackView(views: [tickAll, untick, compare, reveal, NSView(), help, trashButton])
        bar.spacing = 8
        let stack = NSStackView(views: [summaryLabel, scroll, bar])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        for v in [summaryLabel, scroll, bar] as [NSView] { v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true }
        scroll.setContentHuggingPriority(.init(1), for: .vertical)
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
        stack.setHuggingPriority(.init(1), for: .vertical)
        view = stack
        observer = NotificationCenter.default.addObserver(forName: LibraryStore.changed, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.store.isIndexing == false { self?.recompute() } }
        }
        recompute()
    }

    /// Groups the library's records again (after a scan or a move).
    func recompute() {
        let start = ProcessInfo.processInfo.systemUptime
        let records = store.records
        groups = DuplicateFinder.groups(records.map { ($0.byteHash, $0.cellHash) })
        scanMilliseconds = (ProcessInfo.processInfo.systemUptime - start) * 1000
        let keys = Set(records.map(\.key))
        ticked = ticked.filter(keys.contains)
        nodes = groups.map { group in GroupNode(group: group, members: group.members.map { MemberNode(record: records[$0]) }) }
        outline.reloadData()
        nodes.forEach { outline.expandItem($0) }
        update()
    }

    private func update() {
        summaryLabel.stringValue = summary
        trashButton.isEnabled = !ticked.isEmpty
    }

    func setTicked(_ key: String, _ on: Bool) {
        guard let record = store.records.first(where: { $0.key == key }), !record.isInPack else { NSSound.beep(); return }
        if on { ticked.insert(key) } else { ticked.remove(key) }
        outline.reloadData()
        update()
    }

    /// Ticks all but one loose file in every group (packs are never ticked, nor kept by default).
    func tickAllButOne() {
        var keepers = Set<String>()
        var candidates = Set<String>()
        for node in nodes {
            let loose = node.members.map(\.record).filter { !$0.isInPack }
            guard let keep = DuplicateFinder.keeper(paths: loose.map(\.path), dates: loose.map(\.modified)) else { continue }
            keepers.insert(loose[keep].key)
            for record in loose { candidates.insert(record.key) }
        }
        ticked = candidates.subtracting(keepers)
        outline.reloadData()
        update()
    }

    func untickAll() {
        ticked = []
        outline.reloadData()
        update()
    }

    /// Asks, then moves the ticked files to the Trash and takes them out of the library.
    func moveTickedToTrash() {
        guard !ticked.isEmpty else { return }
        let paths = ticked.sorted()
        guard confirm(paths.count, paths) else { return }
        var moved = Set<String>()
        var failed: [String] = []
        for path in paths {
            do {
                try trash(URL(fileURLWithPath: path))
                moved.insert(path)
            } catch {
                failed.append("\((path as NSString).lastPathComponent): \(error.localizedDescription)")
            }
        }
        ticked = []
        store.forget(keys: moved)
        recompute()
        if !failed.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Some files could not be moved to the Trash"
            alert.informativeText = failed.joined(separator: "\n")
            alert.runModal()
        }
    }

    static func askToTrash(_ count: Int, _ paths: [String]) -> Bool {
        let alert = NSAlert()
        alert.messageText = count == 1 ? "Move 1 file to the Trash?" : "Move \(count) files to the Trash?"
        let listed = paths.prefix(12).joined(separator: "\n") + (paths.count > 12 ? "\n...and \(paths.count - 12) more" : "")
        alert.informativeText = "These files go to the Trash (you can put them back from there):\n\n" + listed
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: Outline

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? GroupNode)?.members.count ?? (item == nil ? nodes.count : 0)
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? GroupNode)?.members[index] ?? nodes[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { item is GroupNode }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let id = tableColumn?.identifier.rawValue ?? ""
        if let group = item as? GroupNode {
            guard id == "name" else { return nil }
            let kind = group.group.kind == .exact ? "Exact copies" : "Same art, different bytes"
            let label = NSTextField(labelWithString: "\(kind): \(group.members.count) copies of \(group.members.first?.record.name ?? "")")
            label.font = .systemFont(ofSize: 12, weight: .semibold)
            return label
        }
        guard let member = item as? MemberNode else { return nil }
        let record = member.record
        switch id {
        case "tick":
            let box = NSButton(checkboxWithTitle: "", target: self, action: #selector(tickClicked(_:)))
            box.state = ticked.contains(record.key) ? .on : .off
            box.isEnabled = !record.isInPack
            box.identifier = NSUserInterfaceItemIdentifier(record.key)
            box.toolTip = record.isInPack ? "Inside a pack: it cannot be moved on its own." : "Tick to move this file to the Trash."
            box.setAccessibilityLabel("Move \(record.name) to the Trash")
            return box
        case "name":
            let label = NSTextField(labelWithString: record.isInPack ? record.path + " \u{203A} " + (record.entry ?? "") : record.path)
            label.lineBreakMode = .byTruncatingHead
            label.toolTip = label.stringValue
            return label
        case "size":
            return NSTextField(labelWithString: record.isInPack ? "" : ArtInfo.formatSize(record.size))
        default:
            var notes: [String] = []
            if record.isInPack { notes.append("inside a pack (cannot be moved)") }
            if !record.title.isEmpty || !record.author.isEmpty { notes.append("SAUCE: " + [record.title, record.author].filter { !$0.isEmpty }.joined(separator: " by ")) }
            let label = NSTextField(labelWithString: notes.joined(separator: "; "))
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingTail
            return label
        }
    }

    @objc private func tickClicked(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue else { return }
        setTicked(key, sender.state == .on)
    }

    private var selectedRecords: [IndexRecord] {
        outline.selectedRowIndexes.compactMap { (outline.item(atRow: $0) as? MemberNode)?.record }
    }

    @objc private func tickAllPressed(_ sender: Any?) { tickAllButOne() }
    @objc private func untickPressed(_ sender: Any?) { untickAll() }
    @objc private func trashPressed(_ sender: Any?) { moveTickedToTrash() }

    @objc private func comparePressed(_ sender: Any?) {
        let chosen = selectedRecords
        guard chosen.count == 2, let a = store.artFile(chosen[0]), let b = store.artFile(chosen[1]) else { NSSound.beep(); return }
        CompareWindowController.open(left: ComparePiece(name: chosen[0].name, file: a), right: ComparePiece(name: chosen[1].name, file: b))
    }

    @objc private func revealPressed(_ sender: Any?) {
        let urls = selectedRecords.map { URL(fileURLWithPath: $0.path) }
        guard !urls.isEmpty else { NSSound.beep(); return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    @objc private func openClicked(_ sender: Any?) {
        guard let member = outline.item(atRow: outline.clickedRow) as? MemberNode else { return }
        store.open(member.record)
    }
}

final class DuplicatesWindowController: NSWindowController, NSWindowDelegate {
    private static var current: DuplicatesWindowController?

    static func show(store: LibraryStore) {
        if let current { current.showWindow(nil); return }
        let controller = DuplicatesWindowController(store: store)
        current = controller
        controller.showWindow(nil)
    }

    private init(store: LibraryStore) {
        let content = DuplicatesViewController(store: store)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 560),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Duplicates in the Library"
        window.minSize = NSSize(width: 640, height: 320)
        super.init(window: window)
        window.delegate = self
        window.contentViewController = content
        window.setContentSize(NSSize(width: 1000, height: 560))
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func windowWillClose(_ notification: Notification) { Self.current = nil }
}
