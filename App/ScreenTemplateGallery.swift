import AnsiCore
import AppKit

/// File > New from Template...: the template gallery (screen designer task 10). Each card shows
/// the template drawn for the chosen BBS name, package and width; Create opens it in the editor,
/// fully editable (animated templates open with their frames).
final class ScreenTemplateGalleryWindowController: NSWindowController, NSWindowDelegate {
    private(set) static var current: ScreenTemplateGalleryWindowController?
    let viewController = ScreenTemplateGalleryViewController()

    static func show() {
        let controller = current ?? ScreenTemplateGalleryWindowController()
        current = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1060, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "New from Template"
        window.contentMinSize = NSSize(width: 760, height: 480)
        super.init(window: window)
        window.contentViewController = viewController
        window.setContentSize(NSSize(width: 1060, height: 720))
        window.center()
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func windowWillClose(_ notification: Notification) { Self.current = nil }
}

final class ScreenTemplateGalleryViewController: NSViewController {
    let nameField = NSTextField(string: "My BBS")
    lazy var packagePopup = ScreenDesigner.packagePopup(selected: ScreenDesignerSettings.shared.package,
                                                        tooltip: "The BBS package whose display codes go into the template")
    let widthPopup = NSPopUpButton()
    let fontPopup = NSPopUpButton()
    let grid = NSStackView()
    private(set) var selectedID = ScreenTemplates.all[0].id
    private var cards: [String: NSButton] = [:]
    let detail = NSTextField(wrappingLabelWithString: "")

    var options: TemplateOptions {
        var o = TemplateOptions(columns: widthPopup.indexOfSelectedItem == 1 ? 132 : 80,
                                bbsName: nameField.stringValue.isEmpty ? "My BBS" : nameField.stringValue,
                                package: ScreenDesigner.package(of: packagePopup), samples: ScreenDesignerSettings.shared.samples)
        o.logoFont = fontPopup.indexOfSelectedItem < OriginalFonts.tdfFonts.count
            ? .tdf(OriginalFonts.tdfFonts[[2, 1, 0][min(2, fontPopup.indexOfSelectedItem)]]) : OriginalFonts.figletFont.map { .figlet($0) }
        return o
    }

    override func loadView() {
        nameField.placeholderString = "BBS name for the logo"
        nameField.toolTip = "Drawn as the logo with the chosen font. Elsewhere the template uses your BBS's own code for its name."
        nameField.target = self
        nameField.action = #selector(refresh)
        nameField.widthAnchor.constraint(equalToConstant: 180).isActive = true
        packagePopup.target = self
        packagePopup.action = #selector(refresh)
        widthPopup.addItems(withTitles: ["80 columns", "132 columns"])
        widthPopup.toolTip = "80 columns for most callers; 132 for wide terminals (templates that only make sense at 80 stay 80)"
        widthPopup.target = self
        widthPopup.action = #selector(refresh)
        fontPopup.addItems(withTitles: ["AV Ember (colour)", "AV Block", "AV Outline", "AV Contour (FIGlet)"])
        fontPopup.toolTip = "The logo font: AnsiView's own original fonts. Use Text to ASCII afterwards for any installed TheDraw or FIGlet font."
        fontPopup.target = self
        fontPopup.action = #selector(refresh)
        let help = TextArtImages.helpButton(
            "Templates are original designs drawn by AnsiView. Each one uses the chosen BBS's display codes for the caller's name, time left, node and so on (where that BBS has such a code; otherwise the sample text stands in). Menus leave the last column and row free so they never scroll or wrap on an 80 x 24 caller. Everything is ordinary editable art once created.",
            tooltip: "About templates")
        let top = ScreenDesigner.row([ScreenDesigner.label("BBS name:"), nameField, ScreenDesigner.label("Codes for:"), packagePopup,
                                      widthPopup, ScreenDesigner.label("Logo font:"), fontPopup, NSView(), help])
        grid.orientation = .vertical
        grid.alignment = .leading
        grid.spacing = 14
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        grid.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(grid)
        scroll.documentView = document
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 4),
            grid.topAnchor.constraint(equalTo: document.topAnchor, constant: 4),
            document.bottomAnchor.constraint(equalTo: grid.bottomAnchor, constant: 4),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        detail.textColor = .secondaryLabelColor
        let create = NSButton(title: "Create", target: self, action: #selector(create(_:)))
        create.keyEquivalent = "\r"
        create.toolTip = "Opens the selected template in a new editor window"
        let bottom = ScreenDesigner.row([detail, NSView(), create])
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 360).isActive = true
        let stack = ScreenDesigner.column([top, scroll, bottom], spacing: 12)
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        for view in [top, scroll, bottom] { view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true }
        view = ScreenDesigner.container(stack)
        refresh()
    }

    @objc func refresh() {
        for view in grid.arrangedSubviews { grid.removeArrangedSubview(view); view.removeFromSuperview() }
        cards = [:]
        let o = options
        var row: [NSView] = []
        for template in ScreenTemplates.all {
            let project = template.make(o)
            let canvas = project.frames.last!.composite
            let image = ScreenDesigner.image(canvas)
            let button = NSButton(title: "", target: self, action: #selector(choose(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(template.id)
            button.image = image.map { scaled($0, width: 300) }
            button.imagePosition = .imageOnly
            button.isBordered = false
            button.wantsLayer = true
            button.layer?.borderWidth = template.id == selectedID ? 3 : 0
            button.layer?.borderColor = NSColor.controlAccentColor.cgColor
            button.toolTip = template.summary
            let title = ScreenDesigner.label(template.title + (template.animated ? "  (\(project.frames.count) frames)" : ""), size: 12)
            title.font = NSFont.boldSystemFont(ofSize: 12)
            let card = ScreenDesigner.column([button, title], spacing: 4)
            cards[template.id] = button
            row.append(card)
            if row.count == 3 { grid.addArrangedSubview(ScreenDesigner.row(row, spacing: 18)); row = [] }
        }
        if !row.isEmpty { grid.addArrangedSubview(ScreenDesigner.row(row, spacing: 18)) }
        updateDetail()
    }

    private func scaled(_ image: NSImage, width: CGFloat) -> NSImage {
        let height = image.size.height * width / max(1, image.size.width)
        let result = NSImage(size: NSSize(width: width, height: height))
        result.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        result.unlockFocus()
        return result
    }

    private func updateDetail() {
        guard let template = ScreenTemplates.template(selectedID) else { return }
        let o = options
        detail.stringValue = "\(template.title): \(template.summary) \(o.columns) x \(o.rows), codes for \(o.package.displayName)."
    }

    @objc func choose(_ sender: NSButton) {
        selectedID = sender.identifier?.rawValue ?? selectedID
        for (id, card) in cards { card.layer?.borderWidth = id == selectedID ? 3 : 0 }
        updateDetail()
        if NSApp.currentEvent?.clickCount == 2 { create(sender) }
    }

    @objc func create(_ sender: Any?) {
        guard let template = ScreenTemplates.template(selectedID) else { return }
        let o = options
        ScreenDesignerSettings.shared.package = o.package
        let project = template.make(o)
        let controller = EditorWindowController.open(editor: CanvasEditor(project: project), name: "\(template.title) (\(o.package.displayName))")
        controller.screenSlot = template.slot
        view.window?.close()
    }
}
