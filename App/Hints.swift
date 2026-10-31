import AnsiCore
import AppKit

/// The small (?) buttons that explain jargon in place (plan 9: hints everywhere; item 62: each one
/// is a glossary entry, so the same words appear here, in the glossary window and in Help search).
enum Hint {
    /// A round help button for `term`: its tooltip is the entry's one line hint; clicking shows the
    /// explanation in a popover with Open in Glossary. `detail` adds a sentence about this window.
    static func button(_ term: GlossaryTerm, detail: String? = nil) -> HintButton {
        HintButton(term: term, detail: detail)
    }
}

/// The (?) button of an alert opens a glossary entry (NSAlert.showsHelp; the term rides in helpAnchor).
final class GlossaryAlertHelp: NSObject, NSAlertDelegate {
    static let shared = GlossaryAlertHelp()

    static func attach(_ term: GlossaryTerm, to alert: NSAlert) {
        alert.showsHelp = true
        alert.helpAnchor = term.rawValue
        alert.delegate = shared
    }

    func alertShowHelp(_ alert: NSAlert) -> Bool {
        guard let id = alert.helpAnchor, let term = GlossaryTerm(rawValue: id) else { return false }
        GlossaryWindowController.show(term: term)
        return true
    }
}

final class HintButton: NSButton {
    let term: GlossaryTerm
    let detail: String?
    private var popover: NSPopover?

    /// The glossary id, for checks (the inventory harness reads it through key value coding).
    @objc var glossaryID: String { term.rawValue }

    init(term: GlossaryTerm, detail: String?) {
        self.term = term
        self.detail = detail
        super.init(frame: .zero)
        let entry = Glossary.entry(term)
        bezelStyle = .helpButton
        title = ""
        toolTip = entry.hint
        setAccessibilityLabel(String(localized: "Help: \(entry.title)"))
        target = self
        action = #selector(show(_:))
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The popover's text while it is shown (for checks).
    var shownText: String? { popover?.isShown == true ? Self.popoverText(term: term, detail: detail) : nil }

    /// What the popover says: the glossary explanation, then this window's detail (when given).
    static func popoverText(term: GlossaryTerm, detail: String?) -> String {
        let explanation = Glossary.entry(term).explanation
        guard let detail, !detail.isEmpty else { return explanation }
        return explanation + "\n\n" + detail
    }

    /// The popover's content: heading, text and an Open in Glossary button.
    func popoverView() -> NSView {
        let entry = Glossary.entry(term)
        let head = NSTextField(labelWithString: entry.title)
        head.font = .boldSystemFont(ofSize: 12)
        let label = NSTextField(wrappingLabelWithString: Self.popoverText(term: term, detail: detail))
        label.preferredMaxLayoutWidth = 320
        label.font = .systemFont(ofSize: 12)
        label.isSelectable = true
        let open = NSButton(title: String(localized: "Open in Glossary"), target: self, action: #selector(openGlossary(_:)))
        open.bezelStyle = .push
        open.controlSize = .small
        open.toolTip = String(localized: "Shows this entry in the AnsiView Glossary, with related terms")
        let stack = NSStackView(views: [head, label, open])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        return stack
    }

    @objc func show(_ sender: Any?) {
        if let popover, popover.isShown { popover.close(); return }
        let controller = NSViewController()
        controller.view = popoverView()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        popover.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
        self.popover = popover
    }

    @objc func openGlossary(_ sender: Any?) {
        popover?.close()
        GlossaryWindowController.show(term: term)
    }
}
