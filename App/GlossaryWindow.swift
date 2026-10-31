import AnsiCore
import AppKit

// Help > AnsiView Glossary (item 62): every term in plain English, searchable, with related terms
// as links. The Help menu's own search field lists glossary entries too (GlossaryHelpSearch).

final class GlossaryWindowController: NSWindowController, NSWindowDelegate {
    private(set) static var current: GlossaryWindowController?
    let viewController = GlossaryViewController()

    /// Shows the glossary (one window), on `term` or filtered by `search` when given.
    @discardableResult
    static func show(term: GlossaryTerm? = nil, search: String? = nil) -> GlossaryWindowController {
        let controller = current ?? GlossaryWindowController()
        current = controller
        if let search { controller.viewController.setSearch(search) }
        if let term { controller.viewController.select(term) }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        return controller
    }

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = String(localized: "AnsiView Glossary")
        window.contentMinSize = NSSize(width: 640, height: 380)
        window.contentViewController = viewController
        window.setContentSize(NSSize(width: 900, height: 560))
        window.setFrameAutosaveName("AnsiViewGlossary")
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func windowWillClose(_ notification: Notification) { Self.current = nil }
}

final class GlossaryViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate,
                                    NSTextViewDelegate {
    let searchField = NSSearchField()
    let table = NSTableView()
    let detail = NSTextView()
    private(set) var results: [GlossaryEntry] = Glossary.sorted
    private(set) var selected: GlossaryEntry?
    private var selecting = false

    /// The detail pane's text (for checks).
    var detailText: String { detail.string }

    static let linkScheme = "ansiview-glossary"
    static func link(for term: GlossaryTerm) -> URL { URL(string: "\(linkScheme):\(term.rawValue)")! }

    override func loadView() {
        searchField.placeholderString = String(localized: "Search terms, such as iCE or ZMODEM")
        searchField.toolTip = String(localized: "Finds terms by name, other names and words in their explanations")
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        searchField.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("term"))
        column.title = String(localized: "Term")
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 38
        table.style = .sourceList
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel(String(localized: "Glossary terms"))
        let listScroll = NSScrollView()
        listScroll.documentView = table
        listScroll.hasVerticalScroller = true
        listScroll.translatesAutoresizingMaskIntoConstraints = false

        detail.isEditable = false
        detail.isSelectable = true
        detail.drawsBackground = false
        detail.textContainerInset = NSSize(width: 18, height: 16)
        detail.delegate = self
        detail.isVerticallyResizable = true
        detail.autoresizingMask = [.width]
        detail.textContainer?.widthTracksTextView = true
        detail.setAccessibilityLabel(String(localized: "Glossary entry"))
        let detailScroll = NSScrollView()
        detailScroll.documentView = detail
        detailScroll.hasVerticalScroller = true
        detailScroll.drawsBackground = false
        detailScroll.translatesAutoresizingMaskIntoConstraints = false

        let left = NSView()
        left.addSubview(searchField)
        left.addSubview(listScroll)
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: left.topAnchor, constant: 10),
            searchField.leadingAnchor.constraint(equalTo: left.leadingAnchor, constant: 10),
            searchField.trailingAnchor.constraint(equalTo: left.trailingAnchor, constant: -10),
            listScroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            listScroll.leadingAnchor.constraint(equalTo: left.leadingAnchor),
            listScroll.trailingAnchor.constraint(equalTo: left.trailingAnchor),
            listScroll.bottomAnchor.constraint(equalTo: left.bottomAnchor),
            left.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
        ])

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(left)
        split.addArrangedSubview(detailScroll)
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        split.frame = NSRect(x: 0, y: 0, width: 900, height: 560)
        split.setPosition(300, ofDividerAt: 0)
        view = split
        reload(keeping: nil)
    }

    /// Filters the list; keeps the selected entry when it still matches, else selects the first.
    func setSearch(_ text: String) {
        _ = view
        searchField.stringValue = text
        results = Glossary.search(text)
        reload(keeping: selected?.term)
    }

    /// Shows `term`, clearing the search when it hides that entry.
    func select(_ term: GlossaryTerm) {
        _ = view
        if !results.contains(where: { $0.term == term }) {
            searchField.stringValue = ""
            results = Glossary.sorted
            table.reloadData()
        }
        guard let row = results.firstIndex(where: { $0.term == term }) else { return }
        selecting = true
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
        selecting = false
        show(results[row])
    }

    /// Follows a related term link.
    func followLink(_ url: URL) {
        guard url.scheme == Self.linkScheme, let term = GlossaryTerm(rawValue: url.absoluteString
            .replacingOccurrences(of: Self.linkScheme + ":", with: "")) else { return }
        select(term)
    }

    @objc private func searchChanged(_ sender: Any?) { setSearch(searchField.stringValue) }

    func controlTextDidChange(_ obj: Notification) { setSearch(searchField.stringValue) }

    private func reload(keeping term: GlossaryTerm?) {
        table.reloadData()
        if let term, let row = results.firstIndex(where: { $0.term == term }) {
            selecting = true
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            selecting = false
            show(results[row])
        } else if let first = results.first {
            selecting = true
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            selecting = false
            show(first)
        } else {
            selected = nil
            detail.textStorage?.setAttributedString(NSAttributedString(
                string: String(localized: "No terms match. Try a shorter word."),
                attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor]))
        }
    }

    private func show(_ entry: GlossaryEntry) {
        selected = entry
        detail.textStorage?.setAttributedString(Self.attributed(entry))
        detail.scrollToBeginningOfDocument(nil)
    }

    /// The detail pane: title, category, hint, explanation, where in AnsiView and related links.
    static func attributed(_ entry: GlossaryEntry) -> NSAttributedString {
        let text = NSMutableAttributedString()
        let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor]
        let secondary: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor]
        let heading: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 13), .foregroundColor: NSColor.labelColor]
        text.append(NSAttributedString(string: entry.title + "\n", attributes: [.font: NSFont.boldSystemFont(ofSize: 20), .foregroundColor: NSColor.labelColor]))
        text.append(NSAttributedString(string: entry.category.label + "\n\n", attributes: secondary))
        text.append(NSAttributedString(string: entry.hint + "\n\n", attributes: [.font: NSFont.systemFont(ofSize: 14, weight: .medium), .foregroundColor: NSColor.labelColor]))
        text.append(NSAttributedString(string: entry.explanation + "\n\n", attributes: body))
        if let place = entry.whereInApp {
            text.append(NSAttributedString(string: String(localized: "In AnsiView") + "\n", attributes: heading))
            text.append(NSAttributedString(string: place + "\n\n", attributes: body))
        }
        if !entry.aliases.isEmpty {
            text.append(NSAttributedString(string: String(localized: "Also called") + "\n", attributes: heading))
            text.append(NSAttributedString(string: entry.aliases.joined(separator: ", ") + "\n\n", attributes: secondary))
        }
        text.append(NSAttributedString(string: String(localized: "Related") + "\n", attributes: heading))
        for (index, term) in entry.related.enumerated() {
            if index > 0 { text.append(NSAttributedString(string: "  \u{00B7}  ", attributes: secondary)) }
            var linkAttributes = body
            linkAttributes[.link] = Self.link(for: term)
            text.append(NSAttributedString(string: Glossary.entry(term).title, attributes: linkAttributes))
        }
        return text
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("GlossaryCell")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? {
            let cell = NSTableCellView()
            cell.identifier = id
            let title = NSTextField(labelWithString: "")
            title.font = .systemFont(ofSize: 13, weight: .semibold)
            title.lineBreakMode = .byTruncatingTail
            let hint = NSTextField(labelWithString: "")
            hint.font = .systemFont(ofSize: 11)
            hint.textColor = .secondaryLabelColor
            hint.lineBreakMode = .byTruncatingTail
            let stack = NSStackView(views: [title, hint])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 1
            stack.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(stack)
            cell.textField = title
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                stack.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
                stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                hint.widthAnchor.constraint(lessThanOrEqualTo: cell.widthAnchor, constant: -8),
            ])
            return cell
        }()
        let entry = results[row]
        cell.textField?.stringValue = entry.title
        (cell.subviews.first as? NSStackView)?.arrangedSubviews.last.flatMap { $0 as? NSTextField }?.stringValue = entry.hint
        cell.toolTip = entry.hint
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !selecting, results.indices.contains(table.selectedRow) else { return }
        show(results[table.selectedRow])
    }

    // MARK: Links

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let url = link as? URL, url.scheme == Self.linkScheme else { return false }
        followLink(url)
        return true
    }
}

/// The Help menu's search field lists glossary entries; choosing one opens it in the glossary.
final class GlossaryHelpSearch: NSObject, NSUserInterfaceItemSearching {
    static let shared = GlossaryHelpSearch()

    func searchForItems(withSearch searchString: String, resultLimit: Int, matchedItemHandler handleMatchedItems: @escaping ([Any]) -> Void) {
        guard !searchString.trimmingCharacters(in: .whitespaces).isEmpty else { handleMatchedItems([]); return }
        handleMatchedItems(Glossary.search(searchString).prefix(max(0, resultLimit)).map(\.term.rawValue))
    }

    func localizedTitles(forItem item: Any) -> [String] {
        guard let id = item as? String, let term = GlossaryTerm(rawValue: id) else { return [] }
        return [Glossary.entry(term).title]
    }

    func performAction(forItem item: Any) {
        guard let id = item as? String, let term = GlossaryTerm(rawValue: id) else { return }
        GlossaryWindowController.show(term: term)
    }

    func showAllHelpTopics(forSearch searchString: String) {
        GlossaryWindowController.show(search: searchString)
    }
}
