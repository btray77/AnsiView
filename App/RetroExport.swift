import AnsiCore
import AppKit
import UniformTypeIdentifiers

/// Screen > Export for Retro Platform... (final gaps ruling 8): the focused screen as PETSCII
/// (.seq), ATASCII (.ata) or a Telstar Viewdata frame (.json), with what the platform could not
/// keep reported after saving and a caller preview through the platform's terminal.
enum RetroExportController {
    static func exportFocusedEditor() {
        guard let editor = ScreenDesigner.requireEditor("export") else { return }
        let project = editor.editor.project
        let canvas = project.frames[project.frames.count > 1 ? 0 : project.currentFrame].composite
        let name = editor.window?.title ?? "Screen"
        let chooser = RetroExportChooser(base: (name as NSString).deletingPathExtension)
        let panel = NSSavePanel()
        chooser.panel = panel
        panel.accessoryView = chooser.view
        panel.isExtensionHidden = false
        panel.allowsOtherFileTypes = false
        chooser.update()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let platform = chooser.platform
        let result = RetroScreenEncoder.encode(canvas, for: platform)
        do {
            let data = platform == .viewdata ? try TelstarFrame.json(result.bytes, page: chooser.page) : Data(result.bytes)
            try data.write(to: url, options: .atomic)
        } catch {
            NSAlert(error: error).runModal()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Saved \(url.lastPathComponent) for \(platform.label)"
        var lines = ["\(result.bytes.count) bytes."]
        lines += result.warnings.map { "\u{2022} " + $0.message }
        if result.warnings.isEmpty { lines.append("Every cell shows as designed.") }
        if platform.documentedPackages.isEmpty {
            lines.append("No BBS package documents ATASCII display files; upload the file where your board expects it.")
        }
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Preview as Caller")
        GlossaryAlertHelp.attach(.retroExport, to: alert)
        if alert.runModal() == .alertSecondButtonReturn {
            CallerPreviewWindowController.show(project: project, name: name, platform: platform)
        }
    }
}

/// The save panel's accessory: platform, Viewdata page number, and where each BBS reads the file.
final class RetroExportChooser: NSObject {
    let base: String
    weak var panel: NSSavePanel?
    let platformPopup = NSPopUpButton()
    let pageField = NSTextField(string: "101")
    let pageLabel = ScreenDesigner.label("Telstar page:")
    let whereLabel = ScreenDesigner.label("", size: 11, secondary: true)
    private(set) lazy var view: NSView = makeView()

    init(base: String) {
        self.base = base.isEmpty ? "main" : base
        super.init()
    }

    var platform: RetroPlatform {
        RetroPlatform.allCases[max(0, min(RetroPlatform.allCases.count - 1, platformPopup.indexOfSelectedItem))]
    }

    var page: Int { max(0, Int(pageField.stringValue.filter(\.isNumber)) ?? 101) }

    private func makeView() -> NSView {
        for p in RetroPlatform.allCases { platformPopup.addItem(withTitle: "\(p.label) (\(p.columns) x \(p.rows), .\(p.fileExtension))") }
        platformPopup.toolTip = String(localized: "The home computer or videotex service the screen is redrawn for")
        platformPopup.target = self
        platformPopup.action = #selector(update)
        pageField.toolTip = String(localized: "The Telstar page number the frame is stored as (frame a)")
        pageField.widthAnchor.constraint(equalToConstant: 60).isActive = true
        whereLabel.preferredMaxLayoutWidth = 520
        let top = ScreenDesigner.row([ScreenDesigner.label("Platform:"), platformPopup, pageLabel, pageField,
                                      Hint.button(.retroExport, detail: String(localized: "The file is written for the platform chosen here; Preview as Caller shows it through that platform's terminal."))])
        let stack = ScreenDesigner.column([top, whereLabel], spacing: 6)
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = true
        stack.frame = NSRect(x: 0, y: 0, width: 560, height: 80)
        return stack
    }

    @objc func update() {
        let p = platform
        let viewdata = p == .viewdata
        pageLabel.isHidden = !viewdata
        pageField.isHidden = !viewdata
        if let panel {
            panel.allowedContentTypes = [UTType(filenameExtension: p.fileExtension) ?? .data]
            panel.nameFieldStringValue = viewdata ? "\(base).json" : p.suggestedName(base: base)
        }
        whereLabel.stringValue = p.documentedPackages.isEmpty
            ? String(localized: "No BBS package documents ATASCII display files: AnsiView writes the screen as plain ATASCII bytes.")
            : p.documentedPackages.map { "\($0.name): \($0.how) (\($0.source))." }.joined(separator: "\n")
    }
}
