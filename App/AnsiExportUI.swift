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

    @objc func exportText(_ sender: Any?) {
        guard let player, let window else { return }
        ExportController.exportText(from: player, in: window)
    }
}

/// The popups behind an export: format, size, speed, frame rate, GIF palette and size limit.
/// Rows that do not apply to the chosen format are disabled.
@MainActor
final class ExportOptionsView {
    static let sizeLabels = ["1x (640 px wide)", "2x (1280 px wide)", "3x (1920 px wide)"]
    static let frameRates: [Double] = [5, 10, 15, 20, 30]
    static let limits: [(String, SizeLimit)] = [
        ("None", .none), ("1 MB", .maxBytes(1_000_000)), ("2 MB", .maxBytes(2_000_000)),
        ("5 MB", .maxBytes(5_000_000)), ("10 MB", .maxBytes(10_000_000)),
        ("Fit 800 x 600", .maxPixels(width: 800, height: 600)),
        ("Fit 1280 x 720", .maxPixels(width: 1280, height: 720)),
        ("Fit 1920 x 1080", .maxPixels(width: 1920, height: 1080)),
    ]
    static let speeds = PlaybackSpeed.choices.filter { $0 > 0 }

    let kinds: [ExportKind]
    let format: NSPopUpButton
    let size: NSPopUpButton
    let speed: NSPopUpButton
    let frameRate: NSPopUpButton
    let palette: NSPopUpButton
    let limit: NSPopUpButton
    /// Called after the format changes (after the rows are enabled or disabled).
    var onFormatChange: ((ExportKind) -> Void)?
    private var target: PopupTarget?

    init(kinds: [ExportKind], selected: ExportKind? = nil, scale: Int = 2, baud: Int = PlaybackSpeed.defaultBaud) {
        self.kinds = kinds
        format = Self.popup(kinds.map(\.label), selected: selected.flatMap { kinds.firstIndex(of: $0) } ?? 0)
        size = Self.popup(Self.sizeLabels, selected: max(0, min(2, scale - 1)))
        speed = Self.popup(Self.speeds.map(PlaybackSpeed.label),
                           selected: Self.speeds.firstIndex(of: baud) ?? Self.speeds.firstIndex(of: PlaybackSpeed.defaultBaud)!)
        frameRate = Self.popup(Self.frameRates.map { "\(Int($0)) fps" }, selected: 2)
        palette = Self.popup(GIFPalette.allCases.map(\.label), selected: 0)
        limit = Self.popup(Self.limits.map(\.0), selected: 0)
        let target = PopupTarget { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.updateEnabled()
                self.onFormatChange?(self.kind)
            }
        }
        format.target = target
        format.action = #selector(PopupTarget.changed(_:))
        self.target = target
        updateEnabled()
    }

    var kind: ExportKind { kinds[max(0, format.indexOfSelectedItem)] }

    var settings: ExportSettings {
        var settings = ExportSettings()
        settings.kind = kind
        settings.scale = size.indexOfSelectedItem + 1
        settings.baud = Self.speeds[speed.indexOfSelectedItem]
        settings.fps = Self.frameRates[frameRate.indexOfSelectedItem]
        settings.palette = GIFPalette.allCases[palette.indexOfSelectedItem]
        settings.limit = limit.isEnabled ? Self.limits[limit.indexOfSelectedItem].1 : .none
        return settings
    }

    func updateEnabled() {
        let kind = self.kind
        size.isEnabled = !kind.isText
        speed.isEnabled = kind.isAnimation
        frameRate.isEnabled = kind.isAnimation
        palette.isEnabled = kind == .animation(.gif)
        limit.isEnabled = !kind.isText
    }

    /// The rows to show, as label and popup.
    func rows(format showFormat: Bool = true, animation: Bool = true) -> [(String, NSPopUpButton)] {
        var rows: [(String, NSPopUpButton)] = []
        if showFormat { rows.append(("Format:", format)) }
        rows.append(("Size:", size))
        if animation {
            rows += [("Speed:", speed), ("Frame Rate:", frameRate), ("GIF Palette:", palette)]
        }
        rows.append(("Size Limit:", limit))
        return rows
    }

    static func popup(_ titles: [String], selected: Int) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.addItems(withTitles: titles)
        button.selectItem(at: selected)
        return button
    }

    /// A panel accessory view: a grid of labelled popups.
    static func accessory(_ rows: [(String, NSPopUpButton)]) -> NSView {
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
        container.frame.size = NSSize(width: 380, height: grid.fittingSize.height + 24)
        return container
    }
}

@MainActor
enum ExportController {
    static func exportStill(from player: AnsiPlayerViewController, in window: NSWindow) {
        let options = ExportOptionsView(kinds: StillFormat.allCases.map(ExportKind.still), scale: 2)
        // The frame on screen: the finished art, or wherever a paused animation stopped.
        save(options, rows: options.rows(animation: false), source: player.source, screen: player.screen,
             in: window, title: "Exporting Image")
    }

    static func exportAnimation(from player: AnsiPlayerViewController, in window: NSWindow) {
        let options = ExportOptionsView(kinds: AnimationFormat.allCases.map(ExportKind.animation), scale: 1,
                                        baud: player.speed.baud)
        save(options, rows: options.rows(), source: player.source, screen: nil, in: window,
             title: "Exporting Animation")
    }

    /// File > Export Text: the frame on screen as HTML, terminal ANSI or plain text.
    static func exportText(from player: AnsiPlayerViewController, in window: NSWindow) {
        let options = ExportOptionsView(kinds: TextFormat.allCases.map(ExportKind.text))
        save(options, rows: [("Format:", options.format)], source: player.source, screen: player.screen,
             in: window, title: "Exporting Text")
    }

    /// Asks for a file name with the options as the accessory view, then exports behind a
    /// progress sheet.
    private static func save(_ options: ExportOptionsView, rows: [(String, NSPopUpButton)], source: ArtFile,
                             screen: AnsiScreen?, in window: NSWindow, title: String) {
        let panel = NSSavePanel()
        panel.accessoryView = ExportOptionsView.accessory(rows)
        panel.nameFieldStringValue = baseName(window) + "." + options.kind.fileExtension
        panel.allowedContentTypes = [contentType(options.kind)]
        panel.isExtensionHidden = false
        options.onFormatChange = { kind in
            panel.allowedContentTypes = [contentType(kind)]
            let name = (panel.nameFieldStringValue as NSString).deletingPathExtension
            panel.nameFieldStringValue = name + "." + kind.fileExtension
        }
        panel.beginSheetModal(for: window) { response in
            withExtendedLifetime(options) {}
            guard response == .OK, let url = panel.url else { return }
            let settings = options.settings
            DispatchQueue.main.async {
                runWithProgress(in: window, title: title) { report, isCancelled in
                    try AnsiExporter.export(source, screen: screen, settings: settings, to: url,
                                            progress: report, isCancelled: isCancelled)
                }
            }
        }
    }

    static func contentType(_ kind: ExportKind) -> UTType {
        switch kind {
        case .still(let format): return format.contentType
        case .animation(let format): return format.contentType
        case .text(.html): return .html
        case .text(.ansi), .text(.ansi256): return UTType(filenameExtension: "ans") ?? .plainText
        case .text: return .plainText
        }
    }

    // MARK: Helpers

    private static func baseName(_ window: NSWindow) -> String {
        let title = window.representedURL?.deletingPathExtension().lastPathComponent ?? window.title
        return title.isEmpty ? "ANSI Art" : title
    }

    /// A sheet with a label, a progress bar and a Cancel button.
    @MainActor
    final class ProgressSheet {
        let panel: NSPanel
        let label: NSTextField
        let bar = NSProgressIndicator()
        let cancelButton: NSButton
        /// Read from the export thread.
        let flag = CancelFlag()
        private var buttonTarget: ButtonTarget?

        init(title: String) {
            panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 120), styleMask: [.titled],
                            backing: .buffered, defer: false)
            label = NSTextField(labelWithString: title + "...")
            label.lineBreakMode = .byTruncatingMiddle
            bar.isIndeterminate = false
            bar.minValue = 0
            bar.maxValue = 1
            cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
            cancelButton.keyEquivalent = "\u{1B}"
            let target = ButtonTarget { [weak self] in self?.cancel() }
            cancelButton.target = target
            cancelButton.action = #selector(ButtonTarget.pressed)
            buttonTarget = target
            let stack = NSStackView(views: [label, bar, cancelButton])
            stack.orientation = .vertical
            stack.alignment = .trailing
            stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 16, right: 20)
            bar.widthAnchor.constraint(equalToConstant: 320).isActive = true
            label.widthAnchor.constraint(equalToConstant: 320).isActive = true
            let container = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 120))
            stack.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                stack.topAnchor.constraint(equalTo: container.topAnchor),
                stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
            panel.contentView = container
        }

        func cancel() {
            flag.cancel()
            cancelButton.isEnabled = false
            label.stringValue = "Cancelling..."
        }
    }

    /// Runs `work` off the main thread behind a progress sheet with Cancel. Errors (other than a
    /// cancel) and a byte limit that could not be met are shown as alerts.
    static func runWithProgress(
        in window: NSWindow, title: String,
        work: @escaping (_ report: @escaping (Double) -> Void, _ isCancelled: @escaping () -> Bool) throws -> ExportOutcome,
        onSuccess: @escaping (ExportOutcome) -> Void = { _ in }
    ) {
        let sheet = ProgressSheet(title: title)
        let flag = sheet.flag
        window.beginSheet(sheet.panel)
        DispatchQueue.global(qos: .userInitiated).async {
            var failure: Error?
            var outcome: ExportOutcome?
            do {
                outcome = try work({ fraction in
                    DispatchQueue.main.async { MainActor.assumeIsolated { sheet.bar.doubleValue = fraction } }
                }, { flag.isCancelled })
            } catch {
                failure = error
            }
            DispatchQueue.main.async { MainActor.assumeIsolated {
                window.endSheet(sheet.panel)
                if let failure {
                    if case AnsiExportError.cancelled = failure { return }
                    NSAlert(error: failure).beginSheetModal(for: window)
                } else if let outcome, !outcome.overLimit {
                    onSuccess(outcome)
                } else if let outcome {
                    let alert = NSAlert()
                    alert.messageText = "The file is larger than the size limit."
                    alert.informativeText = "Even the smallest version is \(ByteCountFormatter.string(fromByteCount: Int64(outcome.bytes), countStyle: .file)). It was saved anyway."
                    alert.beginSheetModal(for: window)
                }
            } }
        }
    }
}

final class PopupTarget: NSObject {
    let onChange: (Int) -> Void

    init(_ onChange: @escaping (Int) -> Void) {
        self.onChange = onChange
    }

    @objc func changed(_ sender: NSPopUpButton) {
        onChange(sender.indexOfSelectedItem)
    }
}

/// A cancel request shared between the main thread and an export thread.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

final class ButtonTarget: NSObject {
    let action: () -> Void

    init(_ action: @escaping () -> Void) {
        self.action = action
    }

    @objc func pressed() { action() }
}
