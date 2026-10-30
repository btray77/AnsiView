import AnsiCore
import AppKit

// The Text to ASCII gallery's views (fonts plan ruling 20, review I3). A collection can hold
// thousands of fonts, so only the cards near the visible part of the gallery exist as views; they
// are recycled as the gallery scrolls, and their art is kept at display size.

/// What one card shows: the rendered art, its picture (scaled to display size) and the text and
/// options it was drawn for.
struct GalleryCardState {
    var result: TextArtResult
    var image: NSImage?
    var key: String
}

/// One font in the gallery: name, kind, favourite star, the rendered sample, missing characters.
/// Laid out with frames, not constraints, and reused for other fonts while scrolling.
final class GalleryCardView: NSView, NSDraggingSource {
    static let headerHeight: CGFloat = 24
    static let padding: CGFloat = 8
    static let maxImageHeight: CGFloat = 240
    static let placeholderHeight: CGFloat = 64

    private(set) var entry: FontEntry?
    weak var owner: TextToASCIIViewController?
    let star = NSButton(title: "", target: nil, action: nil)
    let nameLabel = NSTextField(labelWithString: "")
    let kindLabel = NSTextField(labelWithString: "")
    let imageView = NSImageView()
    let missingLabel = NSTextField(labelWithString: "")
    private(set) var result: TextArtResult?
    private var dragStart: NSPoint?

    var isSelected = false { didSet { updateLook() } }
    var isFavourite = false { didSet { star.title = isFavourite ? "★" : "☆" } }

    init(owner: TextToASCIIViewController) {
        self.owner = owner
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

    /// Shows `entry` with its art (nil while it is being drawn).
    func configure(entry: FontEntry, state: GalleryCardState?, favourite: Bool, selected: Bool) {
        if self.entry?.id != entry.id {
            self.entry = entry
            nameLabel.stringValue = entry.name
            kindLabel.stringValue = "\(entry.kindLabel)  \u{00B7}  \(entry.fileName)"
        }
        result = state?.result
        imageView.image = state?.image
        missingLabel.stringValue = (state?.result.missing.isEmpty ?? true) ? "" : "missing: " + String(state!.result.missing.prefix(12))
        isFavourite = favourite
        isSelected = selected
        needsLayout = true
    }

    /// The card's height for an image of `size` (nil: not drawn yet) at `width`.
    static func height(imageSize size: NSSize?, width: CGFloat) -> CGFloat {
        guard let size, size.width > 0, size.height > 0 else { return headerHeight + placeholderHeight + padding + 4 }
        return headerHeight + displaySize(size, width: width).height + padding + 4
    }

    static func displaySize(_ size: NSSize, width: CGFloat) -> NSSize {
        let available = max(16, width - 2 * padding)
        let scale = min(1, available / size.width, maxImageHeight / size.height)
        return NSSize(width: floor(size.width * scale), height: floor(size.height * scale))
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
        let size = imageView.image.map { Self.displaySize($0.size, width: w) } ?? NSSize(width: 0, height: 0)
        imageView.frame = NSRect(x: p, y: Self.headerHeight, width: size.width, height: size.height)
    }

    /// What dragging the card out drops: its art as plain text.
    var dragText: String? { result.map { TextArtOutput.plainText($0.region) } }

    private func updateLook() {
        layer?.borderColor = (isSelected ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
        layer?.borderWidth = isSelected ? 2 : 1
        layer?.backgroundColor = (isSelected ? NSColor.controlAccentColor.withAlphaComponent(0.12) : NSColor.controlBackgroundColor).cgColor
    }

    @objc private func toggleStar(_ sender: Any?) {
        if let id = entry?.id { owner?.toggleFavourite(id) }
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = convert(event.locationInWindow, from: nil)
        guard let id = entry?.id else { return }
        owner?.select(id)
        if event.clickCount == 2 { owner?.copyText(nil) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, let text = dragText else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - start.x, point.y - start.y) > 4 else { return }
        dragStart = nil
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        let dragging = NSDraggingItem(pasteboardWriter: item)
        dragging.setDraggingFrame(imageView.frame, contents: imageView.image)
        beginDraggingSession(with: [dragging], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
}

/// The gallery's document view: positions every font's card slot, keeps views only for the
/// slots near the visible area, and takes the keyboard for card navigation.
final class GalleryDocumentView: NSView {
    weak var owner: TextToASCIIViewController?
    private(set) var entries: [FontEntry] = []
    private var tops: [CGFloat] = []
    private var heights: [CGFloat] = []
    private(set) var live: [String: GalleryCardView] = [:]
    private var pool: [GalleryCardView] = []
    /// The image size of each font's art, when it has been drawn (for its card height).
    var imageSize: (String) -> NSSize? = { _ in nil }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    var cardWidth: CGFloat { max(100, (superview?.bounds.width ?? bounds.width) - 16) }

    func setEntries(_ list: [FontEntry]) {
        entries = list
        relayout()
    }

    /// Recomputes every slot (cheap: arithmetic only), then the live views. Cards above change
    /// height as their art arrives, so the selected card (or else the top visible one) is kept
    /// where it was on screen.
    func relayout() {
        let visible = visibleRect
        var anchor: (id: String, offset: CGFloat)?
        if !visible.isEmpty, !entries.isEmpty, tops.count == entries.count {
            let shown = indexes(in: visible)
            let selected = owner?.selectedID
            let index = shown.first { entries[$0].id == selected } ?? (shown.isEmpty ? nil : shown.lowerBound)
            if let index { anchor = (entries[index].id, tops[index] - visible.minY) }
        }
        layoutSlots()
        if let anchor, let index = entries.firstIndex(where: { $0.id == anchor.id }) {
            let target = NSPoint(x: visible.minX, y: max(0, min(tops[index] - anchor.offset, bounds.height - visible.height)))
            if abs(target.y - visible.minY) > 0.5 {
                scroll(target)
            }
        }
        tile()
    }

    private func layoutSlots() {
        let width = cardWidth
        var y: CGFloat = 8
        tops = []
        heights = []
        tops.reserveCapacity(entries.count)
        heights.reserveCapacity(entries.count)
        for entry in entries {
            let height = GalleryCardView.height(imageSize: imageSize(entry.id), width: width)
            tops.append(y)
            heights.append(height)
            y += height + 8
        }
        setFrameSize(NSSize(width: width + 16, height: max(y, superview?.bounds.height ?? 0)))
    }

    func frame(ofIndex index: Int) -> NSRect {
        NSRect(x: 8, y: tops[index], width: cardWidth, height: heights[index])
    }

    func frame(of id: String) -> NSRect? {
        entries.firstIndex { $0.id == id }.map { frame(ofIndex: $0) }
    }

    /// Indexes of the slots that meet `rect` (binary search over the slot tops).
    func indexes(in rect: NSRect) -> Range<Int> {
        guard !entries.isEmpty else { return 0..<0 }
        var low = 0, high = entries.count
        while low < high {
            let mid = (low + high) / 2
            if tops[mid] + heights[mid] < rect.minY { low = mid + 1 } else { high = mid }
        }
        var end = low
        while end < entries.count, tops[end] <= rect.maxY { end += 1 }
        return low..<end
    }

    /// The area whose cards exist as views: the visible part plus a screen above and below.
    var liveRect: NSRect {
        let visible = visibleRect.isEmpty ? NSRect(x: 0, y: 0, width: bounds.width, height: 800) : visibleRect
        return visible.insetBy(dx: 0, dy: -visible.height)
    }

    /// Makes views for the slots near the visible area and recycles the rest.
    func tile() {
        let range = indexes(in: liveRect)
        var keep: [String: GalleryCardView] = [:]
        for index in range {
            let entry = entries[index]
            let card = live[entry.id] ?? pool.popLast() ?? GalleryCardView(owner: owner!)
            if card.superview !== self { addSubview(card) }
            owner?.configure(card, entry: entry)
            card.frame = frame(ofIndex: index)
            keep[entry.id] = card
        }
        for (id, card) in live where keep[id] == nil {
            card.removeFromSuperview()
            pool.append(card)
        }
        live = keep
    }

    override func resize(withOldSuperviewSize oldSize: NSSize) {
        super.resize(withOldSuperviewSize: oldSize)
        relayout()
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

extension TextArtImages {
    /// The art drawn with AnsiView's renderer and scaled down to at most `maxSize` pixels
    /// (cards never show more), so a gallery of wide art does not hold full size pictures.
    static func thumbnail(_ region: CanvasRegion, maxSize: NSSize = NSSize(width: 1200, height: 240)) -> NSImage? {
        guard let full = image(region), let cg = full.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let scale = min(1, maxSize.width / CGFloat(cg.width), maxSize.height / CGFloat(cg.height))
        guard scale < 1 else { return full }
        let width = max(1, Int(CGFloat(cg.width) * scale)), height = max(1, Int(CGFloat(cg.height) * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return full }
        context.interpolationQuality = .medium
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let small = context.makeImage() else { return full }
        // The point size stays the full art's size: the card scales it the same way.
        return NSImage(cgImage: small, size: full.size)
    }
}
