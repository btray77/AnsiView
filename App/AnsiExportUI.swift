import AnsiCore
import AppKit
import UniformTypeIdentifiers

// File menu export actions, sent through the responder chain to the focused art view.
extension AnsiCanvasView {
    @objc func exportImage(_ sender: Any?) {
        guard let player, let window else { return }
        ExportController.exportStill(from: player, in: window)
    }

    @objc func exportAnimation(_ sender: Any?) {
        guard let player, let window else { return }
        ExportController.exportAnimation(from: player, in: window)
    }
}

@MainActor
enum ExportController {
    private static let sizeLabels = ["1x (640 px wide)", "2x (1280 px wide)", "3x (1920 px wide)"]

    static func exportStill(from player: AnsiPlayerViewController, in window: NSWindow) {
        let panel = NSSavePanel()
        let format = popup(StillFormat.allCases.map(\.rawValue), selected: 0)
        let size = popup(sizeLabels, selected: 1)
        panel.accessoryView = accessory([("Format:", format), ("Size:", size)])
        panel.nameFieldStringValue = baseName(window) + ".png"
        panel.allowedContentTypes = [StillFormat.png.contentType]
        panel.isExtensionHidden = false
        retarget(panel, format) { StillFormat.allCases[$0].contentType }

        // The frame on screen: the finished art, or wherever a paused animation stopped.
        let screen = player.screen
        let rows = player.analysis.canvasRows
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            var padded = screen
            while padded.rows.count < rows {
                padded.rows.append(Array(repeating: AnsiCell(), count: padded.columns))
            }
            do {
                try AnsiExporter.exportStill(padded, format: StillFormat.allCases[format.indexOfSelectedItem],
                                             scale: size.indexOfSelectedItem + 1, to: url)
            } catch {
                NSAlert(error: error).beginSheetModal(for: window)
            }
        }
    }

    static func exportAnimation(from player: AnsiPlayerViewController, in window: NSWindow) {
        let panel = NSSavePanel()
        let format = popup(AnimationFormat.allCases.map(\.rawValue), selected: 0)
        let size = popup(sizeLabels, selected: 0)
        let speeds = PlaybackSpeed.choices.filter { $0 > 0 }
        let speed = popup(speeds.map(PlaybackSpeed.label),
                          selected: speeds.firstIndex(of: player.speed.baud) ?? speeds.firstIndex(of: PlaybackSpeed.defaultBaud)!)
        panel.accessoryView = accessory([("Format:", format), ("Size:", size), ("Speed:", speed)])
        panel.nameFieldStringValue = baseName(window) + ".gif"
        panel.allowedContentTypes = [AnimationFormat.gif.contentType]
        panel.isExtensionHidden = false
        retarget(panel, format) { AnimationFormat.allCases[$0].contentType }

        let source = player.source
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            let chosenFormat = AnimationFormat.allCases[format.indexOfSelectedItem]
            let scale = size.indexOfSelectedItem + 1
            let baud = speeds[speed.indexOfSelectedItem]
            DispatchQueue.main.async {
                runWithProgress(in: window, title: "Exporting \(chosenFormat.rawValue)") { report in
                    let frames = AnsiFrameSequence.make(source, baud: baud)
                    try AnsiExporter.exportAnimation(frames, format: chosenFormat, scale: scale, to: url,
                                                     progress: report)
                }
            }
        }
    }

    // MARK: Helpers

    private static func baseName(_ window: NSWindow) -> String {
        let title = window.representedURL?.deletingPathExtension().lastPathComponent ?? window.title
        return title.isEmpty ? "ANSI Art" : title
    }

    private static func popup(_ titles: [String], selected: Int) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.addItems(withTitles: titles)
        button.selectItem(at: selected)
        return button
    }

    private static func accessory(_ rows: [(String, NSPopUpButton)]) -> NSView {
        let grid = NSGridView(views: rows.map { [NSTextField(labelWithString: $0.0), $0.1] })
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 8
        let container = NSView()
        grid.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            grid.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
            grid.centerXAnchor.constraint(equalTo: container.centerXAnchor),
        ])
        container.frame.size = NSSize(width: 360, height: grid.fittingSize.height + 24)
        return container
    }

    /// Keeps the save panel's file extension in step with the chosen format.
    private static func retarget(_ panel: NSSavePanel, _ popup: NSPopUpButton, type: @escaping (Int) -> UTType) {
        let target = PopupTarget { index in
            let newType = type(index)
            panel.allowedContentTypes = [newType]
            if let ext = newType.preferredFilenameExtension {
                let name = (panel.nameFieldStringValue as NSString).deletingPathExtension
                panel.nameFieldStringValue = name + "." + ext
            }
        }
        popup.target = target
        popup.action = #selector(PopupTarget.changed(_:))
        objc_setAssociatedObject(popup, &PopupTarget.key, target, .OBJC_ASSOCIATION_RETAIN)
    }

    /// Runs `work` off the main thread behind a sheet with a progress bar.
    private static func runWithProgress(
        in window: NSWindow, title: String, work: @escaping (_ report: @escaping (Double) -> Void) throws -> Void
    ) {
        let sheet = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 90), styleMask: [.titled],
                            backing: .buffered, defer: false)
        let label = NSTextField(labelWithString: title + "...")
        let bar = NSProgressIndicator()
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        let stack = NSStackView(views: [label, bar])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        bar.widthAnchor.constraint(equalToConstant: 280).isActive = true
        sheet.contentView = stack
        window.beginSheet(sheet)

        DispatchQueue.global(qos: .userInitiated).async {
            var failure: Error?
            do {
                try work { fraction in
                    DispatchQueue.main.async { bar.doubleValue = fraction }
                }
            } catch {
                failure = error
            }
            DispatchQueue.main.async {
                window.endSheet(sheet)
                if let failure { NSAlert(error: failure).beginSheetModal(for: window) }
            }
        }
    }
}

private final class PopupTarget: NSObject {
    static var key = 0
    let onChange: (Int) -> Void

    init(_ onChange: @escaping (Int) -> Void) {
        self.onChange = onChange
    }

    @objc func changed(_ sender: NSPopUpButton) {
        onChange(sender.indexOfSelectedItem)
    }
}
