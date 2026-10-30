import AnsiCore
import AppKit
import QuartzCore
import UniformTypeIdentifiers

// The Text to ASCII window (fonts plan rulings 17 and 20): type once, see the text in every
// installed font, pick one, adjust it, copy it out or insert it into the editor.

/// Opens the Text to ASCII window from the editor (Tools > Text Art...). Kept to this file so
/// the editor files only gain a menu item.
extension EditorCanvasView {
    @objc func showTextArt(_ sender: Any?) { TextToASCIIWindowController.show(editor: controller) }
}

final class TextToASCIIWindowController: NSWindowController, NSWindowDelegate {
    private(set) static var current: TextToASCIIWindowController?
    let viewController: TextToASCIIViewController

    /// Shows the window; with an editor, Insert places the art there as a floating paste.
    static func show(editor: EditorViewController?) {
        let controller = current ?? TextToASCIIWindowController()
        current = controller
        // Opened without an editor (Window menu), an earlier editor binding is kept.
        if let editor { controller.viewController.bind(editor: editor) }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.viewController.focusText()
    }

    init() {
        viewController = TextToASCIIViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Text to ASCII"
        window.contentMinSize = NSSize(width: 900, height: 560)
        window.contentViewController = viewController
        window.setContentSize(NSSize(width: 1180, height: 760))
        window.setFrameAutosaveName("TextToASCII")
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func windowWillClose(_ notification: Notification) {
        viewController.stopRendering()
        Self.current = nil
    }
}

// MARK: The window

final class TextToASCIIViewController: NSViewController, NSTextViewDelegate, NSSearchFieldDelegate {
    let library = FontStore.library
    let renderer = GalleryRenderer()
    /// Where Copy writes (a private pasteboard in the harness).
    var pasteboard = NSPasteboard.general

    // Input and gallery controls
    let textView = NSTextView()
    let searchField = NSSearchField()
    let categoryPopup = NSPopUpButton()
    let sortPopup = NSPopUpButton()
    let favouritesBox = NSButton(checkboxWithTitle: "Favourites only", target: nil, action: nil)
    let countLabel = NSTextField(labelWithString: "")
    let emptyNote = NSTextField(wrappingLabelWithString: FontHelp.emptyState)
    let gallery = GalleryDocumentView()
    private var layoutPending = false
    let scrollRenderer = GalleryRenderer(concurrency: 2)
    private var renderedKeys: [String: String] = [:]
    private var cardsRevision = -1
    private var sampleSave: DispatchWorkItem?
    private var keyObserver: NSObjectProtocol?
    let galleryScroll = NSScrollView()

    // Detail pane
    let detailTitle = NSTextField(labelWithString: "Choose a font")
    let detailSubtitle = NSTextField(labelWithString: "")
    let previewView = FlippedImageView()
    let previewScroll = NSScrollView()
    let horizontalPopup = NSPopUpButton()
    let verticalPopup = NSPopUpButton()
    let wrapBox = NSButton(checkboxWithTitle: "Wrap at", target: nil, action: nil)
    let wrapField = NSTextField(string: "80")
    let alignmentControl = NSSegmentedControl(labels: ["Left", "Centre", "Right"], trackingMode: .selectOne, target: nil, action: nil)
    var foregroundPopup = TextArtImages.colourPopup(selected: 7, tooltip: "Foreground colour for fonts without their own colours")
    var backgroundPopup = TextArtImages.colourPopup(selected: 0, tooltip: "Background colour (also the gaps between letters)")
    let gradientPopup = NSPopUpButton()
    let outlinePopup = NSPopUpButton()
    let spacingPopup = NSPopUpButton()
    let iceBox = NSButton(checkboxWithTitle: "iCE colours", target: nil, action: nil)
    let asciiBox = NSButton(checkboxWithTitle: "ASCII only", target: nil, action: nil)
    let commentPopup = NSPopUpButton(frame: .zero, pullsDown: true)
    let savePopup = NSPopUpButton(frame: .zero, pullsDown: true)
    let transparentBox = NSButton(checkboxWithTitle: "Transparent", target: nil, action: nil)
    let insertButton = NSButton(title: "Insert into Editor", target: nil, action: nil)
    let statusLabel = NSTextField(labelWithString: "")

    private var states: [String: GalleryCardState] = [:]
    private(set) var selectedID: String?
    private(set) var options = TextArtOptions()
    private(set) weak var editorController: EditorViewController?
    private var sizes: [String: GallerySize] = [:]
    private var query = GalleryQuery()
    private var observer: NSObjectProtocol?
    private var detailResult: TextArtResult?

    // Timings for the harness and the hint line (keystroke to first card, and to all cards).
    private var renderStart: CFTimeInterval = 0
    private var renderToken = 0
    private var delivered = 0
    private var expected = 0
    private(set) var firstCardSeconds: Double?
    private(set) var allCardsSeconds: Double?
    var onGalleryComplete: (() -> Void)?

    static let gradientPresets: [(String, [Int])] = [
        ("Fire", [15, 14, 12, 4]), ("Ice", [15, 11, 9, 1]), ("Rainbow", [12, 14, 10, 11, 9, 13]),
        ("Forest", [10, 2, 6]), ("Steel", [15, 7, 8]),
    ]

    deinit {
        for token in [observer, keyObserver].compactMap({ $0 }) { NotificationCenter.default.removeObserver(token) }
    }

    var text: String { textView.string }

    override func loadView() {
        let root = NSView()

        // Text field (several lines) at the top.
        textView.isRichText = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 15, weight: .regular)
        textView.string = library.sampleText
        textView.delegate = self
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.toolTip = "Type the text to turn into text art; Return starts a new line"
        textView.textContainerInset = NSSize(width: 6, height: 6)
        let textScroll = NSScrollView()
        textScroll.documentView = textView
        textScroll.hasVerticalScroller = true
        textScroll.borderType = .bezelBorder
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textScroll.translatesAutoresizingMaskIntoConstraints = false

        // Gallery controls.
        searchField.placeholderString = "Search fonts"
        searchField.delegate = self
        searchField.toolTip = "Find fonts by name, file, kind or source (Command-F)"
        categoryPopup.addItems(withTitles: ["All kinds"] + TextArtCategory.allCases.map(\.label) + ["Tall (6 rows or more)"])
        categoryPopup.target = self
        categoryPopup.action = #selector(queryChanged(_:))
        categoryPopup.toolTip = "Show one kind of font: FIGlet, TheDraw outline, block or colour, or only tall ones"
        sortPopup.addItems(withTitles: GalleryQuery.Sort.allCases.map { "Sort by \($0.label.lowercased())" })
        sortPopup.target = self
        sortPopup.action = #selector(queryChanged(_:))
        sortPopup.toolTip = "Order of the cards after favourites and recently used fonts"
        favouritesBox.target = self
        favouritesBox.action = #selector(queryChanged(_:))
        favouritesBox.toolTip = "Show only fonts you starred"
        let importButton = NSButton(title: "Import Fonts...", target: self, action: #selector(importFonts(_:)))
        importButton.toolTip = FontHelp.import_
        let managerButton = NSButton(title: "Font Manager", target: self, action: #selector(openManager(_:)))
        managerButton.toolTip = "List, preview, remove and reveal installed fonts"
        let typesHelp = TextArtImages.helpButton(FontHelp.tdfTypes, tooltip: "About TheDraw font kinds")
        countLabel.textColor = .secondaryLabelColor
        countLabel.font = NSFont.systemFont(ofSize: 11)
        let controlsTop = NSStackView(views: [searchField, categoryPopup, sortPopup])
        controlsTop.spacing = 8
        let controlsBottom = NSStackView(views: [favouritesBox, countLabel, NSView(), importButton, managerButton, typesHelp])
        controlsBottom.spacing = 8
        let controls = NSStackView(views: [controlsTop, controlsBottom])
        controls.orientation = .vertical
        controls.alignment = .leading
        controls.spacing = 6
        controlsBottom.translatesAutoresizingMaskIntoConstraints = false
        controlsBottom.widthAnchor.constraint(equalTo: controls.widthAnchor).isActive = true
        for control in [categoryPopup, sortPopup] { control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        searchField.widthAnchor.constraint(equalToConstant: 180).isActive = true

        emptyNote.textColor = .secondaryLabelColor
        emptyNote.font = NSFont.systemFont(ofSize: 12)

        // Gallery.
        gallery.owner = self
        gallery.imageSize = { [weak self] id in self?.cardImageSize(id) }
        gallery.autoresizingMask = [.width]
        galleryScroll.documentView = gallery
        galleryScroll.hasVerticalScroller = true
        galleryScroll.drawsBackground = true
        galleryScroll.backgroundColor = .windowBackgroundColor
        galleryScroll.contentView.postsFrameChangedNotifications = true

        let left = NSStackView(views: [controls, emptyNote, galleryScroll])
        left.orientation = .vertical
        left.alignment = .leading
        left.spacing = 6
        for view in [controls, galleryScroll] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: left.widthAnchor).isActive = true
        }
        emptyNote.widthAnchor.constraint(equalTo: left.widthAnchor).isActive = true

        let detail = buildDetailPane()
        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(left)
        split.addArrangedSubview(detail)
        detail.widthAnchor.constraint(greaterThanOrEqualToConstant: 380).isActive = true
        left.widthAnchor.constraint(greaterThanOrEqualToConstant: 420).isActive = true
        split.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(textScroll)
        root.addSubview(split)
        NSLayoutConstraint.activate([
            textScroll.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            textScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            textScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            textScroll.heightAnchor.constraint(equalToConstant: 64),
            split.topAnchor.constraint(equalTo: textScroll.bottomAnchor, constant: 10),
            split.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            split.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            split.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
        ])
        view = root

        observer = NotificationCenter.default.addObserver(forName: .fontLibraryChanged, object: nil, queue: .main) { [weak self] _ in
            self?.rebuildCards()
        }
        NotificationCenter.default.addObserver(self, selector: #selector(galleryScrolled(_:)),
                                               name: NSView.boundsDidChangeNotification, object: galleryScroll.contentView)
        rebuildCards()
        updateDetailControls()
    }

    private func buildDetailPane() -> NSView {
        detailTitle.font = NSFont.boldSystemFont(ofSize: 15)
        detailSubtitle.textColor = .secondaryLabelColor
        detailSubtitle.font = NSFont.systemFont(ofSize: 11)
        detailSubtitle.lineBreakMode = .byTruncatingTail
        for label in [detailTitle, detailSubtitle, statusLabel] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }

        previewView.imageScaling = .scaleNone
        previewView.imageAlignment = .alignTopLeft
        previewView.wantsLayer = true
        previewView.layer?.backgroundColor = NSColor.black.cgColor
        previewScroll.documentView = previewView
        previewScroll.hasVerticalScroller = true
        previewScroll.hasHorizontalScroller = true
        previewScroll.autohidesScrollers = true
        previewScroll.scrollerStyle = .overlay
        previewScroll.backgroundColor = .black
        previewScroll.borderType = .bezelBorder
        previewScroll.toolTip = "The selected font at twice the size, exactly as it will be copied or inserted"

        for popup in [horizontalPopup, verticalPopup] {
            popup.addItems(withTitles: FIGletLayout.allCases.map(\.label))
            popup.target = self
            popup.action = #selector(optionsChanged(_:))
        }
        horizontalPopup.toolTip = "How close FIGlet letters sit side by side"
        verticalPopup.toolTip = "How close lines of FIGlet text sit above each other"
        wrapBox.target = self
        wrapBox.action = #selector(optionsChanged(_:))
        wrapBox.toolTip = "Move words to a new line when the art gets wider than this many columns"
        wrapField.target = self
        wrapField.action = #selector(optionsChanged(_:))
        wrapField.widthAnchor.constraint(equalToConstant: 48).isActive = true
        wrapField.toolTip = "Width limit in columns (1 to 1000)"
        alignmentControl.selectedSegment = 0
        alignmentControl.target = self
        alignmentControl.action = #selector(optionsChanged(_:))
        alignmentControl.toolTip = "Line up several lines of text on the left, in the centre or on the right"
        for popup in [foregroundPopup, backgroundPopup] {
            popup.target = self
            popup.action = #selector(optionsChanged(_:))
        }
        gradientPopup.addItems(withTitles: ["Plain colour"] + Self.gradientPresets.flatMap { name, _ in
            ["\(name) across", "\(name) down"]
        })
        gradientPopup.target = self
        gradientPopup.action = #selector(optionsChanged(_:))
        gradientPopup.toolTip = "Colours spread across the columns or down the rows (fonts without their own colours)"
        for style in 0..<19 {
            outlinePopup.addItem(withTitle: "Style \(style + 1)   \(TextArt.outlineSample(style))")
        }
        outlinePopup.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        outlinePopup.target = self
        outlinePopup.action = #selector(optionsChanged(_:))
        outlinePopup.toolTip = "The line set TheDraw outline fonts are drawn with"
        spacingPopup.addItems(withTitles: ["Font spacing"] + (0...12).map { "\($0) column\($0 == 1 ? "" : "s")" })
        spacingPopup.target = self
        spacingPopup.action = #selector(optionsChanged(_:))
        spacingPopup.toolTip = "Columns between TheDraw letters; Font spacing uses the font's own"
        iceBox.target = self
        iceBox.action = #selector(optionsChanged(_:))
        iceBox.toolTip = "Colour fonts: the blink bit becomes a bright background, as on an iCE canvas"

        func row(_ label: String, _ views: [NSView]) -> NSStackView {
            let title = NSTextField(labelWithString: label)
            title.alignment = .right
            title.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
            title.widthAnchor.constraint(equalToConstant: 76).isActive = true
            let stack = NSStackView(views: [title] + views)
            stack.spacing = 6
            return stack
        }
        let layoutHelp = TextArtImages.helpButton(FontHelp.figletLayouts, tooltip: "About FIGlet layouts and smushing")
        let outlineHelp = TextArtImages.helpButton(FontHelp.outlineStyles, tooltip: "About outline styles")

        // Output.
        let copyText = NSButton(title: "Copy Text", target: self, action: #selector(copyText(_:)))
        copyText.toolTip = "Copy the art as plain text (Return in the gallery does the same)"
        asciiBox.toolTip = "Copy with ASCII characters only: lines and blocks become - | + # and similar"
        let copyANSI = NSButton(title: "Copy ANSI", target: self, action: #selector(copyANSI(_:)))
        copyANSI.toolTip = "Copy with colour escape codes, for terminals and BBS messages"
        let copyImage = NSButton(title: "Copy Image", target: self, action: #selector(copyImage(_:)))
        copyImage.toolTip = "Copy a PNG picture of the art"
        commentPopup.addItem(withTitle: "Copy as Comment")
        for style in TextArtOutput.CommentStyle.allCases {
            commentPopup.addItem(withTitle: style.label)
            commentPopup.lastItem?.representedObject = style.rawValue
            commentPopup.lastItem?.target = self
            commentPopup.lastItem?.action = #selector(copyComment(_:))
        }
        commentPopup.toolTip = "Copy the art wrapped as a source code comment"
        let copyMarkdown = NSButton(title: "Copy Markdown", target: self, action: #selector(copyMarkdown(_:)))
        copyMarkdown.toolTip = "Copy as a Markdown code block"
        savePopup.addItem(withTitle: "Save As")
        for (title, ext) in [("Text (.txt)...", "txt"), ("ANSI art (.ans)...", "ans"), ("Picture (.png)...", "png")] {
            savePopup.addItem(withTitle: title)
            savePopup.lastItem?.representedObject = ext
            savePopup.lastItem?.target = self
            savePopup.lastItem?.action = #selector(save(_:))
        }
        savePopup.toolTip = "Save the art as a text file, an ANSI art file with SAUCE, or a picture"
        transparentBox.toolTip = "Spaces in the inserted art leave the art underneath (T while it floats)"
        transparentBox.target = self
        transparentBox.action = #selector(optionsChanged(_:))
        insertButton.target = self
        insertButton.action = #selector(insert(_:))
        insertButton.keyEquivalent = "\r"
        insertButton.keyEquivalentModifierMask = [.command]
        insertButton.toolTip = "Place the art in the editor at the cursor as a floating paste: move it, then click or press Return to stamp it (one undo step); Escape cancels (Command-Return)"
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.lineBreakMode = .byTruncatingTail

        let rows: [NSView] = [
            NSStackView(views: [detailTitle]),
            detailSubtitle,
            previewScroll,
            row("Horizontal:", [horizontalPopup, layoutHelp]),
            row("Vertical:", [verticalPopup]),
            row("Width:", [wrapBox, wrapField, NSTextField(labelWithString: "columns")]),
            row("Alignment:", [alignmentControl]),
            row("Colours:", [foregroundPopup, NSTextField(labelWithString: "on"), backgroundPopup]),
            row("Gradient:", [gradientPopup]),
            row("Outline:", [outlinePopup, outlineHelp]),
            row("Spacing:", [spacingPopup, iceBox]),
            NSStackView(views: [copyText, copyANSI, copyImage, asciiBox]),
            NSStackView(views: [commentPopup, copyMarkdown, savePopup]),
            NSStackView(views: [transparentBox, insertButton]),
            statusLabel,
        ]
        for control in [horizontalPopup, verticalPopup, wrapBox, alignmentControl, foregroundPopup, backgroundPopup, gradientPopup,
                        outlinePopup, spacingPopup, iceBox, asciiBox, commentPopup, savePopup, transparentBox, insertButton,
                        copyText, copyANSI, copyImage, copyMarkdown] as [NSControl] {
            control.controlSize = .small
            control.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        }
        outlinePopup.font = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 12, bottom: 4, right: 4)
        previewScroll.translatesAutoresizingMaskIntoConstraints = false
        previewScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        previewScroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -16).isActive = true
        previewScroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -16).isActive = true
        return stack
    }

    // MARK: Binding to an editor

    func bind(editor: EditorViewController?) {
        editorController = editor
        if let editor {
            foregroundPopup.selectItem(at: editor.editor.foreground)
            backgroundPopup.selectItem(at: editor.editor.background)
            wrapField.stringValue = "\(editor.editor.canvas.columns)"
            iceBox.state = editor.editor.canvas.iceColors ? .on : .off
            transparentBox.state = editor.editor.transparentPaste ? .on : .off
        }
        optionsChanged(nil)
    }

    func focusText() { view.window?.makeFirstResponder(textView) }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command, event.charactersIgnoringModifiers == "f" {
            view.window?.makeFirstResponder(searchField)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: Gallery

    var arrangedEntries: [FontEntry] {
        FontGallery.arrange(library.entries, query: query, favourites: library.favourites, recent: library.recent, sizes: sizes)
    }

    /// The fonts in the gallery, in order (only those near the visible area have card views).
    var entries: [FontEntry] { gallery.entries }

    /// What a font's card shows now, when it has been drawn and is still kept.
    func state(for id: String) -> GalleryCardState? { states[id] }

    /// Fills a card view for `entry` (called by the gallery as it tiles).
    func configure(_ card: GalleryCardView, entry: FontEntry) {
        card.configure(entry: entry, state: states[entry.id], favourite: library.favourites.contains(entry.id),
                       selected: entry.id == selectedID)
    }

    /// Rebuilds the gallery for the current query, then renders it.
    func rebuildCards() {
        // After an import or removal nothing drawn for the old fonts is kept (ids can be reused).
        if library.revision != cardsRevision {
            cardsRevision = library.revision
            states = [:]
            renderedKeys = [:]
        }
        gallery.setEntries(arrangedEntries)
        emptyNote.isHidden = !library.userEntries.isEmpty
        countLabel.stringValue = "\(entries.count) of \(library.entries.count) fonts"
        if selectedID == nil || !entries.contains(where: { $0.id == selectedID }) {
            selectedID = entries.first?.id
            gallery.tile()
        }
        renderGallery()
        renderDetail()
    }

    /// Cards on screen now (rendered first).
    var visibleIDs: [String] {
        gallery.indexes(in: galleryScroll.documentVisibleRect).map { entries[$0].id }
    }

    /// Galleries up to this size render every card per keystroke; larger ones render the cards
    /// near the visible part and the rest as they scroll into view (review I3).
    static let renderAllLimit = 300

    var galleryOptions: TextArtOptions {
        var result = TextArtOptions()
        result.foreground = options.foreground
        result.background = options.background
        result.outlineStyle = options.outlineStyle
        result.gradient = options.gradient
        result.iceColors = options.iceColors
        return result
    }

    /// What a card shows: the text and the options that change gallery cards.
    var renderKey: String {
        let o = galleryOptions
        return "\(text)\u{0}\(o.foreground),\(o.background),\(o.outlineStyle),\(o.iceColors),\(String(describing: o.gradient))"
    }

    /// Fonts near the visible part of the gallery: `screens` above and below.
    func nearbyIDs(screens: CGFloat = 1) -> [String] {
        let visible = galleryScroll.documentVisibleRect
        return gallery.indexes(in: visible.insetBy(dx: 0, dy: -visible.height * screens)).map { entries[$0].id }
    }

    /// Starts rendering the cards (visible ones first); a newer call cancels this one.
    func renderGallery() {
        let text = self.text, key = renderKey
        let list = entries
        let wanted = list.count <= Self.renderAllLimit ? list : nearbyIDs().compactMap { id in list.first { $0.id == id } }
        renderStart = CACurrentMediaTime()
        renderToken += 1
        let token = renderToken
        delivered = 0
        expected = wanted.count
        firstCardSeconds = nil
        allCardsSeconds = nil
        renderer.start(text: text, entries: wanted, options: galleryOptions, priority: visibleIDs) { [weak self] id, result in
            // Drawn and scaled to display size here, off the main thread; only the hand-over is on main.
            let image = TextArtImages.thumbnail(result.region)
            DispatchQueue.main.async {
                // A newer keystroke started another run while this card was on its way: drop it.
                guard let self, self.renderToken == token else { return }
                self.deliver(id: id, result: result, image: image, key: key, counted: true)
            }
        }
    }

    /// Cards scrolled into view that still show older text are drawn now (review M12).
    @objc private func galleryScrolled(_ note: Notification) {
        gallery.tile()
        let key = renderKey, text = self.text
        let ids = Set(nearbyIDs().filter { renderedKeys[$0] != key })
        guard !ids.isEmpty else { return }
        let stale = entries.filter { ids.contains($0.id) }
        scrollRenderer.start(text: text, entries: stale, options: galleryOptions, priority: visibleIDs) { [weak self] id, result in
            let image = TextArtImages.thumbnail(result.region)
            DispatchQueue.main.async {
                guard let self, self.renderKey == key else { return }
                self.deliver(id: id, result: result, image: image, key: key, counted: false)
            }
        }
    }

    private func deliver(id: String, result: TextArtResult, image: NSImage?, key: String, counted: Bool) {
        states[id] = GalleryCardState(result: result, image: image, key: key)
        renderedKeys[id] = key
        sizes[id] = GallerySize(columns: result.region.width, rows: result.region.height)
        scheduleLayout()
        guard counted else { return }
        delivered += 1
        let elapsed = CACurrentMediaTime() - renderStart
        if firstCardSeconds == nil { firstCardSeconds = elapsed }
        if delivered == expected {
            allCardsSeconds = elapsed
            // Order and the Tall filter depend on sizes: arrange again now they are known (review M13).
            if query.sort != .name || query.minimumRows != nil {
                let order = arrangedEntries
                if order.map(\.id) != entries.map(\.id) { gallery.setEntries(order) }
                countLabel.stringValue = "\(entries.count) of \(library.entries.count) fonts"
            }
            onGalleryComplete?()
        }
    }

    /// Cards arriving together are laid out once; far away art is let go (memory stays bounded).
    private func scheduleLayout() {
        guard !layoutPending else { return }
        layoutPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.layoutPending = false
            self.evictFarStates()
            self.gallery.relayout()
        }
    }

    /// Keeps the drawn art of at most a few hundred fonts: those near the visible area and the
    /// selected one. Card heights come from `sizes`, which stay.
    private func evictFarStates() {
        guard states.count > Self.renderAllLimit else { return }
        var keep = Set(nearbyIDs(screens: 3))
        if let selectedID { keep.insert(selectedID) }
        for id in states.keys where !keep.contains(id) {
            states[id] = nil
            renderedKeys[id] = nil
        }
    }

    /// The size a card's art has (drawn, or estimated from its last measured size).
    func cardImageSize(_ id: String) -> NSSize? {
        if let image = states[id]?.image { return image.size }
        if let size = sizes[id], size.columns > 0 { return NSSize(width: size.columns * 8, height: size.rows * 16) }
        return nil
    }

    func stopRendering() {
        renderer.cancel()
        scrollRenderer.cancel()
        saveSampleNow()
    }

    func textDidChange(_ notification: Notification) {
        // Saved a second after typing stops, not on every keystroke (review I2).
        sampleSave?.cancel()
        let save = DispatchWorkItem { [weak self] in self?.saveSampleNow() }
        sampleSave = save
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: save)
        renderGallery()
        renderDetail()
    }

    func saveSampleNow() {
        sampleSave?.cancel()
        sampleSave = nil
        guard library.sampleText != text else { return }
        library.sampleText = text
        NotificationCenter.default.post(name: .fontSampleChanged, object: nil)
    }

    func controlTextDidChange(_ obj: Notification) {
        if (obj.object as? NSSearchField) === searchField { queryChanged(nil) }
    }

    @objc func queryChanged(_ sender: Any?) {
        query.search = searchField.stringValue
        let category = categoryPopup.indexOfSelectedItem
        query.categories = []
        query.minimumRows = nil
        if category >= 1, category <= TextArtCategory.allCases.count {
            query.categories = [TextArtCategory.allCases[category - 1]]
        } else if category == TextArtCategory.allCases.count + 1 {
            query.minimumRows = 6
        }
        query.sort = GalleryQuery.Sort.allCases[max(0, sortPopup.indexOfSelectedItem)]
        query.favouritesOnly = favouritesBox.state == .on
        rebuildCards()
    }

    func select(_ id: String) {
        selectedID = id
        for card in gallery.live.values { card.isSelected = card.entry?.id == id }
        if let frame = gallery.frame(of: id) { gallery.scrollToVisible(frame) }
        gallery.tile()
        view.window?.makeFirstResponder(gallery)
        updateDetailControls()
        renderDetail()
    }

    func moveSelection(by step: Int) {
        let list = entries
        guard !list.isEmpty else { return }
        let index = list.firstIndex { $0.id == selectedID } ?? -step
        select(list[min(list.count - 1, max(0, index + step))].id)
    }

    func toggleFavourite(_ id: String) {
        library.setFavourite(id, !library.favourites.contains(id))
        FontStore.changed()
    }

    var selectedEntry: FontEntry? { library.entry(id: selectedID ?? "") }

    // MARK: Detail

    private func updateDetailControls() {
        guard let entry = selectedEntry else {
            detailTitle.stringValue = "Choose a font"
            detailSubtitle.stringValue = ""
            return
        }
        detailTitle.stringValue = entry.name
        detailSubtitle.stringValue = "\(entry.kindLabel), \(entry.fileName), \(entry.source.label)"
        let figlet = entry.category == .figlet
        horizontalPopup.isEnabled = figlet
        verticalPopup.isEnabled = figlet
        outlinePopup.isEnabled = entry.category == .tdfOutline
        spacingPopup.isEnabled = !figlet
        let mono = entry.font.isMonochrome
        foregroundPopup.isEnabled = mono
        gradientPopup.isEnabled = mono
        iceBox.isEnabled = !mono
        refreshEditorBinding()
    }

    @objc func optionsChanged(_ sender: Any?) {
        options.horizontalLayout = FIGletLayout.allCases[max(0, horizontalPopup.indexOfSelectedItem)]
        options.verticalLayout = FIGletLayout.allCases[max(0, verticalPopup.indexOfSelectedItem)]
        options.wrapWidth = wrapBox.state == .on ? min(1000, max(1, Int(wrapField.stringValue) ?? 80)) : nil
        options.alignment = TextArtAlignment.allCases[max(0, alignmentControl.selectedSegment)]
        options.foreground = max(0, foregroundPopup.indexOfSelectedItem)
        options.background = max(0, backgroundPopup.indexOfSelectedItem)
        let gradient = gradientPopup.indexOfSelectedItem
        if gradient > 0 {
            let preset = Self.gradientPresets[(gradient - 1) / 2]
            options.gradient = TextArtGradient(colors: preset.1, direction: (gradient - 1) % 2 == 0 ? .columns : .rows)
        } else {
            options.gradient = nil
        }
        options.outlineStyle = max(0, outlinePopup.indexOfSelectedItem)
        options.spacing = spacingPopup.indexOfSelectedItem > 0 ? spacingPopup.indexOfSelectedItem - 1 : nil
        options.iceColors = iceBox.state == .on
        // The box is the editor's own Transparent paste setting (review M11).
        if (sender as AnyObject?) === transparentBox { editorController?.editor.transparentPaste = transparentBox.state == .on }
        updateDetailControls()
        // Colours, outline style and gradient show on every card; layouts only in the detail.
        if sender == nil || [foregroundPopup, backgroundPopup, gradientPopup, outlinePopup, iceBox].contains(where: { $0 === sender as AnyObject }) {
            renderGallery()
        }
        renderDetail()
    }

    func renderDetail() {
        guard let entry = selectedEntry else {
            previewView.image = nil
            detailResult = nil
            return
        }
        let result = TextArt.render(text, font: entry.font, options: options)
        detailResult = result
        let image = TextArtImages.image(result.region, scale: 2)
        previewView.image = image
        previewView.frame = NSRect(origin: .zero, size: image?.size ?? .zero)
        previewScroll.contentView.scroll(to: .zero)
        previewScroll.reflectScrolledClipView(previewScroll.contentView)
        var status = "\(result.region.width) x \(result.region.height) cells"
        if !result.missing.isEmpty { status += ". Missing in this font: \(String(result.missing.prefix(30)))" }
        if let first = firstCardSeconds {
            status += String(format: ". Gallery: first card %.0f ms", first * 1000)
            if let all = allCardsSeconds { status += String(format: ", all %d in %.0f ms", expected, all * 1000) }
        }
        statusLabel.stringValue = status
    }

    // MARK: Output

    var currentRegion: CanvasRegion? {
        guard let region = detailResult?.region, region.width > 0 else { NSSound.beep(); return nil }
        if let id = selectedID { library.noteUsed(id) }
        return region
    }

    private func put(_ string: String, extra: [(NSPasteboard.PasteboardType, Data)] = []) {
        let board = pasteboard
        board.clearContents()
        board.setString(string, forType: .string)
        for (type, data) in extra { board.setData(data, forType: type) }
        statusLabel.stringValue = "Copied."
    }

    @objc func copyText(_ sender: Any?) {
        guard let region = currentRegion else { return }
        put(TextArtOutput.plainText(region, asciiOnly: asciiBox.state == .on))
    }

    @objc func copyANSI(_ sender: Any?) {
        guard let region = currentRegion else { return }
        put(TextArtOutput.ansi(region), extra: [(NSPasteboard.PasteboardType("com.traynham.ansiview.ansi"), Data(TextArtOutput.ansi(region).utf8))])
    }

    @objc func copyImage(_ sender: Any?) {
        guard let region = currentRegion, let png = TextArtImages.png(region) else { return }
        let board = pasteboard
        board.clearContents()
        board.setData(png, forType: .png)
        statusLabel.stringValue = "Copied."
    }

    @objc func copyComment(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let style = TextArtOutput.CommentStyle(rawValue: raw),
              let region = currentRegion else { return }
        put(TextArtOutput.comment(TextArtOutput.plainText(region, asciiOnly: asciiBox.state == .on), style: style))
    }

    @objc func copyMarkdown(_ sender: Any?) {
        guard let region = currentRegion else { return }
        put(TextArtOutput.markdown(TextArtOutput.plainText(region, asciiOnly: asciiBox.state == .on)))
    }

    @objc func save(_ sender: NSMenuItem) {
        guard let ext = sender.representedObject as? String, let region = currentRegion, let window = view.window else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = (text.split(separator: "\n").first.map(String.init) ?? "Text art") + "." + ext
        if let type = UTType(filenameExtension: ext) { panel.allowedContentTypes = [type] }
        let title = String(text.prefix(35))
        let ascii = asciiBox.state == .on, ice = options.iceColors
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                switch ext {
                case "txt": try (TextArtOutput.plainText(region, asciiOnly: ascii) + "\n").write(to: url, atomically: true, encoding: .utf8)
                case "png": try (TextArtImages.png(region) ?? Data()).write(to: url)
                default: try TextArtOutput.ansFile(region, title: title, iceColors: ice).write(to: url)
                }
            } catch {
                NSAlert(error: error).beginSheetModal(for: window)
            }
        }
    }

    /// Floats the art in the bound editor at its cursor (ruling 17).
    /// Insert names the bound document and is off once it has closed; Transparent shows the
    /// editor's own setting, which T in the editor may have changed (review M10, M11).
    func refreshEditorBinding() {
        let bound = editorController
        insertButton.isEnabled = bound != nil
        transparentBox.isEnabled = bound != nil
        if let bound {
            transparentBox.state = bound.editor.transparentPaste ? .on : .off
            let name = bound.view.window?.title ?? ""
            insertButton.title = name.isEmpty ? "Insert into Editor" : "Insert into \(name)"
        } else {
            insertButton.title = "Insert into Editor"
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard keyObserver == nil, let window = view.window else { return }
        keyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window,
                                                             queue: .main) { [weak self] _ in self?.refreshEditorBinding() }
    }

    @objc func insert(_ sender: Any?) {
        refreshEditorBinding()
        guard let editorController, let region = currentRegion else { NSSound.beep(); return }
        let editor = editorController.editor
        editor.transparentPaste = transparentBox.state == .on
        editor.beginFloating(region)
        editorController.view.window?.makeKeyAndOrderFront(nil)
        editorController.view.window?.makeFirstResponder(editorController.canvasView)
        editorController.editorChanged()
    }

    @objc func importFonts(_ sender: Any?) { FontStore.chooseAndImport(from: view.window) }
    @objc func openManager(_ sender: Any?) { FontManagerWindowController.show() }
}

/// An image view whose origin is the top left, so a scroll view shows the art from its top.
final class FlippedImageView: NSImageView {
    override var isFlipped: Bool { true }
}
