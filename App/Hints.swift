import AppKit

/// The small (?) buttons that explain jargon in place (plan 9: hints everywhere).
enum Hint {
    /// A round help button that shows `text` in a popover; its tooltip says the same.
    static func button(_ text: String, title: String? = nil) -> NSButton {
        let button = HintButton(text: text, title: title)
        return button
    }
}

final class HintButton: NSButton {
    let text: String
    let heading: String?
    private var popover: NSPopover?

    init(text: String, title: String?) {
        self.text = text
        self.heading = title
        super.init(frame: .zero)
        bezelStyle = .helpButton
        self.title = ""
        toolTip = text
        setAccessibilityLabel("Help: " + (title ?? "explain"))
        target = self
        action = #selector(show(_:))
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The popover's text (for checks).
    var shownText: String? { popover?.isShown == true ? text : nil }

    @objc func show(_ sender: Any?) {
        if let popover, popover.isShown { popover.close(); return }
        let label = NSTextField(wrappingLabelWithString: text)
        label.preferredMaxLayoutWidth = 300
        label.font = .systemFont(ofSize: 12)
        var views: [NSView] = [label]
        if let heading {
            let head = NSTextField(labelWithString: heading)
            head.font = .boldSystemFont(ofSize: 12)
            views.insert(head, at: 0)
        }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        let controller = NSViewController()
        controller.view = stack
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        popover.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
        self.popover = popover
    }
}
