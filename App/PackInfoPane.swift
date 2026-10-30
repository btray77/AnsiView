import AnsiCore
import AppKit

/// A pack's FILE_ID.DIZ and NFO files, shown beside its gallery as soon as it opens (plan 9
/// item 46, ruling 13), rendered as art. A picker chooses between several.
final class PackInfoPane: NSViewController {
    let collection: ArtCollection
    /// Collection indexes of the info files, DIZ first.
    let indexes: [Int]
    private let picker = NSPopUpButton()
    private let holder = NSView()
    private(set) var player: AnsiPlayerViewController?
    private(set) var shownIndex: Int?

    init(collection: ArtCollection, indexes: [Int]) {
        self.collection = collection
        self.indexes = indexes
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The info files' names, in picker order.
    var choices: [String] { indexes.map { collection.items[$0].name } }
    var shownName: String? { shownIndex.map { collection.items[$0].name } }

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(white: 0.1, alpha: 1).cgColor
        let title = NSTextField(labelWithString: "Pack info")
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = .white
        picker.addItems(withTitles: choices)
        picker.controlSize = .small
        picker.target = self
        picker.action = #selector(picked(_:))
        picker.toolTip = "The pack's own description files: FILE_ID.DIZ (the short description BBSes showed in file lists) and NFO files (release notes)."
        picker.isHidden = indexes.count < 2
        let help = Hint.button("FILE_ID.DIZ is the short description an art pack carried for BBS file lists; NFO files are "
            + "the group's release notes. AnsiView shows them when a pack or folder opens. View > Show Pack Info hides this pane.",
            title: "Pack info")
        let bar = NSStackView(views: [title, picker, NSView(), help])
        bar.spacing = 8
        bar.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 8)
        bar.appearance = NSAppearance(named: .darkAqua)
        bar.translatesAutoresizingMaskIntoConstraints = false
        holder.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(bar)
        container.addSubview(holder)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: container.topAnchor),
            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            holder.topAnchor.constraint(equalTo: bar.bottomAnchor),
            holder.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            holder.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            holder.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            container.widthAnchor.constraint(greaterThanOrEqualToConstant: 320),
        ])
        view = container
        show(0)
    }

    /// Shows the info file at `choice` (an index into `choices`).
    func show(_ choice: Int) {
        guard indexes.indices.contains(choice) else { return }
        _ = view
        if let old = player {
            old.halt()
            old.view.removeFromSuperview()
            old.removeFromParent()
        }
        let index = indexes[choice]
        let next = AnsiPlayerViewController(source: collection.artFile(at: index), showsTimeline: false)
        next.artName = collection.items[index].name
        next.fileURL = collection.items[index].fileURL
        next.handlesArrowKeys = false
        ViewerCopy.enable(next)
        addChild(next)
        next.view.frame = holder.bounds
        next.view.autoresizingMask = [.width, .height]
        holder.addSubview(next.view)
        player = next
        shownIndex = index
        if picker.indexOfSelectedItem != choice { picker.selectItem(at: choice) }
    }

    @objc private func picked(_ sender: NSPopUpButton) { show(sender.indexOfSelectedItem) }
}

/// A gallery with its pack info pane at the side when the pack has info files.
final class GalleryContainerViewController: NSSplitViewController {
    static let packInfoKey = "showPackInfo"
    let gallery: GalleryViewController
    let packInfo: PackInfoPane?
    private var infoItem: NSSplitViewItem?

    init(collection: ArtCollection, thumbnails: ThumbnailStore = .shared) {
        gallery = GalleryViewController(collection: collection, thumbnails: thumbnails)
        let found = PackInfo.infoFiles(collection.itemPaths)
        packInfo = found.isEmpty ? nil : PackInfoPane(collection: collection, indexes: found)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    static var showsPackInfo: Bool { UserDefaults.standard.object(forKey: packInfoKey) as? Bool ?? true }

    override func viewDidLoad() {
        super.viewDidLoad()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        addSplitViewItem(NSSplitViewItem(viewController: gallery))
        if let packInfo {
            let item = NSSplitViewItem(viewController: packInfo)
            item.canCollapse = true
            item.minimumThickness = 320
            item.preferredThicknessFraction = 0.32
            item.isCollapsed = !Self.showsPackInfo
            addSplitViewItem(item)
            infoItem = item
        }
    }

    var packInfoShown: Bool { infoItem.map { !$0.isCollapsed } ?? false }

    /// View > Show Pack Info: hides or shows the pane, and remembers the choice.
    @objc func togglePackInfo(_ sender: Any?) {
        guard let infoItem else { NSSound.beep(); return }
        infoItem.isCollapsed.toggle()
        UserDefaults.standard.set(!infoItem.isCollapsed, forKey: Self.packInfoKey)
    }
}
