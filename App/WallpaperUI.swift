import AnsiCore
import AppKit
import UniformTypeIdentifiers

extension AnsiCanvasView {
    /// File > Export Wallpaper: the frame on screen as a picture the exact size of a display.
    @objc func exportWallpaper(_ sender: Any?) {
        guard let player, let window else { return }
        WallpaperExport.run(screen: player.screen, in: window)
    }
}

/// The save panel and options behind File > Export Wallpaper (plan 10 ruling 4).
@MainActor
final class WallpaperExport {
    /// A display and its size in pixels.
    struct Display {
        let screen: NSScreen
        let width: Int
        let height: Int
        var label: String { "\(screen.localizedName) (\(width) x \(height) pixels)" }
    }

    static func displays() -> [Display] {
        NSScreen.screens.map { screen in
            Display(screen: screen,
                    width: Int((screen.frame.width * screen.backingScaleFactor).rounded()),
                    height: Int((screen.frame.height * screen.backingScaleFactor).rounded()))
        }
    }

    let displays: [Display]
    let displayPopup: NSPopUpButton
    let modePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let tileSize = NSPopUpButton(frame: .zero, pullsDown: false)
    let setDesktop = NSButton(checkboxWithTitle: "Set as desktop picture for that display", target: nil, action: nil)
    private var target: PopupTarget?

    init(displays: [Display], current: NSScreen?) {
        self.displays = displays
        displayPopup = ExportOptionsView.popup(displays.map(\.label),
                                               selected: displays.firstIndex { $0.screen == current } ?? 0)
        modePopup.addItems(withTitles: WallpaperMode.allCases.map(\.label))
        tileSize.addItems(withTitles: ["1x", "2x", "3x", "4x"])
        setDesktop.state = .off
        setDesktop.toolTip = "After saving, macOS uses the picture as this display's wallpaper. Keep the file where you saved it: macOS reads it from there."
        displayPopup.toolTip = String(localized: "The display whose exact pixel size the picture is made for")
        tileSize.toolTip = String(localized: "Tiled only: how large each copy of the art is drawn")
        modePopup.toolTip = "Centred: the art as large as whole pixels allow, in the middle, on its own background colour. Tiled: copies of the art side by side."
        let target = PopupTarget { [weak self] _ in MainActor.assumeIsolated { self?.updateEnabled() } }
        modePopup.target = target
        modePopup.action = #selector(PopupTarget.changed(_:))
        self.target = target
        updateEnabled()
    }

    var mode: WallpaperMode { WallpaperMode.allCases[max(0, modePopup.indexOfSelectedItem)] }
    var display: Display? { displays.indices.contains(displayPopup.indexOfSelectedItem) ? displays[displayPopup.indexOfSelectedItem] : nil }

    func updateEnabled() { tileSize.isEnabled = mode == .tiled }

    var accessory: NSView {
        let rows: [(String, NSPopUpButton)] = [("Display:", displayPopup), ("Layout:", modePopup), ("Tile Size:", tileSize)]
        return ExportOptionsView.accessory(rows, extra: [[NSView(), setDesktop]])
    }

    static func run(screen: AnsiScreen, in window: NSWindow) {
        let displays = displays()
        guard !displays.isEmpty else { NSSound.beep(); return }
        let options = WallpaperExport(displays: displays, current: window.screen)
        let panel = NSSavePanel()
        panel.accessoryView = options.accessory
        panel.allowedContentTypes = [.png]
        let base = window.representedURL?.deletingPathExtension().lastPathComponent ?? "ANSI Art"
        panel.nameFieldStringValue = base + " wallpaper.png"
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url, let display = options.display else { return }
            do {
                let image = try WallpaperRenderer.image(screen, width: display.width, height: display.height,
                                                        mode: options.mode, scale: options.tileSize.indexOfSelectedItem + 1)
                try WallpaperRenderer.writePNG(image, to: url)
                if options.setDesktop.state == .on {
                    try NSWorkspace.shared.setDesktopImageURL(url, for: display.screen, options: [:])
                }
            } catch {
                NSAlert(error: error).beginSheetModal(for: window)
            }
        }
    }
}
