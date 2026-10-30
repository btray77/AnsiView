import AnsiCore
import AppKit

/// The 16colo.rs browser's preview pane: the selected file's art in AnsiView's own player
/// (animations play, blink blinks, tall art scrolls), or a picture (16colo.rs's thumbnail while
/// the art downloads, its full size picture for files AnsiView does not render), with the
/// SAUCE title, author and group under it and Open, Open in Editor and Save to... buttons.
@MainActor
final class SixteenColorsPreview: NSViewController {
    enum Content {
        case empty(String)
        case picture(NSImage, note: String)
        case art(ArtFile, name: String, url: URL)
    }

    static let emptyHint = "Select a file to preview it here."

    private(set) var player: AnsiPlayerViewController?
    var onOpen: (() -> Void)?
    var onEdit: (() -> Void)?
    var onSave: (() -> Void)?
    /// Told after art is put on screen (the browser gives the keyboard back to its list).
    var onShowArt: (() -> Void)?

    private let stage = NSView()
    private let message = NSTextField(wrappingLabelWithString: "")
    private let pictureScroll = NSScrollView()
    private let picture = PixelPictureView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let openButton = NSButton(title: "Open", target: nil, action: nil)
    private let editButton = NSButton(title: "Open in Editor", target: nil, action: nil)
    private let saveButton = NSButton(title: "Save to...", target: nil, action: nil)

    /// The SAUCE line and the file line, for checks and VoiceOver.
    var caption: String { titleLabel.stringValue + "\n" + detailLabel.stringValue }
    var showsPicture: Bool { !pictureScroll.isHidden }
    /// The hint over the black stage is light enough to read (for checks).
    var hintIsReadable: Bool { (message.textColor?.usingColorSpace(.sRGB)?.brightnessComponent ?? 0) > 0.5 }
    var note: String { message.isHidden ? detailLabel.stringValue : message.stringValue }

    override func loadView() {
        let container = NSView()
        stage.wantsLayer = true
        stage.layer?.backgroundColor = NSColor.black.cgColor
        stage.translatesAutoresizingMaskIntoConstraints = false
        stage.toolTip = "The selected file, drawn by AnsiView. Click animated art to skip to the end."

        message.alignment = .center
        // Light on the black stage in both appearances.
        message.textColor = NSColor(white: 0.72, alpha: 1)
        message.translatesAutoresizingMaskIntoConstraints = false
        stage.addSubview(message)

        pictureScroll.documentView = picture
        pictureScroll.hasVerticalScroller = true
        pictureScroll.autohidesScrollers = true
        pictureScroll.drawsBackground = true
        pictureScroll.backgroundColor = .black
        pictureScroll.frame = stage.bounds
        pictureScroll.autoresizingMask = [.width, .height]
        pictureScroll.isHidden = true
        stage.addSubview(pictureScroll)

        titleLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.toolTip = "Title, author and group from the file's SAUCE record."
        detailLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingMiddle
        for label in [titleLabel, detailLabel] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }

        openButton.target = self
        openButton.action = #selector(openPressed(_:))
        openButton.keyEquivalent = "\r"
        openButton.toolTip = "Open the file in its own window (Return, or double click it)."
        editButton.target = self
        editButton.action = #selector(editPressed(_:))
        editButton.toolTip = "Open a copy of the file in AnsiView's editor."
        saveButton.target = self
        saveButton.action = #selector(savePressed(_:))
        saveButton.toolTip = "Save the original file somewhere, such as your Downloads folder."
        let buttons = NSStackView(views: [openButton, editButton, NSView(), saveButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let info = NSStackView(views: [titleLabel, detailLabel, buttons])
        info.orientation = .vertical
        info.alignment = .leading
        info.spacing = 4
        info.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stage)
        container.addSubview(info)
        NSLayoutConstraint.activate([
            stage.topAnchor.constraint(equalTo: container.topAnchor),
            stage.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stage.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            info.topAnchor.constraint(equalTo: stage.bottomAnchor, constant: 8),
            info.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            info.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            info.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            buttons.widthAnchor.constraint(equalTo: info.widthAnchor),
            message.centerYAnchor.constraint(equalTo: stage.centerYAnchor),
            message.leadingAnchor.constraint(equalTo: stage.leadingAnchor, constant: 20),
            message.trailingAnchor.constraint(equalTo: stage.trailingAnchor, constant: -20),
            stage.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
            stage.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),
        ])
        view = container
        show(.empty(Self.emptyHint))
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        fitPicture()
    }

    /// Puts something new in the pane, replacing (and stopping) what was there.
    func show(_ content: Content) {
        loadViewIfNeeded()
        removePlayer()
        switch content {
        case .empty(let text):
            message.stringValue = text
            message.isHidden = false
            pictureScroll.isHidden = true
            picture.image = nil
            titleLabel.stringValue = ""
            detailLabel.stringValue = ""
            setButtons(open: false, save: false)
        case .picture(let image, let note):
            message.isHidden = true
            picture.image = image
            pictureScroll.isHidden = false
            fitPicture()
            pictureScroll.contentView.scroll(to: .zero)
            titleLabel.stringValue = ""
            detailLabel.stringValue = note
        case .art(let art, let name, let url):
            message.isHidden = true
            pictureScroll.isHidden = true
            picture.image = nil
            let player = AnsiPlayerViewController(source: art)
            player.fileURL = url
            player.artName = name
            player.handlesArrowKeys = false
            addChild(player)
            player.view.frame = stage.bounds
            player.view.autoresizingMask = [.width, .height]
            stage.addSubview(player.view, positioned: .below, relativeTo: message)
            self.player = player
            titleLabel.stringValue = Self.sauceLine(art)
            detailLabel.stringValue = Self.fileLine(art, name: name)
            setButtons(open: true, save: true)
            onShowArt?()
        }
    }

    /// Enables the buttons: Open and Open in Editor for art AnsiView renders, Save for any file.
    func setButtons(open: Bool, save: Bool) {
        openButton.isEnabled = open
        editButton.isEnabled = open
        saveButton.isEnabled = save
    }

    var canOpen: Bool { openButton.isEnabled }
    var canSave: Bool { saveButton.isEnabled }

    private func removePlayer() {
        guard let player else { return }
        player.halt()
        player.view.removeFromSuperview()
        player.removeFromParent()
        self.player = nil
    }

    /// The picture fills the pane's width (pixels kept sharp) and scrolls when it is taller.
    private func fitPicture() {
        guard let image = picture.image, image.size.width > 0 else { return }
        let width = pictureScroll.contentSize.width
        let scale = min(width / image.size.width, 4)
        let size = NSSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        picture.frame = NSRect(x: ((width - size.width) / 2).rounded(), y: 0, width: size.width,
                               height: max(size.height, pictureScroll.contentSize.height))
        picture.drawnHeight = size.height
        picture.needsDisplay = true
    }

    /// "Title" by Author (Group); "No SAUCE record" when the file has none.
    static func sauceLine(_ art: ArtFile) -> String {
        guard let sauce = art.sauce else { return ArtInfo.noSauce }
        let title = sauce.title.isEmpty ? "Untitled" : "\u{201C}\(sauce.title)\u{201D}"
        var line = title
        if !sauce.author.isEmpty { line += " by \(sauce.author)" }
        if !sauce.group.isEmpty { line += " (\(sauce.group))" }
        return line
    }

    static func fileLine(_ art: ArtFile, name: String) -> String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(art.byteCount), countStyle: .file)
        return "\(name)  \u{00B7}  \(art.format.displayName), \(art.columns) columns  \u{00B7}  \(size)"
    }

    @objc private func openPressed(_ sender: Any?) { onOpen?() }
    @objc private func editPressed(_ sender: Any?) { onEdit?() }
    @objc private func savePressed(_ sender: Any?) { onSave?() }
}

/// Draws a picture at the top of its frame without smoothing (block art stays crisp).
final class PixelPictureView: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }
    var drawnHeight: CGFloat = 0

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        dirtyRect.fill()
        guard let image else { return }
        NSGraphicsContext.current?.imageInterpolation = .none
        image.draw(in: NSRect(x: 0, y: 0, width: bounds.width, height: drawnHeight), from: .zero,
                   operation: .copy, fraction: 1, respectFlipped: true, hints: [.interpolation: NSNumber(value: NSImageInterpolation.none.rawValue)])
    }
}
