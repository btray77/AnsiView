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

// MARK: Cards

/// One font in the gallery: name, kind, favourite star, the rendered sample, missing characters.
/// Laid out with frames, not constraints: hundreds of cards changing size on every keystroke
/// must not go through the constraint solver.
final class GalleryCardView: NSView, NSDraggingSource {
    static let headerHeight: CGFloat = 24
    static let padding: CGFloat = 8
    static let maxImageHeight: CGFloat = 240

    let entry: FontEntry
    weak var owner: TextToASCIIViewController?
    let star = NSButton(title: "", target: nil, action: nil)
    let nameLabel: NSTextField
    let kindLabel: NSTextField
    let imageView = NSImageView()
    let missingLabel = NSTextField(labelWithString: "")
    private(set) var result: TextArtResult?
    private var dragStart: NSPoint?

    var isSelected = false { didSet { updateLook() } }
    var isFavourite = false { didSet { star.title = isFavourite ? "★" : "☆" } }

    init(entry: FontEntry, owner: TextToASCIIViewController) {
        self.entry = entry
        self.owner = owner
        nameLabel = NSTextField(labelWithString: entry.name)
        kindLabel = NSTextField(labelWithString: "\(entry.kindLabel)  \u{00B7}  \(entry.fileName)")
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        star.isBordered = false
        star.font = NSFont.systemFont(ofSize: 15)
        star.target = self
        star.action = #selector(toggleStar(_:))
        star.toolTip = "Favourite: favourites come first in the gallery"
        nameLabel.font = NSFont.boldSystemFont(ofSize: 12)
        nameLabel.lineBreakMode = .byTruncatingTail
        kindLabel.font = NSFont.systemFont(ofSize: 11)
        kindLabel.textColor = .secondaryLabelColor
        kindLabel.lineBreakMode = .byTruncatingMiddle
        missingLabel.font = NSFont.systemFont(ofSize: 11)
        missingLabel.textColor = .systemOrange
        missingLabel.lineBreakMode = .byTruncatingTail
        missingLabel.toolTip = "Characters this font does not have; they are left as a gap (letters use the other case first)"
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignTopLeft
        imageView.wantsLayer = true
        imageView.layer?.backgroundColor = NSColor.black.cgColor
        imageView.toolTip = "Click to select, double-click to copy as text, or drag the art out as text"
        for view in [star, nameLabel, kindLabel, missingLabel, imageView] as [NSView] { addSubview(view) }
        updateLook()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    /// The art's size on screen for a card `width` wide: its own size, scaled down to fit.
    func imageSize(forWidth width: CGFloat) -> NSSize {
        guard let size = imageView.image?.size, size.width > 0, size.height > 0 else { return NSSize(width: 0, height: 16) }
        let available = max(16, width - 2 * Self.padding)
        let scale = min(1, available / size.width, Self.maxImageHeight / size.height)
        return NSSize(width: floor(size.width * scale), height: floor(size.height * scale))
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        Self.headerHeight + imageSize(forWidth: width).height + Self.padding + 4
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { needsLayout = true }
    }

    override func layout() {
        super.layout()
        let w = bounds.width, p = Self.padding
        star.frame = NSRect(x: p - 2, y: 3, width: 20, height: 20)
        let nameWidth = min(ceil(nameLabel.intrinsicContentSize.width) + 4, w * 0.45)
        nameLabel.frame = NSRect(x: p + 20, y: 5, width: nameWidth, height: 16)
        let missingWidth = missingLabel.stringValue.isEmpty ? 0 : min(missingLabel.intrinsicContentSize.width, w * 0.3)
        missingLabel.frame = NSRect(x: w - p - missingWidth, y: 6, width: missingWidth, height: 15)
        let kindX = nameLabel.frame.maxX + 8
        kindLabel.frame = NSRect(x: kindX, y: 6, width: max(0, missingLabel.frame.minX - 8 - kindX), height: 15)
        let size = imageSize(forWidth: w)
        imageView.frame = NSRect(x: p, y: Self.headerHeight, width: size.width, height: size.height)
    }

    func show(_ result: TextArtResult, image: NSImage?) {
        self.result = result
        missingLabel.stringValue = result.missing.isEmpty ? "" : "missing: " + String(result.missing.prefix(12))
        imageView.image = image
        needsLayout = true
    }

    /// What dragging the card out drops: its art as plain text.
    var dragText: String? { result.map { TextArtOutput.plainText($0.region) } }

    func clearImage() {
        result = nil
        imageView.image = nil
    }

    private func updateLook() {
        layer?.borderColor = (isSelected ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
        layer?.borderWidth = isSelected ? 2 : 1
        layer?.backgroundColor = (isSelected ? NSColor.controlAccentColor.withAlphaComponent(0.12) : NSColor.controlBackgroundColor).cgColor
    }

    @objc private func toggleStar(_ sender: Any?) { owner?.toggleFavourite(entry.id) }

    override func mouseDown(with event: NSEvent) {
        dragStart = convert(event.locationInWindow, from: nil)
        owner?.select(entry.id)
        if event.clickCount == 2 { owner?.copyText(nil) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, let result else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - start.x, point.y - start.y) > 4 else { return }
        dragStart = nil
        let item = NSPasteboardItem()
        item.setString(dragText ?? "", forType: .string)
        let dragging = NSDraggingItem(pasteboardWriter: item)
        dragging.setDraggingFrame(imageView.frame, contents: imageView.image)
        beginDraggingSession(with: [dragging], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
}

/// The gallery's document view: takes the keyboard for card navigation.
final class GalleryDocumentView: NSView {
    weak var owner: TextToASCIIViewController?
    var cards: [GalleryCardView] = []
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    /// Stacks the cards top to bottom at the scroll view's width and sizes itself to fit.
    func layoutCards() {
        let width = superview?.bounds.width ?? bounds.width
        var y: CGFloat = 8
        for card in cards {
            let height = card.height(forWidth: width - 16)
            card.frame = NSRect(x: 8, y: y, width: width - 16, height: height)
            y += height + 8
        }
        setFrameSize(NSSize(width: width, height: max(y, superview?.bounds.height ?? 0)))
    }

    override func resize(withOldSuperviewSize oldSize: NSSize) {
        super.resize(withOldSuperviewSize: oldSize)
        layoutCards()
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 125, 124: owner?.moveSelection(by: 1)   // down, right
        case 126, 123: owner?.moveSelection(by: -1)  // up, left
        case 36, 76: owner?.copyText(nil)           // Return, Enter
        default: super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }
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

    private(set) var cards: [GalleryCardView] = []
    private var cardByID: [String: GalleryCardView] = [:]
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
        if let observer { NotificationCenter.default.removeObserver(observer) }
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

    /// Rebuilds the cards for the current query, then renders them.
    func rebuildCards() {
        let entries = arrangedEntries
        let existing = Dictionary(uniqueKeysWithValues: cards.map { ($0.entry.id, $0) })
        for card in cards { card.removeFromSuperview() }
        cards = entries.map { entry in
            if let card = existing[entry.id], card.entry == entry { return card }
            return GalleryCardView(entry: entry, owner: self)
        }
        cardByID = Dictionary(uniqueKeysWithValues: cards.map { ($0.entry.id, $0) })
        for card in cards {
            card.isFavourite = library.favourites.contains(card.entry.id)
            card.isSelected = card.entry.id == selectedID
            gallery.addSubview(card)
        }
        gallery.cards = cards
        gallery.layoutCards()
        emptyNote.isHidden = !library.userEntries.isEmpty
        countLabel.stringValue = "\(cards.count) of \(library.entries.count) fonts"
        if selectedID == nil || !cards.contains(where: { $0.entry.id == selectedID }) {
            selectedID = cards.first?.entry.id
            for card in cards { card.isSelected = card.entry.id == selectedID }
        }
        renderGallery()
        renderDetail()
    }

    /// Cards on screen now (rendered first).
    var visibleIDs: [String] {
        let visible = galleryScroll.documentVisibleRect.insetBy(dx: 0, dy: -200)
        return cards.filter { gallery.convert($0.bounds, from: $0).intersects(visible) }.map(\.entry.id)
    }

    /// Starts rendering every card (visible ones first); a newer call cancels this one.
    func renderGallery() {
        let text = self.text
        var galleryOptions = TextArtOptions()
        galleryOptions.foreground = options.foreground
        galleryOptions.background = options.background
        galleryOptions.outlineStyle = options.outlineStyle
        galleryOptions.gradient = options.gradient
        galleryOptions.iceColors = options.iceColors
        let entries = cards.map(\.entry)
        renderStart = CACurrentMediaTime()
        renderToken += 1
        let token = renderToken
        delivered = 0
        expected = entries.count
        firstCardSeconds = nil
        allCardsSeconds = nil
        renderer.start(text: text, entries: entries, options: galleryOptions, priority: visibleIDs) { [weak self] id, result in
            // Drawn here, off the main thread; only the hand-over happens on main.
            let image = TextArtImages.image(result.region)
            DispatchQueue.main.async {
                // A newer keystroke started another run while this card was on its way: drop it.
                guard let self, self.renderToken == token else { return }
                self.deliver(id: id, result: result, image: image)
            }
        }
    }

    private func deliver(id: String, result: TextArtResult, image: NSImage?) {
        guard let card = cardByID[id] else { return }
        card.show(result, image: image)
        sizes[id] = GallerySize(columns: result.region.width, rows: result.region.height)
        // Cards arriving together are laid out once.
        if !layoutPending {
            layoutPending = true
            DispatchQueue.main.async { [weak self] in
                self?.layoutPending = false
                self?.gallery.layoutCards()
            }
        }
        delivered += 1
        let elapsed = CACurrentMediaTime() - renderStart
        if firstCardSeconds == nil { firstCardSeconds = elapsed }
        if delivered == expected {
            allCardsSeconds = elapsed
            onGalleryComplete?()
        }
    }

    func stopRendering() { renderer.cancel() }

    @objc private func galleryScrolled(_ note: Notification) {}

    func textDidChange(_ notification: Notification) {
        library.sampleText = text
        renderGallery()
        renderDetail()
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
        for card in cards { card.isSelected = card.entry.id == id }
        if let card = cards.first(where: { $0.entry.id == id }) { gallery.scrollToVisible(gallery.convert(card.bounds, from: card)) }
        view.window?.makeFirstResponder(gallery)
        updateDetailControls()
        renderDetail()
    }

    func moveSelection(by step: Int) {
        guard !cards.isEmpty else { return }
        let index = cards.firstIndex { $0.entry.id == selectedID } ?? -step
        select(cards[min(cards.count - 1, max(0, index + step))].entry.id)
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
        insertButton.isEnabled = editorController != nil
        transparentBox.isEnabled = editorController != nil
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
    @objc func insert(_ sender: Any?) {
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
