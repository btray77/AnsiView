import AnsiCore
import AppKit
import UniformTypeIdentifiers

extension Notification.Name {
    /// The installed fonts, favourites or recent list changed.
    static let fontLibraryChanged = Notification.Name("AnsiViewFontLibraryChanged")
    /// The sample text was changed in one window (the others show it).
    static let fontSampleChanged = Notification.Name("AnsiViewFontSampleChanged")
}

/// The app's one font library (fonts plan ruling 15), used on the main thread.
enum FontStore {
    /// ANSIVIEW_FONT_DIR points tests and harnesses at a scratch folder instead of the user's.
    static let library = FontLibrary(directory: ProcessInfo.processInfo.environment["ANSIVIEW_FONT_DIR"]
        .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FontLibrary.defaultDirectory)

    static func changed() { NotificationCenter.default.post(name: .fontLibraryChanged, object: nil) }

    /// Asks for font files, folders or .zip packs and imports them; reports the result.
    static func chooseAndImport(from window: NSWindow?) {
        let panel = NSOpenPanel()
        panel.title = "Import Fonts"
        panel.message = "Choose TheDraw (.tdf) or FIGlet (.flf) fonts, folders of them, or .zip font packs."
        panel.prompt = "Import"
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK else { return }
            importFonts(panel.urls, window: window)
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: finish) } else { finish(panel.runModal()) }
    }

    static func importFonts(_ urls: [URL], window: NSWindow?) {
        let report = library.importFonts(from: urls)
        changed()
        let alert = NSAlert()
        alert.messageText = report.summary
        if !report.failures.isEmpty {
            alert.informativeText = report.failures.prefix(8).map { "\($0.file): \($0.reason)" }.joined(separator: "\n")
                + (report.failures.count > 8 ? "\n...and \(report.failures.count - 8) more." : "")
        }
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    /// Removes a user font's file after confirming how many fonts go with it.
    static func confirmRemove(_ entry: FontEntry, window: NSWindow?) {
        guard entry.source == .user else { NSSound.beep(); return }
        let count = library.fontsSharingFile(with: entry).count
        let alert = NSAlert()
        alert.messageText = "Remove \(entry.fileName)?"
        alert.informativeText = count > 1
            ? "This file holds \(count) fonts; all of them are removed from AnsiView's font folder."
            : "The font \"\(entry.name)\" is removed from AnsiView's font folder."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        let remove = {
            do { try library.remove(entry) } catch { NSAlert(error: error).runModal() }
            changed()
        }
        if let window {
            alert.beginSheetModal(for: window) { if $0 == .alertFirstButtonReturn { remove() } }
        } else if alert.runModal() == .alertFirstButtonReturn {
            remove()
        }
    }
}

/// Small drawing helpers shared by the font windows.
enum TextArtImages {
    /// The cells drawn with AnsiView's renderer (VGA font, 8 pixel cells), or nil when empty.
    static func image(_ region: CanvasRegion, scale: Int = 1) -> NSImage? {
        guard region.width > 0, region.height > 0 else { return nil }
        let screen = AnsiScreen(columns: region.width, rows: region.cells)
        guard let rendered = AnsiRenderer.render(screen, options: RenderOptions(font: .vga, ninePixel: false, scale: scale)) else { return nil }
        return NSImage(cgImage: rendered.image, size: NSSize(width: rendered.image.width, height: rendered.image.height))
    }

    static func png(_ region: CanvasRegion, scale: Int = 2) -> Data? {
        guard region.width > 0, region.height > 0 else { return nil }
        let screen = AnsiScreen(columns: region.width, rows: region.cells)
        guard let rendered = AnsiRenderer.render(screen, options: RenderOptions(font: .vga, ninePixel: false, scale: scale)) else { return nil }
        return NSBitmapImageRep(cgImage: rendered.image).representation(using: .png, properties: [:])
    }

    /// A colour swatch for menus.
    static func swatch(_ index: Int) -> NSImage {
        let c = Palette.vga[index]
        return NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            NSColor(srgbRed: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, alpha: 1).setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 2, yRadius: 2).fill()
            NSColor.separatorColor.setStroke()
            NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 2, yRadius: 2).stroke()
            return true
        }
    }

    static let colourNames = ["Black", "Blue", "Green", "Cyan", "Red", "Magenta", "Brown", "Light grey",
                              "Dark grey", "Light blue", "Light green", "Light cyan", "Light red", "Light magenta",
                              "Yellow", "White"]

    static func colourPopup(selected: Int, tooltip: String) -> NSPopUpButton {
        let popup = NSPopUpButton()
        for index in 0..<16 {
            popup.addItem(withTitle: colourNames[index])
            popup.lastItem?.image = swatch(index)
        }
        popup.selectItem(at: selected)
        popup.toolTip = tooltip
        return popup
    }

    /// A (?) button that shows `text` in a popover.
    static func helpButton(_ text: String, tooltip: String) -> NSButton {
        let button = HelpPopoverButton(text: text)
        button.toolTip = tooltip
        return button
    }
}

/// The round (?) button with its explanation in a popover.
final class HelpPopoverButton: NSButton {
    let text: String

    init(text: String) {
        self.text = text
        super.init(frame: .zero)
        bezelStyle = .helpButton
        title = ""
        target = self
        action = #selector(show(_:))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func show(_ sender: Any?) {
        let label = NSTextField(wrappingLabelWithString: text)
        label.preferredMaxLayoutWidth = 360
        let controller = NSViewController()
        let box = NSView()
        label.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -14),
            label.topAnchor.constraint(equalTo: box.topAnchor, constant: 12),
            label.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -12),
            label.widthAnchor.constraint(equalToConstant: 360),
        ])
        controller.view = box
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
    }
}
